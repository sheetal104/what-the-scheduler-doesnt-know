#!/usr/bin/env bash
# Two-arm CPU placement @ 7B (or any MODEL_PATH): pinned vs overlap. Polite dual-NUMA defaults.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared_lab_common.sh
source "$SCRIPT_DIR/shared_lab_common.sh"

MODEL_PATH="${MODEL_PATH:-$TRACELAB_ROOT/data/qwen2.5-coder-7b}"
ROOT="${ROOT:-$TRACELAB_ROOT/results/kubecon-os/placement_7b}"
DURATION="${DURATION:-120}"
WARMUP="${WARMUP:-15}"
CONCURRENCY="${CONCURRENCY:-8}"
MEMBIND_LOCAL="${GPU_NUMA}"

export MODEL_PATH ROOT
activate_venv
check_gpu_free || true

mkdir -p "$ROOT"
BENCH="$(cd "$SCRIPT_DIR/../../scripts" && pwd)/bench_client.py"
[[ -f "$BENCH" ]] || BENCH="$TRACELAB_ROOT/scripts/remote/bench_client.py"

if [[ ! -d "$MODEL_PATH" || ! -f "$MODEL_PATH/config.json" ]]; then
  echo "Set MODEL_PATH or run: bash download_model_hf.sh" >&2
  exit 1
fi

BASE_ROOT="$ROOT"

run_arm() {
  local arm="$1"
  local out="$BASE_ROOT/$arm"
  export ROOT="$out"
  mkdir -p "$out"
  stop_hog
  kill_my_vllm

  echo "=== $arm $(date -Iseconds) GPU=$CUDA_VISIBLE_DEVICES PORT=$PORT ===" | tee "$out/run.log"

  case "$arm" in
    pinned_production)
      start_vllm_numa "$MEMBIND_LOCAL"
      start_hog "$CPUS_HOG"
      ;;
    overlap_worst)
      start_vllm_unpinned
      start_hog "$CPUS_VLLM"
      ;;
    *)
      echo "unknown arm $arm"; exit 1
      ;;
  esac

  sleep 2
  pid=$(cat "$(_my_vllm_pidfile)" 2>/dev/null || pgrep -u "$(id -u)" -f "vllm serve.*${PORT}" | head -1)
  numastat -p "$pid" >"$out/numastat_p_start.txt" 2>&1 || true

  nvidia-smi dmon -s u -d 1 -c 30 >"$out/dmon.txt" &
  dmon_pid=$!

  python3 "$BENCH" \
    --url "http://127.0.0.1:${PORT}/v1/completions" \
    --model "$MODEL_PATH" --model-path "$MODEL_PATH" \
    --warmup "$WARMUP" --duration "$DURATION" --concurrency "$CONCURRENCY" \
    --prompt-tokens 512 --max-tokens 128 \
    --out "$out/bench.jsonl"

  wait "$dmon_pid" 2>/dev/null || true
  numastat -p "$pid" >"$out/numastat_p_end.txt" 2>&1 || true
  grep -E 'voluntary_ctxt_switches|nonvoluntary_ctxt_switches' "/proc/$pid/status" >"$out/ctxt_switches.txt" 2>&1 || true

  stop_hog
  kill_my_vllm
  summarize_bench "$out/bench.jsonl" | tee "$out/summary.txt"
}

numactl -H | tee "$BASE_ROOT/numactl_H.txt"
run_arm pinned_production
run_arm overlap_worst
echo "Done -> $BASE_ROOT"
