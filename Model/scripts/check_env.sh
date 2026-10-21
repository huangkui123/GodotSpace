#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/env.sh

python - <<'PY'
import torch
import vllm
import qwen_agent
import openai
import PIL
import transformers
import fastapi
import uvicorn

print("python ok")
print("torch:", torch.__version__)
print("cuda available:", torch.cuda.is_available())
if torch.cuda.is_available():
    print("gpu:", torch.cuda.get_device_name(0))
print("vllm:", vllm.__version__)
print("transformers:", transformers.__version__)
print("qwen_agent:", getattr(qwen_agent, "__version__", "unknown"))
print("openai:", openai.__version__)
print("pillow:", PIL.__version__)
print("fastapi:", fastapi.__version__)
print("uvicorn:", uvicorn.__version__)
PY
