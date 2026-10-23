#!/usr/bin/env python3
import json
import os
import statistics
from pathlib import Path

ROOT = Path(os.environ.get("ROOT", "/tmp/kubecon_experiments/realistic"))
ARMS = [
    "isolated",
    "shared_neighbor",
    "overlap_worst",
    "oversubscribed",
    "pinned_production",
]


def pct(vals, p):
    if not vals:
        return float("nan")
    xs = sorted(vals)
    k = (len(xs) - 1) * p / 100
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def load(path: Path):
    if not path.exists():
        return []
    return [json.loads(l) for l in path.read_text().splitlines() if l.strip()]


def trim(vals, lo=1, hi=99):
    if len(vals) < 20:
        return vals
    a, b = pct(vals, lo), pct(vals, hi)
    return [v for v in vals if a <= v <= b]


def main():
    rows = []
    for arm in ARMS:
        data = load(ROOT / f"{arm}_bench.jsonl")
        ttft = [r["ttft_ms"] for r in data]
        e2e = [r["e2e_ms"] for r in data]
        tpot = [r["tpot_ms"] for r in data if r.get("tpot_ms")]
        ttft_t = trim(ttft)
        e2e_t = trim(e2e)
        rows.append(
            {
                "arm": arm,
                "n": len(data),
                "ttft_p50": pct(ttft_t, 50),
                "ttft_p99": pct(ttft_t, 99),
                "e2e_p50": pct(e2e_t, 50),
                "e2e_p99": pct(e2e_t, 99),
                "tpot_p50": pct(tpot, 50) if tpot else float("nan"),
            }
        )

    hdr = f"{'arm':<20} {'n':>5} {'ttft_p50':>9} {'ttft_p99':>9} {'tpot_p50':>9} {'e2e_p50':>9} {'e2e_p99':>9}"
    print(hdr)
    for r in rows:
        print(
            f"{r['arm']:<20} {r['n']:5d} {r['ttft_p50']:9.1f} {r['ttft_p99']:9.1f} "
            f"{r['tpot_p50']:9.2f} {r['e2e_p50']:9.1f} {r['e2e_p99']:9.1f}"
        )

    try:
        import matplotlib.pyplot as plt

        fig, axes = plt.subplots(1, 2, figsize=(11, 4))
        for arm in ARMS:
            ttft = sorted(r["ttft_ms"] for r in load(ROOT / f"{arm}_bench.jsonl"))
            if not ttft:
                continue
            ttft = trim(ttft)
            ys = [(i + 1) / len(ttft) for i in range(len(ttft))]
            axes[0].plot(ttft, ys, label=arm)
        axes[0].set_xlabel("TTFT (ms)")
        axes[0].set_ylabel("CDF")
        axes[0].set_title("Time to first token")
        axes[0].legend(fontsize=7)

        labels, p99s = [], []
        for r in rows:
            labels.append(r["arm"].replace("_", "\n"))
            p99s.append(r["ttft_p99"])
        axes[1].bar(range(len(labels)), p99s, color="#4C78A8")
        axes[1].set_xticks(range(len(labels)))
        axes[1].set_xticklabels(labels, fontsize=7)
        axes[1].set_ylabel("TTFT p99 (ms)")
        axes[1].set_title("Tail TTFT by placement")
        fig.tight_layout()
        out = ROOT / "latency_comparison.png"
        fig.savefig(out, dpi=130)
        print(f"Wrote {out}", flush=True)
    except ImportError:
        pass

    (ROOT / "results.json").write_text(json.dumps(rows, indent=2) + "\n")


if __name__ == "__main__":
    main()
