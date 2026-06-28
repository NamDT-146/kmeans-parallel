#!/usr/bin/env bash
# One-command, repeatable cluster demo. Run this on the MASTER (rank 0) after the
# nodes are up and passwordless SSH works. It chains the whole pipeline in order
# and stops at the first failure with a specific hint, so the live demo is a
# single deterministic command instead of a sequence to remember.
#
# Stages:
#   0. make_hostfile.sh   build the hostfile by probing nproc on each node
#                         (skipped if a hostfile already exists, unless FRESH=1)
#   1. sync_nodes.sh      git pull + make on every node -> same commit + binary
#   2. preflight.sh       SSH / MPI / binary / launch / singleton-bug checks
#   3. verify_correctness across the cluster (parallel == sequential, PASS)
#   4. run_size_sweep     runtime vs input size  -> results/size_sweep.csv
#   5. run_granularity    per-rank load balance  -> results/granularity.csv
#   6. run_scaling        speedup ladder at 2N   -> results/scaling.csv
#   7. make_plots.py      all six report figures -> results/fig_*.png
#
# Cluster membership lives in the hostfile (single source of truth). Add the 3rd
# or 4th machine by re-running with NODES set: if the NODES count differs from the
# existing hostfile, the hostfile is rebuilt automatically (no need for FRESH=1).
#
# Usage:
#   # first time / when node set changes — probe nproc over SSH and build hostfile:
#   NODES="node0 node1 node2" NODE_USER=mpi scripts/run_demo.sh
#
#   # you can also pass raw IPs (first = master, treated as local, no SSH to self):
#   NODES="172.20.10.9 172.20.10.8 172.20.10.10" NODE_USER=mpi scripts/run_demo.sh
#
#   # subsequent runs — reuse the existing hostfile:
#   NODE_USER=mpi scripts/run_demo.sh
#
#   # pin the interface if OpenMPI auto-select misfires (usually auto-detected):
#   MPI_IF=enp0s3 NODE_USER=mpi scripts/run_demo.sh
#
#   # skip the long experiments, just prove the cluster works (correctness only):
#   QUICK=1 NODE_USER=mpi scripts/run_demo.sh
#
# Env knobs (all optional):
#   NODES      space-separated hosts; required only to (re)build the hostfile.
#              First host is the master (rank 0) and is treated as LOCAL — it is
#              never SSHed to, so the master needs no passwordless SSH to itself.
#   NODE_USER  SSH/login user shared by every node (e.g. mpi)
#   HOSTFILE   hostfile path (default: hostfile)
#   FRESH=1    force-rebuild the hostfile even if one exists with the right count
#   QUICK=1    stop after correctness (skip sweep/granularity/scaling/plots)
#   NO_SYNC=1  skip the git-pull+rebuild stage (nodes already in sync)
#   N          baseline size for granularity/scaling (default: auto from sweep)
#   MPI_IF     network interface to pin for mpirun (default: auto-detected LAN iface)
#   SIZES      override the size-sweep ladder
#
# Networking note: cross-node MPI is pinned to the LAN IPv4 interface with IPv6
# disabled in the TCP transport (see scripts/_cluster_lib.sh mpi_mca_flags). This
# is required on bridged VMs whose interfaces also carry non-routable IPv6
# addresses — without it OpenMPI tries those and aborts with "Unable to find
# reachable pairing between local and remote interfaces".
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HOSTFILE="${HOSTFILE:-hostfile}"
export HOSTFILE
[[ -n "${NODE_USER:-}" ]] && export NODE_USER
[[ -n "${MPI_IF:-}" ]] && export MPI_IF

say() { printf '\n========== %s ==========\n' "$*"; }

