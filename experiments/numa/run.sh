#!/usr/bin/env bash
# Non-root NUMA membind A/B for 2-node hosts. Small, polite load.
set -euo pipefail

MODEL="${MODEL:-}"
MODEL_PATH="${MODEL_PATH:-$MODEL}"
PORT="${PORT:-8765}"
ROOT="${ROOT:-$HOME/kubecon_results/numa_ab}"
DURATION="${DURATION:-120}"
WARMUP="${WARMUP:-15}"
CONCURRENCY="${CONCURRENCY:-8}"
GPU_MEM_UTIL="${GPU_MEM_UTIL:-${GPU_MEMORY_UTILIZATION:-0.85}}"
GPU_NUMA="${GPU_NUMA:-}"   # set after topo -m, e.g. 0
REMOTE_NUMA="${REMOTE_NUMA:-1}"

export PATH="${HOME}/.local/bin:${PATH}"
export CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"

# tracelab/conda often has vllm outside default PATH; override with VLLM_BIN or VLLM_PYTHON
VLLM_PYTHON="${VLLM_PYTHON:-python3}"

vllm_launch() {
  if [[ -n "${VLLM_BIN:-}" && -x "$VLLM_BIN" ]]; then
    echo "$VLLM_BIN"
    return 0
  fi
  if command -v vllm >/dev/null 2>&1; then
    command -v vllm
    return 0
  fi
  if "$VLLM_PYTHON" -c "import vllm" >/dev/null 2>&1; then
    echo "$VLLM_PYTHON -m vllm.entrypoints.cli.main"
    return 0
  fi
  echo "vLLM not found. Set VLLM_BIN=/path/to/vllm or activate tracelab env; try: $VLLM_PYTHON -c 'import vllm'" >&2
  return 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$ROOT"

if [[ -z "$MODEL_PATH" || ! -d "$MODEL_PATH" ]]; then
  echo "Set MODEL_PATH=/path/to/weights (dir with config.json)" >&2
  exit 1
fi

NODES=$(numactl -H | awk '/available:/ { print $2 }')
if [[ "${NODES:-0}" -lt 2 ]]; then
  echo "Need 2 NUMA nodes; got ${NODES:-?}" >&2
  exit 1
fi

if [[ -z "$GPU_NUMA" ]]; then
  echo "Set GPU_NUMA=0 or 1 from: nvidia-smi topo -m" >&2
  exit 1
fi

if [[ "$GPU_NUMA" == "0" ]]; then
  REMOTE_NUMA=1
else
  REMOTE_NUMA=0
fi

# One physical core per logical slot on node 0 (adjust if your job cpuset differs)
CPUS_LOCAL="${CPUS_LOCAL:-0-7}"
CPUS_HOG="${CPUS_HOG:-8-15}"

kill_vllm() {
  pkill -f "vllm serve" 2>/dev/null || true
  pkill -f "vllm.entrypoints" 2>/dev/null || true
  sleep 3
}

wait_health() {
  for _ in $(seq 1 90); do
    curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null && return 0
    sleep 2
  done
  return 1
}

run_arm() {
  local arm="$1" membind="$2"
  local out="$ROOT/$arm"
  mkdir -p "$out"
  kill_vllm

  log="$out/run.log"
  echo "=== $arm cpunodebind=$GPU_NUMA membind=$membind $(date -Iseconds) ===" | tee "$log"

  launcher=$(vllm_launch) || exit 1
  # shellcheck disable=SC2086
  numactl --cpunodebind="$GPU_NUMA" --membind="$membind" --physcpubind="$CPUS_LOCAL" \
    env PATH="$PATH" CUDA_VISIBLE_DEVICES="$CUDA_VISIBLE_DEVICES" \
    bash -c 'exec '"$launcher"' serve "$0" --port "$1" --max-model-len 4096 \
      --gpu-memory-utilization '"$GPU_MEM_UTIL"' --enforce-eager' \
    "$MODEL_PATH" "$PORT" >>"$out/vllm.log" 2>&1 &

  wait_health || { tail -20 "$out/vllm.log" >&2; exit 1; }
  pid=$(pgrep -f "vllm serve" | head -1)
  [[ -z "$pid" ]] && pid=$(pgrep -f "vllm.entrypoints" | head -1)
  numastat -p "$pid" >"$out/numastat_p_start.txt" 2>&1 || true

  nvidia-smi dmon -s u -d 1 -c 30 >"$out/dmon.txt" &
  dmon_pid=$!

  python3 "$(cd "$SCRIPT_DIR/../../scripts" && pwd)/bench_client.py" \
    --url "http://127.0.0.1:${PORT}/v1/completions" \
    --model "$MODEL_PATH" --model-path "$MODEL_PATH" \
    --warmup "$WARMUP" --duration "$DURATION" --concurrency "$CONCURRENCY" \
    --prompt-tokens 512 --max-tokens 128 \
    --out "$out/bench.jsonl"

  wait "$dmon_pid" 2>/dev/null || true
  numastat -p "$pid" >"$out/numastat_p_end.txt" 2>&1 || true
  numastat -n >"$out/numastat_n_end.txt" 2>&1 || true
  kill_vllm
  python3 -c "
import json
from pathlib import Path
p = Path('${out}/bench.jsonl')
rows = [json.loads(l) for l in p.read_text().splitlines() if l.strip()]
def pct(vals, q):
    xs = sorted(vals)
    k = (len(xs) - 1) * q / 100
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)
t = [r['ttft_ms'] for r in rows]
e = [r['e2e_ms'] for r in rows]
tp = [r['tpot_ms'] for r in rows if r.get('tpot_ms') is not None]
print(f'n={len(rows)} ttft_p50={pct(t,50):.1f} ttft_p99={pct(t,99):.1f} e2e_p50={pct(e,50):.1f} e2e_p99={pct(e,99):.1f}', end='')
if tp:
    print(f' tpot_p50={pct(tp,50):.2f}')
else:
    print()
" | tee "$out/summary.txt"
}

numactl -H | tee "$ROOT/numactl_H.txt"
run_arm "membind_local" "$GPU_NUMA"
run_arm "membind_remote" "$REMOTE_NUMA"
echo "Done -> $ROOT"
