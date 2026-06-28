# Running the cluster on WSL2 (Ubuntu x64) + a Mac driver

This guide is for the practical team setup we actually have:

- **Friends:** Windows 11 machines running **WSL2 Ubuntu (x86-64)**.
- **You:** a Mac, using the **x86-64 Docker environment** (`docker/run.sh`) for
  development. The Mac does **not** join the MPI job (ARM vs x86); it edits code,
  pushes, and can drive the cluster over SSH.

> **Grading caveat — read first.** The assignment asks for **VMs with bridged
> adapters, one per physical machine**. WSL2 is not a bridged VM, and its default
> NAT networking hides each Ubuntu behind the Windows host. WSL is excellent for
> *developing and testing the Linux build*, but using it for the **graded** run is
> a risk — confirm with the professor, or do the final measured runs on the
> VirtualBox bridged-adapter cluster in [`CLUSTER_SETUP.md`](CLUSTER_SETUP.md).
> Everything below still applies for development and for a WSL-based dry run.

All machines must be x86-64 and run the **same MPI implementation** (this repo
standardises on **OpenMPI**). Do not mix OpenMPI and MPICH across nodes.

---

## Stage 0 — Everyone verifies the build solo (no networking)

Prove the code builds and is correct on each machine before touching the network.
This needs zero coordination — each person does it independently.

**You (Mac, Docker x86):**
```bash
cd ~/Developer/parallel-kmeans-mpi
docker/run.sh build      # one-time
docker/run.sh verify     # expect: PASS ... bit-identical
```

**Each friend (WSL Ubuntu):**
```bash
git clone https://github.com/ronanhansel/parallel-kmeans.git
cd parallel-kmeans
sudo apt update
sudo apt install -y build-essential libopenmpi-dev openmpi-bin \
    openssh-server net-tools python3-numpy python3-matplotlib
make
scripts/verify_correctness.sh        # expect: PASS ... bit-identical
```

When all four machines print `PASS`, the algorithm is proven everywhere. This is
a real checkpoint with no networking risk — bank it before moving on.

---

## Stage 1 — Make each WSL reachable on the LAN (the hard part)

By default WSL2 sits behind a NAT, so other machines on the Wi-Fi **cannot** reach
it. Pick **one** of the two options below. Mirrored mode is far easier — use it if
everyone is on Windows 11 22H2 or newer.

### Option A — Mirrored networking (recommended, Windows 11 22H2+)

Each friend edits (or creates) `C:\Users\<name>\.wslconfig`:

```ini
[wsl2]
networkingMode=mirrored
```

Then in **PowerShell**:
```powershell
wsl --shutdown
```
Reopen Ubuntu. Now inside WSL, `ip addr` shows the **same LAN IP as the Windows
host** — the WSL Ubuntu is directly reachable like any normal LAN machine.

Verify from another machine on the same Wi-Fi:
```bash
ping <that-windows-host-LAN-IP>
```

### Option B — NAT + port forwarding (Windows 10 / older 11)

Keep default NAT and forward SSH from the Windows host into WSL. In **admin
PowerShell** on each machine (re-run after every reboot — the WSL IP changes):

```powershell
$wslIp = (wsl hostname -I).Trim().Split()[0]
netsh interface portproxy add v4tov4 listenport=22 listenaddress=0.0.0.0 connectport=22 connectaddress=$wslIp
netsh advfirewall firewall add rule name="WSL SSH" dir=in action=allow protocol=TCP localport=22
```

Other nodes then reach this machine at the **Windows host's LAN IP** on port 22.

> **Not in the same room?** If teammates are on different networks, neither option
> reaches across the internet. Install **Tailscale** on every machine to put them
> on one private mesh, then use each machine's Tailscale IP everywhere this guide
> says "LAN IP". See [`REMOTE_ACCESS.md`](REMOTE_ACCESS.md).

---

## Stage 2 — SSH so MPI can launch across nodes

WSL does **not** start the SSH server automatically. On every WSL node, each
session:

```bash
sudo service ssh start            # not systemctl — WSL has no systemd by default
```

To avoid retyping this, add to `/etc/wsl.conf` and `wsl --shutdown`:
```ini
[boot]
command = service ssh start
```

Run the bootstrap helper on **every** node to install packages, prep `~/.ssh`, and
generate a passwordless key (it prints the node's IP and public key):
```bash
ROLE=master scripts/bootstrap_node.sh     # on the node you'll launch from
ROLE=slave  scripts/bootstrap_node.sh     # on the others
```

**Exchange keys** so every node can SSH into every other node without a password.
The simplest way, once each node can reach the others:
```bash
# from each node, copy its key to every node (including itself):
ssh-copy-id <user>@<node-LAN-IP>
```
Then confirm passwordless login works **in both directions** between every pair:
```bash
ssh <user>@<other-node-ip> hostname     # must print the hostname, no password
```
MPI launches workers over SSH non-interactively, so this must be seamless or the
run hangs.

---

## Stage 3 — Form the cluster and run

On the **master** node, create a `hostfile` listing each node's reachable IP and
its core count (`slots`):

```
192.168.1.10 slots=4
192.168.1.11 slots=4
192.168.1.12 slots=4
```

Smoke test — every node should print its own hostname:
```bash
mpirun --hostfile hostfile -np 12 hostname
```

If that works, you have a cluster. Run the experiments (full detail in
[`RUNBOOK.md`](RUNBOOK.md)):
```bash
HOSTFILE=hostfile P=12 scripts/run_size_sweep.sh      # find N (~2-3 min wall)
HOSTFILE=hostfile P=12 N=<chosen>  scripts/run_granularity.sh
HOSTFILE=hostfile MAXP=12 N=<chosen> scripts/run_scaling.sh
python3 plots/make_plots.py
```

> The repo must be at the **same path** on every node (e.g. `~/parallel-kmeans`),
> and the dataset must exist on every node — either regenerate it on each (same
> `--seed` gives identical data) or share via a synced folder. The run scripts
> generate datasets locally on the launching node only, so for multi-node runs
> generate the dataset on each node first with the same `gen_dataset.py` arguments.

---

## Stage 4 (optional) — Drive the cluster from your Mac

You don't need to be sat at the master node. From the Mac:
```bash
# edit code locally, then:
git push
# pull + run on the master in one shot:
ssh <user>@<master-ip> 'cd parallel-kmeans && git pull && make && \
    mpirun --hostfile hostfile -np 12 ./bin/kmeans_mpi data/train.bin 16 50 1e-9'
# copy result CSVs back to plot locally:
scp '<user>@<master-ip>:parallel-kmeans/results/*.csv' results/
python3 plots/make_plots.py
```

The Mac stays the code authority and does the plotting (matplotlib is already
installed); the x86 WSL nodes do the actual MPI compute.

---

## WSL gotchas, in one place

- **SSH isn't running** by default — `sudo service ssh start` each session (or the
  `/etc/wsl.conf` `[boot]` trick above). `systemctl` usually fails on WSL.
- **WSL IP is unreachable** under default NAT — use mirrored networking (Option A)
  or port-forwarding (Option B).
- **Windows Firewall** must allow inbound TCP 22, or other nodes can't connect.
- **WSL IP changes on reboot** under NAT mode — re-run the `netsh` commands, or use
  mirrored mode where the IP follows the Windows host.
- **Same MPI everywhere** — all nodes OpenMPI (this repo's default). Mixing
  implementations or versions causes launch failures or silent wrong behaviour.
- **Emulation on the Mac** — the Docker x86 image runs under emulation; trust it
  for correctness, never for timing. Speedup/granularity numbers come from the
  real x86 nodes.
