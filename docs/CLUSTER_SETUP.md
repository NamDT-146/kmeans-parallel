# Cluster Setup Guide — Ubuntu VMs on Windows hosts

This is the "set up any new machine fast" guide. Follow it once per physical
machine. It reproduces the SSH/MPI cluster from the assignment video, automated
where possible.

Target: **≥ 3 physical machines**, one Ubuntu VM each, on one shared LAN, talking
over passwordless SSH, running the same MPI program.

> **Hosts are Windows; nodes are Ubuntu.** The host OS does not matter to MPI —
> all MPI processes run *inside* the Ubuntu VMs. The only host-specific part is
> the VirtualBox network setting (the Bridged Adapter), covered below.

---

## 0. Topology and naming (agree on this as a team first)

| Role   | Hostname  | Example LAN IP   | Notes                         |
|--------|-----------|------------------|-------------------------------|
| master | `node0`   | `192.168.1.50`   | rank 0, launches `mpirun`     |
| slave  | `node1`   | `192.168.1.51`   |                               |
| slave  | `node2`   | `192.168.1.52`   |                               |
| slave  | `node3`   | `192.168.1.53`   | optional 4th machine          |

- One person broadcasts a WiFi hotspot (a phone is fine, as the assignment
  suggests). Every physical machine joins **that one network**.
- The IPs above are examples — you read the real ones in step 3.
- Use the **same Linux username** on every VM (e.g. `mpiuser`). It makes the
  hostfile and SSH config trivial. The rest of this guide assumes `mpiuser`.

---

## 1. Create the Ubuntu VM (per physical machine)

1. Install [VirtualBox](https://www.virtualbox.org/) on the Windows host.
2. Create a VM, install **Ubuntu Server 22.04 or 24.04** (Desktop is fine too,
   Server is lighter). Give it ≥ 2 vCPUs and ≥ 2 GB RAM.
3. **Network — the critical setting.** VM → Settings → Network → Adapter 1:
   - **Attached to: Bridged Adapter**
   - **Name:** pick the host's *active* WiFi/Ethernet adapter (the one connected
     to the shared hotspot).
   - This puts the VM directly on the LAN with its own IP, so the VMs can reach
     each other. NAT (the default) will **not** work — the VMs would be
     invisible to one another.
4. Boot the VM, create the `mpiuser` account during install.

> **Rule from the assignment:** at most **one VM per physical machine**. Don't
> run two nodes on one laptop.

---

## 2. Get the code onto every VM

On each VM:

```bash
sudo apt update
sudo apt install -y git
git clone https://github.com/NamDT-146/kmeans-parallel.git kmeans-parallel
cd kmeans-parallel
```

> **Quick reference:** see [`docs/SETUP_COMMANDS.md`](SETUP_COMMANDS.md) for
> copy-paste master/slave commands only.
>
> If you cloned on Windows and copied the folder in, the shell scripts may have
> CRLF line endings and fail with `bad interpreter`. This repo ships a
> `.gitattributes` that forces LF on `*.sh`, so a fresh `git clone` inside the VM
> is always safe. Prefer cloning directly in the VM.

---

## 3. Run the bootstrap script (per VM)

```bash
# On node0 (master):
ROLE=master scripts/bootstrap_node.sh

# On node1, node2, ... (slaves):
ROLE=slave scripts/bootstrap_node.sh
```

This installs `openssh-server`, `make`, and the MPI toolchain (**OpenMPI** —
`libopenmpi-dev openmpi-bin`), prepares `~/.ssh` (mode 700), generates a
passphrase-less RSA key if missing, and prints the VM's **LAN IP** and its
**public key**. Write down each IP. (Every node must use the same MPI
implementation; preflight checks this.)

The script only installs packages that are actually **missing**, so re-running
it on an already-provisioned VM is a fast no-op — it never runs `apt update` or
upgrades anything when nothing is needed.

On the **master**, the script also sets up the `node0`/`node1`/… aliases in
`/etc/hosts` for you. If they aren't configured yet it prompts for the LAN IP of
every node, **master first**, space-separated:

```
IPs: 192.168.1.50 192.168.1.51 192.168.1.52
```

The **number of IPs you enter sets the cluster size** — `node0` is the master,
then `node1`, `node2`, and so on. To skip the prompt (e.g. for scripted setup),
pass them via `NODE_IPS`:

