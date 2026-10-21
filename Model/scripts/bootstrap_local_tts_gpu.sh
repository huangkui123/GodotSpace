#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
tts_env="${TTS_GPU_ENV:-$repo_root/.venv-tts-gpu}"
python_bin="${TTS_PYTHON:-$repo_root/.venv/bin/python}"
if [[ ! -x "$python_bin" ]]; then python_bin="python3.12"; fi
if [[ -e "$tts_env" && "${TTS_RESUME_INSTALL:-0}" != 1 ]]; then
  echo "Environment exists. Inspect it, then use TTS_RESUME_INSTALL=1 to resume this installation." >&2
  exit 1
fi
if [[ ! -e "$tts_env" ]]; then "$python_bin" -m venv "$tts_env"; fi
"$tts_env/bin/python" -m pip install -r requirements-tts-gpu.txt
"$tts_env/bin/python" scripts/install_tts_cuda_runtime.py
"$tts_env/bin/python" -m pip check
"$tts_env/bin/python" scripts/download_tts_model.py --model kokoro-cuda
LOCAL_TTS_DEVICE=cuda "$tts_env/bin/python" -c 'from tts_service.engine import SpeechEngine; e=SpeechEngine(); e.load(); assert e.loaded; print(e.model_name, e.device)'
