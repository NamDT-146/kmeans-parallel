# Parallel K-Means on an MPI Cluster

Data-parallel K-means clustering in C + MPI, with a complete experiment harness
that produces every figure the assignment report requires. Built to run on a
cluster of **≥3 Ubuntu machines** (one VM per physical host, bridged network),
and to develop/validate on a single laptop first.

> Course project: implement a non-trivial parallel algorithm on a real MPI
> cluster, prove it matches the sequential solution, and characterise its
> load balance and speedup. Deadline **24 June 2026**. See
> [`docs/REPORT_OUTLINE.md`](docs/REPORT_OUTLINE.md).

## What's here

```
src/kmeans_mpi.c     parallel K-means (the graded core): Scatterv -> Bcast
                     -> local assign -> Allreduce -> uniform convergence
src/kmeans_seq.c     sequential baseline (correctness reference + T1 for speedup)
src/common.h         dataset I/O, distance, deterministic seeding (shared)
Makefile             `make` builds both binaries (mpicc + cc)

scripts/gen_dataset.py        synthetic Gaussian blobs -> binary dataset
scripts/verify_correctness.sh parallel labels == sequential labels (PASS/FAIL)
scripts/run_size_sweep.sh     find N where wall time ~= 2-3 min on all cores
scripts/run_granularity.sh    per-rank compute/comm timing + 25% load verdict
scripts/run_scaling.sh        speedup ladder 1,2,4,8,... at data scale 2N
scripts/bootstrap_node.sh     one-shot Ubuntu cluster-node setup (SSH + OpenMPI)
scripts/make_hostfile.sh      probe nproc over SSH -> hostfile (any node count)
scripts/sync_nodes.sh         git pull + make on every node (same commit+binary)
scripts/preflight.sh          pre-demo health check (SSH/MPI/binary/launch)
scripts/run_demo.sh           ONE command: hostfile->sync->checks->experiments->plots

plots/make_plots.py           CSVs -> all 6 report figures (PNG): size sweep,
                              granularity, runtime, speedup, efficiency,
                              comm-fraction

docker/Dockerfile             x86-64 Ubuntu image mirroring the cluster toolchain
docker/run.sh                 build/shell/make/verify wrapper (handles --platform)
docker/compose/               3-node Docker "cluster": proves the distributed
                              mpirun --hostfile path + captures topology evidence

docs/CLUSTER_SETUP.md         set up any new machine fast (Windows host -> Ubuntu VM)
docs/WSL_SETUP.md             WSL2 Ubuntu cluster + Mac driver (staged, with networking)
docs/REMOTE_ACCESS.md         Tailscale mesh for teammates on different networks
docs/RUNBOOK.md               exact commands to reproduce every result + figure
docs/REPORT_OUTLINE.md        10-20 pg report scaffold mapped to each experiment
```

## Quickstart (single machine — develop & validate)

Prereqs: a C/MPI toolchain and Python with numpy + matplotlib.

- **macOS:** `brew install open-mpi`
- **Ubuntu:** `sudo apt install -y build-essential libopenmpi-dev openmpi-bin python3-numpy python3-matplotlib`

```bash
make                              # build bin/kmeans_mpi and bin/kmeans_seq
scripts/verify_correctness.sh     # proves parallel == sequential (PASS)

# quick speedup demo on local cores, then draw the curves
N=60000 scripts/run_scaling.sh
python3 plots/make_plots.py
open results/fig_speedup.png      # Linux: xdg-open
```

`verify_correctness.sh` should print `PASS: … bit-identical …`. That confirms the
build and the algorithm before you touch the cluster.

## Matching the cluster on a Mac (x86-64 Ubuntu in Docker)

The cluster nodes are **x86-64 Ubuntu**. An Apple-Silicon Mac is ARM, so binaries
built natively there won't match the cluster and some code compiles differently
(e.g. POSIX feature-test macros). To develop against an environment that's
byte-compatible with the cluster, use the bundled x86-64 Ubuntu image:

