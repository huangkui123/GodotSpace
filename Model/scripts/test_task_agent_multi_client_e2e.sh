#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
godot_exe="/mnt/d/godot_modding/bin/godot.windows.editor.x86_64.llvm.console.exe"
mock_log="/tmp/godotspace_task_agent_multi_gateway.log"
server_log="/tmp/godotspace_task_agent_multi_server.log"
client1_log="/tmp/godotspace_task_agent_multi_client1.log"
client2_log="/tmp/godotspace_task_agent_multi_client2.log"

source "$repo_root/.venv/bin/activate"
TASK_AGENT_SCENARIO=multi python "$repo_root/scripts/mock_task_agent_gateway.py" >"$mock_log" 2>&1 &
gateway_pid=$!
"$godot_exe" --headless --path 'F:\GodotSpace\GodotSpace' \
    --script 'res://Assets/ARSpace/Scripts/AI/LocalAgent/task_agent_multi_client_e2e_self_test.gd' \
    -- --multi-e2e-server >"$server_log" 2>&1 &
server_pid=$!

cleanup() {
    kill "$server_pid" "$gateway_pid" ${client1_pid:-} ${client2_pid:-} 2>/dev/null || true
    wait "$server_pid" "$gateway_pid" ${client1_pid:-} ${client2_pid:-} 2>/dev/null || true
}
trap cleanup EXIT

sleep 1
"$godot_exe" --headless --path 'F:\GodotSpace\GodotSpace' \
    --script 'res://Assets/ARSpace/Scripts/AI/LocalAgent/task_agent_multi_client_e2e_self_test.gd' \
    -- --multi-e2e-client-1 >"$client1_log" 2>&1 &
client1_pid=$!
sleep 0.5
"$godot_exe" --headless --path 'F:\GodotSpace\GodotSpace' \
    --script 'res://Assets/ARSpace/Scripts/AI/LocalAgent/task_agent_multi_client_e2e_self_test.gd' \
    -- --multi-e2e-client-2 >"$client2_log" 2>&1 &
client2_pid=$!

set +e
wait "$client1_pid"; client1_status=$?
wait "$client2_pid"; client2_status=$?
wait "$server_pid"; server_status=$?
wait "$gateway_pid"; gateway_status=$?
set -e

cat "$server_log"
cat "$client1_log"
cat "$client2_log"
cat "$mock_log"
for status in "$server_status" "$client1_status" "$client2_status" "$gateway_status"; do
    if [[ $status -ne 0 ]]; then
        exit "$status"
    fi
done
