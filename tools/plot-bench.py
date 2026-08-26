#!/usr/bin/env python3
"""Plot the memory/perf benchmark matrix as a grouped bar chart.

    plot-bench.py [results.csv] [out.png]

Reads build/bench-results.csv (from scripts/bench/bench-memory.sh) and writes
docs/bench.png: host RAM used + KSM saved + zram compressed per setting, plus
guest throughput. Colours and a dark-neutral background read on light or dark.
"""

import csv
import sys
from pathlib import Path

import matplotlib

# The headless backend must be selected before pyplot is imported.
matplotlib.use("Agg")

import matplotlib.pyplot as plt

ROOT = Path(__file__).resolve().parent.parent
REQUIRED = ("state", "vm_rss_mib", "ksm_saved_mib", "zram_compr_mib", "perf_ops_s")
MIB_PER_GIB = 1024
BAR_W = 0.2  # one of four bars per group
LABEL_FLOOR_GIB = 0.5  # don't label savings smaller than this
DPI = 130


def col(row: dict[str, str], key: str) -> int:
    """A blank cell means the collector could not read that counter: treat it as 0."""
    v = row[key]
    return 0 if not v else int(float(v))


def main() -> None:
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "build" / "bench-results.csv"
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "docs" / "bench.png"

    if not src.is_file():
        sys.exit(f"no such file: {src}")
    with src.open(encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    if not rows:
        sys.exit(f"no data rows in {src}")
    missing = set(REQUIRED) - rows[0].keys()
    if missing:
        sys.exit(f"{src}: missing columns {sorted(missing)}")

    states = [r["state"] for r in rows]
    rss = [col(r, "vm_rss_mib") / MIB_PER_GIB for r in rows]
    zsw = [col(r, "zram_compr_mib") / MIB_PER_GIB for r in rows]
    ksm = [col(r, "ksm_saved_mib") / MIB_PER_GIB for r in rows]
    perf = [col(r, "perf_ops_s") for r in rows]
    # True memory cost: resident VM pages plus the cold pages held compressed in zram.
    # vm_rss alone undercounts zram states (squeezed pages left RSS but still cost RAM).
    used = [r + z for r, z in zip(rss, zsw, strict=True)]

    # Prefer an explicit baseline row; fall back to the first sample.
    baseline = next(
        (u for s, u in zip(states, used, strict=True) if s.startswith("baseline")), used[0]
    )
    saved = [baseline - u for u in used]

    x = range(len(states))
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(max(12, len(states) * 1.5), 5))
    fig.suptitle(
        "vmetal-openshift: memory optimization (3 masters + 2 workers)",
        fontsize=13,
        weight="bold",
    )

    ax1.bar(
        [i - 1.5 * BAR_W for i in x],
        used,
        BAR_W,
        label="memory footprint, RSS + zram (GiB)",
        color="#ef4444",
    )
    ax1.bar(
        [i - 0.5 * BAR_W for i in x],
        saved,
        BAR_W,
        label="RAM saved vs baseline (GiB)",
        color="#f59e0b",
    )
    ax1.bar([i + 0.5 * BAR_W for i in x], ksm, BAR_W, label="KSM merged (GiB)", color="#10b981")
    ax1.bar(
        [i + 1.5 * BAR_W for i in x], zsw, BAR_W, label="zram compressed (GiB)", color="#6366f1"
    )
    ax1.set_xticks(list(x))
    ax1.set_xticklabels(states, rotation=30, ha="right", fontsize=8)
    ax1.set_ylabel("GiB")
    ax1.set_title("Memory")
    ax1.legend(fontsize=8)
    ax1.grid(axis="y", alpha=0.3)
    for i, v in zip(x, saved, strict=True):
        if v > LABEL_FLOOR_GIB:
            ax1.text(
                i - 0.5 * BAR_W,
                v,
                f"{v:.0f}",
                ha="center",
                va="bottom",
                fontsize=7,
                color="#92400e",
            )

    ax2.bar(list(x), perf, 0.5, color="#f59e0b")
    ax2.set_xticks(list(x))
    ax2.set_xticklabels(states, rotation=30, ha="right", fontsize=8)
    ax2.set_ylabel("openssl sha256 throughput, k/s (higher = better)")
    ax2.set_title("Guest performance")
    ax2.grid(axis="y", alpha=0.3)
    for i, v in zip(x, perf, strict=True):
        ax2.text(i, v, f"{v:,}", ha="center", va="bottom", fontsize=7)

    fig.tight_layout(rect=(0, 0, 1, 0.95))
    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out, dpi=DPI, bbox_inches="tight")
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
