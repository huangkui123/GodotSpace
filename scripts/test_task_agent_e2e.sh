#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
godot_exe="/mnt/d/godot_modding/bin/godot.windows.editor.x86_64.llvm.console.exe"
mock_log="/tmp/godotspace_task_agent_gateway.log"

source "$repo_root/.venv/bin/activate"
python "$repo_root/scripts/mock_task_agent_gateway.py" >"$mock_log" 2>&1 &
server_pid=$!

cleanup() {
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT

sleep 1
set +e
"$godot_exe" \
    --headless \
    --path 'F:\GodotSpace\GodotSpace' \
    --script 'res://Assets/ARSpace/Scripts/AI/LocalAgent/task_agent_e2e_self_test.gd' \
    -- --local-agent-testmode
godot_status=$?
wait "$server_pid"
gateway_status=$?
set -e

cat "$mock_log"
if [[ $godot_status -ne 0 ]]; then
    exit "$godot_status"
fi
exit "$gateway_status"
