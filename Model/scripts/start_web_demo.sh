#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/env.sh

HOST="${WEB_HOST:-127.0.0.1}"
PORT="${WEB_PORT:-7860}"

exec python -m uvicorn web_demo.app:app --host "$HOST" --port "$PORT"

