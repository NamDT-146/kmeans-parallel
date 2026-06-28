#!/usr/bin/env bash
# Shared helpers for the cluster orchestration scripts (make_hostfile, sync_nodes,
# preflight). Sourced, not executed.
#
# The key idea: the MASTER (rank 0) is whichever listed host IS this machine, and
# it must NOT SSH to itself. mpirun launches the local rank by fork, not SSH, and
# a master typically has no passwordless SSH to its own name. So every per-node
# action checks is_local() first and runs locally for the master, SSH otherwise.
#
# Locality is detected purely by IDENTITY (hostname + bound IPs, and resolving
# each alias back to an IP), NOT by argument order. That way the same hostfile is
# correct no matter which node launches, and a misconfigured alias (e.g. 'node1'
# pointed at the master's IP) is exposed by the callers instead of silently
# building a cluster of clones.
#
# Callers set NODE_USER (bare username, no @) before sourcing; we normalise it.

# Bare login user (may be empty) and the user@ prefix for SSH.
CLUSTER_USER="${NODE_USER:-}"
SSH_USER="${CLUSTER_USER:+${CLUSTER_USER}@}"

# CLUSTER_MASTER is kept only for backward compatibility (some callers still set
# it). It is NO LONGER used to force locality: which host is "local" is detected
# purely by identity now (see is_local), so the topology is correct no matter
# which node you launch from, and a misconfigured alias is exposed not masked.
CLUSTER_MASTER="${CLUSTER_MASTER:-}"

# Names that refer to THIS machine (hostnames only; IPs are handled separately
# so a hostname that happens to look like an IP can't slip through).
# The trailing `|| true` keeps a no-match grep (exit 1) from killing the script
# under `set -e`/`pipefail` when none of the hostname forms is available.
_self_names="$( { hostname; hostname -s; hostname -f; } 2>/dev/null \
    | tr ' ' '\n' | grep -v '^$' | sort -u || true )"

# local_ips : every IPv4 address bound to this machine, one per line. Used to
# decide whether a host alias/IP points back at us (fork) or at another box (SSH).
# Sources, in order of preference: `hostname -I` (Linux), `ip` (Linux), then
# `ifconfig` (macOS / older systems) so this also works off the cluster. The
# trailing `|| true` stops an empty result's grep (exit 1) from failing `set -e`.
local_ips() {
    {
        hostname -I 2>/dev/null
        if command -v ip >/dev/null 2>&1; then
            ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1
        elif command -v ifconfig >/dev/null 2>&1; then
            ifconfig 2>/dev/null | awk '/inet /{print $2}'
        fi
    } | tr ' ' '\n' | grep -vE '^$' | sort -u || true
}
_self_ips="$(local_ips)"

# _resolve <host> : print the IPv4 addresses <host> resolves to, one per line
# (empty if it can't be resolved). Tries getent (Linux) then a Python fallback
# so an /etc/hosts alias like 'node0' -> the master's LAN IP is detected.
_resolve() {
    if command -v getent >/dev/null 2>&1; then
        getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u
    else
        python3 - "$1" 2>/dev/null <<'PY' || true
import socket, sys
try:
    print("\n".join(sorted({ai[4][0] for ai in socket.getaddrinfo(sys.argv[1], None, socket.AF_INET)})))
except OSError:
    pass
PY
    fi
}

# is_local <host> : true if <host> names the machine we're running on. This is
# decided ENTIRELY by identity — no "first host is master" assumption — so the
# same hostfile gives the correct topology regardless of which node launches it.
# Match order: loopback, our own hostnames, our own IPs (literal), then resolve
# <host> to its IP(s) and check those against our IPs (catches an alias like
# 'node1' that points back here). If none match, the host is remote.
is_local() {
    case "$1" in
        localhost|127.0.0.1|::1) return 0 ;;
    esac
    grep -qxF "$1" <<<"$_self_names" && return 0
    grep -qxF "$1" <<<"$_self_ips"   && return 0
    local ip
    while IFS= read -r ip; do
        [[ -n "$ip" ]] && grep -qxF "$ip" <<<"$_self_ips" && return 0
    done < <(_resolve "$1")
    return 1
}

