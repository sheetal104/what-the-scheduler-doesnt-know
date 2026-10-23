#!/usr/bin/env bash
# Record a short asciinema cast of the below-kube workflow (no IRQ affinity changes).
# Prereq: vLLM already serving on PORT; or run in two terminals (start vLLM first).
set -euo pipefail

CAST="${1:-/tmp/kubecon_workflow.cast}"
PORT="${PORT:-8000}"
MODEL_PATH="${MODEL_PATH:-}"

if ! command -v asciinema >/dev/null; then
  echo "Install: pip install --user asciinema  (or uv pip install asciinema)" >&2
  exit 1
fi

SCRIPT=$(mktemp)
trap 'rm -f "$SCRIPT"' EXIT
cat >"$SCRIPT" <<'DEMO'
#!/usr/bin/env bash
set -e
PORT="${PORT:-8000}"
echo "=== 1) Cluster view: pod would be Ready; check local health ==="
curl -sf "http://127.0.0.1:${PORT}/health" && echo " vLLM healthy" || echo " start vLLM first on this port"

PID=$(pgrep -f "vllm serve" | head -1 || pgrep -f "APIServer" | head -1 || true)
echo "=== 2) GPU not idle? (10 samples) ==="
nvidia-smi dmon -s u -d 1 -c 10 || true

echo "=== 3) Process-level: numastat + scheduler (PID=${PID:-missing}) ==="
if [[ -n "${PID:-}" ]]; then
  numastat -p "$PID" 2>/dev/null | head -20 || true
  grep -E 'voluntary_ctxt_switches|nonvoluntary_ctxt_switches' "/proc/$PID/status" 2>/dev/null || true
fi

echo "=== 4) IRQ snapshot (read-only; mlx/virtio/eth) ==="
grep -E 'mlx|virtio|eth|enp' /proc/interrupts 2>/dev/null | head -15 || head -5 /proc/interrupts

echo "=== Done (extend with: sudo bpftrace ... on hosts that allow it) ==="
DEMO
chmod +x "$SCRIPT"

echo "Recording -> $CAST"
echo "Tip: start vLLM in another session before recording."
asciinema rec -c "PORT=$PORT bash $SCRIPT" "$CAST" --title "kubecon-os-workflow"
echo "Upload: asciinema upload $CAST"
