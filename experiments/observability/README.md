# Observability capture

Short pinned and overlap runs that record the same signals used to explain the CPU-placement result: GPU `dmon`, `numastat` timeline, context switches, and IRQ samples. These windows are about 70 seconds. Quote latency from [`cpu-placement`](../cpu-placement), not from this directory.

## Run

```bash
export MODEL="$HOME/qwen0.6b"
export CUDA_VISIBLE_DEVICES=0
bash experiments/observability/run.sh pinned
bash experiments/observability/run.sh overlap
```

Set `SKIP_BPFTRACE=1` when passwordless sudo is unavailable. Artifacts default to `/tmp/kubecon_experiments/workflow_capture/`.

## Published capture

512/128 tokens, concurrency 16, 10 warmup requests, 70 s measure.

| Scenario | vLLM | CPU hog | n | TTFT p50 | TTFT p99 | E2E p99 |
|----------|------|---------|---|----------|----------|---------|
| pinned | CPUs 0–7 | 8–15 | 592 | 61 ms | 132 ms | 2134 ms |
| overlap | unpinned | 0–7 | 592 | 65 ms | 124 ms | 2165 ms |

During the load window, `nonvoluntary_ctxt_switches` rose about 70→88 (pinned) and 79→100 (overlap). The bpftrace sample under overlap shows IRQ counts on the low-numbered CPUs. Heap stays on the single NUMA node.

## Files

`results/pinned/` and `results/overlap/` contain `timeline.txt`, `dmon.txt`, `bench.jsonl`, `pidstat_vllm.txt`, `bpftrace_irq_10s.txt`, and IRQ counter snapshots (`interrupts_t0.txt`, `interrupts_t1.txt`).
