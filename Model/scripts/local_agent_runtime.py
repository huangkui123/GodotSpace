"""Host-scoped startup controller. Never installs, evicts or stops a service."""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import time
import urllib.request


def write_status(path: Path, state: str, message: str, **extra: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(dict(state=state, message=message, **extra)), encoding="utf-8")
    temp.replace(path)


def get_json(port: int, path: str) -> dict:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=2) as response:
        return json.loads(response.read(65536))


def port_open(port: int) -> bool:
    with socket.socket() as sock:
        sock.settimeout(0.2)
        return sock.connect_ex(("127.0.0.1", port)) == 0


def validate_port(value: object) -> int:
    if type(value) is not int or not 1024 <= value <= 65535:
        raise ValueError("Service ports must be integers in 1024..65535")
    return value


def service_specs(config: dict, role: str, mode: str) -> list[dict]:
    result = []
    if role in ("server", "server_voice"):
        model = dict(config["compute"][mode])
        model.setdefault("model_id", "Qwen/Qwen3-VL-8B-Instruct")
        model["port"] = validate_port(model.get("port", 8000 if mode == "local" else 18000))
        result.append(dict(model, service="vllm" if mode == "local" else "remote"))
        result.append(dict(service="gateway", env_dir=config["gateway_env"],
                           model_id=model["model_id"], model_port=model["port"],
                           port=validate_port(model.get("gateway_port", 7861 if mode == "local" else 7862))))
    if role in ("client", "server_voice", "asr"):
        for name, port in (("asr", 8765), ("tts", 8767)):
            if role == "asr" and name != "asr":
                continue
            spec = dict(config[name], service=name)
            spec["port"] = validate_port(spec.get("port", port))
            result.append(spec)
    if len({s["port"] for s in result}) != len(result):
        raise ValueError("Service ports overlap")
    return result


def fingerprint(spec: dict) -> str:
    return hashlib.sha256(json.dumps(spec, sort_keys=True).encode()).hexdigest()


def process_token(pid: int) -> str:
    try:
        # /proc stat field 22, after the potentially space-containing comm.
        return Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19]
    except (OSError, IndexError):
        return ""


def ownership_path(port: int) -> Path:
    return Path.home() / f".cache/godotspace-local-agent/port-{port}.json"


def live_owner_fingerprint(port: int) -> str:
    try:
        record = json.loads(ownership_path(port).read_text())
        token = process_token(record["pid"])
        return str(record["fingerprint"]) if token and token == record["token"] else ""
    except (OSError, ValueError, KeyError, TypeError):
        return ""


def matching_owner(spec: dict) -> bool:
    return live_owner_fingerprint(spec["port"]) == fingerprint(spec)


def ready(spec: dict) -> bool:
    name, port = spec["service"], spec["port"]
    try:
        if name in ("vllm", "remote"):
            return spec["model_id"] in [m.get("id") for m in get_json(port, "/v1/models").get("data", [])]
        if name == "gateway":
            data = get_json(port, "/readyz")
            return (data.get("status") == "ready" and data.get("model") == spec["model_id"]
                    and data.get("runtime_id") == fingerprint(spec))
        data = get_json(port, "/health")
        if data.get("status") != "ready":
            return False
        if name == "asr":
            return (data.get("service") == "local-funasr" and data.get("vad_loaded")
                    and data.get("warmed_up") and data.get("device") == spec.get("asr_device", "cpu")
                    and data.get("model") == spec["asr_model"] and data.get("vad_model") == spec["vad_model"])
        return (data.get("service") == "local-tts" and data.get("device") == spec.get("tts_device", "cpu")
                and data.get("speaker") == spec.get("speaker", 17)
                and data.get("model") == spec.get("model", "kokoro-int8-multi-lang-v1_1"))
    except (OSError, ValueError, KeyError, TypeError):
        return False


def command(spec: dict, repo: Path) -> tuple[list[str], dict[str, str]]:
    if spec["service"] == "remote":
        # SSH alias configured once by deployment. No password or remote shell.
        alias = spec.get("ssh_host", "")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", alias):
            raise ValueError("Remote compute requires a trusted SSH config alias")
        remote_port = validate_port(spec.get("remote_port", 8000))
        return ["ssh", "-N", "-T", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
                "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
                "-L", f"127.0.0.1:{spec['port']}:127.0.0.1:{remote_port}", alias], dict(os.environ)
    sys.path.insert(0, str(repo / ".agents/skills/deploy-local-agent/scripts"))
    from launch_service import build, parse_args
    allowed = {"env_dir", "port", "model_id", "model_port", "model_path", "dtype", "max_model_len",
               "gpu_memory_utilization", "asr_device", "asr_model", "vad_model", "tts_device"}
    args = [spec["service"], "--repo", str(repo)]
    for key in allowed:
        if key in spec:
            args.extend(["--" + key.replace("_", "-"), str(spec[key])])
    argv, env = build(parse_args(args), dict(os.environ))
    env["LOCAL_AGENT_RUNTIME_ID"] = fingerprint(spec)
    if spec["service"] == "tts":
        env["LOCAL_TTS_SPEAKER"] = str(spec.get("speaker", 17))
        env["LOCAL_TTS_MODEL_DIR"] = str(spec["model_dir"])
        env["LOCAL_TTS_MODEL"] = "kokoro"
        env["LOCAL_TTS_DEVICE"] = spec.get("tts_device", "cpu")
    return argv, env


