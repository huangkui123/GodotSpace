#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
mkdir -p logs

pid_file="logs/local_asr.pid"
log_file="logs/local_asr.log"
if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
  echo "Local ASR is already running with PID $(cat "$pid_file")."
  exit 0
fi

nohup bash scripts/start_local_asr.sh >"$log_file" 2>&1 &
echo $! >"$pid_file"
echo "Started Local ASR with PID $!. Log: $log_file"
