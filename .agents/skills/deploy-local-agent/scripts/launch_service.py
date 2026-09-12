"""Foreground Linux/WSL launcher; no installs, daemonization or process killing."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import socket
import sys

from deployment_check import DEFAULT_MODEL_ID, PORTS, port_number, repository


def build(args: argparse.Namespace, inherited: dict[str, str]) -> tuple[list[str], dict[str, str]]:
    root = repository(args.repo)
    backend = root / "Model"
    env_dir = Path(args.env_dir).absolute()
    python = env_dir / "bin/python"
    if not python.is_file():
        raise ValueError("Missing Linux venv/bin/python; do not use a Windows virtualenv.")
    if args.service in ("vllm", "gateway") and not args.model_id:
        raise ValueError("--model-id is required for vLLM/Gateway.")
    env = dict(inherited)
    env.update(PYTHONUNBUFFERED="1", HF_ENDPOINT="https://huggingface.co")
    port = args.port or PORTS["model" if args.service == "vllm" else args.service]
    argv = [str(python), "-m", "uvicorn", f"{args.service}_service.app:app",
            "--host", "127.0.0.1", "--port", str(port)]
    if args.service == "vllm":
        if not args.model_path or not Path(args.model_path).is_dir():
            raise ValueError("--model-path must identify downloaded local model files.")
        if not 0 < args.gpu_memory_utilization < 1 or args.max_model_len < 512:
            raise ValueError("Invalid GPU allocation or context length.")
        executable = env_dir / "bin/vllm"
        if not executable.is_file():
            raise ValueError("vLLM executable missing in selected environment.")
        argv = [str(executable), "serve", str(Path(args.model_path).resolve()),
                "--served-model-name", args.model_id, "--host", "127.0.0.1",
                "--port", str(port), "--dtype", args.dtype,
                "--gpu-memory-utilization", str(args.gpu_memory_utilization),
                "--max-model-len", str(args.max_model_len), "--max-num-seqs", "1",
                "--max-num-batched-tokens", str(args.max_model_len),
                "--limit-mm-per-prompt", '{"image": 1, "video": 0}',
                "--mm-processor-kwargs", '{"max_pixels": 401408}',
                "--skip-mm-profiling", "--enforce-eager"]
        libraries = sorted(str(path) for path in env_dir.glob(
            "lib/python*/site-packages/nvidia/**/lib") if path.is_dir())
        if libraries:
            env["LD_LIBRARY_PATH"] = ":".join(libraries + [env.get("LD_LIBRARY_PATH", "")])
        env["HF_HUB_OFFLINE"] = "1"
        env["TRANSFORMERS_OFFLINE"] = "1"
    elif args.service == "gateway":
        argv[3] = "agent_service.app:app"
        env.update(MODEL_NAME=args.model_id, MODEL_SERVER=f"http://127.0.0.1:{args.model_port}/v1",
                   API_KEY="EMPTY", MODEL_TYPE="qwenvl_oai", MODEL_USE_RAW_API="0",
                   MODEL_FNCALL_PROMPT_TYPE="nous")
    elif args.service == "asr":
        env.update(FUNASR_DEVICE=args.asr_device, FUNASR_WARMUP="1", FUNASR_PRELOAD="1",
                   FUNASR_MODEL=args.asr_model, FUNASR_VAD_MODEL=args.vad_model,
                   MODELSCOPE_CACHE=str(backend / "models/funasr"))
    elif args.service == "tts":
        env.update(LOCAL_TTS_MODEL_DIR=str(backend / "models/tts/vits-icefall-zh-aishell3"),
                   LOCAL_TTS_THREADS="2")
        argv.append("--no-access-log")
    return argv, env


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("service", choices=("vllm", "gateway", "asr", "tts"))
    parser.add_argument("--repo")
    parser.add_argument("--env-dir", required=True)
    parser.add_argument("--port", type=port_number)
    parser.add_argument("--model-port", type=port_number, default=8000)
    parser.add_argument("--model-id", default=DEFAULT_MODEL_ID)
    parser.add_argument("--model-path")
    parser.add_argument("--dtype", choices=("auto", "bfloat16", "float16"), default="bfloat16")
    parser.add_argument("--max-model-len", type=int, default=8192)
    parser.add_argument("--gpu-memory-utilization", type=float, default=0.75)
    parser.add_argument("--asr-device", choices=("cpu", "cuda"), default="cpu")
    parser.add_argument("--asr-model", default="paraformer-zh-streaming")
    parser.add_argument("--vad-model", default="fsmn-vad")
    return parser.parse_args(argv)


def main() -> int:
    args = parse_args()
    if sys.platform != "linux":
        print("Run this launcher inside Linux/WSL, not Windows Python.", file=sys.stderr)
        return 2
    try:
        argv, env = build(args, dict(os.environ))
        port = args.port or PORTS["model" if args.service == "vllm" else args.service]
        # A later race is handled by the actual server bind; never evict the listener.
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", port))
        os.chdir(repository(args.repo) / "Model")
        os.execve(argv[0], argv, env)
    except (OSError, ValueError) as exc:
        print(f"Cannot launch {args.service}: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
