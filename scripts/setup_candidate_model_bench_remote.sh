#!/usr/bin/env bash
set -euo pipefail

bench_root="${MODEL_BENCH_ROOT:-$HOME/local-agent-model-bench}"
hf_endpoint="${HF_ENDPOINT:-https://hf-mirror.com}"
hub_python="${REMOTE_VLLM_DIR:-$HOME/local-agent-qwen}/.venv/bin/python"
uv_bin="${UV_BIN:-/snap/bin/uv}"
pypi_index="${PYPI_INDEX_URL:-https://mirrors.aliyun.com/pypi/simple/}"

mkdir -p "$bench_root/models" "$bench_root/logs" "$bench_root/pids" "$bench_root/results"

HF_ENDPOINT="$hf_endpoint" HF_HUB_DOWNLOAD_TIMEOUT=120 "$hub_python" - <<'PY'
from huggingface_hub import snapshot_download
from pathlib import Path
import os

root = Path(os.environ.get("MODEL_BENCH_ROOT", Path.home() / "local-agent-model-bench"))
models = [
    (
        "Qwen/Qwen2.5-1.5B-Instruct-AWQ",
        "3ecffa0ceb27851800f45519bab9c457a04405e1",
        root / "models" / "Qwen2.5-1.5B-Instruct-AWQ",
    ),
    (
        "openbmb/MiniCPM5-1B",
        "4e9de7a0778dc1c362e983e6858f0e77542cbdca",
        root / "models" / "MiniCPM5-1B",
    ),
]
for repo_id, revision, local_dir in models:
    snapshot_download(
        repo_id=repo_id,
        revision=revision,
        local_dir=local_dir,
    )
PY

if [[ ! -x "$bench_root/.venv-sglang/bin/python" ]]; then
  "$uv_bin" venv --python /usr/bin/python3 "$bench_root/.venv-sglang"
fi
"$uv_bin" pip install \
  --prerelease=allow \
  --index-url "$pypi_index" \
  --python "$bench_root/.venv-sglang/bin/python" \
  sglang==0.5.16 \
  kernels==0.14.1

# SGLang 0.5.12 installed a separately versioned cubin bundle. SGLang 0.5.16's
# FlashInfer 0.6.14 no longer depends on it and rejects the stale 0.6.11 bundle.
"$uv_bin" pip uninstall \
  --python "$bench_root/.venv-sglang/bin/python" \
  flashinfer-cubin 2>/dev/null || true