```bash
docker/run.sh build               # one time: build the x86-64 Ubuntu image
docker/run.sh verify              # build + correctness check inside Linux x86-64
docker/run.sh make                # just compile the Linux binaries
docker/run.sh shell               # interactive Ubuntu shell at /work
docker/run.sh run -- mpirun -np 4 ./bin/kmeans_mpi data/verify.bin 8 100 1e-8
```

The repo is bind-mounted, so host edits are live in the container. This is the
right place to confirm the **Linux build and correctness** before pushing.

> On Apple Silicon this image runs under emulation (QEMU). It's faithful for
> compilation and correctness but **not** for timing — the speedup/granularity
> numbers in the report must come from real x86 cluster hardware, not Docker.

## Proving the distributed path (3-node Docker compose)

`docker/compose/` brings up three containers — `node1`, `node2`, `node3` — each
with its own hostname and a static IP on a private bridge network, sharing one
SSH key so `mpirun` on the head node launches ranks on the others over SSH+TCP.
This rehearses the **exact** `mpirun --hostfile` path the real cluster uses, and
produces the two artifacts the report's cluster section needs: the per-node
`hostname` topology proof and a distributed correctness PASS across all 3 nodes.

```bash
docker compose -f docker/compose/docker-compose.yml up -d --build
# run the demo as the unprivileged 'mpi' user (SSH keys belong to it;
# OpenMPI refuses to run as root)
docker compose -f docker/compose/docker-compose.yml exec -u mpi node1 \
    bash docker/compose/demo.sh
docker compose -f docker/compose/docker-compose.yml down
```

The demo writes `results/cluster_hostname.txt` (4 ranks each on node1/node2/node3)
and prints `PASS: 20000 points, partitions identical up to relabeling`.

> **Not a timing environment** — the three containers share this host's cores, so
> adding "nodes" is just oversubscription. Use it for the distributed-path and
> topology proof only; the speedup/granularity numbers come from native runs.
> The demo builds into `bin-linux/` (override `make BIN=...`) so the container's
> Linux binaries never collide with the host's native `bin/`.

## Running on the real cluster

**One-time setup** (per machine): bring up the Ubuntu VMs and wire passwordless
SSH per [`docs/CLUSTER_SETUP.md`](docs/CLUSTER_SETUP.md). It walks Windows users
through VirtualBox + bridged networking and runs `scripts/bootstrap_node.sh` to
install OpenMPI and generate keys. Use the **same login user** and clone the repo
to `~/kmeans-parallel` on every node. See [`docs/SETUP_COMMANDS.md`](docs/SETUP_COMMANDS.md)
for copy-paste master/slave commands.

**Then the whole demo is one command** on the master:

```bash
# first run — probes nproc on each node, builds the hostfile, runs end to end
NODES="node0 node1 node2" NODE_USER=mpiuser scripts/run_demo.sh
```

`run_demo.sh` chains the full pipeline and stops at the first failure with a fix
hint, so the live demo is deterministic:

```
0. make_hostfile.sh   probe nproc over SSH -> hostfile (single source of truth)
1. sync_nodes.sh      git pull + make on EVERY node -> same commit + binary
2. preflight.sh       SSH / same-MPI / binary / launch / singleton-bug checks
3. verify_correctness across the cluster (parallel == sequential, PASS)
4. run_size_sweep     runtime vs input size  -> results/size_sweep.csv
5. run_granularity    per-rank load balance  -> results/granularity.csv
6. run_scaling        speedup ladder at 2N   -> results/scaling.csv
7. make_plots.py      all six report figures -> results/fig_*.png
```

Subsequent runs reuse the existing hostfile (`NODE_USER=mpiuser scripts/run_demo.sh`).
Useful knobs:

