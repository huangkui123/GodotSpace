#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
pid_file="logs/remote_vllm_tunnel.pid"

if [[ ! -f "$pid_file" ]]; then
  echo "No remote model tunnel PID file found."
  exit 0
fi

pid="$(cat "$pid_file")"
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid"
  wait "$pid" 2>/dev/null || true
fi
rm -f "$pid_file"
echo "Remote model tunnel stopped."
