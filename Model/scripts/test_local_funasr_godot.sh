#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sample="$(find /root/.cache/modelscope/models -name asr_example.wav -print -quit)"
if [[ -z "$sample" ]]; then
  echo "FunASR example WAV was not found. Start the Local ASR service once first." >&2
  exit 1
fi

mkdir -p "$repo_root/generated"
target="$repo_root/generated/local_asr_smoke.wav"
cp "$sample" "$target"
windows_target="$(wslpath -w "$target")"
windows_target="${windows_target//\\//}"
godot_exe="/mnt/d/godot_modding/bin/godot.windows.editor.x86_64.llvm.console.exe"

"$godot_exe" \
  --headless \
  --path 'F:\GodotSpace\GodotSpace' \
  --script 'res://Assets/ARSpace/Scripts/Network/local_funasr_e2e_self_test.gd' \
  -- "--local-asr-test-wav=$windows_target"