# run_on <host> <command-string> : run the command on <host>. Local exec for the
# master (no SSH), passwordless SSH for every other node. Returns the command's
# own exit status so callers can branch on success/failure.
run_on() {
    local h="$1"; shift
    if is_local "$h"; then
        bash -c "$*"
    else
        ssh -o BatchMode=yes -o ConnectTimeout=8 "${SSH_USER}${h}" "$*"
    fi
}

# master_token : the name to write into the hostfile for the master (rank 0).
# We use this machine's real hostname, NOT whatever alias the caller passed
# (e.g. 'node0'). OpenMPI does its OWN locality check on each hostfile entry: if
# the name resolves to one of its local interfaces it forks the rank instead of
# SSHing. An /etc/hosts alias that points at a wrong/placeholder IP defeats that
# and makes OpenMPI try to SSH to itself; the real hostname never does.
master_token() {
    hostname
}

# primary_iface : the network interface carrying this machine's main IPv4 LAN
# address (e.g. enp0s3 on a VirtualBox bridged VM). Used to pin MPI's TCP
# transport so it doesn't wander onto a non-routable interface.
primary_iface() {
    ip -4 -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1
}

# mpi_mca_flags : the --mca flags every cluster mpirun must use, as a string.
# Settled empirically on the bridged VM cluster (3/3 reliable vs flaky/​failing
# without): pin the TCP byte-transport to the LAN interface AND disable IPv6 in
# that transport. Without the IPv6 disable, OpenMPI keeps trying the VMs'
# non-routable link/global IPv6 addresses (2401:.../fd17:...) and aborts with
# "Unable to find reachable pairing between local and remote interfaces".
#
# Override the interface with MPI_IF=<iface> if auto-detection picks wrong.
mpi_mca_flags() {
    local iface="${MPI_IF:-$(primary_iface)}"
    local flags=""
    if [[ -n "$iface" ]]; then
        flags="--mca btl_tcp_if_include $iface --mca oob_tcp_if_include $iface"
    fi
    # Disable IPv6 in the TCP BTL (the decisive flag) regardless of iface.
    flags="$flags --mca btl_tcp_disable_family 6"
    echo "$flags"
}

# mpi_unbuffer_flag : echo "--stream-buffering 0" iff this mpirun accepts it,
# else nothing. OpenMPI 5.x buffers each rank's stdout/stderr and only flushes at
# exit, so the live progress bar's \r redraws don't appear until the run ends.
# This flag forwards them unbuffered. It is OpenMPI-5-specific (older OpenMPI and
# MPICH reject it), so we probe once (by execution) and cache the answer. Callers
# use it ONLY when the progress bar is on; never with output they parse.
_MPI_UNBUFFER_CACHED=""
mpi_unbuffer_flag() {
    if [[ -z "$_MPI_UNBUFFER_CACHED" ]]; then
        # Probe by EXECUTION, not --help: OpenMPI 5.x accepts the flag but hides
        # it from the default --help (it only shows under `--help all`). A trivial
        # local run with the flag is the authoritative test — exit 0 = supported.
        if "${MPIRUN:-mpirun}" --stream-buffering 0 -np 1 true >/dev/null 2>&1; then
            _MPI_UNBUFFER_CACHED="yes"
        else
            _MPI_UNBUFFER_CACHED="no"
        fi
    fi
    [[ "$_MPI_UNBUFFER_CACHED" == "yes" ]] && echo "--stream-buffering 0"
}

# hosts_from_hostfile <path> : print the host token (first field) of each real
# entry, one per line. Skips comments and blank lines.
hosts_from_hostfile() {
    grep -vE '^\s*(#|$)' "$1" | awk '{print $1}'
}

# total_slots_from_hostfile <path> : sum of every slots=N in the hostfile.
total_slots_from_hostfile() {
    grep -vE '^\s*(#|$)' "$1" | sed -n 's/.*slots=\([0-9]*\).*/\1/p' | paste -sd+ - | bc
}
