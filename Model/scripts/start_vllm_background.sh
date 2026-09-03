#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

mkdir -p logs

if [ -f logs/vllm.pid ]; then
  old_pid="$(cat logs/vllm.pid)"
  if [ -n "$old_pid" ] && kill -0 "$old_pid" >/dev/null 2>&1; then
    echo "vLLM already appears to be running with PID $old_pid"
    exit 0
  fi
fi

if [ -f .venv/bin/activate ]; then
  source .venv/bin/activate
fi

nohup bash scripts/start_vllm.sh > logs/vllm.log 2>&1 &
pid="$!"
echo "$pid" > logs/vllm.pid
echo "Started vLLM with PID $pid"
echo "Log: logs/vllm.log"

