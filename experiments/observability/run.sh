#!/usr/bin/env bash
# Short pinned vs overlap capture for workflow artifacts (~4 min each).
set -euo pipefail

SCENARIO="${1:-pinned}"  # pinned | overlap
ROOT="/tmp/kubecon_experiments/workflow_capture/${SCENARIO}"
MODEL="${MODEL:-$HOME/workdir/models/qwen0.6b}"
PORT=8000
export PATH="$HOME/.local/bin:$PATH"
export CUDA_VISIBLE_DEVICES=0

mkdir -p "$ROOT"
kill_vllm() { pkill -f "vllm serve" 2>/dev/null || true; sleep 4; }
stop_hog() {
  pkill -f kubecon_cpu_hog 2>/dev/null || true
  pkill -f "stress-ng --cpu" 2>/dev/null || true
}

start_hog() {
  local cpus="$1"
  for c in $(echo "$cpus" | tr ',' ' '); do
    taskset -c "$c" bash -c 'exec -a kubecon_cpu_hog bash -c "while true; do :; done"' &
  done
}

wait_health() {
  for _ in $(seq 1 120); do
    curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null && return 0
    sleep 2
  done
  return 1
}

kill_vllm
stop_hog

case "$SCENARIO" in
  pinned)
    PIN=(numactl --physcpubind=0-7 --membind=0)
    HOG="8-15"
    ;;
  overlap)
    PIN=()
    HOG="0-7"
    ;;
  *)
    echo "usage: $0 pinned|overlap"; exit 1
    ;;
esac

"${PIN[@]}" vllm serve "$MODEL" --port "$PORT" --max-model-len 4096 \
  --gpu-memory-utilization 0.88 --enforce-eager >>"$ROOT/vllm.log" 2>&1 &
wait_health
start_hog "$HOG"
sleep 2

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts" && pwd)"
ROOT="$ROOT" DURATION=75 INTERVAL=2 bash "$SCRIPT_DIR/workflow_sampler.sh" &
SAMPLER=$!

python3 "$SCRIPT_DIR/bench_client.py" \
  --url "http://127.0.0.1:${PORT}/v1/completions" \
  --model "$MODEL" --model-path "$MODEL" \
  --warmup 10 --duration 70 --concurrency 16 \
  --prompt-tokens 512 --max-tokens 128 \
  --out "$ROOT/bench.jsonl" || true

wait "$SAMPLER" 2>/dev/null || true
nvidia-smi dmon -s u -d 1 -c 30 >"$ROOT/dmon.txt" &
DM=$!
sleep 32
wait $DM 2>/dev/null || true

stop_hog
kill_vllm
echo "workflow capture $SCENARIO -> $ROOT"
