#!/usr/bin/env bash
# Sample OS observability while vLLM is under load. Run in a second shell.
set -uo pipefail

ROOT="${ROOT:-/tmp/kubecon_experiments/workflow_capture}"
DURATION="${DURATION:-90}"
INTERVAL="${INTERVAL:-2}"
mkdir -p "$ROOT"

vllm_pid() {
  pgrep -f "vllm serve" | head -1
}

log() { echo "[$(date -Iseconds)] $*" | tee -a "$ROOT/sampler.log"; }

log "sampler duration=${DURATION}s interval=${INTERVAL}s"
log "tools: numastat=$(command -v numastat) bpftrace=$(command -v bpftrace) pidstat=$(command -v pidstat)"

grep -E "virtio|CPU0" /proc/interrupts | head -30 > "$ROOT/interrupts_t0.txt"
cp /proc/interrupts "$ROOT/interrupts_full_t0.txt"

end=$((SECONDS + DURATION))
while (( SECONDS < end )); do
  ts=$(date -Iseconds)
  pid=$(vllm_pid || true)
  {
    echo "=== $ts pid=$pid ==="
    if [[ -n "$pid" ]]; then
      numastat -p "$pid" 2>/dev/null || true
      if [[ -r /proc/$pid/status ]]; then
        grep -E "^(voluntary_ctxt_switches|nonvoluntary_ctxt_switches):" "/proc/$pid/status" || true
      fi
      if [[ -r /proc/$pid/schedstat ]]; then
        echo -n "schedstat: "
        cat "/proc/$pid/schedstat"
      fi
    fi
    nvidia-smi --query-gpu=utilization.gpu,utilization.memory --format=csv,noheader 2>/dev/null || true
  } >> "$ROOT/timeline.txt"
  sleep "$INTERVAL"
done

grep -E "virtio|CPU0" /proc/interrupts | head -30 > "$ROOT/interrupts_t1.txt"
cp /proc/interrupts "$ROOT/interrupts_full_t1.txt"

if [[ "${SKIP_BPFTRACE:-0}" == "1" ]]; then
  log "bpftrace skipped (SKIP_BPFTRACE=1)"
elif command -v bpftrace >/dev/null && sudo -n true 2>/dev/null; then
  log "bpftrace irq sample 10s"
  if sudo -n bpftrace -e 'tracepoint:irq:irq_handler_entry { @[cpu] = count(); }
interval:s:10 { print(@); clear(@); exit(); }' \
    > "$ROOT/bpftrace_irq_10s.txt" 2>&1; then
    log "bpftrace ok"
  else
    log "bpftrace failed (see bpftrace_irq_10s.txt)"
  fi
else
  log "bpftrace skipped (no passwordless sudo — use /proc/interrupts only)"
  echo "skipped: no sudo -n" > "$ROOT/bpftrace_irq_10s.txt"
fi

if command -v pidstat >/dev/null; then
  pid=$(vllm_pid || true)
  if [[ -n "$pid" ]]; then
    pidstat -u -w -p "$pid" 1 "$DURATION" > "$ROOT/pidstat_vllm.txt" 2>&1 || true
  fi
fi

log "done -> $ROOT"
