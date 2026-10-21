#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ -f .venv/bin/activate ]; then
  source .venv/bin/activate
fi

site_packages="$(python - <<'PY'
import site
print(site.getsitepackages()[0])
PY
)"

nvidia_libs=(
  "$site_packages/nvidia/cu13/lib"
  "$site_packages/nvidia/cu13/cccl/lib"
  "$site_packages/nvidia/cublas/lib"
  "$site_packages/nvidia/cuda_cupti/lib"
  "$site_packages/nvidia/cuda_nvrtc/lib"
  "$site_packages/nvidia/cuda_runtime/lib"
  "$site_packages/nvidia/cudnn/lib"
  "$site_packages/nvidia/cufft/lib"
  "$site_packages/nvidia/cufile/lib"
  "$site_packages/nvidia/curand/lib"
  "$site_packages/nvidia/cusolver/lib"
  "$site_packages/nvidia/cusparse/lib"
  "$site_packages/nvidia/cusparselt/lib"
  "$site_packages/nvidia/nccl/lib"
  "$site_packages/nvidia/nvjitlink/lib"
  "$site_packages/nvidia/nvshmem/lib"
  "$site_packages/nvidia/nvtx/lib"
)

joined_libs="$(IFS=:; echo "${nvidia_libs[*]}")"
export LD_LIBRARY_PATH="$joined_libs:${LD_LIBRARY_PATH:-}"
export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
export HF_HUB_ENABLE_HF_TRANSFER="${HF_HUB_ENABLE_HF_TRANSFER:-0}"
export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}"
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
export PYTHONUNBUFFERED="${PYTHONUNBUFFERED:-1}"
