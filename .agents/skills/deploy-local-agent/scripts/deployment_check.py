"""Read-only inventory, loopback readiness checks and opt-in synthetic smoke."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import platform
import shutil
import socket
import subprocess
import sys
import time
import urllib.request

PORTS = {"model": 8000, "gateway": 7861, "asr": 8765, "tts": 8767}
DEFAULT_MODEL_ID = "Qwen/Qwen3-VL-8B-Instruct"
REQUIRED = ("Model/agent_service/app.py", "GodotSpace/project.godot")


def repository(path: str | None = None) -> Path:
    root = Path(path).resolve() if path else Path(__file__).resolve().parents[4]
    if not all((root / item).is_file() for item in REQUIRED):
        raise ValueError("Expected full GodotSpace monorepo (GodotSpace/ and Model/).")
    return root


def command(args: list[str], cwd: Path | None = None) -> dict:
    try:
        result = subprocess.run(args, cwd=cwd, capture_output=True, text=True,
                                encoding="utf-8", errors="replace", timeout=20)
        return {"code": result.returncode, "output": result.stdout.strip(),
                "error": result.stderr.strip()}
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"code": -1, "error": str(exc)}


def port_open(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            return True
    except OSError:
        return False


def lfs_pointers(root: Path) -> dict:
    result = command(["git", "lfs", "ls-files", "--name-only"], root)
    if result["code"] != 0:
        return {"checked": False, "detail": result.get("error", "")}
    pointers = []
    missing = []
    for name in result["output"].splitlines():
        candidate = (root / name).resolve()
        # Do not follow a repository symlink outside the checkout.
        if root not in candidate.parents:
            continue
        try:
            with candidate.open("rb") as source:
                if source.read(128).startswith(b"version https://git-lfs.github.com/spec/v1"):
                    pointers.append(name)
        except OSError:
            missing.append(name)
    return {"checked": True, "pointers": pointers, "missing": missing}


def inventory(root: Path, ports: dict) -> dict:
    return {
        "kind": "inventory_only_not_readiness", "repo": str(root),
        "platform": platform.platform(), "python": sys.version.split()[0],
        "disk_free_gib": round(shutil.disk_usage(root).free / 2**30, 2),
        "git": command(["git", "status", "--short", "--branch"], root),
        "commit": command(["git", "rev-parse", "HEAD"], root),
        "gpu": command(["nvidia-smi", "--query-gpu=name,memory.total,memory.free,driver_version",
                        "--format=csv,noheader"]),
        "loopback_ports_open": {name: port_open(port) for name, port in ports.items()},
        "lfs": lfs_pointers(root),
        "notes": ["Open port does not establish service identity.",
                  "ASR 8765 may conflict with optional Depth Pro.",
                  "Windows-to-WSL forwarding and Pico require separate checks."],
    }


def request(port: int, path: str, payload: dict | None = None, timeout: int = 10):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data,
                                 headers={"Content-Type": "application/json"})
    # Loopback must not be routed through a configured external proxy.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req, timeout=timeout) as response:
        return response.read(4 * 1024 * 1024), response.headers


def fetch_json(port: int, path: str) -> dict:
    data, _ = request(port, path)
    result = json.loads(data)
    if not isinstance(result, dict):
        raise ValueError("Expected a JSON object.")
    return result


def assess(payloads: dict, model_id: str) -> dict[str, bool]:
    models = payloads.get("model", {}).get("data", [])
    model_found = isinstance(models, list) and any(
        isinstance(item, dict) and item.get("id") == model_id for item in models)
    gateway = payloads.get("gateway", {})
    identity = payloads.get("gateway_identity", {})
    asr = payloads.get("asr", {})
    tts = payloads.get("tts", {})
    return {
        "model": model_found,
        "gateway": identity.get("service") == "godotspace-local-agent"
        and gateway.get("status") == "ready" and gateway.get("model") == model_id
        and all(gateway.get(key) is True for key in ("vllm", "model_found", "qwen_agent")),
        "asr": asr.get("service") == "local-funasr" and asr.get("status") == "ready"
        and asr.get("vad_loaded") is True and asr.get("warmed_up") is True,
        "tts": tts.get("service") == "local-tts" and tts.get("status") == "ready"
        and tts.get("device") in ("cpu", "cuda"),
    }


def services(ports: dict, model_id: str) -> dict:
    payloads, errors = {}, {}
    routes = {"model": ("model", "/v1/models"),
              "gateway_identity": ("gateway", "/healthz"),
              "gateway": ("gateway", "/readyz"),
              "asr": ("asr", "/health"), "tts": ("tts", "/health")}
    for name, (service, route) in routes.items():
        try:
            payloads[name] = fetch_json(ports[service], route)
        except (OSError, ValueError) as exc:
            errors[name] = type(exc).__name__
    checks = assess(payloads, model_id)
    gateway = payloads.get("gateway", {})
    return {"ok": all(checks.values()), "checks": checks, "errors": errors,
            "expected_model": model_id,
            "asr_model": payloads.get("asr", {}).get("model"),
            "asr_device": payloads.get("asr", {}).get("device"),
            "godot_connected": gateway.get("godot_connected") is True,
            "note": "Backend readiness only; Godot tools and physical audio not verified."}


def smoke(ports: dict, model_id: str) -> dict:
    started = time.monotonic()
    body, _ = request(ports["model"], "/v1/chat/completions",
                      {"model": model_id, "messages": [{"role": "user", "content": "只回答：部署测试"}],
                       "max_tokens": 32, "temperature": 0}, timeout=120)
    reply = json.loads(body)["choices"][0]["message"]["content"]
    if not isinstance(reply, str) or not reply.strip():
        raise ValueError("Model returned no textual content.")
    inference_seconds = time.monotonic() - started
    started = time.monotonic()
    pcm, headers = request(ports["tts"], "/v1/speech", {"text": "智能助手，部署测试。"}, timeout=30)
    rate = int(headers.get("X-Sample-Rate", "0"))
    if (headers.get("X-Audio-Format") != "pcm_s16le" or not 8000 <= rate <= 192000
            or len(pcm) % 2 or len(pcm) <= rate // 5 or not any(pcm)):
        raise ValueError("Invalid or silent PCM response.")
    return {"model_text_nonempty": True, "model_seconds": round(inference_seconds, 3),
            "tts_seconds": round(time.monotonic() - started, 3),
            "tts_sample_rate": rate, "tts_audio_seconds": round(len(pcm) / 2 / rate, 3),
            "note": "Synthetic HTTP smoke; no ASR, Godot tool or Pico assertion."}


def port_number(value: str) -> int:
    number = int(value)
    if not 1 <= number <= 65535:
        raise argparse.ArgumentTypeError("Port must be 1..65535.")
    return number


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("inventory", "services", "smoke"))
    parser.add_argument("--repo")
    parser.add_argument("--model-id", default=DEFAULT_MODEL_ID)
    for name, default in PORTS.items():
        parser.add_argument(f"--{name}-port", type=port_number, default=default)
    args = parser.parse_args()
    ports = {name: getattr(args, f"{name}_port") for name in PORTS}
    if len(set(ports.values())) != len(ports):
        parser.error("Service ports must be distinct.")
    if args.action != "inventory" and not args.model_id:
        parser.error("--model-id must not be empty.")
    try:
        if args.action == "inventory":
            result = inventory(repository(args.repo), ports)
        else:
            result = services(ports, args.model_id)
            if args.action == "smoke" and result["ok"]:
                result["synthetic_smoke"] = smoke(ports, args.model_id)
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0 if result.get("ok", True) else 1
    except (OSError, ValueError, KeyError, IndexError, TypeError) as exc:
        print(json.dumps({"ok": False, "error": type(exc).__name__, "detail": str(exc)},
                         ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
