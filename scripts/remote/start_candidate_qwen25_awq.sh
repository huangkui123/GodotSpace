#!/usr/bin/env bash
set -euo pipefail

bench_root="${MODEL_BENCH_ROOT:-$HOME/local-agent-model-bench}"
runtime_root="${REMOTE_VLLM_DIR:-$HOME/local-agent-qwen}"
model_dir="${REMOTE_MODEL_DIR:-$bench_root/models/Qwen2.5-1.5B-Instruct-AWQ}"

export CUDA_VISIBLE_DEVICES="${REMOTE_GPU:-3}"
export PYTHONUNBUFFERED=1
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"

exec "$runtime_root/.venv/bin/vllm" serve "$model_dir" \
  --served-model-name "${SERVED_MODEL_NAME:-Qwen/Qwen2.5-1.5B-Instruct-AWQ}" \
  --host 127.0.0.1 \
  --port "${REMOTE_MODEL_PORT:-18100}" \
  --dtype auto \
  --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION:-0.25}" \
  --max-model-len "${MAX_MODEL_LEN:-16384}" \
  --max-num-seqs 1 \
  --max-num-batched-tokens "${MAX_MODEL_LEN:-16384}" \
  --enforce-eager
