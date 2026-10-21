#!/usr/bin/env bash
set -euo pipefail

bench_root="${MODEL_BENCH_ROOT:-$HOME/local-agent-model-bench}"

stop_candidate() {
  local name="$1"
  local expected_fragment="$2"
  local pid_file="$bench_root/pids/${name}_server.pid"
  [[ -f "$pid_file" ]] || return 0
  local pid
  pid="$(cat "$pid_file")"
  if kill -0 "$pid" 2>/dev/null; then
    local command
    command="$(tr '\0' ' ' <"/proc/$pid/cmdline")"
    if [[ "$command" != *"$expected_fragment"* ]]; then
      echo "Refusing to stop unexpected PID $pid: $command" >&2
      return 1
    fi
    kill "$pid"
    for _ in $(seq 1 30); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "Candidate PID $pid did not stop within 30 seconds." >&2
      return 1
    fi
  fi
  rm -f "$pid_file"
}

stop_candidate qwen25 "Qwen2.5-1.5B-Instruct-AWQ"
stop_candidate minicpm5 "MiniCPM5-1B"
stop_candidate qwen3vl "Qwen3-VL-2B-Instruct-FP8"
echo "Remote candidate model services stopped."
