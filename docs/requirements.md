# Requirements

## Host

| Item | CPU placement and observability | NUMA, 7B placement, IRQ |
|------|----------------------------------|-------------------------|
| OS | Linux x86_64 | Linux x86_64 |
| GPU | 1× NVIDIA GPU, ≥24 GiB VRAM | Same; pick an idle device on a shared host |
| CPU | ≥16 logical CPUs | CPUs on the GPU’s NUMA node, plus a second range for a CPU hog |
| NUMA | 1 node is sufficient | **2 nodes** for membind A/B |
| RAM | ≥64 GiB | More if a 7B model and CPU load share a socket |
| Tools | `numactl`, `nvidia-smi`, Python 3.10+, vLLM **0.31**, `aiohttp` | Same; optional `bpftrace` with passwordless sudo |

```bash
sudo apt-get install -y numactl stress-ng python3.10-dev
pip install --user 'vllm==0.31.0' aiohttp
bash scripts/download_qwen06.sh
export MODEL_PATH="$HOME/qwen0.6b"
bash scripts/pin_environment.sh
```

Align `CUDA_VISIBLE_DEVICES` with `nvidia-smi topo -m` before NUMA or IRQ runs.

## Workload

| Parameter | CPU placement | Other experiments |
|-----------|---------------|-------------------|
| Model | Qwen3-0.6B | 0.6B, or Qwen2.5-Coder-7B for `placement-7b` |
| Prompt / output | 512 / 128 tokens | 512 / 128 tokens |
| Concurrency | 16 | 8 |
| Measure window | 300 s per arm | 70–120 s per arm |

## Scope

IRQ affinity changes are not part of these runners. On a shared host, use one idle GPU and do not change global interrupt configuration.
