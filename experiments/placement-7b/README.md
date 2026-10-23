# CPU placement at 7B

Two arms only: pinned serving CPUs versus a CPU hog overlapping those CPUs. Model: Qwen2.5-Coder-7B-Instruct. Use this to check that the workflow still runs at a larger weight size. The five-arm comparison in [`cpu-placement`](../cpu-placement) is the reference for ordering.

## Run

```bash
export MODEL_PATH="$HOME/qwen2.5-coder-7b"
export CUDA_VISIBLE_DEVICES=0
export GPU_NUMA=1          # match topology
export CPUS_VLLM=56-63     # example
export CPUS_HOG=64-71
export PORT=8765
bash experiments/placement-7b/run.sh
```

## Published run

120 s per arm, concurrency 8, one GPU, vLLM CPUs 56–63, hog on 64–71.

| Arm | n | TTFT p50 | TTFT p99 | E2E p50 | E2E p99 |
|-----|---|----------|----------|---------|---------|
| pinned_production | 848 | 36.3 ms | 43.1 ms | 1117 ms | 1320 ms |
| overlap_worst | 872 | 35.9 ms | 42.5 ms | 1089 ms | 1248 ms |

On this host the overlap arm was slightly faster. Treat the gap as environment-specific. Do not copy the 0.6B arm ranking onto this table.
