#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

source scripts/env.sh

DEFAULT_MODEL_ID="Qwen/Qwen3-VL-2B-Instruct"
LOCAL_MODEL_DIR="models/Qwen3-VL-2B-Instruct"
if [ -d "$LOCAL_MODEL_DIR" ]; then
  MODEL_NAME="${MODEL_NAME:-$LOCAL_MODEL_DIR}"
else
  MODEL_NAME="${MODEL_NAME:-$DEFAULT_MODEL_ID}"
fi
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-$DEFAULT_MODEL_ID}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8000}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-2048}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.60}"
MM_MAX_PIXELS="${MM_MAX_PIXELS:-401408}"

exec vllm serve "$MODEL_NAME" \
  --served-model-name "$SERVED_MODEL_NAME" \
  --host "$HOST" \
  --port "$PORT" \
  --dtype auto \
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
  --max-model-len "$MAX_MODEL_LEN" \
  --max-num-seqs 1 \
  --max-num-batched-tokens "$MAX_MODEL_LEN" \
  --limit-mm-per-prompt '{"image": 1, "video": 0}' \
  --mm-processor-kwargs "{\"max_pixels\": $MM_MAX_PIXELS}" \
  --skip-mm-profiling \
  --enforce-eager
