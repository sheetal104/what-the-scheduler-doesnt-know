#!/usr/bin/env bash
# IRQ observation only: mlx counter snapshot + short bench. NO affinity changes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/shared_lab_common.sh"

MODEL_PATH="${MODEL_PATH:-$TRACELAB_ROOT/data/qwen0.6b}"
ROOT="${ROOT:-$TRACELAB_ROOT/results/kubecon-os/irq_readonly}"
DURATION="${DURATION:-90}"
WARMUP="${WARMUP:-10}"
CONCURRENCY="${CONCURRENCY:-8}"

export MODEL_PATH ROOT
activate_venv
check_gpu_free || true
mkdir -p "$ROOT"
BENCH="$(cd "$SCRIPT_DIR/../../scripts" && pwd)/bench_client.py"

kill_my_vllm
stop_hog
start_vllm_numa "$GPU_NUMA"

pid=$(cat "$(_my_vllm_pidfile)")
snapshot_irq_mlx "$ROOT/interrupts_mlx_t0.txt"
cp /proc/interrupts "$ROOT/interrupts_full_t0.txt"

python3 "$BENCH" \
  --url "http://127.0.0.1:${PORT}/v1/completions" \
  --model "$MODEL_PATH" --model-path "$MODEL_PATH" \
  --warmup "$WARMUP" --duration "$DURATION" --concurrency "$CONCURRENCY" \
  --prompt-tokens 512 --max-tokens 128 \
  --out "$ROOT/bench.jsonl"

snapshot_irq_mlx "$ROOT/interrupts_mlx_t1.txt"
cp /proc/interrupts "$ROOT/interrupts_full_t1.txt"
numastat -p "$pid" >"$ROOT/numastat_p_end.txt" 2>&1 || true
summarize_bench "$ROOT/bench.jsonl" | tee "$ROOT/summary.txt"

if command -v bpftrace >/dev/null && sudo -n true 2>/dev/null; then
  sudo bpftrace -e 'tracepoint:irq:irq_handler_entry { @[cpu] = count(); }
interval:s:10 { print(@); exit(); }' >"$ROOT/bpftrace_irq_10s.txt" 2>&1 || true
else
  echo "bpftrace skipped (no passwordless sudo)" >"$ROOT/bpftrace_irq_10s.txt"
fi

kill_my_vllm
echo "Compare: diff -u $ROOT/interrupts_mlx_t0.txt $ROOT/interrupts_mlx_t1.txt"
echo "Done -> $ROOT"
