#!/usr/bin/env bash
set -euo pipefail

godot_exe="/mnt/d/godot_modding/bin/godot.windows.editor.x86_64.llvm.console.exe"
server_log="/tmp/godotspace_assistant_history_server.log"
client1_log="/tmp/godotspace_assistant_history_client1.log"
client2_log="/tmp/godotspace_assistant_history_client2.log"
test_script="res://Assets/ARSpace/Scripts/AI/LocalAgent/assistant_history_multi_client_self_test.gd"

"$godot_exe" --headless --path 'F:\GodotSpace\GodotSpace' \
    --script "$test_script" -- --history-server >"$server_log" 2>&1 &
server_pid=$!

cleanup() {
    kill "$server_pid" ${client1_pid:-} ${client2_pid:-} 2>/dev/null || true
    wait "$server_pid" ${client1_pid:-} ${client2_pid:-} 2>/dev/null || true
}
trap cleanup EXIT

sleep 1
"$godot_exe" --headless --path 'F:\GodotSpace\GodotSpace' \
    --script "$test_script" -- --history-client-1 >"$client1_log" 2>&1 &
client1_pid=$!
sleep 0.5
"$godot_exe" --headless --path 'F:\GodotSpace\GodotSpace' \
    --script "$test_script" -- --history-client-2 >"$client2_log" 2>&1 &
client2_pid=$!

set +e
wait "$client1_pid"; client1_status=$?
wait "$client2_pid"; client2_status=$?
wait "$server_pid"; server_status=$?
set -e

cat "$server_log"
cat "$client1_log"
cat "$client2_log"
for status in "$server_status" "$client1_status" "$client2_status"; do
    if [[ $status -ne 0 ]]; then
        exit "$status"
    fi
done
