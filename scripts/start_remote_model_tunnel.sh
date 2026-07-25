#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p logs

remote_host="${REMOTE_HOST:-lab_4090}"
local_port="${LOCAL_MODEL_PORT:-18000}"
remote_port="${REMOTE_VLLM_PORT:-18000}"
pid_file="logs/remote_vllm_tunnel.pid"
log_file="logs/remote_vllm_tunnel.log"

if [[ -f "$pid_file" ]]; then
  old_pid="$(cat "$pid_file")"
  if kill -0 "$old_pid" 2>/dev/null; then
    echo "Remote model tunnel already running with PID $old_pid."
    exit 0
  fi
  rm -f "$pid_file"
fi

nohup ssh \
  -o BatchMode=yes \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -N \
  -L "127.0.0.1:$local_port:127.0.0.1:$remote_port" \
  "$remote_host" >"$log_file" 2>&1 &
pid="$!"
echo "$pid" >"$pid_file"

for _ in $(seq 1 20); do
  if curl --silent --fail --max-time 2 \
    "http://127.0.0.1:$local_port/v1/models" >/dev/null; then
    echo "Remote model tunnel ready on http://127.0.0.1:$local_port/v1"
    exit 0
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "SSH tunnel exited unexpectedly. See $log_file." >&2
    exit 1
  fi
  sleep 1
done

echo "SSH tunnel is running, but the remote model is not ready yet." >&2
exit 1
