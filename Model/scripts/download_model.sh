#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/env.sh

MODEL_ID="${MODEL_ID:-Qwen/Qwen3-VL-2B-Instruct}"
LOCAL_MODEL_DIR="${LOCAL_MODEL_DIR:-models/Qwen3-VL-2B-Instruct}"

mkdir -p "$(dirname "$LOCAL_MODEL_DIR")"

hf download "$MODEL_ID" \
  --local-dir "$LOCAL_MODEL_DIR"

echo "Downloaded $MODEL_ID to $LOCAL_MODEL_DIR"

