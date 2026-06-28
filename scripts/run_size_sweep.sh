#!/usr/bin/env bash
# Size sweep: find N such that the parallel program runs for ~2-3 minutes when
# using all physical cores.
#
# We fix P to the number of physical cores (or override via the P env var) and
# step the dataset size M upward, recording wall time with and without the
# communication component. The output CSV feeds plots/make_plots.py, which draws
# "runtime vs input size" so you can read off the N that lands in 120-180 s.
#
# Usage:
#   scripts/run_size_sweep.sh
#   P=12 SIZES="200000 400000 800000 1600000 3200000" scripts/run_size_sweep.sh
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

# Default process count = physical cores on this box.
if [[ -z "${P:-}" ]]; then
    if command -v sysctl >/dev/null 2>&1; then
        P="$(sysctl -n hw.physicalcpu 2>/dev/null || echo 4)"
    else
        P="$(nproc 2>/dev/null || echo 4)"
    fi
fi

SIZES="${SIZES:-50000 100000 200000 400000 800000}"
OUT="results/size_sweep.csv"

# Extra mpirun flags. Set HOSTFILE to run across the cluster; OVERSUBSCRIBE to
# pack more ranks than slots on a single box.
EXTRA=()
# shellcheck disable=SC2206
[[ -n "${HOSTFILE:-}" ]] && EXTRA+=(--hostfile "$HOSTFILE" $(mpi_mca_flags))
[[ -n "${OVERSUBSCRIBE:-}" ]] && EXTRA+=(--oversubscribe)

mkdir -p data results
make --no-print-directory >/dev/null

echo "M,dim,K,P,iters,wall_s,compute_s,comm_s" > "$OUT"
echo "[sweep] P=$P dim=$DIM K=$K iters=$ITERS sizes: $SIZES"

for M in $SIZES; do
    DS="data/sweep_${M}.bin"
    [[ -f "$DS" ]] || python3 scripts/gen_dataset.py --out "$DS" \
        --points "$M" --dim "$DIM" --clusters "$K" --seed "$SEED"

    # Capture the SUMMARY line the MPI program prints to stderr.
    SUMMARY="$("$MPIRUN" ${EXTRA[@]+"${EXTRA[@]}"} -np "$P" ./bin/kmeans_mpi "$DS" "$K" "$ITERS" "$EPS" \
        2>&1 1>/dev/null | grep '^SUMMARY' || true)"
    WALL="$(sed -n 's/.*wall=\([0-9.]*\).*/\1/p'    <<<"$SUMMARY")"
    COMP="$(sed -n 's/.*compute=\([0-9.]*\).*/\1/p' <<<"$SUMMARY")"
    COMM="$(sed -n 's/.*comm=\([0-9.]*\).*/\1/p'    <<<"$SUMMARY")"
    echo "$M,$DIM,$K,$P,$ITERS,$WALL,$COMP,$COMM" >> "$OUT"
    printf "[sweep] M=%-9s wall=%ss comm=%ss\n" "$M" "$WALL" "$COMM"
done

echo "[sweep] wrote $OUT"
echo "[sweep] pick N where wall_s is ~120-180; set it as N for the next steps."
