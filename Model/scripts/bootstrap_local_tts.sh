#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
python_bin="${TTS_PYTHON:-$repo_root/.venv/bin/python}"
if [[ ! -x "$python_bin" ]]; then
  python_bin="python3.12"
fi
"$python_bin" -m venv .venv-tts
.venv-tts/bin/python -m pip install -r requirements-tts.txt
.venv-tts/bin/python scripts/download_tts_model.py
