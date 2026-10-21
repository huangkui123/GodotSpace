#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
godot_exe="/mnt/d/godot_modding/bin/godot.windows.editor.x86_64.llvm.console.exe"
agent_log="$repo_root/logs/task_agent_live_gateway.log"
vllm_log="$repo_root/logs/task_agent_live_vllm.log"
agent_pid=""
vllm_pid=""

cd "$repo_root"
source scripts/env.sh
mkdir -p logs

cleanup() {
    if [[ -n "$agent_pid" ]]; then
        kill "$agent_pid" 2>/dev/null || true
        wait "$agent_pid" 2>/dev/null || true
    fi
    if [[ -n "$vllm_pid" ]]; then
        kill "$vllm_pid" 2>/dev/null || true
        wait "$vllm_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

wait_for_url() {
    local url="$1"
    local attempts="$2"
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        if curl --silent --fail --max-time 2 "$url" >/dev/null; then
            return 0
        fi
        sleep 2
    done
    return 1
}

wait_for_gateway_ready() {
    local attempts="$1"
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        response="$(curl --silent --fail --max-time 3 http://127.0.0.1:7861/readyz || true)"
        if [[ "$response" == *'"status":"ready"'* ]]; then
            return 0
        fi
        sleep 2
    done
    return 1
}

if ! curl --silent --fail --max-time 2 http://127.0.0.1:8000/v1/models >/dev/null; then
    bash scripts/start_vllm.sh >"$vllm_log" 2>&1 &
    vllm_pid=$!
    if ! wait_for_url http://127.0.0.1:8000/v1/models 150; then
        tail -n 120 "$vllm_log" >&2 || true
        exit 1
    fi
fi

python -m uvicorn agent_service.app:app --host 127.0.0.1 --port 7861 >"$agent_log" 2>&1 &
agent_pid=$!
if ! wait_for_gateway_ready 30; then
    tail -n 120 "$agent_log" >&2 || true
    exit 1
fi

"$godot_exe" \
    --headless \
    --path 'F:\GodotSpace\GodotSpace' \
    --script 'res://Assets/ARSpace/Scripts/AI/LocalAgent/task_agent_e2e_self_test.gd' \
    -- --local-agent-testmode

echo "Live Qwen task Agent smoke test passed."
