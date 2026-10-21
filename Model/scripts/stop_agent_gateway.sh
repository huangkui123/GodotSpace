#!/usr/bin/env bash
set -euo pipefail

pkill -f "uvicorn agent_service.app:app" >/dev/null 2>&1 || true
echo "Stopped matching Agent Gateway processes."