```bash
ROLE=master NODE_IPS="192.168.1.50 192.168.1.51 192.168.1.52" scripts/bootstrap_node.sh
```

Re-running is safe: if the aliases already exist the script prints them and
leaves `/etc/hosts` untouched. Workers don't need the aliases (only the master
launches `mpirun`), so `ROLE=slave` skips this step.

> **Why passphrase-less keys?** `mpirun` opens SSH sessions to the workers
> non-interactively; it cannot type a password. This is standard for an isolated
> lab cluster on a private hotspot. Do not reuse these keys outside the lab.

---

## 4. Exchange SSH keys (so every node can reach every node)

MPI's launcher SSHes from the master to each worker non-interactively, so it
needs **key-based** auth — a shared login password is not enough. You push the
master's public key to each worker once; after that, SSH is keyless.

Easiest path — one command from the master. It reads the `node*` aliases from
`/etc/hosts` (written in step 3), skips the master itself, and runs `ssh-copy-id`
for each worker. Because every node shares the same password in the lab setup,
you just type that password once per worker:

```bash
NODE_USER=mpiuser scripts/exchange_keys.sh
```

It verifies passwordless SSH to every worker at the end, so a wrong password or
unreachable host is caught here instead of mid-demo. You can also pass hosts
explicitly: `NODE_USER=mpiuser scripts/exchange_keys.sh node1 node2 node3`.

Manual alternative — from the master, copy its key to every node (including
itself):

```bash
# Run on node0. Repeat the IP list for your cluster.
for ip in 192.168.1.50 192.168.1.51 192.168.1.52 192.168.1.53; do
    ssh-copy-id mpiuser@$ip
done
```

If `ssh-copy-id` is unavailable, do it manually: copy the contents of
`~/.ssh/id_rsa.pub` (printed by the bootstrap script) and paste each one into
every other machine's `~/.ssh/authorized_keys`, then:

```bash
chmod 600 ~/.ssh/authorized_keys
```

The `node0`/`node1`/… aliases were already written to `/etc/hosts` on the master
by the bootstrap script (step 3). If you're setting up by hand or want them on a
worker too, add them there:

```bash
sudo tee -a /etc/hosts >/dev/null <<'EOF'
192.168.1.50  node0
192.168.1.51  node1
192.168.1.52  node2
192.168.1.53  node3
EOF
```

---

## 5. Verify passwordless SSH (do this before touching MPI)

From the master, every hop must work **without a password prompt**:

```bash
ssh node1 hostname
ssh node2 hostname
ssh node3 hostname
```

If any prompts for a password, fix step 4 before continuing. MPI will hang
otherwise.

---

## 6. Build the hostfile, sync, and run — one command from the master

From here on you only work on the **master** (node0). The repo ships four
orchestration scripts that make the whole pipeline repeatable; `run_demo.sh`
chains them in order and stops at the first failure with a fix hint.

```bash
cd ~/kmeans-parallel

# First run: probe each node's core count over SSH, build the hostfile, sync
# every node to the same commit + binary, run preflight checks, then the full
# experiment + plotting pipeline. NODE_USER is the shared Linux username.
NODES="node0 node1 node2" NODE_USER=mpiuser scripts/run_demo.sh
```

That single command performs, in order:

| Stage | Script | What it proves / produces |
|-------|--------|---------------------------|
| 0 | `make_hostfile.sh` | probes `nproc` per node → `hostfile` (first host = rank 0/master) |
| 1 | `sync_nodes.sh` | `git pull` + `make clean && make` on every node → same commit + fresh binary |
| 2 | `preflight.sh` | SSH, identical MPI impl, binary present, launch path, no `P=1` singleton bug |
| 3 | `verify_correctness.sh` | parallel == sequential **across the cluster** (PASS) |
| 4–6 | `run_size_sweep` / `run_granularity` / `run_scaling` | the three graded experiments |
| 7 | `make_plots.py` | all six report figures |

> **Only the master needs the dataset.** This program reads the `.bin` **only on
> rank 0** and distributes rows with `MPI_Scatterv`, so workers get their points
> over the wire. What every node *does* need is the compiled binary at the
> **same path** — `sync_nodes.sh` guarantees that (it rebuilds on each node), so
> there is no NFS to set up and no data to copy around.

> The cluster runs **OpenMPI** (`libopenmpi-dev openmpi-bin`), installed by the
> bootstrap script. Every node must use the **same** implementation — preflight
> fails loudly if they differ.

