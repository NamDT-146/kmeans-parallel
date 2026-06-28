#!/usr/bin/env python3
"""
Render every figure the report needs from the experiment CSVs in results/.

Figures produced (only those whose source CSV exists):

  results/fig_size_sweep.png   runtime vs input size (with / without comm)
                               -> read off N where wall time is ~120-180 s
  results/fig_granularity.png  per-rank stacked compute+comm bar chart
                               -> visual load-balance check at the baseline N
  results/fig_runtime.png      runtime vs process count (with / without comm)
  results/fig_speedup.png      speedup vs process count, against the ideal line

Usage:
    python3 plots/make_plots.py
    python3 plots/make_plots.py --results-dir results

Each figure is independent; missing CSVs are skipped with a note so you can
generate plots incrementally as experiments finish.
"""
import argparse
import csv
import os
import struct
import sys

import matplotlib
matplotlib.use("Agg")            # headless: works over SSH on the cluster
import matplotlib.pyplot as plt

try:
    import numpy as np
    HAVE_NUMPY = True
except ImportError:
    HAVE_NUMPY = False


def read_csv(path):
    with open(path) as f:
        return list(csv.DictReader(f))


def plot_size_sweep(results_dir):
    path = os.path.join(results_dir, "size_sweep.csv")
    if not os.path.isfile(path):
        return f"skip size_sweep: {path} not found"
    rows = read_csv(path)
    rows = [r for r in rows if r.get("wall_s")]
    rows.sort(key=lambda r: int(r["M"]))
    M = [int(r["M"]) for r in rows]
    wall = [float(r["wall_s"]) for r in rows]
    comm = [float(r["comm_s"]) for r in rows]
    compute = [w - c for w, c in zip(wall, comm)]

    # Log-log axes. The measured runtimes here span ~0.1-40 s, three orders of
    # magnitude below the literal 2-3 min target; on a linear axis with the band
    # drawn at 120-180 s the real curve is crushed flat against zero. Log-log
    # keeps the near-linear O(M) growth readable AND lets us show where the band
    # would be reached by extrapolation, which is the honest way to present a
    # single-host measurement whose absolute times the cluster will dwarf.
    fig, ax = plt.subplots(figsize=(8, 5))
    ax.plot(M, wall, "o-", label="total wall time (with comm)")
    ax.plot(M, compute, "s--", label="compute only (without comm)")
    ax.set_xscale("log"); ax.set_yscale("log")

    # Extrapolate the wall-time trend (a near-linear power law in M) to mark the
    # M at which this host would enter the 2-3 min band, instead of pretending
    # the band sits among the measured points.
    note = ""
    if len(M) >= 2:
        import math
        lm = [math.log(x) for x in M]; lw = [math.log(x) for x in wall]
        n = len(M); sx = sum(lm); sy = sum(lw)
        sxx = sum(x * x for x in lm); sxy = sum(x * y for x, y in zip(lm, lw))
        slope = (n * sxy - sx * sy) / (n * sxx - sx * sx)
        inter = (sy - slope * sx) / n
        m_at = lambda secs: math.exp((math.log(secs) - inter) / slope)
        m_lo, m_hi = m_at(120), m_at(180)
        ax.axhspan(120, 180, color="green", alpha=0.12,
                   label="target 2-3 min band (extrapolated)")
        ax.axvspan(m_lo, m_hi, color="green", alpha=0.07)
        note = (f" — on this host the band is reached near "
                f"M≈{m_lo/1e6:.0f}-{m_hi/1e6:.0f}M points (extrapolated)")

    ax.set_xlabel("input size M (points, log scale)")
    ax.set_ylabel("runtime (s, log scale)")
    ax.set_title("Runtime vs input size (single host; band extrapolated)")
    ax.grid(True, which="both", alpha=0.3)
    ax.legend()
    out = os.path.join(results_dir, "fig_size_sweep.png")
    fig.tight_layout(); fig.savefig(out, dpi=130); plt.close(fig)
    return f"wrote {out}{note}"


