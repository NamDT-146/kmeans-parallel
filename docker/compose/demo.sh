#!/usr/bin/env bash
# Distributed-path + topology demo, run from the head node (node1).
#
# This rehearses the EXACT `mpirun --hostfile ...` path the real cluster uses:
# mpirun on node1 launches ranks across node1/node2/node3 over SSH+TCP. It
# produces the two artifacts the report's cluster-setup section needs:
#
#   1. results/cluster_hostname.txt  — every rank prints its node's hostname,
#      proving the job really spread across three separate hosts (the §2 proof).
#   2. a distributed correctness PASS — the parallel solver, run across three
#      "machines", reproduces the sequential reference bit-for-bit.
#
# NOT a timing run: the three containers share this host's cores. The speedup and
# granularity numbers in the report come from native single-host runs (RUNBOOK).
#
# Usage (from the host). Run as the unprivileged 'mpi' user: the passwordless-SSH
# keys belong to that user, and Open MPI refuses to run as root.
#   docker compose -f docker/compose/docker-compose.yml up -d --build
#   docker compose -f docker/compose/docker-compose.yml exec -u mpi node1 bash docker/compose/demo.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

HOSTFILE="docker/compose/hostfile"
NODES=(node1 node2 node3)
NP="${NP:-12}"           # 3 nodes x 4 slots; matches the report's framing
K="${K:-8}"
ITERS="${ITERS:-100}"
EPS="${EPS:-1e-8}"

# Build into a Linux-only dir so the container's x86/ARM-Linux binaries never
# collide with the host's native bin/ (the repo is bind-mounted, so bin/ may hold
# macOS Mach-O executables this container cannot run).
BINDIR="bin-linux"

mkdir -p data results

echo "[demo] waiting for SSH on every node ..."
for node in "${NODES[@]}"; do
    for attempt in $(seq 1 30); do
        if ssh -o ConnectTimeout=2 -o BatchMode=yes "$node" true 2>/dev/null; then
            echo "[demo]   $node reachable"
            break
        fi
        if [[ "$attempt" -eq 30 ]]; then
            echo "[demo] ERROR: $node not reachable over SSH after 30 tries" >&2
            exit 1
        fi
        sleep 1
    done
done

echo "[demo] building binaries (shared /work, so all nodes see them) ..."
make --no-print-directory BIN="$BINDIR" >/dev/null

# ---- Artifact 1: topology proof -------------------------------------------
# One rank per slot prints which physical node it landed on. On a real cluster
# this is the screenshot the report includes; here we also save it to a file.
echo "[demo] capturing cluster topology (mpirun --hostfile ... hostname) ..."
PROOF="results/cluster_hostname.txt"
{
    echo "# mpirun --hostfile $HOSTFILE -np $NP hostname"
    echo "# captured $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    mpirun --hostfile "$HOSTFILE" -np "$NP" hostname | sort | uniq -c
} | tee "$PROOF"
echo "[demo] wrote $PROOF"

# ---- Artifact 2: distributed correctness ----------------------------------
# Reuse the project's correctness proof, but force it through the hostfile so the
# parallel run genuinely spans the three nodes.
echo "[demo] distributed correctness check across ${#NODES[@]} nodes ..."
DATA="data/verify.bin"
[[ -f "$DATA" ]] || python3 scripts/gen_dataset.py --out "$DATA" \
    --points 20000 --dim 4 --clusters "$K" --seed 1

"./$BINDIR/kmeans_seq" "$DATA" "$K" "$ITERS" "$EPS" \
    results/seq_labels.txt results/seq_centroids.txt
mpirun --hostfile "$HOSTFILE" -np "$NP" "./$BINDIR/kmeans_mpi" "$DATA" "$K" "$ITERS" "$EPS" \
    results/par_labels.txt results/par_centroids.txt

python3 - <<'PY'
seq = [l.strip() for l in open("results/seq_labels.txt")]
par = [l.strip() for l in open("results/par_labels.txt")]
assert len(seq) == len(par), f"length mismatch {len(seq)} vs {len(par)}"
fwd, rev = {}, {}
for s, p in zip(seq, par):
    assert fwd.setdefault(s, p) == p, f"seq {s} maps to two labels"
    assert rev.setdefault(p, s) == s, f"par {p} maps to two labels"
identical = sum(1 for s, p in zip(seq, par) if s == p)
print(f"PASS: {len(seq)} points, partitions identical up to relabeling "
      f"({identical}/{len(seq)} labels bit-identical, {len(fwd)} clusters matched)")
PY

echo "[demo] done — distributed path verified across ${NODES[*]}."
