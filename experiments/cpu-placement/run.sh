#!/usr/bin/env bash
# Industry-shaped serving load: 512-token prefill, 128-token decode, concurrency 16,
# 40-request warmup, 5-minute measurement window per arm.
set -euo pipefail

ROOT="${ROOT:-/tmp/kubecon_experiments/realistic}"
MODEL="${MODEL:-$HOME/workdir/models/qwen0.6b}"
PORT="${PORT:-8000}"
GPU="${CUDA_VISIBLE_DEVICES:-0}"
PROMPT_TOKENS="${PROMPT_TOKENS:-512}"
MAX_TOKENS="${MAX_TOKENS:-128}"
WARMUP="${WARMUP:-40}"
LOAD_SEC="${LOAD_SEC:-300}"
CONCURRENCY="${CONCURRENCY:-16}"
HEALTH_WAIT_SEC="${HEALTH_WAIT_SEC:-2400}"
VLLM_CPUS_ALL="${VLLM_CPUS_ALL:-0-15}"
VLLM_CPUS_PINNED="${VLLM_CPUS_PINNED:-0-7}"
HOG_CPUS_OTHER="${HOG_CPUS_OTHER:-8-15}"
HOG_CPUS_OVERLAP="${HOG_CPUS_OVERLAP:-0-7}"

mkdir -p "$ROOT"
export CUDA_VISIBLE_DEVICES="$GPU"
export HF_HUB_DISABLE_XET=1
export HF_HUB_ENABLE_HF_TRANSFER=0
export PATH="$HOME/.local/bin:$PATH"

log() { echo "[$(date -Iseconds)] $*" | tee -a "$ROOT/run.log"; }

kill_vllm() {
  pkill -f "vllm serve" 2>/dev/null || true
  pkill -f "vllm.entrypoints" 2>/dev/null || true
  sleep 5
}

stop_hog() {
  pkill -f kubecon_cpu_hog 2>/dev/null || true
  pkill -f "stress-ng --cpu" 2>/dev/null || true
}

start_hog_cpus() {
  local cpus="$1"
  stop_hog
  if command -v stress-ng >/dev/null; then
    stress-ng --cpu "$(echo "$cpus" | tr ',' ' ' | wc -w)" --cpu-method matrixprod --taskset "$cpus" --timeout "${LOAD_SEC}s" --metrics-brief &
    return
  fi
  for c in $(echo "$cpus" | tr ',' ' '); do
    taskset -c "$c" bash -c 'exec -a kubecon_cpu_hog bash -c "while true; do :; done"' &
  done
}

wait_health() {
  local vpid="$1"
  local deadline=$((SECONDS + HEALTH_WAIT_SEC))
  while (( SECONDS < deadline )); do
    kill -0 "$vpid" 2>/dev/null || return 1
    curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1 && return 0
    curl -sf "http://127.0.0.1:${PORT}/v1/models" >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}

run_arm() {
  local name="$1"
  local pin_cpus="$2"  # empty = no pin
  local hog_cpus="$3"  # empty = no hog
  local bench_out="$ROOT/${name}_bench.jsonl"
  local vllm_log="$ROOT/vllm_${name}.log"

  log "=== $name pin=${pin_cpus:-none} hog=${hog_cpus:-none} ==="
  kill_vllm
  stop_hog
  sleep 2

  local -a numa=()
  if [[ -n "$pin_cpus" ]]; then
    numa=(numactl --physcpubind="$pin_cpus" --membind=0)
  fi

  "${numa[@]}" vllm serve "$MODEL" \
    --port "$PORT" \
    --max-model-len 4096 \
    --gpu-memory-utilization 0.88 \
    --enforce-eager \
    >>"$vllm_log" 2>&1 &
  local vpid=$!
  if ! wait_health "$vpid"; then
    log "vLLM failed for $name"
    tail -60 "$vllm_log" >> "$ROOT/errors.log"
    return 1
  fi

  if [[ -n "$hog_cpus" ]]; then
    start_hog_cpus "$hog_cpus"
    sleep 3
  fi

  nvidia-smi dmon -s u -d 1 -c 60 >"$ROOT/${name}_dmon.txt" &
  local dmon_pid=$!
  numastat -n >"$ROOT/${name}_numastat_n.txt" 2>&1 || true
  numastat -p "$vpid" >"$ROOT/${name}_numastat_p.txt" 2>&1 || true

  MODEL="$MODEL" LOCAL_MODEL_DIR="$MODEL" python3 "$ROOT/bench_client.py" \
    --url "http://127.0.0.1:${PORT}/v1/completions" \
    --model "$MODEL" \
    --model-path "$MODEL" \
    --prompt-tokens "$PROMPT_TOKENS" \
    --max-tokens "$MAX_TOKENS" \
    --warmup "$WARMUP" \
    --duration "$LOAD_SEC" \
    --concurrency "$CONCURRENCY" \
    --out "$bench_out"

  wait "$dmon_pid" 2>/dev/null || true
  stop_hog
  kill_vllm
  log "$name complete -> $bench_out"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts" && pwd)"
cp -f "$SCRIPT_DIR/bench_client.py" "$SCRIPT_DIR/analyze_realistic.py" "$ROOT/"

{
  date
  nvidia-smi topo -m
  numactl --hardware
} > "$ROOT/topology_report.txt"

# Arms aligned to K8s placement stories
run_arm isolated "$VLLM_CPUS_ALL" ""
run_arm shared_neighbor "" "$HOG_CPUS_OTHER"
run_arm overlap_worst "" "$HOG_CPUS_OVERLAP"
run_arm oversubscribed "" "0-15"
run_arm pinned_production "$VLLM_CPUS_PINNED" "$HOG_CPUS_OTHER"

python3 "$ROOT/analyze_realistic.py" | tee "$ROOT/results_summary.txt"
log "All arms done under $ROOT"
