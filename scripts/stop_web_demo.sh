#!/usr/bin/env bash
set -euo pipefail

pkill -f "uvicorn web_demo.app:app" >/dev/null 2>&1 || true
echo "Stopped matching web demo processes."

