#!/usr/bin/env bash
set -euo pipefail

runtime_root="${REMOTE_VLLM_DIR:-$HOME/local-agent-qwen}"
model_dir="${REMOTE_MODEL_DIR:-$runtime_root/models/Qwen3-VL-8B-Instruct-FP8}"

export CUDA_VISIBLE_DEVICES="${REMOTE_GPU:-2}"
export PYTHONUNBUFFERED=1
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"

exec "$runtime_root/.venv/bin/vllm" serve "$model_dir" \
  --served-model-name "${SERVED_MODEL_NAME:-Qwen/Qwen3-VL-8B-Instruct-FP8}" \
  --host 127.0.0.1 \
  --port "${REMOTE_MODEL_PORT:-18400}" \
  --dtype auto \
  --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION:-0.60}" \
  --max-model-len "${MAX_MODEL_LEN:-8192}" \
  --max-num-seqs 1 \
  --max-num-batched-tokens "${MAX_MODEL_LEN:-8192}" \
  --limit-mm-per-prompt '{"image": 1, "video": 0}' \
  --mm-processor-kwargs '{"max_pixels": 401408}' \
  --enable-auto-tool-choice \
  --tool-call-parser hermes \
  --skip-mm-profiling \
  --enforce-eager
