#!/usr/bin/env bash
set -euo pipefail

output_path="${1:?usage: sample_candidate_gpus.sh OUTPUT_CSV}"
interval_seconds="${SAMPLE_INTERVAL_SECONDS:-0.2}"

printf 'timestamp_ms,gpu_index,memory_used_mib,memory_free_mib,utilization_gpu_percent\n' >"$output_path"
while true; do
  timestamp_ms="$(date +%s%3N)"
  nvidia-smi \
    --id=3,4,5 \
    --query-gpu=index,memory.used,memory.free,utilization.gpu \
    --format=csv,noheader,nounits \
    | sed "s/^/$timestamp_ms,/" >>"$output_path"
  sleep "$interval_seconds"
done
