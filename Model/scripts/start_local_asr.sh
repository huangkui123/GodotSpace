#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ ! -x .venv/bin/python ]]; then
  echo "Missing Linux virtual environment. Run scripts/bootstrap_wsl.sh first." >&2
  exit 1
fi

host="${LOCAL_ASR_HOST:-127.0.0.1}"
port="${LOCAL_ASR_PORT:-8765}"
exec .venv/bin/python -m uvicorn asr_service.app:app --host "$host" --port "$port"
