#!/usr/bin/env bash
# Exit 0 only if vLLM can load weights from DIR.
DIR="${1:-$HOME/workdir/models/qwen0.6b}"
echo "Checking $DIR"
test -f "$DIR/config.json" || { echo "MISSING config.json"; exit 1; }
shards=$(find "$DIR" -maxdepth 1 -name '*.safetensors' 2>/dev/null | wc -l)
bin=$(find "$DIR" -maxdepth 1 -name '*.bin' 2>/dev/null | wc -l)
echo "safetensors shards: $shards  pytorch .bin: $bin"
if [[ "$shards" -eq 0 && "$bin" -eq 0 ]]; then
  echo "MISSING weight files — re-download with HF_HUB_DISABLE_XET=1"
  exit 1
fi
du -sh "$DIR"
ls -lh "$DIR"/*.safetensors 2>/dev/null | head -5
echo "OK"
