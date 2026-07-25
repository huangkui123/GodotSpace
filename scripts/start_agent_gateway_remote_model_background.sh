#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p logs

pid_file="logs/agent_gateway_remote_model.pid"
log_file="logs/agent_gateway_remote_model.log"

if [[ -f "$pid_file" ]]; then
  existing_pid="$(cat "$pid_file")"
  if kill -0 "$existing_pid" 2>/dev/null; then
    echo "Remote-model Gateway already running with PID $existing_pid."
    exit 0
  fi
  rm -f "$pid_file"
fi

nohup bash scripts/start_agent_gateway_remote_model.sh >"$log_file" 2>&1 &
gateway_pid="$!"
echo "$gateway_pid" >"$pid_file"
echo "Remote-model Gateway started with PID $gateway_pid."
