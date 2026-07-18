#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
godot_exe="/mnt/d/Godot_v4.4-stable_win64.exe/Godot_v4.4-stable_win64.exe"
mock_log="/tmp/godotspace_mock_gateway.log"

source "$repo_root/.venv/bin/activate"
python "$repo_root/scripts/mock_godot_tool_gateway.py" >"$mock_log" 2>&1 &
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
    --script 'res://Assets/ARSpace/Scripts/AI/LocalAgent/local_agent_websocket_self_test.gd'
godot_status=$?
set -e

cat "$mock_log"
exit "$godot_status"
