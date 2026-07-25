#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

remote_host="${REMOTE_HOST:-lab_4090}"
remote_dir="${REMOTE_VLLM_DIR:-/home/admin/local-agent-qwen}"
local_model_dir="${LOCAL_MODEL_DIR:-models/Qwen3-VL-2B-Instruct-FP8}"
remote_model_dir="$remote_dir/models/Qwen3-VL-2B-Instruct-FP8"
pypi_index_url="${PYPI_INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"
transformers_version="${TRANSFORMERS_VERSION:-4.57.1}"
weight_file="model-00001-of-00001.safetensors"
model_revision="${MODEL_REVISION:-46485250d8854c0a9be4f1adbc67ca47e5bb6fa5}"
weight_url="${MODEL_WEIGHT_URL:-https://hf-mirror.com/Qwen/Qwen3-VL-2B-Instruct-FP8/resolve/$model_revision/$weight_file?download=true}"

if [[ ! -f "$local_model_dir/config.json" || ! -f "$local_model_dir/$weight_file" ]]; then
  echo "Model not found: $local_model_dir" >&2
  exit 1
fi

ssh "$remote_host" \
  "mkdir -p '$remote_dir/bin' '$remote_dir/logs' '$remote_model_dir' ~/.config/systemd/user"

uv_version="$(ssh "$remote_host" 'command -v uv || command -v /snap/bin/uv')"
ssh "$remote_host" \
  "'$uv_version' venv '$remote_dir/.venv' --python /usr/bin/python3 && \
   UV_HTTP_TIMEOUT=120 '$uv_version' pip install \
     --index-url '$pypi_index_url' \
     --python '$remote_dir/.venv/bin/python' \
     'vllm==0.11.0' 'transformers==$transformers_version' 'huggingface-hub<1.0'"

rsync -a --exclude='.cache/' --exclude='*.safetensors' \
  "$local_model_dir/" "$remote_host:$remote_model_dir/"
ssh "$remote_host" \
  "cd '$remote_model_dir' && \
   aria2c --continue=true --max-connection-per-server=16 --split=16 \
     --min-split-size=4M --file-allocation=none \
     --out='$weight_file' '$weight_url'"

expected_size="$(stat -c '%s' "$local_model_dir/$weight_file")"
actual_size="$(ssh "$remote_host" "stat -c '%s' '$remote_model_dir/$weight_file'")"
if [[ "$actual_size" != "$expected_size" ]]; then
  echo "Remote weight size mismatch: expected $expected_size, got $actual_size" >&2
  exit 1
fi

rsync -a scripts/remote/start_vllm.sh \
  "$remote_host:$remote_dir/bin/start_vllm.sh"
rsync -a scripts/remote/qwen-vllm.service \
  "$remote_host:~/.config/systemd/user/qwen-vllm.service"

ssh "$remote_host" \
  "chmod 755 '$remote_dir/bin/start_vllm.sh' && \
   systemctl --user daemon-reload && \
   systemctl --user enable --now qwen-vllm.service"

echo "Remote vLLM deployment started on $remote_host."
echo "Check with: ssh $remote_host systemctl --user status qwen-vllm.service"
