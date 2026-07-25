#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

export MODEL_SERVER="${MODEL_SERVER:-http://127.0.0.1:18000/v1}"
export MODEL_NAME="${MODEL_NAME:-Qwen/Qwen3-VL-2B-Instruct}"
export VLLM_HEALTH_TIMEOUT="${VLLM_HEALTH_TIMEOUT:-5}"
export AGENT_WARMUP="${AGENT_WARMUP:-1}"

exec bash scripts/start_agent_gateway.sh
