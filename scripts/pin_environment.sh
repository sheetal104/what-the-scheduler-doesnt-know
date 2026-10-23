#!/usr/bin/env bash
# Idempotent environment checks for machine-a (or same SKU).
set -euo pipefail

export PATH="${HOME}/.local/bin:${PATH}"
MODEL="${MODEL:-$HOME/workdir/models/qwen0.6b}"

ok=true
check() { if eval "$2"; then echo "OK  $1"; else echo "FAIL $1"; ok=false; fi; }

check "nvidia-smi" "command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1"
check "numactl" "command -v numactl >/dev/null"
check "stress-ng" "command -v stress-ng >/dev/null"
check "python3.10-dev" "test -f /usr/include/python3.10/Python.h"
check "vllm" "python3 -c 'import vllm; assert vllm.__version__.startswith(\"0.31\")'"
check "model weights" "test -f '$MODEL/model.safetensors'"
check "aiohttp" "python3 -c 'import aiohttp'"

if $ok; then
  echo "Environment pinned and ready."
  exit 0
fi
echo "Fix failures above before run_realistic.sh"
exit 1
