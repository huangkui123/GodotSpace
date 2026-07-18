#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/env.sh

HOST="${AGENT_HOST:-127.0.0.1}"
PORT="${AGENT_PORT:-7861}"

exec python -m uvicorn agent_service.app:app --host "$HOST" --port "$PORT"
