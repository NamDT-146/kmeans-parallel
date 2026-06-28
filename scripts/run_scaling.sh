#!/usr/bin/env bash
# Speedup experiment.
#
# Fixes the data scale at 2*N and steps the process count exponentially
# (1, 2, 4, 8, ... up to MAXP) as the assignment requires. For each P it records
# wall time, compute-only time, and comm time, then derives speedup S(P)=T(1)/T(P).
#
# Output: results/scaling.csv with columns
#   P,M,wall_s,compute_s,comm_s,iters,speedup_wall,speedup_compute
# plots/make_plots.py turns this into the runtime + speedup curves.
#
# Usage:
#   N=400000 scripts/run_scaling.sh           # uses 2N internally
#   N=400000 MAXP=12 scripts/run_scaling.sh   # cap the process ladder at 12
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
M=$(( 2 * N ))                 # speedup runs at twice the baseline size

# Default process ladder cap = physical cores (override with MAXP).
if [[ -z "${MAXP:-}" ]]; then
    if command -v sysctl >/dev/null 2>&1; then
        MAXP="$(sysctl -n hw.physicalcpu 2>/dev/null || echo 8)"
    else
        MAXP="$(nproc 2>/dev/null || echo 8)"
    fi
fi

# Extra mpirun flags. On a single laptop with few cores you may need
# --oversubscribe to run more ranks than slots; on the real cluster, leave empty
# and use a hostfile via the HOSTFILE env var.
EXTRA=()
[[ -n "${HOSTFILE:-}" ]] && EXTRA+=(--hostfile "$HOSTFILE")
[[ -n "${OVERSUBSCRIBE:-}" ]] && EXTRA+=(--oversubscribe)

mkdir -p data results
make --no-print-directory >/dev/null

DS="data/scale_${M}.bin"
[[ -f "$DS" ]] || python3 scripts/gen_dataset.py --out "$DS" \
    --points "$M" --dim "$DIM" --clusters "$K" --seed "$SEED"

# Build the exponential ladder 1,2,4,... up to MAXP (always includes MAXP).
PLIST=()
p=1
while (( p < MAXP )); do PLIST+=("$p"); p=$(( p * 2 )); done
PLIST+=("$MAXP")

RAW="results/scaling_raw.csv"
echo "P,M,wall_s,compute_s,comm_s,iters" > "$RAW"

echo "[scale] M=2N=$M dim=$DIM K=$K ladder=${PLIST[*]}"
for P in "${PLIST[@]}"; do
    echo "[scale] -np $P ..."
    # The program prints a SUMMARY line to stderr; capture and parse it.
    LINE="$("$MPIRUN" ${EXTRA[@]+"${EXTRA[@]}"} -np "$P" ./bin/kmeans_mpi \
        "$DS" "$K" "$ITERS" "$EPS" 2>&1 1>/dev/null | grep '^SUMMARY' || true)"
    if [[ -z "$LINE" ]]; then
        echo "[scale] WARN: no SUMMARY for P=$P (run failed?)" >&2
        continue
    fi
    wall=$(sed -n 's/.*wall=\([0-9.]*\).*/\1/p' <<<"$LINE")
    comp=$(sed -n 's/.*compute=\([0-9.]*\).*/\1/p' <<<"$LINE")
    comm=$(sed -n 's/.*comm=\([0-9.]*\).*/\1/p' <<<"$LINE")
    iters=$(sed -n 's/.*iters=\([0-9]*\).*/\1/p' <<<"$LINE")
    echo "$P,$M,$wall,$comp,$comm,$iters" >> "$RAW"
done

# Derive speedup vs the P=1 baseline.
OUT="results/scaling.csv"
python3 - "$RAW" "$OUT" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
rows.sort(key=lambda r: int(r["P"]))
base = next((r for r in rows if int(r["P"]) == 1), None)
t1_wall = float(base["wall_s"]) if base else None
t1_comp = float(base["compute_s"]) if base else None
with open(sys.argv[2], "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["P","M","wall_s","compute_s","comm_s","iters",
                "speedup_wall","speedup_compute"])
    for r in rows:
        P = int(r["P"]); wall = float(r["wall_s"]); comp = float(r["compute_s"])
        sw = (t1_wall / wall) if t1_wall else 1.0
        sc = (t1_comp / comp) if t1_comp else 1.0
        w.writerow([P, r["M"], r["wall_s"], r["compute_s"], r["comm_s"],
                    r["iters"], f"{sw:.4f}", f"{sc:.4f}"])
print(f"[scale] wrote {sys.argv[2]}")
PY

echo "[scale] done — feed results/scaling.csv to plots/make_plots.py."
