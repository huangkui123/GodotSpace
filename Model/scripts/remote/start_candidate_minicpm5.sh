#!/usr/bin/env bash
set -euo pipefail

bench_root="${MODEL_BENCH_ROOT:-$HOME/local-agent-model-bench}"
model_dir="${REMOTE_MODEL_DIR:-$bench_root/models/MiniCPM5-1B}"

export CUDA_VISIBLE_DEVICES="${REMOTE_GPU:-4}"
export PYTHONUNBUFFERED=1
export PATH="$bench_root/.venv-sglang/bin:$PATH"

exec "$bench_root/.venv-sglang/bin/sglang" serve \
  --model-path "$model_dir" \
  --served-model-name "${SERVED_MODEL_NAME:-openbmb/MiniCPM5-1B}" \
  --host 127.0.0.1 \
  --port "${REMOTE_MODEL_PORT:-18200}" \
  --tool-call-parser minicpm5 \
  --context-length "${MAX_MODEL_LEN:-16384}" \
  --mem-fraction-static "${GPU_MEMORY_UTILIZATION:-0.25}" \
  --max-running-requests 1 \
  --disable-cuda-graph
