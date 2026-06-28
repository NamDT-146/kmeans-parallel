#!/usr/bin/env bash
# Bootstrap an Ubuntu VM into a cluster-ready MPI node.
#
# Reproduces the manual steps from the assignment video, automated:
#   - install net-tools, openssh-server/client, make, MPI toolchain (only the
#     packages that are actually missing; a fully provisioned node is a no-op)
#   - prepare ~/.ssh with mode 700
#   - generate a passphrase-less RSA key if one does not exist
#   - (master only) set node0/node1/... aliases in /etc/hosts, prompting for the
#     LAN IPs when they aren't configured yet
#   - print this node's LAN IP and public key for the key-exchange step
#
# Run on EVERY VM. Pass the role for clarity in the output:
#   ROLE=master scripts/bootstrap_node.sh
#   ROLE=slave  scripts/bootstrap_node.sh
#
# The cluster size is NOT fixed: on the master, the number of IPs you enter (or
# pass via NODE_IPS) sets how many node aliases are written (node0=master,
# node1, node2, ...). Non-interactive example:
#   ROLE=master NODE_IPS="192.168.1.50 192.168.1.51 192.168.1.52" scripts/bootstrap_node.sh
#
# To replace stale aliases after a DHCP IP change, pass NODE_IPS again (or FRESH=1):
#   ROLE=master NODE_IPS="172.20.10.6 172.20.10.5 172.20.10.4" scripts/bootstrap_node.sh
#
# Passphrase-less keys are required because mpirun logs in to workers
# non-interactively. This is appropriate for an isolated lab cluster on a private
# network; do not reuse these keys elsewhere.
set -euo pipefail

ROLE="${ROLE:-node}"
# OpenMPI by default to match the Docker image and README. Every node in one
# cluster MUST use the SAME implementation — do not mix OpenMPI and MPICH.
# Set MPI_PKG="mpich" to switch the whole cluster to MPICH instead.
MPI_PKG="${MPI_PKG:-libopenmpi-dev openmpi-bin}"

echo "==> Bootstrapping this VM as: $ROLE"

if ! command -v apt >/dev/null 2>&1; then
    echo "This script targets Debian/Ubuntu (apt not found)." >&2
    exit 1
fi

echo "==> [1/7] Checking packages (install only what's missing)"
# python3-numpy + python3-matplotlib are needed on the master to generate
# datasets (gen_dataset.py) and render figures (make_plots.py). Installing them
# on every node is harmless and keeps any node usable as the launcher.
#
# Cold start installs missing packages; warm start is a no-op. We never run
# `apt update` or upgrade already-installed packages — only a missing package
# triggers a single `apt update` + install of just the gaps, so re-running this
# script on a provisioned node costs nothing.
REQUIRED_PKGS=(net-tools openssh-server openssh-client make gcc $MPI_PKG \
    python3 python3-numpy python3-matplotlib)

missing=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        missing+=("$pkg")
    fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
    echo "    all packages already installed, skipping apt"
else
    echo "    missing: ${missing[*]}"
    sudo apt update
    sudo apt install -y --no-upgrade "${missing[@]}"
fi

echo "==> [2/7] Ensuring SSH server is running"
sudo systemctl enable --now ssh 2>/dev/null || sudo service ssh start || true

echo "==> [3/7] Preparing ~/.ssh (mode 700)"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
chmod 600 "$HOME/.ssh/authorized_keys"

echo "==> [4/7] Generating passphrase-less RSA key (if absent)"
if [[ ! -f "$HOME/.ssh/id_rsa" ]]; then
    ssh-keygen -t rsa -b 4096 -N "" -f "$HOME/.ssh/id_rsa"
    echo "    generated ~/.ssh/id_rsa"
else
    echo "    key already exists, leaving it untouched"
fi

