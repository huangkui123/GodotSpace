#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pid_file="$repo_root/logs/local_asr.pid"
if [[ ! -f "$pid_file" ]]; then
  echo "Local ASR pid file does not exist."
  exit 0
fi

pid="$(cat "$pid_file")"
if kill -0 "$pid" 2>/dev/null; then
  kill "$pid"
fi
rm -f "$pid_file"
echo "Stopped Local ASR PID $pid."
