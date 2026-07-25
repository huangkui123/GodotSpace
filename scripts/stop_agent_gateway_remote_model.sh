#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
pid_file="logs/agent_gateway_remote_model.pid"

if [[ ! -f "$pid_file" ]]; then
  echo "No remote-model Gateway PID file found."
  exit 0
fi

gateway_pid="$(cat "$pid_file")"
if kill -0 "$gateway_pid" 2>/dev/null; then
  kill "$gateway_pid"
  wait "$gateway_pid" 2>/dev/null || true
fi
rm -f "$pid_file"
echo "Remote-model Gateway stopped."
