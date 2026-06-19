#!/usr/bin/env python3
"""Plot the memory/perf benchmark matrix as a grouped bar chart.

    plot-bench.py [results.csv] [out.png]

Reads build/bench-results.csv (from scripts/bench-memory.sh) and writes
docs/bench.png: host RAM used + KSM saved + zswap compressed per setting, plus
guest throughput. Colours and a dark-neutral background read on light or dark.
"""
import csv
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "build", "bench-results.csv")
out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "docs", "bench.png")

rows = list(csv.DictReader(open(src)))
states = [r["state"] for r in rows]
used = [int(r["host_used_mib"]) / 1024 for r in rows]
ksm = [int(r["ksm_saved_mib"]) / 1024 for r in rows]
zsw = [int(r["zram_compr_mib"]) / 1024 for r in rows]
perf = [int(r["perf_ops_s"]) for r in rows]

x = range(len(states))
width = max(12, len(states) * 1.5)
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(width, 5))
fig.suptitle("vmetal-openshift: memory optimization (3 masters + 2 workers)", fontsize=13, weight="bold")

w = 0.27
ax1.bar([i - w for i in x], used, w, label="host RAM used (GiB)", color="#ef4444")
ax1.bar([i for i in x], ksm, w, label="KSM saved (GiB)", color="#10b981")
ax1.bar([i + w for i in x], zsw, w, label="zram compressed (GiB)", color="#6366f1")
ax1.set_xticks(list(x))
ax1.set_xticklabels(states, rotation=30, ha="right", fontsize=8)
ax1.set_ylabel("GiB")
ax1.set_title("Memory")
ax1.legend(fontsize=8)
ax1.grid(axis="y", alpha=0.3)

ax2.bar(list(x), perf, 0.5, color="#f59e0b")
ax2.set_xticks(list(x))
ax2.set_xticklabels(states, rotation=30, ha="right", fontsize=8)
ax2.set_ylabel("stress-ng bogo-ops/s (higher = better)")
ax2.set_title("Guest performance")
ax2.grid(axis="y", alpha=0.3)
for i, v in zip(x, perf):
    ax2.text(i, v, f"{v:,}", ha="center", va="bottom", fontsize=7)

fig.tight_layout(rect=(0, 0, 1, 0.95))
os.makedirs(os.path.dirname(out), exist_ok=True)
fig.savefig(out, dpi=130, bbox_inches="tight")
print(f"wrote {out}")
