#!/usr/bin/env bash
# User-level HF download (venv with huggingface_hub). No admin.
set -euo pipefail

REPO="${1:-Qwen/Qwen2.5-Coder-7B-Instruct}"
DEST="${2:-$HOME/tracelab-vllm-experiments/data/qwen2.5-coder-7b}"

export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}"
mkdir -p "$DEST"

python3 -c "
from huggingface_hub import snapshot_download
snapshot_download('${REPO}', local_dir='${DEST}')
"
test -f "$DEST/config.json" && echo "OK -> $DEST"
