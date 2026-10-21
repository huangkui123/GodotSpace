#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

for candidate in qwen25 minicpm5 qwen3vl; do
  for component in agent_gateway model_tunnel; do
    pid_file="logs/${candidate}_${component}.pid"
    [[ -f "$pid_file" ]] || continue
    pid="$(cat "$pid_file")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid"
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$pid_file"
  done
done

echo "Candidate Gateways and SSH tunnels stopped."
