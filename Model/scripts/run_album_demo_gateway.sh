#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$repo_root/.venv/bin/activate"
exec python "$repo_root/scripts/demo_godot_album_gateway.py"
