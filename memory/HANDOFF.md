# Project Handoff — Parallel K-Means MPI Cluster

**Last updated:** 2026-06-25
**Read this first.** It lets any agent resume without re-deriving the context.

---

## 1. What this project is

Course assignment: implement a non-trivial **parallel algorithm on a real MPI
cluster** (≥3 machines), prove it matches the sequential solution, and produce
load-balance + speedup charts. **Deadline: 24 June 2026.** Team of 4.

Chosen problem: **Parallel K-Means** (data parallelism, 1D block-row
decomposition). The code is complete and correct. See `README.md` and
`docs/REPORT_OUTLINE.md`.

The repo (code, experiment scripts, plotting, docs) is **done and pushed**. The
remaining work is **standing up the cluster and collecting results on real
hardware**, then writing the report.

---

## 2. Hard-won facts — DO NOT relitigate these

These were settled through painful debugging. Trust them.

### 2a. The Mac is the DRIVER, never a compute node
- User's machine is an **Apple Silicon (ARM) Mac**. MPI cannot mix ARM and x86
  ranks in one job. Cluster nodes must all be **x86_64 Linux**.
- **Docker on Mac cannot be an MPI node either.** Docker Desktop containers sit
  behind a LinuxKit NAT (`172.17.x`); `--network host` does NOT work on Mac. The
  container's self-IP is unreachable from other machines, so MPI rank callbacks
  hang. Also it runs under QEMU emulation → timings are meaningless.
- **Conclusion:** Mac = code authority + launcher + plotting (matplotlib is
  installed). It SSHes into the master node and runs `mpirun`. This is normal HPC
  (login node ≠ compute node). The Mac's x86 Docker env (`docker/run.sh`) is for
  **local build/correctness testing only**, never timing, never cluster peer.

### 2b. WSL2 was abandoned for the cluster — use VirtualBox bridged VMs
We spent a long session trying WSL2 Ubuntu nodes. Two distinct, real bugs:
- **Mirrored networking mode** breaks loopback routing
  (`127.0.0.1 via 169.254.x dev loopback0`). MPICH's Hydra PMI barrier and
  OpenMPI's launcher both hang because their localhost back-channel is mangled.
- **NAT mode** isolates each WSL behind its Windows host → no rank-to-rank
  reachability → can't form a multi-node cluster. Also the WSL IP changes on
  reboot.
- WSL hostname (`LAPTOP-...`) resolved to **IPv6 link-local only**, and stray
  interfaces (a Radmin VPN `eth0 26.x/8`) confused MPI interface auto-selection.

**Decision (user, 2026-06-21):** abandon WSL, use **VirtualBox + Ubuntu Server
24.04 + Bridged Adapter** — this is also exactly what the professor's spec
requires ("bridged adapters over a shared LAN, 1 VM per physical machine").

### 2c. MPI implementation = OpenMPI
- During the WSL firefight we briefly switched the repo to MPICH (Hydra dodged
  the WSL launcher hang). **That has been reverted.** The WSL hangs do NOT exist
  on clean bridged Ubuntu VMs.
- Repo standardizes on **OpenMPI** (`libopenmpi-dev openmpi-bin`). README,
  Dockerfile, `bootstrap_node.sh`, and all docs assume OpenMPI. **Every node must
  use the same implementation — do not mix.**
- If a future WSL-only fallback is ever needed, `bootstrap_node.sh` accepts
  `MPI_PKG="mpich"`, but the cluster should be OpenMPI.

### 2d. The singleton bug to watch for
On a node, `mpirun -np 4 ./bin/kmeans_mpi ...` printing **four `P=1` lines**
instead of one `P=4` means the binary is linked against a *different* MPI runtime
than the `mpirun` launching it (stale binary after switching MPI impls). Fix:
`make clean && make`. A correct run prints a single `kmeans_mpi: P=4 ...` line.

---

## 3. Current repo state

- Remote: `https://github.com/ronanhansel/parallel-kmeans.git`, branch `main`.
- Last pushed commit: `1d7fa9d` (OpenMPI reverts of Dockerfile + bootstrap_node.sh,
  plus this handoff doc). Working tree is clean / fully pushed.
