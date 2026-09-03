#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

pkill -f "vllm serve|VLLM::EngineCore" >/dev/null 2>&1 || true

if [ ! -f logs/vllm.pid ]; then
  echo "Stopped matching vLLM processes. No logs/vllm.pid found."
  exit 0
fi

pid="$(cat logs/vllm.pid)"
if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
  kill "$pid"
  echo "Stopped vLLM PID $pid"
else
  echo "vLLM PID $pid is not running."
fi

rm -f logs/vllm.pid
echo "Stopped matching vLLM processes."
