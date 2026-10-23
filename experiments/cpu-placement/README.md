# CPU placement

Five vLLM serving arms on one GPU, with a synthetic CPU hog on different core sets. The question is whether tail latency moves when GPU SM utilization stays in a similar band.

## Run

Requires ≥16 CPUs. Single NUMA is sufficient.

```bash
export MODEL="$HOME/qwen0.6b"
export CUDA_VISIBLE_DEVICES=0
export ROOT="$PWD/experiments/cpu-placement/results/repro"
bash experiments/cpu-placement/run.sh
```

About 45–55 minutes. Outputs land in `$ROOT` (`results_summary.txt`, per-arm `*_bench.jsonl`, `*_dmon.txt`, `*_numastat_*.txt`).

## Published run

Load: 512 prompt tokens, 128 output tokens, concurrency 16, 40 warmup requests, 300 s per arm. vLLM 0.31, `--enforce-eager`, max model length 4096. Qwen3-0.6B. 16 vCPU, one NUMA node, one GPU.

| Arm | vLLM CPUs | CPU hog | n | TTFT p50 | TTFT p99 | TPOT p50 | E2E p50 | E2E p99 |
|-----|-----------|---------|---|----------|----------|----------|---------|---------|
| isolated | 0–15 | none | 2400 | 64.5 | 85.6 | 15.03 | 1967 | **2565** |
| shared_neighbor | all | 8–15 | 2403 | 64.6 | 79.7 | 14.74 | 1935 | 2257 |
| overlap_worst | all | 0–7 | 2494 | 60.8 | 77.3 | 14.43 | 1885 | 2189 |
| oversubscribed | all | 0–15 | 2483 | 62.2 | 75.1 | 14.65 | 1917 | 2104 |
| pinned_production | 0–7 | 8–15 | 2528 | **58.0** | 77.4 | **14.23** | **1867** | 2120 |

GPU SM active (60×1 Hz `nvidia-smi dmon` samples) averaged about 58–64% on every arm.

Median TTFT stays in a narrow band. End-to-end p99 is higher for `isolated` (2565 ms) than for `pinned_production` (2120 ms).

A second run on the same host class, about 24 hours later, kept the same arm design and request volume. Median TTFT moved about 5–15% on several arms; end-to-end p99 usually stayed within about 10%. Use this directory’s table as the reference, and treat single-digit millisecond gaps as run noise.

| Arm | TTFT p50 (repeat) | E2E p99 (repeat) |
|-----|-------------------|------------------|
| isolated | 67.2 | 2509 |
| shared_neighbor | 54.4 | 2240 |
| overlap_worst | 63.2 | 2148 |
| oversubscribed | 45.8 | 2252 |
| pinned_production | 51.5 | 2286 |

## Files

| Path | Contents |
|------|----------|
| `results/results_summary.txt` | Percentile table |
| `results/results.json` | Machine-readable percentiles |
| `results/*_bench.jsonl` | Per-request TTFT, TPOT, E2E |
| `results/*_dmon.txt` | GPU samples |
| `results/*_numastat_*.txt` | Node memory during the arm |
| `results/latency_comparison.png` | CDF and p99 chart |
| `results/figures/` | Rolling TTFT p99 and SM plots |