```bash
QUICK=1   scripts/run_demo.sh   # stop after correctness (fast cluster proof)
FRESH=1   scripts/run_demo.sh   # rebuild the hostfile (node set changed)
NO_SYNC=1 scripts/run_demo.sh   # skip git-pull+rebuild (nodes already synced)
MPI_IF=enp0s3 scripts/run_demo.sh   # pin the interface if auto-select misfires
```

> The dataset is read **only on rank 0** (the master) and scattered to workers,
> so the `.bin` file lives only on the master. The **binary**, however, must be
> current at the same path on every node — that's exactly what `sync_nodes.sh`
> guarantees before each run.

To run any stage by hand instead of the wrapper, see
[`docs/RUNBOOK.md`](docs/RUNBOOK.md).

## Reproducing the report figures

The report (`report/pdmain.tex`) was built from these exact operating points on a
10-core machine (8 performance + 2 efficiency cores). To regenerate the same
figures:

```bash
# 1. Correctness (small dataset, P=4)
scripts/verify_correctness.sh

# 2. Size sweep — 100k to 12.8M points at P=8 (performance cores)
P=8 SIZES="100000 200000 400000 800000 1600000 3200000 6400000 12800000" \
  scripts/run_size_sweep.sh

# 3. Granularity at the operating size N=6.4M, P=8
N=6400000 P=8 scripts/run_granularity.sh

# 4. Speedup ladder 1,2,4,8 at data scale 2N=12.8M
N=6400000 MAXP=8 scripts/run_scaling.sh

# 5. Render all 6 figures, then copy into the report
python3 plots/make_plots.py
cp results/fig_*.png report/figures/
```

**Why the ladder caps at P=8, not 10.** This machine has 8 performance + 2
efficiency cores. At P=10 two ranks land on the slower E-cores, and because the
per-iteration `Allreduce` is a hard barrier, all ranks wait on those two
stragglers — wall time *rises* at P=10. That's a heterogeneous-core artifact, not
an algorithm limit, so the reported ladder stops at the 8 uniform P-cores. A
homogeneous cluster of identical cores has no such split and extends the ladder
to its full core count.

**Operating sizes.** N=6.4M points (~3.3 s at P=8) for load balance; 2N=12.8M for
speedup. The literal 2–3 min target band is only reached near M≈450–725M points
(extrapolated) — far beyond a single machine's RAM — so the size-sweep figure
marks that band by extrapolation and the cluster reports the literal operating
point on its own aggregate hardware.

**Figures (6 total)** rendered by `plots/make_plots.py` into `results/`:
`fig_size_sweep`, `fig_granularity`, `fig_runtime`, `fig_speedup`,
`fig_efficiency`, `fig_comm_fraction`. Last regenerated values: load-balance
spread ~5.2% (PASS); speedup at P=8 is 6.55× (with comm) / 7.25× (compute only);
efficiency falls 100%→82%; comm-fraction climbs 0.3%→12.1%.

## Design at a glance

| Aspect | Choice |
|---|---|
| Parallelism level | Data parallelism |
| Decomposition | Data, 1D block-row over M points |
| Mapping | 1D block; `Scatterv` spreads the remainder (≤1 point imbalance) |
| Communication | Master–slave hybrid: `Scatterv` once, `Bcast` + `Allreduce` per iter, `Gatherv` once; blocking collectives |
| Topology | Tree (MPI collective binomial-tree reduction), O(log P) depth |
| Convergence | Every rank holds identical global centroids → uniform termination |

Full rationale for each choice is in [`docs/REPORT_OUTLINE.md`](docs/REPORT_OUTLINE.md) §3.

## Notes

- Shell scripts are forced to LF via `.gitattributes` so they run correctly
  inside the Linux VMs even when checked out on Windows hosts.
- Datasets and results are gitignored; regenerate them with the scripts above.
- The passwordless SSH keys created by `bootstrap_node.sh` are for an isolated
  lab cluster only — don't reuse that setup on machines exposed to the internet.