@contextlib.contextmanager
def host_lock(timeout: float = 650):
    # All checkouts/processes of this OS user share the lock, not just one repo.
    path = Path.home() / ".cache/godotspace-local-agent/start.lock"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("Another startup is still running")
                time.sleep(0.2)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def ensure(spec: dict, repo: Path, status: Path, timeout: float = 600) -> str:
    name = spec["service"]
    owner = live_owner_fingerprint(spec["port"])
    if owner and owner != fingerprint(spec):
        raise RuntimeError(f"{name}: another managed configuration is still running/starting; no process stopped")
    if ready(spec):
        if name == "remote" and not matching_owner(spec):
            raise RuntimeError("Remote tunnel identity cannot be verified; use a free configured local port")
        return "reused"
    if matching_owner(spec):
        write_status(status, "starting", f"Waiting for existing {name} startup")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and matching_owner(spec):
            if ready(spec):
                return "reused"
            time.sleep(0.5)
        raise TimeoutError(f"Existing {name} not ready; inspect its log")
    if port_open(spec["port"]):
        raise RuntimeError(f"{name}: port {spec['port']} occupied by unready/different configuration; no process stopped")
    argv, env = command(spec, repo)
    logs = repo / "Model/logs/local-agent-deploy"
    logs.mkdir(parents=True, exist_ok=True)
    log = logs / f"{name}-{spec['port']}.log"
    write_status(status, "starting", f"Starting {name}; log: {log.name}")
    with log.open("ab") as output:
        process = subprocess.Popen(argv, cwd=repo / "Model", env=env, stdin=subprocess.DEVNULL,
                                   stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
    # Record ownership for diagnostics only. Exiting Godot never kills shared services.
    record = repo / f"Model/generated/local-agent-deploy/{name}-{spec['port']}.json"
    write_status(record, "started", name, pid=process.pid, started_at=time.time(), argv=argv,
                 fingerprint=fingerprint(spec), log=str(log))
    owner = ownership_path(spec["port"])
    write_status(owner, "started", name, pid=process.pid, token=process_token(process.pid),
                 fingerprint=fingerprint(spec))
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"{name} exited ({process.returncode}); inspect {log.name}")
        if ready(spec):
            return "started"
        time.sleep(0.5)
    raise TimeoutError(f"{name} startup timed out; process left running, inspect {log.name}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--status", type=Path, required=True)
    parser.add_argument("--role", choices=("server", "client", "server_voice", "asr"), required=True)
    parser.add_argument("--mode", choices=("local", "remote"), default="local")
    parser.add_argument("--require-windows-check", action="store_true")
    args = parser.parse_args()
    try:
        write_status(args.status, "starting", "Checking host services / waiting for startup lock")
        config = json.loads(args.config.read_text(encoding="utf-8-sig"))
        specs = service_specs(config, args.role, args.mode)
        results = {}
        with host_lock():
            for spec in specs:
                results[spec["service"]] = ensure(spec, args.repo, args.status)
        endpoints = {}
        checks = []
        for spec in specs:
            name, port = spec["service"], spec["port"]
            if name == "gateway":
                endpoints["GODOTSPACE_AGENT_ENDPOINT"] = f"ws://127.0.0.1:{port}/ws/godot"
            elif name == "asr":
                endpoints["LOCAL_ASR_ENDPOINT"] = f"ws://127.0.0.1:{port}/ws/asr"
                endpoints["GODOT_ASR_PROVIDER"] = "funasr"
            elif name == "tts":
                endpoints["GODOTSPACE_TTS_ENDPOINT"] = f"http://127.0.0.1:{port}/v1/speech"
            if name in ("gateway", "asr", "tts"):
                path = "/readyz" if name == "gateway" else "/health"
                health = get_json(port, path)
                expected = {k: health[k] for k in ("status", "service", "model", "runtime_id", "device", "speaker", "vad_loaded", "warmed_up") if k in health}
                checks.append(dict(url=f"http://127.0.0.1:{port}{path}", expected=expected))
        write_status(args.status, "verifying" if args.require_windows_check else "ready",
                     "Checking Windows localhost forwarding" if args.require_windows_check else "Local Agent services ready",
                     endpoints=endpoints, services=results, health_checks=checks)
        return 0
    except Exception as exc:
        write_status(args.status, "failed", str(exc))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
