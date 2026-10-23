# IRQ visibility

Read-only capture of NIC completion interrupts during a short vLLM load. The runner does not change IRQ affinity.

## Run

```bash
export MODEL_PATH="$HOME/qwen0.6b"
export CUDA_VISIBLE_DEVICES=0
export GPU_NUMA=1
export PORT=8765
bash experiments/irq/run.sh
```

Compare `interrupts_mlx_t0.txt` and `interrupts_mlx_t1.txt` under the output directory. Counters should rise on the CPUs listed in the interrupt affinity for the NIC completion queues.

## Published run

90 s load, concurrency 8, Qwen3-0.6B, n = 640.

| TTFT p50 | TTFT p99 | E2E p50 | E2E p99 |
|----------|----------|---------|---------|
| 36.5 ms | 40.1 ms | 1126 ms | 1160 ms |

On that host, `mlx5` completion interrupts for the NIC in use were affined to a CPU inside the vLLM CPU set (CPU 63, with vLLM on 56–63). The latency row is context for the capture, not a placement comparison.

bpftrace is skipped unless passwordless sudo is available. `/proc/interrupts` snapshots are the recorded signal.
