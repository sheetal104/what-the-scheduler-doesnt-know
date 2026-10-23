# What the Scheduler Doesn't Know

Measurements and runners for OS-layer effects on vLLM inference: CPU placement, NUMA locality, and interrupt visibility. Supporting material for KubeCon NA 2026.

## Experiments

| Directory | Question | Reproduce |
|-----------|----------|-----------|
| [`experiments/cpu-placement`](experiments/cpu-placement) | Does CPU placement change tail latency when GPU utilization looks fine? | `bash experiments/cpu-placement/run.sh` |
| [`experiments/observability`](experiments/observability) | Which host signals show the difference during a short run? | `bash experiments/observability/run.sh pinned` |
| [`experiments/numa`](experiments/numa) | Does remote DRAM change tails when the GPU and CPUs stay fixed? | `bash experiments/numa/run.sh` |
| [`experiments/placement-7b`](experiments/placement-7b) | Does the same placement comparison hold on a 7B model? | `bash experiments/placement-7b/run.sh` |
| [`experiments/irq`](experiments/irq) | Where do NIC completion interrupts land during inference? | `bash experiments/irq/run.sh` |

## Requirements

See [`docs/requirements.md`](docs/requirements.md). A single-NUMA GPU host is enough for CPU placement and observability. NUMA membind requires two NUMA nodes. Mapping from arms to Kubernetes controls: [`docs/kubernetes.md`](docs/kubernetes.md).

## Shared code

[`scripts/`](scripts/) holds the load generator, analyzers, and model helpers used by the experiment runners.
