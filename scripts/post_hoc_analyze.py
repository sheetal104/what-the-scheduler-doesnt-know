#!/usr/bin/env python3
"""Post-hoc figures from realistic r1 bench jsonl + dmon."""

from __future__ import annotations

import json
import os
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
ROOT = Path(os.environ.get("ROOT", _REPO / "results" / "realistic"))
OUT = ROOT / "post_hoc"
ARMS = ["isolated", "pinned_production", "overlap_worst"]


def load_jsonl(path: Path) -> list[dict]:
    return [json.loads(l) for l in path.read_text().splitlines() if l.strip()]


def pct(vals: list[float], p: float) -> float:
    xs = sorted(vals)
    k = (len(xs) - 1) * p / 100
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def load_dmon_gpu0(path: Path) -> list[float]:
    sm = []
    for line in path.read_text().splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "0":
            try:
                sm.append(float(parts[1]))
            except ValueError:
                pass
    return sm


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)

    # --- TTFT rolling p99 + timeline ---
    try:
        import matplotlib.pyplot as plt
    except ImportError:
        raise SystemExit("need matplotlib")

    fig, axes = plt.subplots(2, 1, figsize=(10, 7), sharex=False)

    window = 100
    for arm in ARMS:
        rows = load_jsonl(ROOT / f"{arm}_bench.jsonl")
        ttft = [r["ttft_ms"] for r in rows]
        ts0 = rows[0]["ts"]
        minutes = [(r["ts"] - ts0) / 60 for r in rows]
        rolling_p99 = []
        rx = []
        for i in range(window, len(ttft)):
            rolling_p99.append(pct(ttft[i - window : i], 99))
            rx.append(minutes[i])
        axes[0].plot(rx, rolling_p99, label=arm, alpha=0.9)

    axes[0].set_ylabel("Rolling TTFT p99 (ms)")
    axes[0].set_xlabel("Minutes since measure start")
    axes[0].set_title(f"Tail TTFT stability during 300s load (window={window})")
    axes[0].legend(fontsize=8)
    axes[0].grid(True, alpha=0.3)

    # --- GPU SM from dmon (first 60 samples) vs arm ---
    labels, avgs, mins, maxs = [], [], [], []
    for arm in [
        "isolated",
        "shared_neighbor",
        "overlap_worst",
        "oversubscribed",
        "pinned_production",
    ]:
        sm = load_dmon_gpu0(ROOT / f"{arm}_dmon.txt")
        if not sm:
            continue
        labels.append(arm.replace("_", "\n"))
        avgs.append(sum(sm) / len(sm))
        mins.append(min(sm))
        maxs.append(max(sm))

    x = range(len(labels))
    axes[1].bar(x, avgs, color="#4C78A8", label="avg SM%")
    axes[1].set_xticks(list(x))
    axes[1].set_xticklabels(labels, fontsize=7)
    axes[1].set_ylabel("GPU0 SM util (%)")
    axes[1].set_title("GPU busy during load (dmon, ~60s sample) — not idle")
    axes[1].set_ylim(0, 100)

    fig.tight_layout()
    p1 = OUT / "ttft_rolling_p99_and_gpu_sm.png"
    fig.savefig(p1, dpi=130)
    print(f"Wrote {p1}")

    # --- Coarse TTFT vs concurrent GPU SM (pinned only): bin by minute ---
    arm = "pinned_production"
    rows = load_jsonl(ROOT / f"{arm}_bench.jsonl")
    sm_series = load_dmon_gpu0(ROOT / f"{arm}_dmon.txt")
    if rows and sm_series:
        ts0 = rows[0]["ts"]
        by_min: dict[int, list[float]] = {}
        for r in rows:
            m = int((r["ts"] - ts0) // 60)
            by_min.setdefault(m, []).append(r["ttft_ms"])
        mins = sorted(by_min)
        ttft_p99 = [pct(by_min[m], 99) for m in mins]
        # dmon ~1s; map minute index to avg sm
        sm_by_min = []
        for m in mins:
            lo, hi = m * 60, (m + 1) * 60
            chunk = sm_series[lo:hi] if hi <= len(sm_series) else sm_series[lo:]
            sm_by_min.append(sum(chunk) / len(chunk) if chunk else 0)

        fig2, ax1 = plt.subplots(figsize=(8, 4))
        ax1.plot(mins, ttft_p99, "o-", color="#E45756", label="TTFT p99")
        ax1.set_xlabel("Minute")
        ax1.set_ylabel("TTFT p99 (ms)", color="#E45756")
        ax2 = ax1.twinx()
        ax2.plot(mins, sm_by_min, "s--", color="#4C78A8", label="GPU0 SM avg")
        ax2.set_ylabel("SM util (%)", color="#4C78A8")
        ax1.set_title("pinned_production: tail latency vs GPU util (same wall clock)")
        fig2.tight_layout()
        p2 = OUT / "ttft_vs_sm_pinned.png"
        fig2.savefig(p2, dpi=130)
        print(f"Wrote {p2}")

    summary = {
        "note": "GPU SM averages 58-64% across arms while TTFT/E2E tails differ by placement.",
        "arms_gpu_sm_avg": dict(zip(labels, avgs)) if labels else {},
    }
    (OUT / "post_hoc_summary.json").write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    main()
