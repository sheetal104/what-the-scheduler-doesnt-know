#!/usr/bin/env bash
set -euo pipefail
DEST="${DEST:-$HOME/workdir/models/qwen0.6b}"
REPO="${REPO:-Qwen/Qwen3-0.6B}"

export HF_HUB_DISABLE_XET=1
export HF_HUB_ENABLE_HF_TRANSFER=0

rm -rf "$DEST"
mkdir -p "$DEST"

if command -v hf >/dev/null; then
  hf download "$REPO" --local-dir "$DEST"
elif command -v huggingface-cli >/dev/null; then
  huggingface-cli download "$REPO" \
    --local-dir "$DEST" \
    --local-dir-use-symlinks False \
    --resume-download
else
  python3 <<PY
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id="${REPO}",
    local_dir="${DEST}",
    local_dir_use_symlinks=False,
    max_workers=4,
)
PY
fi

"$(dirname "$0")/verify_model.sh" "$DEST"
