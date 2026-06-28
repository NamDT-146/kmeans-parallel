# RUNBOOK — reproduce every experiment and figure

This is the exact command sequence to go from a fresh checkout to all report
figures. Run it on the cluster master (after `docs/CLUSTER_SETUP.md`) or on a
single multi-core machine for a dry run.

All scripts read knobs from environment variables and write CSVs to `results/`.
`plots/make_plots.py` turns those CSVs into PNGs, also in `results/`.

## TL;DR — the whole pipeline in one command (cluster)

On the master, after the nodes are up and passwordless SSH works:

```bash
# First run: build hostfile (probes nproc per node), sync every node to the same
# commit + binary, preflight, correctness, all three experiments, all figures.
NODES="node0 node1 node2" NODE_USER=mpiuser scripts/run_demo.sh
```

`run_demo.sh` chains stages 0–7 below and stops at the first failure with a fix
hint, so a live demo is one deterministic command. Useful variants:

```bash
QUICK=1   NODE_USER=mpiuser scripts/run_demo.sh   # topology + correctness only
          NODE_USER=mpiuser scripts/run_demo.sh   # reuse existing hostfile
FRESH=1 NODES="node0 node1 node2 node3" NODE_USER=mpiuser scripts/run_demo.sh  # add a node
MPI_IF=enp0s3 NODE_USER=mpiuser scripts/run_demo.sh                            # pin interface
```

The orchestration scripts that `run_demo.sh` calls (all usable standalone):

| Script | Job |
|--------|-----|
| `scripts/make_hostfile.sh node0 node1 node2` | probe `nproc` over SSH → `hostfile` |
| `scripts/sync_nodes.sh` | `git pull` + `make clean && make` on every node in the hostfile |
| `scripts/preflight.sh` | SSH / same-MPI / binary / launch / singleton-bug checks |

The rest of this file is the **manual path** — drive each experiment yourself,
e.g. to retune N or rerun a single chart. It's also the single-machine dry run.

## 0. Build

```bash
make                 # builds bin/kmeans_mpi and bin/kmeans_seq
```

Dependencies: an MPI toolchain (`mpicc`/`mpirun`) and `python3` with `numpy` +
`matplotlib` (only needed for dataset generation and plotting, not for the C
programs).

## 1. Correctness proof (required: "parallel == sequential")

```bash
scripts/verify_correctness.sh
```

Generates a small dataset, runs the sequential baseline and the MPI program with
the same K / iterations / epsilon, and asserts the two partitions are identical
up to cluster relabeling. Expect `PASS: ... partitions identical`.

Put the printed PASS line in the report's correctness subsection.

## 2. Size sweep — find N (required: "wall time ~2-3 min on all cores")

```bash
# P defaults to the physical core count of this machine.
# On the cluster, set P to the TOTAL cores across all nodes (e.g. 3 nodes x 4 = 12)
# and pass a hostfile so the ranks actually spread across machines.
P=12 HOSTFILE=hostfile \
SIZES="200000 400000 800000 1600000 3200000 6400000" \
scripts/run_size_sweep.sh
```

Look at `results/size_sweep.csv` (or the `fig_size_sweep.png` after step 5) and
pick the `M` whose `wall_s` lands in **120–180 s**. Call that **N**. Everything
below takes `N` as input.

> On a single laptop you will hit ~2-3 min at a much smaller M than on the full
> cluster. That's expected — find N on the hardware you'll report on.

## 3. Granularity / load balance at N (required: per-rank stacked chart)

```bash
N=<your N> P=12 HOSTFILE=hostfile scripts/run_granularity.sh
```

Writes `results/granularity.csv` with `compute_s` and `comm_s` per rank, and
prints a PASS / RETUNE verdict using the 25%-spread rule. If it says RETUNE,
adjust granularity (change `K` or the per-rank chunk by changing N) and rerun.

## 4. Speedup at 2N (required: process ladder 1,2,4,...,2X)

```bash
N=<your N> MAXP=12 HOSTFILE=hostfile scripts/run_scaling.sh
```

Runs the data scale fixed at `2N` across P = 1, 2, 4, 8, …, MAXP and writes
`results/scaling.csv` with wall/compute/comm times and derived speedup.

> To push the ladder past the physical core count on one machine (e.g. for a
> quick local sanity check), add `OVERSUBSCRIBE=1`. Do NOT oversubscribe for the
> numbers you report — those must come from real cores on the cluster.

## 5. Generate all figures

```bash
python3 plots/make_plots.py
```

Produces in `results/`:

| File | Report figure | Source CSV |
|------|----------------|------------|
| `fig_size_sweep.png`  | runtime vs input size (with/without comm) | `size_sweep.csv` |
| `fig_granularity.png` | per-rank compute+comm stacked bars        | `granularity.csv` |
| `fig_runtime.png`     | runtime vs P at 2N (with/without comm)    | `scaling.csv` |
| `fig_speedup.png`     | speedup curve vs ideal linear             | `scaling.csv` |

## Cluster vs single-machine cheat-sheet

| Knob | Single machine | 3-node cluster |
|------|----------------|----------------|
| `P`  | physical cores | total cores across nodes (e.g. 12) |
| `HOSTFILE` | unset | `hostfile` listing each node + `slots=` |
| `MAXP` | core count | total cores |
| `OVERSUBSCRIBE` | only for dry runs | never for reported numbers |
| `MPIRUN` | `mpirun` | `mpirun` (same; hostfile does the spreading) |

## hostfile format (OpenMPI)

```
192.168.1.10 slots=4     # master
192.168.1.11 slots=4     # slave1
192.168.1.12 slots=4     # slave2
```

For MPICH use `192.168.1.10:4` per line instead.

## Knobs reference (all scripts)

| Var | Meaning | Default |
|-----|---------|---------|
| `DIM` | point dimensionality | 16 |
| `K` | number of clusters | 16 |
| `ITERS` | max iterations | 50 |
| `EPS` | convergence epsilon | 1e-9 |
| `SEED` | dataset RNG seed | 7 |
| `P` / `MAXP` | process count / ladder cap | physical cores |
| `HOSTFILE` | mpirun hostfile | unset (local) |
