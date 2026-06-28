#!/usr/bin/env python3
"""
Generate a synthetic Gaussian-blob dataset for the parallel K-means experiments.

The output is the little-endian binary format consumed by src/common.h:

    int32   M           number of points
    int32   dim         dimensionality
    int32   K           number of ground-truth clusters
    float64 data[M*dim] row-major coordinates
    int32   labels[M]   ground-truth cluster id per point

Coordinates are float64 so the C programs read bit-identical inputs and the
sequential-vs-parallel correctness comparison stays exact.

Usage:
    python3 gen_dataset.py --points 200000 --dim 16 --clusters 8 --out data/train.bin
    python3 gen_dataset.py --M 200000 --dim 16 --K 8 --seed 42 --spread 1.5 \
            --out data/train.bin

The blobs are well separated by default (spread 1.0) so K-means converges to a
clear solution, which makes the correctness assertion meaningful.

numpy is used when available (fast path for the multi-million-point experiment
datasets). If numpy is NOT installed the script transparently falls back to a
pure-stdlib generator so the cluster smoke tests and correctness checks still
run on a bare node — no extra packages required. The fallback is slower, so for
the large experiment sizes installing numpy is recommended
(`sudo apt install -y python3-numpy`).
"""
import argparse
import os
import struct
import sys

try:
    import numpy as np
    HAVE_NUMPY = True
except ImportError:
    HAVE_NUMPY = False


def _log(msg: str) -> None:
    print(f"[gen] {msg}", file=sys.stderr, flush=True)


def _progress_bar(done: int, total: int, prefix: str = "") -> None:
    if total <= 0:
        return
    pct = min(100, int(done * 100 / total))
    bar_w = 30
    filled = int(bar_w * done / total)
    bar = "#" * filled + "-" * (bar_w - filled)
    line = f"\r[gen] {prefix}[{bar}] {pct:3d}% ({done}/{total} points)"
    print(line, file=sys.stderr, end="", flush=True)
    if done >= total:
        print(file=sys.stderr, flush=True)


def _gen_numpy(M, dim, K, seed, spread, box, show_progress: bool):
    """Fast path: vectorised Gaussian blobs via numpy."""
    est_mb = (12 + M * dim * 8 + M * 4) / 1e6
    if show_progress:
        _log(f"numpy: M={M} dim={dim} K={K} (~{est_mb:.1f} MB)")
        _log("allocating cluster centers...")
    rng = np.random.default_rng(seed)
    centers = rng.uniform(-box, box, size=(K, dim))
    if show_progress:
        _log("generating Gaussian blobs...")
    labels = np.tile(np.arange(K), M // K + 1)[:M]
    rng.shuffle(labels)
    data = centers[labels] + rng.normal(0.0, spread, size=(M, dim))
    if show_progress:
        _log("packing binary...")
    return data.astype("<f8").tobytes(), labels.astype("<i4").tobytes()


def _gen_stdlib(M, dim, K, seed, spread, box, show_progress: bool):
    """Fallback path: same construction with the standard library only.

    Produces the identical binary layout (different RNG, so different exact
    values than the numpy path, but a statistically equivalent dataset). Used
    when numpy is unavailable so a bare node can still run the smoke/correctness
    checks. Packs into array('d')/array('i') for speed without numpy.
    """
    import random
    from array import array

    if show_progress:
        _log(f"stdlib (slow): M={M} dim={dim} K={K} — install python3-numpy for speed")

    rnd = random.Random(seed)
    centers = [[rnd.uniform(-box, box) for _ in range(dim)] for _ in range(K)]

    labels_list = [i % K for i in range(M)]
    rnd.shuffle(labels_list)

    data = array("d", bytes(8 * M * dim))   # zero-filled, then overwrite
    idx = 0
    gauss = rnd.gauss
    step = max(1, min(M // 100, 10_000))
    for i in range(M):
        c = centers[labels_list[i]]
        for d in range(dim):
            data[idx] = c[d] + gauss(0.0, spread)
            idx += 1
        if show_progress and (i + 1) % step == 0:
            _progress_bar(i + 1, M, "generating ")

    labels = array("i", labels_list)

    # Force little-endian on big-endian hosts (no-op on x86/ARM little-endian).
    if sys.byteorder != "little":
        data.byteswap()
        labels.byteswap()

    if show_progress:
        _progress_bar(M, M, "generating ")

    return data.tobytes(), labels.tobytes()


def main() -> int:
    ap = argparse.ArgumentParser(description="Generate Gaussian-blob dataset (binary).")
    # --points/--clusters are the canonical flags used by the run scripts;
    # --M/--K are kept as aliases for convenience on the command line.
    ap.add_argument("--points", "--M", dest="M", type=int, required=True,
                    help="number of points")
    ap.add_argument("--dim", type=int, default=16, help="dimensionality (default 16)")
    ap.add_argument("--clusters", "--K", dest="K", type=int, default=8,
                    help="number of clusters (default 8)")
    ap.add_argument("--seed", type=int, default=42, help="RNG seed (default 42)")
    ap.add_argument("--spread", type=float, default=1.0,
                    help="per-cluster std-dev; smaller = better separated (default 1.0)")
    ap.add_argument("--box", type=float, default=50.0,
                    help="centers are drawn uniformly in [-box, box] per axis")
    ap.add_argument("--out", required=True, help="output path (e.g. data/train.bin)")
    ap.add_argument("--progress", action="store_true", default=None,
                    help="show generation progress on stderr")
    ap.add_argument("--no-progress", action="store_true",
                    help="disable progress output")
    args = ap.parse_args()

    if args.K <= 0 or args.K > args.M:
        print(f"error: need 0 < K <= M (got K={args.K}, M={args.M})", file=sys.stderr)
        return 1

    use_stdlib = not HAVE_NUMPY
    if args.no_progress:
        show_progress = False
    elif args.progress is True:
        show_progress = True
    else:
        show_progress = args.M >= 5000 or use_stdlib

    if HAVE_NUMPY:
        data_bytes, label_bytes = _gen_numpy(
            args.M, args.dim, args.K, args.seed, args.spread, args.box, show_progress)
        backend = "numpy"
    else:
        if args.M * args.dim > 2_000_000:
            print(f"[gen] numpy not found; using the pure-Python fallback for "
                  f"M={args.M} dim={args.dim}. This is slow at this size — "
                  f"`sudo apt install -y python3-numpy` for the fast path.",
                  file=sys.stderr)
        data_bytes, label_bytes = _gen_stdlib(
            args.M, args.dim, args.K, args.seed, args.spread, args.box, show_progress)
        backend = "stdlib"

    out_dir = os.path.dirname(args.out)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)

    if show_progress:
        _log(f"writing {args.out}...")

    with open(args.out, "wb") as f:
        f.write(struct.pack("<3i", args.M, args.dim, args.K))
        f.write(data_bytes)
        f.write(label_bytes)

    mb = (12 + len(data_bytes) + len(label_bytes)) / 1e6
    print(f"wrote {args.out}: M={args.M} dim={args.dim} K={args.K} "
          f"({mb:.1f} MB, seed={args.seed}, spread={args.spread}, backend={backend})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
