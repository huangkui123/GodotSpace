#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
tts_env=".venv-tts"
if [[ "${LOCAL_TTS_DEVICE:-cpu}" == cuda ]]; then tts_env=".venv-tts-gpu"; fi
if [[ ! -x "$tts_env/bin/python" ]]; then
  echo "Bootstrap the selected CPU/GPU TTS environment first." >&2
  exit 1
fi
# Keep the unauthenticated service private; do not expose it to the LAN.
exec "$tts_env/bin/python" -m uvicorn tts_service.app:app --host 127.0.0.1 --port "${LOCAL_TTS_PORT:-8767}" --no-access-log
