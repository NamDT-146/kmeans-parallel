#!/usr/bin/env bash
# Pre-demo health check for the cluster. Run AFTER make_hostfile.sh + sync_nodes.sh
# and BEFORE the graded demo. Catches every failure mode we hit during setup:
#   1. passwordless SSH to the WORKERS (mpirun launches them non-interactively —
#      a prompt = hang). The master is checked locally; it never SSHes to itself.
#   2. mixed MPI implementations across nodes (must all be the same; we use OpenMPI)
#   3. stale / missing binary (the "four P=1 lines" singleton bug)
#   4. wrong network interface auto-selected by OpenMPI (rank callbacks hang)
#
# Exits non-zero on the first hard failure with a specific fix hint.
#
# Usage:
#   scripts/preflight.sh
#   HOSTFILE=hosts.txt NODE_USER=mpi scripts/preflight.sh
#   MPI_IF=enp0s3 scripts/preflight.sh    # pin the interface if auto-select misfires
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/_cluster_lib.sh
source "$ROOT/scripts/_cluster_lib.sh"

HOSTFILE="${HOSTFILE:-hostfile}"
REPO_DIR="${REPO_DIR:-$(basename "$ROOT")}"
MPIRUN="${MPIRUN:-mpirun}"

[[ -f "$HOSTFILE" ]] || { echo "[preflight] FAIL: no hostfile '$HOSTFILE'." >&2; exit 1; }

mapfile -t HOSTS < <(hosts_from_hostfile "$HOSTFILE")
# Which host is local (the master, checked locally not over SSH) is decided
# per-host by is_local() in _cluster_lib.sh — by identity, not list position.
TOTAL="$(total_slots_from_hostfile "$HOSTFILE")"
[[ "${TOTAL:-0}" -ge 1 ]] || { echo "[preflight] FAIL: could not total slots from '$HOSTFILE'." >&2; exit 1; }

# MCA flags pin the TCP transport to the LAN interface and disable IPv6 (settled
# empirically — see mpi_mca_flags in _cluster_lib.sh). MPI_IF overrides the iface.
EXTRA=(--hostfile "$HOSTFILE")
# shellcheck disable=SC2046
EXTRA+=($(mpi_mca_flags))
# Stream each rank's stderr live (OpenMPI 5.x buffers to exit otherwise) so the
# stage-5 progress bar shows motion. Probed, so it's a no-op on MPIs without it.
# shellcheck disable=SC2046
EXTRA+=($(mpi_unbuffer_flag))

