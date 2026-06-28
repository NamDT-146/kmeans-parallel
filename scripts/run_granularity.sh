#!/usr/bin/env bash
# Granularity / load-balance probe.
#
# Runs the parallel program once at the chosen baseline size N using all cores
# (P = physical cores, override with the P env var) and writes a per-rank timing
# CSV: compute_s and comm_s for every rank. plots/make_plots.py renders this as a
# stacked bar chart (compute + comm per rank) so you can see whether the work is
# balanced.
#
# Decision rule from the assignment: if the idle time between any two ranks
# differs by more than 25%, re-tune granularity (finer or coarser). The script
# computes that spread and prints a PASS/RETUNE verdict.
#
# Usage:
#   N=800000 scripts/run_granularity.sh
#   N=800000 P=12 scripts/run_granularity.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/_cluster_lib.sh
source "$ROOT/scripts/_cluster_lib.sh"

MPIRUN="${MPIRUN:-mpirun}"
DIM="${DIM:-16}"
K="${K:-16}"
ITERS="${ITERS:-50}"
EPS="${EPS:-1e-9}"
SEED="${SEED:-7}"
N="${N:-200000}"

if [[ -z "${P:-}" ]]; then
    if command -v sysctl >/dev/null 2>&1; then
        P="$(sysctl -n hw.physicalcpu 2>/dev/null || echo 4)"
    else
        P="$(nproc 2>/dev/null || echo 4)"
    fi
fi

mkdir -p data results
make --no-print-directory >/dev/null

DS="data/gran_${N}.bin"
[[ -f "$DS" ]] || python3 scripts/gen_dataset.py --out "$DS" \
    --points "$N" --dim "$DIM" --clusters "$K" --seed "$SEED"

# Optional cross-node execution: HOSTFILE=cluster_hostfile to span the cluster.
EXTRA=()
# shellcheck disable=SC2206
[[ -n "${HOSTFILE:-}" ]] && EXTRA+=(--hostfile "$HOSTFILE" $(mpi_mca_flags))
[[ -n "${OVERSUBSCRIBE:-}" ]] && EXTRA+=(--oversubscribe)

CSV="results/granularity.csv"
echo "[gran] N=$N P=$P dim=$DIM K=$K -> $CSV"
"$MPIRUN" ${EXTRA[@]+"${EXTRA[@]}"} -np "$P" ./bin/kmeans_mpi "$DS" "$K" "$ITERS" "$EPS" \
    /dev/null /dev/null "$CSV"

# Load-balance verdict: spread of compute time across ranks. The slowest rank
# defines the critical path; the fastest one sits idle for the difference.
python3 - "$CSV" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
comp = [float(r["compute_s"]) for r in rows]
lo, hi = min(comp), max(comp)
spread = (hi - lo) / hi * 100 if hi > 0 else 0.0
print(f"[gran] compute per rank: min={lo:.4f}s max={hi:.4f}s spread={spread:.1f}%")
if spread > 25.0:
    print("[gran] RETUNE: spread > 25% — adjust granularity (finer/coarser).")
else:
    print("[gran] PASS: load is balanced within 25%.")
PY

echo "[gran] wrote $CSV — feed to plots/make_plots.py for the stacked chart."
