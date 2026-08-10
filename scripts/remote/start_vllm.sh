#!/usr/bin/env bash
set -euo pipefail

install_dir="${REMOTE_VLLM_DIR:-$HOME/local-agent-qwen}"
model_dir="${REMOTE_MODEL_DIR:-$install_dir/models/Qwen3-VL-2B-Instruct-FP8}"

export CUDA_VISIBLE_DEVICES="${REMOTE_GPU:-2}"
export PYTHONUNBUFFERED=1
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"

exec "$install_dir/.venv/bin/vllm" serve "$model_dir" \
  --served-model-name "${SERVED_MODEL_NAME:-Qwen/Qwen3-VL-2B-Instruct}" \
  --host 127.0.0.1 \
  --port "${REMOTE_VLLM_PORT:-18000}" \
  --dtype auto \
  --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION:-0.30}" \
  --max-model-len "${MAX_MODEL_LEN:-16384}" \
  --max-num-seqs 1 \
  --max-num-batched-tokens "${MAX_MODEL_LEN:-16384}" \
  --limit-mm-per-prompt '{"image": 1, "video": 0}' \
  --mm-processor-kwargs '{"max_pixels": 401408}' \
  --skip-mm-profiling \
  --enforce-eager