echo "[preflight] hostfile '$HOSTFILE': ${#HOSTS[@]} node(s), $TOTAL total slots"
if [[ ${#HOSTS[@]} -lt 3 ]]; then
    echo "[preflight] WARN: only ${#HOSTS[@]} node(s). The assignment requires >= 3 physical machines."
fi

# --- 1. reachability: master locally, workers over passwordless SSH ---------
echo "[preflight] [1/5] reach each node (master local, workers over SSH)"
for host in "${HOSTS[@]}"; do
    if is_local "$host"; then
        echo "[preflight]   OK   $host (master, local — no SSH needed)"
    elif ssh -o BatchMode=yes -o ConnectTimeout=8 "${SSH_USER}${host}" true 2>/dev/null; then
        echo "[preflight]   OK   $host"
    else
        echo "[preflight]   FAIL: '$host' needs a password or is unreachable." >&2
        echo "[preflight]   fix: ssh-copy-id ${SSH_USER}${host}  (and check it's on the LAN)." >&2
        exit 1
    fi
done

# --- 2. same MPI implementation + version on every node ---------------------
echo "[preflight] [2/5] MPI implementation consistent across nodes"
ref=""
for host in "${HOSTS[@]}"; do
    ver="$(run_on "$host" 'mpirun --version 2>&1 | head -1' 2>/dev/null || true)"
    [[ -n "$ver" ]] || { echo "[preflight]   FAIL: no mpirun on '$host' (re-run bootstrap_node.sh)." >&2; exit 1; }
    printf "[preflight]   %-22s %s\n" "$host" "$ver"
    if [[ -z "$ref" ]]; then ref="$ver"
    elif [[ "$ver" != "$ref" ]]; then
        echo "[preflight]   FAIL: MPI differs across nodes — every node must use the SAME impl/version." >&2
        exit 1
    fi
done

# --- 3. binary present at the same path on every node -----------------------
echo "[preflight] [3/5] bin/kmeans_mpi present + same commit on every node"
ref_commit=""
for host in "${HOSTS[@]}"; do
    if is_local "$host"; then
        dir="$ROOT"
    else
        dir="\$HOME/$REPO_DIR"
    fi
    line="$(run_on "$host" "cd $dir 2>/dev/null && test -x bin/kmeans_mpi && git rev-parse --short HEAD" 2>/dev/null || true)"
    [[ -n "$line" ]] || {
        echo "[preflight]   FAIL: bin/kmeans_mpi missing on '$host' — run scripts/sync_nodes.sh." >&2; exit 1; }
    printf "[preflight]   %-22s commit=%s\n" "$host" "$line"
    if [[ -z "$ref_commit" ]]; then ref_commit="$line"
    elif [[ "$line" != "$ref_commit" ]]; then
        echo "[preflight]   WARN: '$host' is at $line, master at $ref_commit — re-run sync_nodes.sh." >&2
    fi
done

# --- 4. cluster hostname smoke test (proves SSH+TCP launch path) ------------
# mpirun launches the master's rank by fork and the workers over SSH itself, so
# this does not go through run_on — it's the real launch path under test.
echo "[preflight] [4/5] mpirun hostname across the cluster (-np $TOTAL)"
HN="$("$MPIRUN" "${EXTRA[@]}" -np "$TOTAL" hostname 2>&1 || true)"
if [[ -z "$HN" ]]; then
    echo "[preflight]   FAIL: mpirun hostname produced no output (launch path broken)." >&2
    echo "[preflight]   hint: try MPI_IF=<iface> to pin the interface (see handoff 2b/2d)." >&2
    exit 1
fi
echo "$HN" | sort | uniq -c | sed 's/^/[preflight]   /'
mkdir -p results
echo "$HN" | sort | uniq -c > results/cluster_hostname.txt
echo "[preflight]   saved topology proof -> results/cluster_hostname.txt"

# --- 5. real run, must report a SINGLE P=<total> line (no singleton bug) ----
echo "[preflight] [5/5] tiny kmeans run, expect one 'P=$TOTAL' line"
[[ -f data/t.bin ]] || {
    echo "[preflight] generating probe dataset data/t.bin (20k points)..."
    python3 scripts/gen_dataset.py --out data/t.bin --points 20000 --dim 16 --clusters 16 --seed 7 --progress
}
# KMEANS_PROGRESS=1 makes rank 0 draw a live bar on STDERR; we let that flow to
# the terminal so the run shows motion instead of looking hung, while still
# capturing STDOUT (the 'P=' line) for the singleton-bug check below.
RUN="$(KMEANS_PROGRESS=1 "$MPIRUN" "${EXTRA[@]}" -np "$TOTAL" ./bin/kmeans_mpi data/t.bin 16 50 1e-9 || true)"
pcount="$(grep -c "P=$TOTAL " <<<"$RUN" || true)"
psingle="$(grep -c 'P=1 ' <<<"$RUN" || true)"
echo "$RUN" | sed 's/^/[preflight]   /'
if [[ "$pcount" -ge 1 ]]; then
    echo "[preflight]   OK: single P=$TOTAL run — ranks share one communicator."
elif [[ "$psingle" -ge 1 ]]; then
    echo "[preflight]   FAIL: saw P=1 lines (singleton bug). Binary linked vs a different MPI." >&2
    echo "[preflight]   fix: scripts/sync_nodes.sh (make clean && make on every node)." >&2
    exit 1
else
    echo "[preflight]   FAIL: no P= line — run did not complete." >&2; exit 1
fi

echo "[preflight] ALL CHECKS PASSED — cluster is demo-ready. Next: scripts/run_demo.sh"
