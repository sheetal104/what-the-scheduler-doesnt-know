# Placement arms and Kubernetes

Numbers are from [`experiments/cpu-placement`](../experiments/cpu-placement) (primary run).

| Arm | Host setup | Kubernetes analogue |
|-----|------------|---------------------|
| `isolated` | vLLM on CPUs 0–15, no CPU hog | Dedicated node, low tenant density |
| `shared_neighbor` | vLLM unpinned; hog on CPUs 8–15 | BestEffort work on a different CPU set |
| `overlap_worst` | vLLM unpinned; hog on CPUs 0–7 | Noisy neighbor on the same cores as the server |
| `oversubscribed` | Hog on CPUs 0–15 | Sum of CPU limits above node capacity |
| `pinned_production` | vLLM on 0–7; hog on 8–15 | Guaranteed QoS, static CPU Manager, separate pool for serving |

Legal scheduling can still place host work on the CPUs that serve inference. The measurements use `numastat`, `nvidia-smi dmon`, `/proc`, and optional bpftrace to show that gap.