# --- NODES default from /etc/hosts -----------------------------------------
# The master's bootstrap (bootstrap_node.sh step 5) writes the cluster's node
# aliases into /etc/hosts inside a marked block, master first:
#   # >>> kmeans-cluster >>>
#   192.168.1.50  node0
#   192.168.1.51  node1
#   ...
#   # <<< kmeans-cluster <<<
# If NODES wasn't passed, recover it from that block so a first run doesn't make
# you retype the list. We use the node* aliases (in file order = rank order);
# node0 is the master and is treated as local. Empty if the block is absent.
if [[ -z "${NODES:-}" ]]; then
    NODES="$(awk '
        /# >>> kmeans-cluster >>>/{f=1; next}
        /# <<< kmeans-cluster <<</{f=0}
        f && $2 ~ /^node[0-9]+$/ {print $2}
    ' /etc/hosts 2>/dev/null | paste -sd' ' -)"
    [[ -n "$NODES" ]] && echo "[demo] NODES not set; using /etc/hosts aliases: $NODES"
fi

# --- 0. hostfile ------------------------------------------------------------
# Decide whether to (re)build the hostfile. Rebuild when:
#   - FRESH=1 is set, or
#   - no hostfile exists yet, or
#   - NODES is set and its node COUNT differs from the existing hostfile.
# That last case is the trap to avoid: you pass NODES="node0 node1 node2" but an
# old 2-node hostfile is silently reused, so node2 never joins. We detect the
# mismatch and rebuild instead of running on the wrong cluster.
need_build=""
if [[ -n "${FRESH:-}" || ! -f "$HOSTFILE" ]]; then
    need_build=1
elif [[ -n "${NODES:-}" ]]; then
    want_n="$(wc -w <<<"$NODES")"
    have_n="$(grep -cvE '^\s*(#|$)' "$HOSTFILE" 2>/dev/null || echo 0)"
    if [[ "$want_n" != "$have_n" ]]; then
        echo "[demo] NODES requests $want_n node(s) but '$HOSTFILE' has $have_n — rebuilding." >&2
        need_build=1
    fi
fi

if [[ -n "$need_build" ]]; then
    [[ -n "${NODES:-}" ]] || {
        echo "[demo] No hostfile and NODES unset, and no kmeans-cluster aliases" >&2
        echo "       found in /etc/hosts. Either run the master bootstrap first:" >&2
        echo "         ROLE=master scripts/bootstrap_node.sh   # writes node aliases" >&2
        echo "       or pass the nodes explicitly:" >&2
        echo "         NODES=\"node0 node1 node2\" NODE_USER=mpi scripts/run_demo.sh" >&2
        exit 1; }
    say "0/7  build hostfile from: $NODES"
    # shellcheck disable=SC2086
    scripts/make_hostfile.sh $NODES
fi

NODE_COUNT="$(grep -cvE '^\s*(#|$)' "$HOSTFILE")"
TOTAL="$(grep -vE '^\s*(#|$)' "$HOSTFILE" | sed -n 's/.*slots=\([0-9]*\).*/\1/p' | paste -sd+ - | bc)"
echo "[demo] cluster: $NODE_COUNT node(s), $TOTAL total slots (hostfile: $HOSTFILE)"
[[ "$NODE_COUNT" -ge 3 ]] || echo "[demo] WARN: assignment requires >= 3 physical machines (have $NODE_COUNT)."

# --- 1. sync code + binary to every node ------------------------------------
if [[ -z "${NO_SYNC:-}" ]]; then
    say "1/7  sync nodes (git pull + make on each)"
    scripts/sync_nodes.sh
else
    say "1/7  sync skipped (NO_SYNC=1)"
fi

# --- 2. preflight health check ----------------------------------------------
say "2/7  preflight checks"
scripts/preflight.sh

# --- 3. correctness across the cluster --------------------------------------
say "3/7  correctness: parallel == sequential (across the cluster)"
scripts/verify_correctness.sh