- The stray `hostfile` from WSL testing (`vinh@172.20.10.2 slots=4`) was removed;
  build the real cluster hostfile fresh when nodes are up.
- **Verified working:** correctness (parallel == sequential, bit-identical) and
  the full scaling→plot pipeline, both on the Mac's x86 Docker env. The algorithm
  is sound; only real-hardware data collection remains.

### Repo map
```
src/kmeans_mpi.c     parallel core (graded): Scatterv→Bcast→assign→Allreduce→converge
src/kmeans_seq.c     sequential baseline (correctness ref + T1 for speedup)
src/common.h         dataset I/O, distance, deterministic seeding
Makefile             `make` → bin/kmeans_mpi (mpicc) + bin/kmeans_seq (cc)
scripts/gen_dataset.py        Gaussian blobs → binary dataset (--points --dim --clusters --seed)
scripts/verify_correctness.sh parallel labels == sequential (PASS/FAIL)
scripts/run_size_sweep.sh     find N where wall time ≈ 2–3 min on all cores
scripts/run_granularity.sh    per-rank compute/comm timing + 25% load verdict
scripts/run_scaling.sh        speedup ladder 1,2,4,8,… at data scale 2N
scripts/bootstrap_node.sh     one-shot Ubuntu node setup (apt + SSH keys + OpenMPI)
plots/make_plots.py           CSVs → all report figures (PNG)
docker/run.sh                 x86 Docker dev env on Mac (build/verify only)
docs/CLUSTER_SETUP.md         VirtualBox + bridged networking walkthrough
docs/RUNBOOK.md               exact commands to reproduce every result/figure
docs/REPORT_OUTLINE.md        10–20 pg report scaffold mapped to experiments
docs/WSL_SETUP.md             (superseded for the cluster — kept for reference)
docs/REMOTE_ACCESS.md         Tailscale + SSH if team is not co-located
```

All scripts take `HOSTFILE=<file>` to span the cluster and read `P`/`N`/`MAXP`
from env. Datasets/results are gitignored (regenerate with the same `--seed`).

---

## 4. Where the user is RIGHT NOW — CLUSTER IS WORKING

The cluster runs. Cross-node `mpirun` produces a clean single `P=<total>` line and
correctness PASSes across nodes. Hard-won fixes from the bring-up session are now
baked into the scripts (see §5). Current topology observed:

| Role  | Name   | IP            | cores | user |
|-------|--------|---------------|-------|------|
| master| `vb`   | 172.20.10.9   | 2     | mpi  |
| slave | node1  | 172.20.10.8   | 4     | mpi  |
| slave | node2  | 172.20.10.10  | 2     | mpi  |

All on commit `2ad1a49`+ (OpenMPI 4.1.6). IPs are DHCP on a phone hotspot, so
**they change across reboots** — re-check `hostname -I` after any sleep/restart.

