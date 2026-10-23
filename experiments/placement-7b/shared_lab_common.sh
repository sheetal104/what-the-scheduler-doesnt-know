#!/usr/bin/env bash
# Shared dual-NUMA settings — polite: one GPU, small CPU set, only kill our vLLM PID.
# shellcheck disable=SC2034
: "${TRACELAB_ROOT:=$HOME/tracelab-vllm-experiments}"
: "${VENV:=$TRACELAB_ROOT/.venv}"
: "${PORT:=8765}"
: "${GPU_MEM_UTIL:=0.85}"
: "${CUDA_VISIBLE_DEVICES:=4}"
: "${GPU_NUMA:=1}"
: "${CPUS_VLLM:=56-63}"
: "${CPUS_HOG:=64-71}"

export CUDA_VISIBLE_DEVICES GPU_NUMA GPU_MEM_UTIL PORT

activate_venv() {
  # shellcheck source=/dev/null
  source "$VENV/bin/activate"
  export PATH="$VENV/bin:$HOME/.local/bin:$PATH"
}

vllm_launch() {
  if command -v vllm >/dev/null 2>&1; then
    command -v vllm
    return 0
  fi
  echo "vLLM not found; source $VENV/bin/activate" >&2
  return 1
}

_my_vllm_pidfile() {
  echo "${ROOT:-/tmp}/.vllm.pid"
}

stop_hog() {
  pkill -u "$(id -u)" -f kubecon_cpu_hog 2>/dev/null || true
}

start_hog() {
  local cpus="$1"
  stop_hog
  for c in $(echo "$cpus" | tr ',' ' '); do
    taskset -c "$c" bash -c 'exec -a kubecon_cpu_hog bash -c "while true; do :; done"' &
  done
}

kill_my_vllm() {
  local pf
  pf=$(_my_vllm_pidfile)
  if [[ -f "$pf" ]]; then
    local pid
    pid=$(cat "$pf")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
    rm -f "$pf"
  fi
  sleep 2
}

wait_health() {
  local i
  for i in $(seq 1 120); do
    curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null && return 0
    sleep 2
  done
  return 1
}

start_vllm_numa() {
  local membind="$1"
  shift
  local extra_pin=("$@")
  local launcher log
  launcher=$(vllm_launch) || return 1
  log="${ROOT}/vllm.log"
  mkdir -p "$ROOT"
  kill_my_vllm

  # shellcheck disable=SC2086
  numactl --cpunodebind="$GPU_NUMA" --membind="$membind" --physcpubind="$CPUS_VLLM" \
    env CUDA_VISIBLE_DEVICES="$CUDA_VISIBLE_DEVICES" \
    bash -c 'exec '"$launcher"' serve "$0" --port "$1" --max-model-len 4096 \
      --gpu-memory-utilization '"$GPU_MEM_UTIL"' --enforce-eager' \
    "$MODEL_PATH" "$PORT" >>"$log" 2>&1 &
  echo $! >"$(_my_vllm_pidfile)"
  wait_health
}

start_vllm_unpinned() {
  local launcher log
  launcher=$(vllm_launch) || return 1
  log="${ROOT}/vllm.log"
  mkdir -p "$ROOT"
  kill_my_vllm
  # shellcheck disable=SC2086
  env CUDA_VISIBLE_DEVICES="$CUDA_VISIBLE_DEVICES" \
    bash -c 'exec '"$launcher"' serve "$0" --port "$1" --max-model-len 4096 \
      --gpu-memory-utilization '"$GPU_MEM_UTIL"' --enforce-eager' \
    "$MODEL_PATH" "$PORT" >>"$log" 2>&1 &
  echo $! >"$(_my_vllm_pidfile)"
  wait_health
}

summarize_bench() {
  local jsonl="$1"
  python3 -c "
import json
from pathlib import Path
p = Path('$jsonl')
rows = [json.loads(l) for l in p.read_text().splitlines() if l.strip()]
def pct(vals, q):
    xs = sorted(vals)
    k = (len(xs) - 1) * q / 100
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)
t = [r['ttft_ms'] for r in rows]
e = [r['e2e_ms'] for r in rows]
print(f'n={len(rows)} ttft_p50={pct(t,50):.1f} ttft_p99={pct(t,99):.1f} e2e_p50={pct(e,50):.1f} e2e_p99={pct(e,99):.1f}')
"
}

snapshot_irq_mlx() {
  local out="$1"
  grep -E 'mlx|MLX' /proc/interrupts 2>/dev/null || grep -E 'PCI-MSI' /proc/interrupts | head -30 >"$out" || cp /proc/interrupts "$out"
}

check_gpu_free() {
  local idx="$CUDA_VISIBLE_DEVICES"
  local used
  used=$(nvidia-smi -i "$idx" --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')
  if [[ -n "$used" && "$used" -gt 1000 ]]; then
    echo "WARNING: GPU $idx reports ${used} MiB used — pick an idle GPU (nvidia-smi)." >&2
    return 1
  fi
  return 0
}
