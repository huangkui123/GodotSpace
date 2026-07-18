#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
godot_exe="/mnt/d/godot_modding/bin/godot.windows.editor.x86_64.llvm.console.exe"
mock_log="/tmp/godotspace_task_agent_remote_gateway.log"
server_log="/tmp/godotspace_task_agent_remote_server.log"
client_log="/tmp/godotspace_task_agent_remote_client.log"

source "$repo_root/.venv/bin/activate"
python "$repo_root/scripts/mock_task_agent_gateway.py" >"$mock_log" 2>&1 &
gateway_pid=$!
"$godot_exe" \
    --headless \
    --path 'F:\GodotSpace\GodotSpace' \
    --script 'res://Assets/ARSpace/Scripts/AI/LocalAgent/task_agent_remote_e2e_self_test.gd' \
    -- --remote-e2e-server >"$server_log" 2>&1 &
server_pid=$!

cleanup() {
    kill "$server_pid" "$gateway_pid" 2>/dev/null || true
    wait "$server_pid" "$gateway_pid" 2>/dev/null || true
}
trap cleanup EXIT

sleep 1
set +e
"$godot_exe" \
    --headless \
    --path 'F:\GodotSpace\GodotSpace' \
    --script 'res://Assets/ARSpace/Scripts/AI/LocalAgent/task_agent_remote_e2e_self_test.gd' \
    -- --remote-e2e-client >"$client_log" 2>&1
client_status=$?
wait "$server_pid"
server_status=$?
wait "$gateway_pid"
gateway_status=$?
set -e

cat "$server_log"
cat "$client_log"
cat "$mock_log"
if [[ $server_status -ne 0 ]]; then
    exit "$server_status"
fi
if [[ $client_status -ne 0 ]]; then
    exit "$client_status"
fi
exit "$gateway_status"