### Useful variants

```bash
# Fast cluster proof only — topology + correctness, skip the long experiments:
QUICK=1 NODE_USER=mpiuser scripts/run_demo.sh

# Re-run later reusing the existing hostfile (no NODES needed):
NODE_USER=mpiuser scripts/run_demo.sh

# Adding the 3rd/4th machine — rebuild the hostfile from the new node set:
FRESH=1 NODES="node0 node1 node2 node3" NODE_USER=mpiuser scripts/run_demo.sh

# Pin the network interface if OpenMPI auto-select grabs the wrong one:
MPI_IF=enp0s3 NODE_USER=mpiuser scripts/run_demo.sh
```

> If `~/kmeans-parallel` is not the repo path on a node, pass
> `REPO_DIR=<path-relative-to-home>`. If you'd rather drive each step by hand,
> the individual scripts take the same env vars — see [`docs/RUNBOOK.md`](RUNBOOK.md).

---

## 7. You're cluster-ready

`run_demo.sh` already produced every CSV and figure. To re-run or tune
individual experiments by hand, proceed to [`docs/RUNBOOK.md`](RUNBOOK.md).

### Quick troubleshooting

| Symptom | Cause / fix |
|---|---|
| `mpirun` hangs | Passwordless SSH not working (step 5), or firewall. `sudo ufw disable` on the lab VMs. |
| `bad interpreter: /bin/bash^M` | CRLF line endings. `git clone` inside the VM, or run `sed -i 's/\r$//' scripts/*.sh`. |
| `mpirun: command not found` | MPI not installed / not on PATH. Re-run bootstrap. |
| VMs can't ping each other | Network not Bridged, or on different WiFi networks. Re-check step 1.3. |
| `There are not enough slots` | Asking for more ranks than `slots` in the hostfile. Raise slots or add `--oversubscribe`. |
| Different MPI on different nodes | Use the same MPI implementation everywhere (all OpenMPI). `preflight.sh` catches this. |
| Four `P=1` lines instead of one `P=<total>` | Stale binary linked against a different MPI runtime. Re-run `scripts/sync_nodes.sh` (`make clean && make` on every node). |
| `Unable to find reachable pairing between local and remote interfaces` / `connect() to 2401:... failed, No route to host` | OpenMPI tried a **non-routable IPv6** interface for rank-to-rank TCP. The scripts now auto-pin the LAN interface and disable IPv6 in the TCP transport (`btl_tcp_if_include <iface>` + `btl_tcp_disable_family 6`, via `mpi_mca_flags` in `_cluster_lib.sh`). If auto-detection picks the wrong NIC, set `MPI_IF=<iface>` (find it with `ip -4 route get 1.1.1.1`). |
| `Host key verification failed` from `mpirun`/`ssh` | A worker VM was rebuilt or its IP changed, so its host key no longer matches `known_hosts`. `bootstrap_node.sh` step 5 writes a `~/.ssh/config` block that disables strict host-key checking for the lab subnet, which prevents this. To clear by hand: `ssh-keygen -R <host>`. |
| `mpirun hostname` works but the real run hangs/aborts | The launch path (SSH) is fine but the **data** transport isn't — almost always the IPv6 issue above. The `hostname` smoke test needs no rank-to-rank traffic, so it can pass while the Allreduce path fails. Preflight step 5 (the tiny `P=<total>` kmeans run) is what actually exercises the data path. |
| `ModuleNotFoundError: No module named 'numpy'` | The launcher node needs `python3-numpy` (datasets) and `python3-matplotlib` (figures). `bootstrap_node.sh` installs both. `gen_dataset.py` also has a pure-stdlib fallback so the cluster-proof path (correctness) works even without numpy. |
| `sudo: A terminal is required to authenticate` | You ran `sudo` over a non-interactive SSH. Use `ssh -t <host> sudo ...`, or run the command while logged into the VM directly. |
| Demo runs on the wrong number of nodes | An old `hostfile` was reused. `run_demo.sh` now rebuilds automatically when `NODES` lists a different node count, but you can always force it with `FRESH=1`. |
| Huge `comm` time, poor speedup | Cross-VM network latency (common on a phone hotspot — hundreds of ms). The Allreduce-heavy algorithm is latency-bound, so speedup numbers degrade. For graded timing, put all VMs on a fast/wired LAN. Correctness and cluster-formation are unaffected. |
