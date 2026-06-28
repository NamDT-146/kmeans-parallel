#!/usr/bin/env bash
# Build an OpenMPI hostfile by probing each node's core count.
#
# Node-count agnostic: pass any number of hosts; adding the 3rd (or 4th) machine
# later is just another argument. Rank 0 (the master) is whichever listed host
# IS this machine — detected by identity, NOT by argument order. mpirun launches
# the master's rank by fork (not SSH) and rank 0 reads the dataset and Scatterv's
# the rows, so the data file only needs to live on the master.
#
# The master is probed LOCALLY; only the other nodes are probed over SSH. So the
# master never needs passwordless SSH to itself.
#
# Two silent-wrong-cluster failure modes are caught here and turned into hard
# errors (instead of producing a cluster of clones):
#   - two aliases that resolve to the SAME machine (e.g. 'node1' mis-pointed at
#     the master's IP in /etc/hosts), and
#   - an alias that doesn't resolve at all.
#
# Usage:
#   scripts/make_hostfile.sh node0 node1 node2 [node3 ...]
#   NODE_USER=mpi scripts/make_hostfile.sh 192.168.1.50 192.168.1.51 192.168.1.52
#   SLOTS=4 scripts/make_hostfile.sh node0 node1 node2   # force slots, skip nproc probe
#   OUT=hosts.txt scripts/make_hostfile.sh node0 node1 node2
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/_cluster_lib.sh
source "$ROOT/scripts/_cluster_lib.sh"

[[ $# -ge 1 ]] || { echo "usage: $0 <host1> [host2 ...]" >&2; exit 1; }

OUT="${OUT:-hostfile}"

# --- resolve + classify every host -----------------------------------------
# Which host is "local" is decided by identity (is_local), so rank 0 is whichever
# listed host is this machine regardless of order. We also resolve each host to a
# canonical IP to catch two distinct aliases that point at the same box.
declare -a LOCAL_HOSTS=()
declare -a REMOTE_HOSTS=()
declare -A IP_OWNER=()

for host in "$@"; do
    ip="$(_resolve "$host" | head -1)"
    if [[ -z "$ip" ]]; then
        echo "[hostfile] FAIL: '$host' does not resolve to an IP." >&2
        echo "           Add it to /etc/hosts (run bootstrap_node.sh on the master)" >&2
        echo "           or pass a real IP/hostname." >&2
        exit 1
    fi
    if [[ -n "${IP_OWNER[$ip]:-}" ]]; then
        echo "[hostfile] FAIL: '$host' and '${IP_OWNER[$ip]}' both resolve to $ip." >&2
        echo "           Each node must be a DISTINCT machine. A worker alias is" >&2
        echo "           probably pointing at the wrong IP in /etc/hosts — fix it" >&2
        echo "           (re-run 'ROLE=master scripts/bootstrap_node.sh' to reset)." >&2
        exit 1
    fi
    IP_OWNER[$ip]="$host"
    if is_local "$host"; then
        LOCAL_HOSTS+=("$host")
    else
        REMOTE_HOSTS+=("$host")
    fi
done

if [[ ${#LOCAL_HOSTS[@]} -eq 0 ]]; then
    echo "[hostfile] FAIL: none of the listed hosts is THIS machine." >&2
    echo "           Run this on the master and include its alias/IP in the list." >&2
    echo "           this machine's IPs: $(local_ips | paste -sd' ' -)" >&2
    exit 1
fi
if [[ ${#LOCAL_HOSTS[@]} -gt 1 ]]; then
    echo "[hostfile] FAIL: multiple aliases map to THIS machine: ${LOCAL_HOSTS[*]}" >&2
    echo "           Only the master should resolve here; fix /etc/hosts." >&2
    exit 1
fi

# Rank 0 = the local node, then the remotes in the order given.
ORDERED=("${LOCAL_HOSTS[0]}" "${REMOTE_HOSTS[@]}")

# --- probe nproc + write the hostfile ---------------------------------------
: > "$OUT.tmp"
total=0
for host in "${ORDERED[@]}"; do
    if [[ -n "${SLOTS:-}" ]]; then
        slots="$SLOTS"
    else
        # Master probed locally, workers over SSH (run_on handles the split).
        slots="$(run_on "$host" nproc 2>/dev/null || true)"
        [[ "$slots" =~ ^[0-9]+$ ]] || {
            echo "[hostfile] FAIL: could not read nproc on '$host'." >&2
            if is_local "$host"; then
                echo "           (this is the master — 'nproc' failed locally?)" >&2
            else
                echo "           Check passwordless SSH: ssh ${SSH_USER}${host} hostname" >&2
                echo "           Set it up with: scripts/exchange_keys.sh" >&2
            fi
            rm -f "$OUT.tmp"; exit 1; }
    fi
    # For the master, write its REAL hostname (not the user's alias). OpenMPI
    # matches the hostfile entry against its own hostname to decide locality; an
    # alias like 'node0' that /etc/hosts maps to some other IP makes OpenMPI
    # think the master is remote and SSH to itself (stale host key, hang). The
    # canonical hostname is always recognised as local -> rank 0 is forked.
    write_name="$host"
    if is_local "$host"; then
        write_name="$(master_token)"
    fi
    echo "$write_name slots=$slots" >> "$OUT.tmp"
    total=$(( total + slots ))
    printf "[hostfile] %-22s slots=%s%s\n" "$write_name" "$slots" \
        "$(is_local "$host" && echo '  (rank 0, local)')"
done
mv "$OUT.tmp" "$OUT"
echo "[hostfile] wrote $OUT  (total slots = $total; rank 0 = $(master_token), local)"