def plot_granularity(results_dir):
    path = os.path.join(results_dir, "granularity.csv")
    if not os.path.isfile(path):
        return f"skip granularity: {path} not found"
    rows = read_csv(path)
    rows.sort(key=lambda r: int(r["rank"]))
    ranks = [int(r["rank"]) for r in rows]
    compute = [float(r["compute_s"]) for r in rows]
    comm = [float(r["comm_s"]) for r in rows]

    fig, ax = plt.subplots(figsize=(9, 5))
    ax.bar(ranks, compute, label="compute", color="#3b78b0")
    ax.bar(ranks, comm, bottom=compute, label="communication", color="#e08a1e")
    ax.set_xlabel("MPI rank")
    ax.set_ylabel("time (s)")
    ax.set_xticks(ranks)

    lo, hi = min(compute), max(compute)
    spread = (hi - lo) / hi * 100 if hi > 0 else 0.0
    verdict = "balanced (<=25%)" if spread <= 25 else "RETUNE (>25%)"
    ax.set_title(f"Per-rank compute + comm at baseline N "
                 f"(compute spread {spread:.1f}% — {verdict})")
    ax.grid(True, axis="y", alpha=0.3)
    ax.legend()
    out = os.path.join(results_dir, "fig_granularity.png")
    fig.tight_layout(); fig.savefig(out, dpi=130); plt.close(fig)
    return f"wrote {out} (spread {spread:.1f}%)"


def _load_scaling(results_dir):
    path = os.path.join(results_dir, "scaling.csv")
    if not os.path.isfile(path):
        return None, f"{path} not found"
    rows = read_csv(path)
    rows.sort(key=lambda r: int(r["P"]))
    return rows, None


def plot_runtime(results_dir):
    rows, err = _load_scaling(results_dir)
    if rows is None:
        return f"skip runtime: {err}"
    P = [int(r["P"]) for r in rows]
    wall = [float(r["wall_s"]) for r in rows]
    comm = [float(r["comm_s"]) for r in rows]
    compute = [w - c for w, c in zip(wall, comm)]

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.plot(P, wall, "o-", label="total wall time (with comm)")
    ax.plot(P, compute, "s--", label="compute only (without comm)")
    ax.set_xscale("log", base=2)
    ax.set_xticks(P); ax.set_xticklabels([str(p) for p in P])
    ax.set_xlabel("number of processes P")
    ax.set_ylabel("runtime (s)")
    ax.set_title("Runtime vs process count at data scale 2N")
    ax.grid(True, alpha=0.3)
    ax.legend()
    out = os.path.join(results_dir, "fig_runtime.png")
    fig.tight_layout(); fig.savefig(out, dpi=130); plt.close(fig)
    return f"wrote {out}"


def plot_speedup(results_dir):
    rows, err = _load_scaling(results_dir)
    if rows is None:
        return f"skip speedup: {err}"
    P = [int(r["P"]) for r in rows]
    sw = [float(r["speedup_wall"]) for r in rows]
    sc = [float(r["speedup_compute"]) for r in rows]

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.plot(P, P, "k:", label="ideal linear speedup")
    ax.plot(P, sw, "o-", label="measured speedup (with comm)")
    ax.plot(P, sc, "s--", label="measured speedup (compute only)")
    ax.set_xscale("log", base=2); ax.set_yscale("log", base=2)
    ax.set_xticks(P); ax.set_xticklabels([str(p) for p in P])
    ax.set_yticks(P); ax.set_yticklabels([str(p) for p in P])
    ax.set_xlabel("number of processes P")
    ax.set_ylabel("speedup S(P) = T(1) / T(P)")
    ax.set_title("Speedup vs process count at data scale 2N")
    ax.grid(True, which="both", alpha=0.3)
    ax.legend()
    out = os.path.join(results_dir, "fig_speedup.png")
    fig.tight_layout(); fig.savefig(out, dpi=130); plt.close(fig)
    return f"wrote {out}"


def plot_efficiency(results_dir):
    rows, err = _load_scaling(results_dir)
    if rows is None:
        return f"skip efficiency: {err}"
    P = [int(r["P"]) for r in rows]
    eff_w = [float(r["speedup_wall"]) / p for r, p in zip(rows, P)]
    eff_c = [float(r["speedup_compute"]) / p for r, p in zip(rows, P)]

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.axhline(1.0, color="k", ls=":", label="ideal efficiency = 1")
    ax.plot(P, eff_w, "o-", label="efficiency (with comm)")
    ax.plot(P, eff_c, "s--", label="efficiency (compute only)")
    ax.set_xscale("log", base=2)
    ax.set_xticks(P); ax.set_xticklabels([str(p) for p in P])
    ax.set_ylim(0, 1.1)
    ax.set_xlabel("number of processes P")
    ax.set_ylabel("parallel efficiency $E_P = S_P / P$")
    ax.set_title("Parallel efficiency vs process count at data scale 2N")
    ax.grid(True, alpha=0.3)
    ax.legend()
    out = os.path.join(results_dir, "fig_efficiency.png")
    fig.tight_layout(); fig.savefig(out, dpi=130); plt.close(fig)
    return f"wrote {out}"


