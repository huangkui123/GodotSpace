#!/usr/bin/env bash
set -euo pipefail

godot_exe="/mnt/d/godot_modding/bin/godot.windows.editor.x86_64.llvm.console.exe"
test_script="${1:-assistant_command_router_self_test.gd}"

"$godot_exe" \
    --headless \
    --path 'F:\GodotSpace\GodotSpace' \
    --script "res://Assets/ARSpace/Scripts/AI/LocalAgent/$test_script" \
    -- --local-agent-testmode
