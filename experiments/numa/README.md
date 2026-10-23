# NUMA membind

Same GPU and CPU set; only `numactl --membind` changes. The run needs **two NUMA nodes**. Bind vLLM CPUs to the socket that owns the chosen GPU (`nvidia-smi topo -m`).

## Run

```bash
export MODEL_PATH="$HOME/qwen0.6b"
export CUDA_VISIBLE_DEVICES=0    # GPU on the socket you bind
export GPU_NUMA=1                # example: match your topology
export CPUS_LOCAL=56-63          # example: CPUs on that node
export ROOT="$PWD/experiments/numa/results/repro"
bash experiments/numa/run.sh
```

Default load: 512/128 tokens, concurrency 8, 120 s per arm (`membind_local`, `membind_remote`).

## Published run

Dual-socket host, one GPU on NUMA node 1, vLLM CPUs 56–63, Qwen3-0.6B.

| Arm | Heap node 0 | Heap node 1 | n | TTFT p50 | TTFT p99 | E2E p99 |
|-----|-------------|-------------|---|----------|----------|---------|
| membind_local | ~0 MB | ~448 MB | 832 | 37.2 ms | 39.6 ms | **1181 ms** |
| membind_remote | ~464 MB | ~0 MB | 800 | 38.8 ms | **48.2 ms** | **1305 ms** |

Medians stay close. Tails move: TTFT p99 about 39.6 → 48.2 ms, E2E p99 about 1181 → 1305 ms, with process heap on the remote node in the second arm.
