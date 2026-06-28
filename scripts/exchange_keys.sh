#!/usr/bin/env bash
# Push the master's SSH public key to every worker so mpirun can launch them
# non-interactively. Run this ONCE on the master after bootstrap, before the demo.
#
# Why: mpirun and the orchestration scripts SSH into the workers without a TTY,
# so they need KEY-based auth — a shared login password is not enough. This wraps
# ssh-copy-id for each worker. Because every node shares the same password in the
# lab setup, you just type that password once per worker.
#
# Node-count agnostic. With no arguments it reads the node aliases the master's
# bootstrap wrote into /etc/hosts (the kmeans-cluster block, master first). The
# master (node0 / first host / this machine) is skipped — it never SSHes to
# itself. Pass hosts explicitly to override.
#
# Usage:
#   scripts/exchange_keys.sh                       # workers from /etc/hosts
#   scripts/exchange_keys.sh node1 node2 node3     # explicit list
#   NODE_USER=mpi scripts/exchange_keys.sh         # set the shared login user
#   NODE_USER=mpi scripts/exchange_keys.sh 192.168.1.51 192.168.1.52
#
# After this, verify with:  ssh node1 hostname   (no password prompt)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/_cluster_lib.sh
source "$ROOT/scripts/_cluster_lib.sh"

PUBKEY="$HOME/.ssh/id_rsa.pub"
[[ -f "$PUBKEY" ]] || {
    echo "[keys] FAIL: no public key at $PUBKEY." >&2
    echo "[keys] fix: run scripts/bootstrap_node.sh first (it generates the key)." >&2
    exit 1; }

command -v ssh-copy-id >/dev/null 2>&1 || {
    echo "[keys] FAIL: ssh-copy-id not found (install openssh-client)." >&2
    exit 1; }

# Hosts: explicit args win; otherwise recover the node* aliases from the
# kmeans-cluster block in /etc/hosts (file order = rank order, master first).
if [[ $# -ge 1 ]]; then
    HOSTS=("$@")
else
    mapfile -t HOSTS < <(awk '
        /# >>> kmeans-cluster >>>/{f=1; next}
        /# <<< kmeans-cluster <<</{f=0}
        f && $2 ~ /^node[0-9]+$/ {print $2}
    ' /etc/hosts 2>/dev/null)
    [[ ${#HOSTS[@]} -ge 1 ]] || {
        echo "[keys] FAIL: no hosts given and no kmeans-cluster aliases in /etc/hosts." >&2
        echo "[keys] fix: run 'ROLE=master scripts/bootstrap_node.sh' or pass hosts:" >&2
        echo "[keys]        scripts/exchange_keys.sh node1 node2 node3" >&2
        exit 1; }
fi

# Which listed host is THIS machine is detected by identity (is_local), so the
# master is skipped no matter where it sits in the list — we never copy a key to
# ourselves.

echo "[keys] master public key: $PUBKEY"
echo "[keys] login user: ${CLUSTER_USER:-<current user>}"
echo "[keys] you'll be asked for each worker's password once (shared in the lab)."

copied=0
skipped=0
failed=()
for host in "${HOSTS[@]}"; do
    if is_local "$host"; then
        echo "[keys]   skip $host (master / local — no key needed)"
        skipped=$((skipped + 1))
        continue
    fi
    echo "[keys]   --> ssh-copy-id ${SSH_USER}${host}"
    if ssh-copy-id -o StrictHostKeyChecking=no -i "$PUBKEY" "${SSH_USER}${host}"; then
        copied=$((copied + 1))
    else
        echo "[keys]   FAIL on '$host'." >&2
        failed+=("$host")
    fi
done

echo "[keys] done: $copied copied, $skipped skipped (local), ${#failed[@]} failed."
if [[ ${#failed[@]} -gt 0 ]]; then
    echo "[keys] failed: ${failed[*]}" >&2
    echo "[keys] check the host is on the LAN and the password is correct, then retry." >&2
    exit 1
fi

# Quick non-interactive verification so a wrong setup is caught here, not later.
echo "[keys] verifying passwordless SSH to each worker..."
bad=()
for host in "${HOSTS[@]}"; do
    is_local "$host" && continue
    if ssh -o BatchMode=yes -o ConnectTimeout=8 "${SSH_USER}${host}" true 2>/dev/null; then
        echo "[keys]   OK   $host"
    else
        echo "[keys]   STILL PROMPTS: $host" >&2
        bad+=("$host")
    fi
done
[[ ${#bad[@]} -eq 0 ]] || {
    echo "[keys] FAIL: ${bad[*]} still require a password." >&2; exit 1; }

echo "[keys] ALL WORKERS KEYLESS. Next: scripts/run_demo.sh"