**The Mac drives via SSH only** (it's ARM, never a compute node). Its key is
authorized on the master; from the Mac: `ssh mpi@<master-ip>`. The master's own
key is authorized on node1/node2 so `mpirun` can launch workers.

The user's Mac SSH public key (authorize on the master so the Mac can drive):
```
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDFdaC37lSOHfGfWjSyxxkepE4J7hG+BYg+GZFQme9oayqgL21Zs2yOVswGCSMefan+2uqn7vh8NmwHh/gLtp1BcoPCgxaqPc65VXxJA94tfIFRaM3Y8juwAf5ExKQeSS2H+p4HjwufPBoKUjJkznoS1rg+xGPy1mX8WuQW2qoT8NeZfVa7mbg3k01NyaJSH8WMhNpivj45+QBDq+WUPukJF/Xp5ODDMF/d66PQktrlS842b/5PCzfaQjf+PBUwYo38ST/B2T1xhSjU9mL9AFveiKgF0OIccrblJdxCbsDvEPWeKB4k68STgRRHH9MUxvZX6A9BLzLHLbJbg0nXmP3RV0mMAFN8i1ppDsr1cBScRs0ILFoOJkP7qcd6pyXklWkofgce5tCfi3NIVEXHol70bQId4jmelmxS2Bha+mGvc1a2l+TzEaB3K3d1uYh2iLYr9vpo1GKWDu9qKWyO9cArrNQIPC0E2n+wy/sipfnduIvZxwNDGHmIXQK0vgW3IEX2BnbNxllcRpzcCbaF6QcCTxqbqidMc0NJTMuPvzcAlUGoqZivi1hErypNomOtljvc5lBV9+WxDprDD7MV7V76M4/iejTNhbb8aKz36ULRVRfLa0k+Vjj0O8yLooSw4+dcYpS0/E43QBxPOaaIUtA2ccbvnieFVJDwbUoix1Ci5Q== ronan@Ronans-MacBook-Pro.local
```

---

## 5. Hard-won bring-up fixes (now baked into the scripts)

Each of these was a real failure during cluster bring-up. The scripts now handle
them automatically — listed so no one re-debugs them from scratch.

- **Master must not SSH to itself.** `mpirun` launches the local rank by fork, not
  SSH. The orchestration scripts (`_cluster_lib.sh` → `is_local`/`run_on`) run the
  master's commands locally; only workers go over SSH. The hostfile writes the
  master by its **real hostname** (`master_token`) so OpenMPI also forks rank 0
  instead of SSHing to itself.
- **IPv6 / wrong-NIC data transport (the big one).** Launch (`mpirun hostname`)
  worked but real runs aborted: `Unable to find reachable pairing between local
  and remote interfaces` / `connect() to 2401:... No route to host`. OpenMPI was
  using non-routable IPv6 / the wrong interface. Fix (proved 3/3 reliable, now in
  `mpi_mca_flags`): `--mca btl_tcp_if_include <iface> --mca btl_tcp_disable_family 6`.
  The iface auto-detects via `ip route get 1.1.1.1`; override with `MPI_IF=<iface>`.
- **`Host key verification failed` after VM rebuild / IP churn.** `bootstrap_node.sh`
  now writes an `~/.ssh/config` block disabling strict host-key checks for the lab
  subnet (isolated network only).
- **Stale hostfile reused.** Passing `NODES="a b c"` but an old 2-node hostfile was
  silently reused. `run_demo.sh` now rebuilds when the `NODES` count differs from
  the existing hostfile; `FRESH=1` always forces it.
- **`numpy` missing.** `gen_dataset.py` has a pure-stdlib fallback so the
  cluster-proof (correctness) path runs without numpy; bootstrap installs
  numpy+matplotlib for fast big-dataset generation and plotting.
- **Only the master needs the dataset.** rank 0 reads the `.bin` and `Scatterv`s
  the rows; workers only need the **binary** at the same path (`sync_nodes.sh`
  guarantees that). No NFS, no per-node data copy. (Corrects the old §2 note.)

### How to run it (one command, from the master)
```
FRESH=1 NODES="172.20.10.9 172.20.10.8 172.20.10.10" NODE_USER=mpi scripts/run_demo.sh
```
First host = master (local). `QUICK=1` stops after correctness; drop `FRESH=1` to
reuse the hostfile. Full per-stage detail in `docs/RUNBOOK.md`; setup in
`docs/CLUSTER_SETUP.md` (troubleshooting table covers every error above).

---

## 6. Open questions / decisions pending

- **Network latency is the timing risk.** On the phone hotspot, node2 showed
  150–800 ms RTT vs node1's ~20 ms. The Allreduce-per-iteration algorithm is
  latency-bound, so speedup numbers degrade badly on a weak link (preflight saw
  `comm=14 s` on a trivial job). Correctness and cluster-formation are unaffected.
  **For the graded timing run, use a fast/wired LAN**, not a congested hotspot.
- **Speedup ladder** = 1,2,4,…,2×total_cores. With the 3 VMs above that's 8 total
  cores → ladder 1,2,4,8.
- **Remote teammates?** `docs/REMOTE_ACCESS.md` covers Tailscale, but WAN latency
  makes timing meaningless — do FINAL measurements co-located. Confirm with prof.
- Mac stays the driver (asked/answered twice). Don't reopen unless the user insists.
