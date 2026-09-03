#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

export MODEL_SERVER="${MODEL_SERVER:-http://127.0.0.1:18400/v1}"
export MODEL_NAME="${MODEL_NAME:-Qwen/Qwen3-VL-8B-Instruct-FP8}"
export MODEL_TYPE="${MODEL_TYPE:-qwenvl_oai}"
export MODEL_FNCALL_PROMPT_TYPE="${MODEL_FNCALL_PROMPT_TYPE:-nous}"
export MODEL_ENABLE_THINKING="${MODEL_ENABLE_THINKING:-false}"
export VLLM_HEALTH_TIMEOUT="${VLLM_HEALTH_TIMEOUT:-5}"
export AGENT_WARMUP="${AGENT_WARMUP:-1}"
export AGENT_MAX_MESSAGE_CHARS="${AGENT_MAX_MESSAGE_CHARS:-40000}"

exec bash scripts/start_agent_gateway.sh
