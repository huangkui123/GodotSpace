#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

sudo apt-get update
sudo apt-get install -y build-essential ca-certificates curl git

if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

uv venv --python 3.12 --seed --managed-python --clear
source .venv/bin/activate

uv pip install --upgrade pip setuptools wheel
uv pip install "vllm==0.11.0" --torch-backend=cu126
uv pip install \
  "qwen-agent==0.0.34" \
  "transformers==4.57.1" \
  "qwen-vl-utils>=0.0.14" \
  "openai>=1.50.0" \
  "fastapi>=0.115.0,<1.0.0" \
  "uvicorn[standard]>=0.30.0,<1.0.0" \
  "json5>=0.9.0" \
  "pillow>=10.0.0" \
  "requests>=2.31.0" \
  "soundfile>=0.12.0" \
  "python-dateutil>=2.8.0"

python - <<'PY'
import torch
print("torch:", torch.__version__)
print("cuda available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("gpu:", torch.cuda.get_device_name(0))
PY

echo "Bootstrap complete. Activate with: source .venv/bin/activate"
