#!/usr/bin/env bash
# Bring every node to the same code + binary before a cluster run.
#
# mpirun execs ./bin/kmeans_mpi at the SAME relative path on every host, so a
# stale binary on any slave silently breaks the run (classic symptom: four
# "P=1" lines instead of one "P=<total>" — the binary was linked against a
# different MPI runtime; see docs/RUNBOOK / handoff "singleton bug").
#
# This script brings each host in the hostfile to the same commit + a freshly
# linked binary by running, in the repo:
#     git pull --ff-only   (skip with NO_PULL=1)
#     make clean && make
#
# The MASTER (rank 0, wherever this runs) is built LOCALLY — it never SSHes to
# itself. Only the other nodes are reached over SSH.
#
# The hostfile is the single source of truth for cluster membership — add the
# 3rd/4th node there (via make_hostfile.sh) and it's picked up automatically.
#
# Usage:
#   scripts/sync_nodes.sh
#   HOSTFILE=hosts.txt NODE_USER=mpi scripts/sync_nodes.sh
#   REPO_DIR=parallel-kmeans-mpi scripts/sync_nodes.sh
#   NO_PULL=1 scripts/sync_nodes.sh        # just rebuild, don't git pull
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/_cluster_lib.sh
source "$ROOT/scripts/_cluster_lib.sh"

HOSTFILE="${HOSTFILE:-hostfile}"
REPO_DIR="${REPO_DIR:-$(basename "$ROOT")}"   # path on each node, relative to ~

[[ -f "$HOSTFILE" ]] || { echo "[sync] FAIL: no hostfile '$HOSTFILE' (run make_hostfile.sh first)." >&2; exit 1; }

mapfile -t HOSTS < <(hosts_from_hostfile "$HOSTFILE")
[[ ${#HOSTS[@]} -ge 1 ]] || { echo "[sync] FAIL: no hosts in '$HOSTFILE'." >&2; exit 1; }
# Which host is local (the master, run by fork not SSH) is decided per-host by
# is_local() in _cluster_lib.sh — by identity, not list position.

if [[ -n "${NO_PULL:-}" ]]; then
    BUILD='make clean >/dev/null && make'
else
    BUILD='git pull --ff-only && make clean >/dev/null && make'
fi

echo "[sync] hosts: ${HOSTS[*]}"
echo "[sync] repo on each node: ~/$REPO_DIR   ($( [[ -n "${NO_PULL:-}" ]] && echo 'rebuild only' || echo 'git pull + rebuild'))"

fail=0
for host in "${HOSTS[@]}"; do
    tag="$host"; is_local "$host" && tag="$host (master, local)"
    echo "[sync] ===== $tag ====="
    # The master builds in this very checkout ($ROOT); workers build in ~/REPO_DIR.
    if is_local "$host"; then
        cmd="cd '$ROOT' && $BUILD"
    else
        cmd="cd ~/$REPO_DIR && $BUILD"
    fi
    if run_on "$host" "$cmd" 2>&1 | sed "s/^/[sync:$host] /"; then
        # Confirm the binary is present and report its commit for an audit trail.
        if is_local "$host"; then
            check="cd '$ROOT' && test -x bin/kmeans_mpi && git rev-parse --short HEAD"
        else
            check="cd ~/$REPO_DIR && test -x bin/kmeans_mpi && git rev-parse --short HEAD"
        fi
        commit="$(run_on "$host" "$check" 2>/dev/null || true)"
        if [[ -n "$commit" ]]; then
            printf "[sync] OK   %-22s commit=%s\n" "$host" "$commit"
        else
            echo "[sync] FAIL: bin/kmeans_mpi missing on $host after build." >&2; fail=1
        fi
    else
        echo "[sync] FAIL: build failed on $host (see lines above)." >&2; fail=1
    fi
done

if (( fail )); then
    echo "[sync] one or more nodes failed — fix before running the demo." >&2
    exit 1
fi
echo "[sync] all nodes synced and built. Next: scripts/preflight.sh"
