#!/usr/bin/env bash
set -euo pipefail

godot_exe="/mnt/d/godot_modding/bin/godot.windows.editor.x86_64.llvm.console.exe"

"$godot_exe" \
    --headless \
    --path 'F:\GodotSpace\GodotSpace' \
    --script 'res://Assets/ARSpace/Scripts/AI/llm_assistant_voice_panel_self_test.gd'
