#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

candidate="${1:?usage: start_candidate_model_tunnel.sh qwen25|minicpm5|qwen3vl|qwen3vl8b}"
case "$candidate" in
  qwen25) local_port=18100; remote_port=18100 ;;
  minicpm5) local_port=18200; remote_port=18200 ;;
  qwen3vl) local_port=18300; remote_port=18300 ;;
  qwen3vl8b) local_port=18400; remote_port=18400 ;;
  *) echo "Unknown candidate: $candidate" >&2; exit 2 ;;
esac

mkdir -p logs
remote_host="${REMOTE_HOST:-lab_4090}"
identity_file="${SSH_IDENTITY_FILE:-/tmp/lab_4090_codex_key}"
pid_file="logs/${candidate}_model_tunnel.pid"
log_file="logs/${candidate}_model_tunnel.log"

if [[ -f "$pid_file" ]]; then
  old_pid="$(cat "$pid_file")"
  if kill -0 "$old_pid" 2>/dev/null; then
    echo "$candidate tunnel already running with PID $old_pid."
    exit 0
  fi
  rm -f "$pid_file"
fi

ssh_args=(
  -o BatchMode=yes
  -o ExitOnForwardFailure=yes
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
)
if [[ -f "$identity_file" ]]; then
  ssh_args+=( -i "$identity_file" )
fi

nohup setsid ssh \
  "${ssh_args[@]}" \
  -N \
  -L "127.0.0.1:$local_port:127.0.0.1:$remote_port" \
  "$remote_host" >"$log_file" 2>&1 &
pid="$!"
echo "$pid" >"$pid_file"
echo "$candidate tunnel started with PID $pid on port $local_port."