# Resolve a token to an IPv4 address: pass through literals, resolve hostnames.
_resolve_ipv4() {
    local token="$1"
    if [[ "$token" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        echo "$token"
        return 0
    fi
    if command -v getent >/dev/null 2>&1; then
        getent ahostsv4 "$token" 2>/dev/null | awk '{print $1; exit}'
        return 0
    fi
    python3 - "$token" 2>/dev/null <<'PY' || true
import socket, sys
try:
    addrs = sorted({ai[4][0] for ai in socket.getaddrinfo(sys.argv[1], None, socket.AF_INET)})
    if addrs:
        print(addrs[0])
except OSError:
    pass
PY
}

# Collect this machine's LAN IPv4 addresses (for master-first validation).
_self_lan_ips() {
    {
        hostname -I 2>/dev/null
        if command -v ip >/dev/null 2>&1; then
            ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1
        elif command -v ifconfig >/dev/null 2>&1; then
            ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -v '127.0.0.1'
        fi
    } | tr ' ' '\n' | grep -vE '^$|^127\.' | sort -u || true
}

_hosts_block_present() {
    grep -qF "$HOSTS_BEGIN" "$HOSTS_FILE"
}

_hosts_print_block() {
    awk -v b="$HOSTS_BEGIN" -v e="$HOSTS_END" \
        '$0==b{f=1;next} $0==e{f=0} f' "$HOSTS_FILE" | sed 's/^/      /'
}

_hosts_remove_block() {
    if _hosts_block_present; then
        sudo sed -i '/^# >>> kmeans-cluster >>>$/,/^# <<< kmeans-cluster <<<$/d' "$HOSTS_FILE"
    fi
}

_hosts_node0_ip() {
    awk -v b="$HOSTS_BEGIN" -v e="$HOSTS_END" \
        '$0==b{f=1;next} $0==e{f=0} f && $2=="node0"{print $1; exit}' "$HOSTS_FILE"
}

_hosts_master_is_local() {
    local n0 lan
    n0="$(_hosts_node0_ip)"
    [[ -n "$n0" ]] || return 1
    while IFS= read -r lan; do
        [[ -n "$lan" && "$lan" == "$n0" ]] && return 0
    done < <(_self_lan_ips)
    return 1
}

_write_hosts_from_ips() {
    local ips="${1:-}"
    if [[ -z "$ips" ]]; then
        echo "    No kmeans-cluster aliases found in /etc/hosts."
        echo "    Enter the LAN IP (or hostname) of EVERY node, MASTER FIRST, space-separated."
        echo "    Example: 192.168.1.50 192.168.1.51 192.168.1.52"
        echo "    The number of entries sets the cluster size (node0=master, node1, ...)."
        read -rp "    IPs: " ips
    fi
    local -a entries=()
    local idx=0 master_ip="" token ip
    IFS=', ' read -ra _raw_ips <<< "$ips"
    for token in "${_raw_ips[@]}"; do
        token="$(echo "$token" | tr -d '[:space:]')"
        [[ -z "$token" ]] && continue
        ip="$(_resolve_ipv4 "$token" | head -1 | tr -d '[:space:]')"
        if [[ -z "$ip" || ! "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            echo "    ERROR: cannot resolve '$token' to an IPv4 address." >&2
            echo "           Pass its LAN IP directly or ensure the host is reachable." >&2
            exit 1
        fi
        [[ $idx -eq 0 ]] && master_ip="$ip"
        entries+=("$ip  node$idx")
        printf '      node%-2d  %-15s  (from %s)\n' "$idx" "$ip" "$token"
        idx=$((idx + 1))
    done
    if [[ ${#entries[@]} -eq 0 ]]; then
        echo "    ERROR: no IPs provided; cannot configure node aliases." >&2
        exit 1
    fi
    local master_ok=0 lan
    while IFS= read -r lan; do
        [[ -n "$lan" && "$lan" == "$master_ip" ]] && master_ok=1
    done < <(_self_lan_ips)
    if [[ $master_ok -eq 0 ]]; then
        echo "    WARN: first entry ($master_ip) is not a LAN IP on this machine." >&2
        echo "           List the master (this VM) first in NODE_IPS." >&2
    fi
    _hosts_remove_block
    {
        printf '%s\n' "$HOSTS_BEGIN"
        printf '%s\n' "${entries[@]}"
        printf '%s\n' "$HOSTS_END"
    } | sudo tee -a "$HOSTS_FILE" >/dev/null
    echo "    wrote ${#entries[@]} node alias(es) to /etc/hosts:"
    printf '      %s\n' "${entries[@]}"
}

# The master must resolve node0/node1/... to launch mpirun across the cluster.
# These live in /etc/hosts. Re-run with NODE_IPS to replace stale aliases after
# DHCP changes; pass FRESH=1 as an alias for the same behaviour.
echo "==> [5/7] Node aliases in /etc/hosts (node0=master, node1, node2, ...)"
HOSTS_FILE="/etc/hosts"
HOSTS_BEGIN="# >>> kmeans-cluster >>>"
HOSTS_END="# <<< kmeans-cluster <<<"
if [[ "$ROLE" != "master" ]]; then
    if _hosts_block_present; then
        echo "    aliases present (informational; workers don't need them for mpirun):"
        _hosts_print_block
    else
        echo "    not master and no aliases set; skipping"
        echo "    (workers don't need the aliases — only the master launches mpirun)"
    fi
elif _hosts_block_present && [[ -n "${NODE_IPS:-}" || -n "${FRESH:-}" ]]; then
    echo "    replacing existing kmeans-cluster aliases..."
    _write_hosts_from_ips "${NODE_IPS:-}"
elif _hosts_block_present && _hosts_master_is_local; then
    echo "    aliases already set, leaving /etc/hosts untouched:"
    _hosts_print_block
elif _hosts_block_present; then
    echo "    ERROR: /etc/hosts aliases are STALE — node0 is not this machine." >&2
    echo "           (VM IPs often change on a phone hotspot after reboot.)" >&2
    _hosts_print_block
    echo "    This machine: $(hostname)  LAN: $(_self_lan_ips | paste -sd' ' -)" >&2
    echo "    Fix — pass current IPs with this machine FIRST:" >&2
    echo "      ROLE=master NODE_IPS=\"<master-ip> <worker1-ip> <worker2-ip>\" scripts/bootstrap_node.sh" >&2
    exit 1
else
    _write_hosts_from_ips "${NODE_IPS:-}"
fi

# For an isolated lab cluster on a private hotspot, VM IPs and host keys change
# across reboots/rebuilds, which makes SSH throw "Host key verification failed"
# and breaks mpirun's non-interactive worker launch. Relax host-key checking for
# the cluster's private subnet + node aliases so the launcher never gets stuck on
# a stale key. This block is idempotent (only added once).
echo "==> [6/7] Relaxing SSH host-key checks for the lab subnet (idempotent)"
SSH_CFG="$HOME/.ssh/config"
touch "$SSH_CFG"; chmod 600 "$SSH_CFG"
if ! grep -q '# >>> kmeans-cluster >>>' "$SSH_CFG"; then
    # Generate a generous range of node aliases so any reasonable cluster size is
    # covered without re-editing this file; IP connections match the subnet
    # wildcards regardless of name.
    NODE_ALIASES=""
    for i in $(seq 0 15); do NODE_ALIASES+="node$i "; done
    cat >> "$SSH_CFG" <<CFG

# >>> kmeans-cluster >>>
# Isolated lab cluster on a private LAN. Disable host-key prompts so mpirun can
# SSH to workers non-interactively even after VM rebuilds / DHCP IP churn.
# Do NOT use these settings on machines exposed to the internet.
Host 10.* 172.16.* 172.17.* 172.18.* 172.19.* 172.2*.* 172.3*.* 192.168.* ${NODE_ALIASES}
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
# <<< kmeans-cluster <<<
CFG
    echo "    added kmeans-cluster block to ~/.ssh/config"
else
    echo "    kmeans-cluster block already present, leaving it"
fi

echo "==> [7/7] Node identity (record these for the key-exchange step)"
echo "----------------------------------------------------------------"
echo "Hostname : $(hostname)"
echo -n "LAN IP   : "
# Prefer the bridged interface address; fall back across tools.
if command -v ip >/dev/null 2>&1; then
    ip -4 addr show scope global | awk '/inet /{print $2}' | cut -d/ -f1 | paste -sd' ' -
elif command -v ifconfig >/dev/null 2>&1; then
    ifconfig | awk '/inet /{print $2}' | grep -v '127.0.0.1' | paste -sd' ' -
else
    hostname -I
fi
echo "MPI      : $(command -v mpirun || echo 'NOT FOUND') ($(mpirun --version 2>/dev/null | head -1))"
echo "Public key (append to authorized_keys on every OTHER node):"
echo "----------------------------------------------------------------"
cat "$HOME/.ssh/id_rsa.pub"
echo "----------------------------------------------------------------"
echo "==> Done. Next: exchange keys (CLUSTER_SETUP.md step 4) and build with 'make'."
