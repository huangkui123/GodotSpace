#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
if [[ ! -x .venv-tts/bin/python ]]; then
  echo "Run bash scripts/bootstrap_local_tts.sh first." >&2
  exit 1
fi
# Keep the unauthenticated service private; do not expose it to the LAN.
exec .venv-tts/bin/python -m uvicorn tts_service.app:app --host 127.0.0.1 --port "${LOCAL_TTS_PORT:-8767}" --no-access-log
