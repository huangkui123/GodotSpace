#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gateway_url="${AGENT_GATEWAY_URL:-http://127.0.0.1:7861}"

cd "$repo_root"
source scripts/env.sh

ready="$(curl --silent --fail --max-time 5 "$gateway_url/readyz")"
if [[ "$ready" != *'"status":"ready"'* ]]; then
    echo "Agent Gateway is not ready: $ready" >&2
    exit 1
fi

python scripts/test_qwen_tool_routing_live.py
bash scripts/test_assistant_command_router.sh

"${GODOT_EXE:-/mnt/d/godot_modding/bin/godot.windows.editor.x86_64.llvm.console.exe}" \
    --headless \
    --path 'F:\GodotSpace\GodotSpace' \
    --script 'res://Assets/ARSpace/Scripts/AI/LocalAgent/task_agent_e2e_self_test.gd' \
    -- --local-agent-testmode

echo "Qwen routing and Godot headless regression passed."