if [[ -n "${QUICK:-}" ]]; then
    say "QUICK mode: cluster proven (topology + correctness). Stopping before experiments."
    # The clustering RESULT figure only needs the dataset + the parallel labels
    # that verify_correctness.sh just produced — no experiment CSVs required — so
    # render and show it even in QUICK mode. OPEN=0 suppresses opening (headless).
    if python3 -c 'import matplotlib' 2>/dev/null; then
        OPEN_FLAG=""; [[ "${OPEN:-1}" != "0" ]] && OPEN_FLAG="--open"
        python3 plots/make_plots.py $OPEN_FLAG || true
    else
        echo "[demo] (matplotlib absent — skipping the result figure)" >&2
    fi
    echo "[demo] artifacts: results/cluster_hostname.txt, results/{seq,par}_labels.txt, results/fig_clustering.png"
    exit 0
fi

# --- 4. size sweep ----------------------------------------------------------
say "4/7  size sweep (runtime vs input size)"
P="$TOTAL" scripts/run_size_sweep.sh

# Pick N: the largest swept size whose wall time is <= 180s, else the largest
# completed size. Reported numbers come from the cluster's own aggregate HW.
if [[ -z "${N:-}" ]]; then
    N="$(python3 - <<'PY'
import csv
rows=[r for r in csv.DictReader(open("results/size_sweep.csv")) if r.get("wall_s")]
def f(r):
    try: return float(r["wall_s"])
    except: return None
ok=[r for r in rows if f(r) is not None]
band=[r for r in ok if f(r)<=180.0]
pick=(band[-1] if band else (ok[-1] if ok else None))
print(pick["M"] if pick else "")
PY
)"
    [[ -n "$N" ]] || { echo "[demo] FAIL: size sweep produced no usable rows." >&2; exit 1; }
    echo "[demo] auto-selected N=$N from size_sweep.csv"
fi

# --- 5. granularity / load balance ------------------------------------------
say "5/7  granularity / load balance at N=$N"
N="$N" P="$TOTAL" scripts/run_granularity.sh

# --- 6. speedup ladder ------------------------------------------------------
say "6/7  speedup ladder 1,2,4,... up to $TOTAL at 2N"
N="$N" MAXP="$TOTAL" scripts/run_scaling.sh

# --- 7. figures -------------------------------------------------------------
# The graded CSVs (size_sweep/granularity/scaling) are already on disk from
# stages 4-6. Plotting needs matplotlib; if it's missing, don't crash the whole
# demo over a figure step — report it and let the user render later.
say "7/7  render figures"
if python3 -c 'import matplotlib' 2>/dev/null; then
    # OPEN=0 suppresses opening the images (e.g. a headless cluster node);
    # default is to open every figure in the OS image viewer after rendering.
    OPEN_FLAG=""; [[ "${OPEN:-1}" != "0" ]] && OPEN_FLAG="--open"
    python3 plots/make_plots.py $OPEN_FLAG
else
    echo "[demo] WARN: matplotlib not installed — skipping figures." >&2
    echo "[demo]       CSVs are saved in results/. To draw the figures later:" >&2
    echo "[demo]         sudo apt-get install -y python3-matplotlib && python3 plots/make_plots.py" >&2
fi

say "DEMO COMPLETE"
cat <<EOF
[demo] cluster: $NODE_COUNT nodes / $TOTAL cores | operating size N=$N
[demo] evidence:
  results/cluster_hostname.txt   per-node rank topology (>=3 machines)
  results/{seq,par}_labels.txt   correctness PASS (parallel == sequential)
  results/fig_clustering.png     the k-means RESULT (points coloured by cluster)
  results/size_sweep.csv         runtime vs size  -> results/fig_size_sweep.png
  results/granularity.csv        load balance     -> results/fig_granularity.png
  results/scaling.csv            speedup ladder    -> results/fig_speedup.png, fig_runtime.png
  results/fig_efficiency.png, results/fig_comm_fraction.png
[demo] next: fill docs/REPORT_OUTLINE.md from these CSVs/figures.
EOF