def plot_comm_fraction(results_dir):
    rows, err = _load_scaling(results_dir)
    if rows is None:
        return f"skip comm_fraction: {err}"
    P = [int(r["P"]) for r in rows]
    wall = [float(r["wall_s"]) for r in rows]
    comm = [float(r["comm_s"]) for r in rows]
    frac = [100.0 * c / w if w > 0 else 0.0 for c, w in zip(comm, wall)]

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.plot(P, frac, "o-", color="#e08a1e")
    ax.set_xscale("log", base=2)
    ax.set_xticks(P); ax.set_xticklabels([str(p) for p in P])
    ax.set_xlabel("number of processes P")
    ax.set_ylabel("communication share of wall time (%)")
    ax.set_title("Communication fraction vs process count at data scale 2N")
    ax.grid(True, alpha=0.3)
    for p, f in zip(P, frac):
        ax.annotate(f"{f:.1f}%", (p, f), textcoords="offset points",
                    xytext=(0, 8), ha="center", fontsize=9)
    out = os.path.join(results_dir, "fig_comm_fraction.png")
    fig.tight_layout(); fig.savefig(out, dpi=130); plt.close(fig)
    return f"wrote {out}"


def plot_convergence(results_dir):
    """WCSS (within-cluster sum of squares = total squared intra-cluster
    distance) per iteration — the k-means objective. It decreases monotonically
    and flattening signals convergence. Written by kmeans_mpi when KMEANS_CONV_CSV
    is set; the demo points it at results/convergence.csv."""
    path = os.path.join(results_dir, "convergence.csv")
    if not os.path.isfile(path):
        return f"skip convergence: {path} not found"
    rows = read_csv(path)
    rows = [r for r in rows if r.get("wcss")]
    if not rows:
        return "skip convergence: no rows in convergence.csv"
    rows.sort(key=lambda r: int(r["iter"]))
    it = [int(r["iter"]) for r in rows]
    wcss = [float(r["wcss"]) for r in rows]

    fig, ax = plt.subplots(figsize=(8, 5))
    ax.plot(it, wcss, "o-", color="#3b78b0")
    # Log y so the early orders-of-magnitude drop and the late fine-tuning are
    # both legible (WCSS often falls by 100x in the first few iterations).
    if min(wcss) > 0:
        ax.set_yscale("log")
    ax.set_xlabel("iteration")
    ax.set_ylabel("WCSS (total squared intra-cluster distance)")
    ax.set_title(f"K-means convergence: WCSS per iteration "
                 f"({wcss[0]:.3e} -> {wcss[-1]:.3e} over {len(it)} iters)")
    ax.grid(True, which="both", alpha=0.3)
    out = os.path.join(results_dir, "fig_convergence.png")
    fig.tight_layout(); fig.savefig(out, dpi=130); plt.close(fig)
    return f"wrote {out} ({len(it)} iters)"


def _read_dataset(path):
    """Read the little-endian dataset binary written by gen_dataset.py.
    Returns (M, dim, K, data as a flat float list). numpy used when present."""
    with open(path, "rb") as f:
        M, dim, K = struct.unpack("<3i", f.read(12))
        n = M * dim
        if HAVE_NUMPY:
            data = np.frombuffer(f.read(8 * n), dtype="<f8").reshape(M, dim)
        else:
            data = list(struct.unpack("<%dd" % n, f.read(8 * n)))
    return M, dim, K, data


def _read_labels(path):
    with open(path) as f:
        return [int(x) for x in f if x.strip()]


