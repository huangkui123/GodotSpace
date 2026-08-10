#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

candidate="${1:?usage: start_candidate_agent_gateway.sh qwen25|minicpm5|qwen3vl}"
case "$candidate" in
  qwen25)
    model_port=18100
    gateway_port=7862
    model_name="Qwen/Qwen2.5-1.5B-Instruct-AWQ"
    use_raw_api=false
    ;;
  minicpm5)
    model_port=18200
    gateway_port=7863
    model_name="openbmb/MiniCPM5-1B"
    use_raw_api=true
    ;;
  qwen3vl)
    model_port=18300
    gateway_port=7864
    model_name="Qwen/Qwen3-VL-2B-Instruct"
    model_type="qwenvl_oai"
    use_raw_api=false
    ;;
  *) echo "Unknown candidate: $candidate" >&2; exit 2 ;;
esac

mkdir -p logs
pid_file="logs/${candidate}_agent_gateway.pid"
log_file="logs/${candidate}_agent_gateway.log"
if [[ -f "$pid_file" ]]; then
  old_pid="$(cat "$pid_file")"
  if kill -0 "$old_pid" 2>/dev/null; then
    echo "$candidate Gateway already running with PID $old_pid."
    exit 0
  fi
  rm -f "$pid_file"
fi

export MODEL_SERVER="http://127.0.0.1:$model_port/v1"
export MODEL_NAME="$model_name"
export MODEL_TYPE="${model_type:-oai}"
export MODEL_USE_RAW_API="$use_raw_api"
export MODEL_FNCALL_PROMPT_TYPE=nous
export MODEL_ENABLE_THINKING=false
export VLLM_HEALTH_TIMEOUT=5
export AGENT_WARMUP=0
export AGENT_HOST=127.0.0.1
export AGENT_PORT="$gateway_port"
export AGENT_MAX_MESSAGE_CHARS=40000

nohup bash scripts/start_agent_gateway.sh >"$log_file" 2>&1 &
pid="$!"
echo "$pid" >"$pid_file"
echo "$candidate Gateway started with PID $pid on port $gateway_port."
