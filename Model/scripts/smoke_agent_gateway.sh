#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/env.sh

mkdir -p logs

vllm_pid=""
agent_pid=""

cleanup() {
  if [ -n "$agent_pid" ]; then
    kill "$agent_pid" >/dev/null 2>&1 || true
    wait "$agent_pid" >/dev/null 2>&1 || true
  fi
  if [ -n "$vllm_pid" ]; then
    kill "$vllm_pid" >/dev/null 2>&1 || true
    wait "$vllm_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

wait_for_url() {
  local url="$1"
  local process_id="$2"
  local label="$3"
  local attempts="$4"
  local delay_seconds="$5"

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if curl --silent --fail --max-time 2 "$url" >/dev/null; then
      echo "$label is ready after $attempt checks."
      return 0
    fi
    if ! kill -0 "$process_id" >/dev/null 2>&1; then
      echo "$label exited before becoming ready." >&2
      return 1
    fi
    sleep "$delay_seconds"
  done

  echo "$label did not become ready after $attempts checks." >&2
  return 1
}

echo "Starting temporary vLLM smoke-test process..."
bash scripts/start_vllm.sh >logs/vllm_smoke.log 2>&1 &
vllm_pid="$!"
if ! wait_for_url "http://127.0.0.1:8000/v1/models" "$vllm_pid" "vLLM" 150 2; then
  tail -n 120 logs/vllm_smoke.log >&2 || true
  exit 1
fi

echo "Starting temporary Agent Gateway smoke-test process..."
python -m uvicorn agent_service.app:app --host 127.0.0.1 --port 7861 \
  >logs/agent_gateway_smoke.log 2>&1 &
agent_pid="$!"
if ! wait_for_url "http://127.0.0.1:7861/healthz" "$agent_pid" "Agent Gateway" 30 1; then
  tail -n 120 logs/agent_gateway_smoke.log >&2 || true
  exit 1
fi

python scripts/check_agent_gateway.py
echo "Agent Gateway smoke test passed."
