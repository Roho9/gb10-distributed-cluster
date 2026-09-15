#!/usr/bin/env python3
"""Aggregate NCCL sweep results into a markdown table and a scaling chart.

Input CSV (from nccl-sweep.sh): columns nodes,size_bytes,busbw
Outputs:
  - a markdown table of peak bus bandwidth per node count (stdout + results/summary.md)
  - a PNG line chart of bus bandwidth vs message size, one line per node count

The chart follows a validated, colorblind-safe categorical palette (worst adjacent CVD
delta-E 24.2). Two of the four light-mode hues sit below 3:1 contrast on the surface, so
per the relief rule every line is directly labeled at its end AND the markdown table is
emitted as the non-color reading path.

Usage:
  python3 aggregate.py results/nccl-sweep.csv [--out results/nccl-scaling.png] [--dark]
"""
import argparse
import csv
import pathlib
import sys
from collections import defaultdict

# Categorical palette (fixed slot order; do not cycle). Light and dark are the same hues
# stepped for each surface, from the validated reference palette.
PALETTE = {
    "light": {
        "surface": "#fcfcfb", "primary": "#0b0b0b", "secondary": "#52514e",
        "muted": "#898781", "grid": "#e1e0d9", "baseline": "#c3c2b7",
        "series": ["#2a78d6", "#1baf7a", "#eda100", "#008300"],  # blue, aqua, yellow, green
    },
    "dark": {
        "surface": "#1a1a19", "primary": "#ffffff", "secondary": "#c3c2b7",
        "muted": "#898781", "grid": "#2c2c2a", "baseline": "#383835",
        "series": ["#3987e5", "#199e70", "#c98500", "#008300"],
    },
}


def load(csv_path):
    """Return {nodes: [(size_bytes, busbw), ...] sorted by size}."""
    by_nodes = defaultdict(list)
    with open(csv_path, newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            try:
                by_nodes[int(row["nodes"])].append((int(row["size_bytes"]), float(row["busbw"])))
            except (KeyError, ValueError):
                continue
    for n in by_nodes:
        by_nodes[n].sort()
    return dict(sorted(by_nodes.items()))


def size_label(n):
    for div, suf in ((1 << 30, "G"), (1 << 20, "M"), (1 << 10, "K")):
        if n >= div:
            v = n / div
            return f"{v:.0f}{suf}" if v == int(v) else f"{v:.1f}{suf}"
    return f"{n}B"


def markdown_table(data):
    lines = ["| nodes | peak busbw (GB/s) | at message size |",
             "| --- | --- | --- |"]
    for nodes, series in data.items():
        peak_bw, peak_sz = 0.0, 0
        for sz, bw in series:
            if bw > peak_bw:
                peak_bw, peak_sz = bw, sz
        lines.append(f"| {nodes} | {peak_bw:.1f} | {size_label(peak_sz)} |")
    return "\n".join(lines)


def make_chart(data, out_path, mode):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        from matplotlib.ticker import FuncFormatter
    except ImportError:
        print("matplotlib not installed; skipping chart (table still written). "
              "pip install matplotlib to enable.", file=sys.stderr)
        return False

    c = PALETTE[mode]
    fig, ax = plt.subplots(figsize=(8, 5), dpi=140)
    fig.patch.set_facecolor(c["surface"])
    ax.set_facecolor(c["surface"])

    node_counts = list(data.keys())
    for i, (nodes, series) in enumerate(data.items()):
        color = c["series"][i % len(c["series"])]
        xs = [s for s, _ in series]
        ys = [b for _, b in series]
        # thin 2px line, modest markers
        ax.plot(xs, ys, color=color, linewidth=2, marker="o", markersize=6,
                markeredgecolor=c["surface"], markeredgewidth=1, solid_capstyle="round",
                clip_on=False, zorder=3)
        # direct end label in ink (not the series color) satisfies identity + relief rule
        if xs:
            ax.annotate(f"{nodes} nodes", xy=(xs[-1], ys[-1]),
                        xytext=(6, 0), textcoords="offset points",
                        va="center", ha="left", fontsize=9, color=c["secondary"])

    ax.set_xscale("log", base=2)
    ax.xaxis.set_major_formatter(FuncFormatter(lambda v, _pos: size_label(int(v))))
    ax.set_xlabel("message size", fontsize=10, color=c["secondary"])
    ax.set_ylabel("bus bandwidth (GB/s)", fontsize=10, color=c["secondary"])
    ax.set_title("NCCL all-reduce bus bandwidth vs message size", fontsize=13,
                 color=c["primary"], pad=12, loc="left")

    # recessive chrome: hairline y-grid, hidden top/right spines, muted ticks
    ax.grid(axis="y", color=c["grid"], linewidth=0.6, zorder=0)
    ax.grid(axis="x", visible=False)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(c["baseline"])
    ax.tick_params(colors=c["muted"], labelsize=9)
    ax.set_ylim(bottom=0)

    # legend present for >= 2 series (identity never color-alone)
    if len(node_counts) >= 2:
        leg = ax.legend([f"{n} nodes" for n in node_counts], frameon=False,
                        fontsize=9, loc="lower right", labelcolor=c["secondary"])
        for text in leg.get_texts():
            text.set_color(c["secondary"])

    # headroom on the right for the end labels
    ax.margins(x=0.08)
    fig.tight_layout()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out_path, facecolor=c["surface"], bbox_inches="tight")
    print(f"wrote chart {out_path}")
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", help="nccl-sweep.csv (nodes,size_bytes,busbw)")
    ap.add_argument("--out", default="results/nccl-scaling.png", help="chart PNG path")
    ap.add_argument("--dark", action="store_true", help="render with the dark palette")
    args = ap.parse_args()

    data = load(args.csv)
    if not data:
        print(f"no usable rows in {args.csv}", file=sys.stderr)
        sys.exit(1)

    table = markdown_table(data)
    print(table)
    summary = pathlib.Path("results/summary.md")
    summary.parent.mkdir(parents=True, exist_ok=True)
    summary.write_text("# NCCL sweep summary\n\n" + table + "\n", encoding="utf-8")

    make_chart(data, pathlib.Path(args.out), "dark" if args.dark else "light")


if __name__ == "__main__":
    main()