def plot_clustering(results_dir, data_path="data/verify.bin",
                    labels_path=None):
    """The actual k-means RESULT: points coloured by their assigned cluster.

    Uses the dataset that the correctness check clustered (data/verify.bin) and
    the parallel run's labels (results/par_labels.txt). For dim > 2 we project
    to the first two principal components (numpy); with numpy absent or dim < 2
    we fall back to the first two raw coordinates. Centroids are drawn as the
    per-cluster mean so the partition is easy to read at a glance.
    """
    if labels_path is None:
        labels_path = os.path.join(results_dir, "par_labels.txt")
    if not os.path.isfile(data_path):
        return f"skip clustering: {data_path} not found (run verify_correctness.sh)"
    if not os.path.isfile(labels_path):
        return f"skip clustering: {labels_path} not found (run verify_correctness.sh)"

    M, dim, K, data = _read_dataset(data_path)
    labels = _read_labels(labels_path)
    if len(labels) != M:
        return f"skip clustering: {len(labels)} labels but M={M} points"

    if HAVE_NUMPY:
        X = data
        lab = np.asarray(labels)
        if dim >= 2:
            # Project to 2D principal components so high-dim structure is visible.
            Xc = X - X.mean(axis=0)
            # SVD is numerically stable and avoids forming the covariance matrix.
            _, _, Vt = np.linalg.svd(Xc, full_matrices=False)
            P = Xc @ Vt[:2].T
            axis_label = "principal component"
        else:
            P = np.column_stack([X[:, 0], np.zeros(M)])
            axis_label = "x"
        fig, ax = plt.subplots(figsize=(7, 6))
        ax.scatter(P[:, 0], P[:, 1], c=lab, cmap="tab20", s=6, alpha=0.6,
                   linewidths=0)
        # Centroid of each cluster in the projected space.
        for k in range(K):
            pts = P[lab == k]
            if len(pts):
                cx, cy = pts[:, 0].mean(), pts[:, 1].mean()
                ax.scatter([cx], [cy], marker="X", c="black", s=120,
                           edgecolors="white", linewidths=1.5, zorder=5)
        ax.set_xlabel(f"{axis_label} 1")
        ax.set_ylabel(f"{axis_label} 2" if dim >= 2 else "")
    else:
        # Pure-Python fallback: first two raw dims, no projection, no centroids.
        xs = [data[i * dim + 0] for i in range(M)]
        ys = [data[i * dim + 1] if dim >= 2 else 0.0 for i in range(M)]
        fig, ax = plt.subplots(figsize=(7, 6))
        ax.scatter(xs, ys, c=labels, cmap="tab20", s=6, alpha=0.6, linewidths=0)
        ax.set_xlabel("x 1"); ax.set_ylabel("x 2" if dim >= 2 else "")

    ax.set_title(f"K-means result: {M} points, K={K}, dim={dim} "
                 f"({'PCA proj.' if (HAVE_NUMPY and dim > 2) else 'raw dims'})")
    ax.grid(True, alpha=0.2)
    out = os.path.join(results_dir, "fig_clustering.png")
    fig.tight_layout(); fig.savefig(out, dpi=130); plt.close(fig)
    return f"wrote {out} (M={M}, K={K}, dim={dim})"


def _open_images(paths):
    """Open the given image files in the OS default viewer. Best-effort and
    cross-platform: macOS `open`, Linux `xdg-open`, Windows `start`. Skips
    silently when no opener is available (e.g. a headless cluster node)."""
    import shutil
    import subprocess

    if sys.platform == "darwin":
        opener = ["open"]
    elif os.name == "nt":
        opener = ["cmd", "/c", "start", ""]
    elif shutil.which("xdg-open"):
        opener = ["xdg-open"]
    else:
        print("[plots] --open: no image viewer found (headless?); skipping.",
              file=sys.stderr)
        return
    for p in paths:
        try:
            subprocess.Popen(opener + [p],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as e:
            print(f"[plots] --open: could not open {p}: {e}", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser(description="Render report figures from results CSVs.")
    ap.add_argument("--results-dir", default="results", help="directory holding the CSVs")
    ap.add_argument("--data", default="data/verify.bin",
                    help="dataset binary to visualise in the clustering figure")
    ap.add_argument("--open", action="store_true",
                    help="open every figure that was written in the default image viewer")
    args = ap.parse_args()

    if not os.path.isdir(args.results_dir):
        print(f"error: results dir '{args.results_dir}' does not exist", file=sys.stderr)
        return 1

    # Clustering first: it's the actual result. The rest are performance figures.
    print("[plots]", plot_clustering(args.results_dir, args.data))
    for fn in (plot_convergence, plot_size_sweep, plot_granularity, plot_runtime,
               plot_speedup, plot_efficiency, plot_comm_fraction):
        print("[plots]", fn(args.results_dir))

    # Collect every figure that actually exists on disk, in a sensible order
    # (result first), and optionally open them all.
    figs = ["fig_clustering.png", "fig_convergence.png", "fig_size_sweep.png",
            "fig_granularity.png", "fig_runtime.png", "fig_speedup.png",
            "fig_efficiency.png", "fig_comm_fraction.png"]
    present = [os.path.join(args.results_dir, f) for f in figs
               if os.path.isfile(os.path.join(args.results_dir, f))]
    print(f"[plots] {len(present)} figure(s) in {args.results_dir}/:")
    for p in present:
        print(f"[plots]   {p}")
    if args.open and present:
        _open_images(present)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
