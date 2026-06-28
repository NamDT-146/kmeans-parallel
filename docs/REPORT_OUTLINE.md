# Report Outline — Parallel K-Means with MPI

Target length **10–20 pages** (hard cap 20). Write in the language your group
submits in (Vietnamese or English). Every required section from the assignment
brief is mapped below to the code/experiment that supplies its content, so you
fill the report from artifacts you already produced — no section is left to
invent.

Submission: Teams → **Projects** folder → create a sub-folder named with your
**group ID** → upload the PDF. Deadline **end of day 24 June 2026**.

---

## 0. Title page (½ pg)
- Project title, course code, group ID, the four members' names + student IDs.
- One-line problem statement: "Parallel K-means clustering of M points into K
  clusters on an MPI cluster of ≥3 Ubuntu machines."

## 1. Introduction (1 pg)
- What K-means does (partition M points into K clusters minimising within-cluster
  squared distance; Lloyd's iteration).
- Why it is worth parallelising: the assignment step is O(M·K·dim) per iteration
  and dominates runtime, and it is embarrassingly parallel across points.
- State the goal: same result as the sequential solver, faster, and measure how
  the speedup scales with process count.

## 2. Cluster setup (1–2 pg)
- Hardware table: 3+ physical machines (CPU model, physical cores, RAM, OS).
- Network: phone hotspot / shared LAN, **bridged adapter**, one Ubuntu VM per
  physical host, static or DHCP-reserved IPs. Include the `/etc/hosts` table.
- SSH: passwordless key auth between all nodes (summarise the tutorial steps;
  note these were automated by `scripts/bootstrap_node.sh`).
- MPI: OpenMPI version, how the hostfile maps slots to cores.
- Insert 1 screenshot: `mpirun --hostfile hostfile -np <total> hostname` printing
  every node's hostname — proof the cluster runs distributed jobs.

## 3. Parallelisation design (3–4 pg) — **the graded core**

Use these exact sub-headings; each maps to a required bullet in the brief.

### 3.1 Level of parallelism
- **Data parallelism.** The same assignment computation runs on every process;
  only the data differs. (Contrast briefly with task parallelism to show you
  understand the distinction.)

### 3.2 Decomposition technique
- **Data decomposition**, specifically **1D block-row** partitioning of the M×dim
  point matrix. Each process owns a contiguous block of rows.
- Mention you considered the alternatives (exploratory / recursive / speculative)
  and why data decomposition fits: the work is a uniform map over independent
  points with a fixed iteration structure.

### 3.3 Mapping technique (process assignment)
- **1D block.** Process r gets `M/P` rows; the `M mod P` remainder is spread one
  row per low-rank process via `MPI_Scatterv`, bounding imbalance to ≤1 point.
- State why not 2D `n/√p × n/√p`: K-means assignment needs the full `dim` vector
  of each point together, so splitting along the feature axis would force extra
  communication for no benefit. 1D row blocks keep each point whole on one rank.
- Reference `kmeans_mpi.c` lines computing `row_counts` / `row_displs`.

### 3.4 Communication strategy and topology
- **Master–slave hybrid built on collectives.** Rank 0 is the master (reads data,
  seeds centroids, owns final output); all ranks are workers.
- Per-phase table:
  | Phase | MPI call | Pattern | When |
  |-------|----------|---------|------|
  | Distribute points | `MPI_Scatterv` | one-to-all | once, at start |
  | Push centroids | `MPI_Bcast` | one-to-all (tree) | each iteration |
  | Reduce sums + counts | `MPI_Allreduce` | all-to-all (tree) | each iteration |
  | Collect labels | `MPI_Gatherv` | all-to-one | once, at end |
- **Blocking** collectives (justify: the algorithm has a hard barrier each
  iteration — centroids can't update until every partial sum is in — so
  non-blocking would buy nothing and complicate the code).
- **Topology: tree.** `Bcast`/`Allreduce` are internally tree-structured
  (binomial tree) in OpenMPI, giving O(log P) communication depth. This is the
  "collective tree-reduction" from the architecture spec.

### 3.5 Load balancing
- Even row split + remainder spreading ⇒ near-perfect balance for uniform data.
- How you *measured* it: per-rank compute/comm timing (`run_granularity.sh`).
- State the decision rule you applied: idle-time spread >25% between any two
  ranks ⇒ re-tune granularity. Report the measured spread and verdict here
  (fill from `results/granularity.csv`).

### 3.6 Pseudo-code of the parallel algorithm
- Paste the block below (it mirrors `kmeans_mpi.c` exactly).

```
function PARALLEL_KMEANS(dataset, K, max_iters, epsilon):
    MPI_Init
    rank, P  <- comm rank and size
    if rank == 0:
        read dataset (M points, dim features); shape <- (M, dim)
    MPI_Bcast(shape)                              # everyone learns M, dim

    compute row_counts[r], row_displs[r] for 1D block split (remainder spread)
    local <- MPI_Scatterv(data by row blocks)     # each rank gets ~M/P rows

    if rank == 0: centroids <- first K points
    MPI_Bcast(centroids)

    for it in 1..max_iters:
        # ---- compute (no communication) ----
        zero(local_sum[K][dim]); zero(local_cnt[K])
        for each point p in local:
            c <- argmin_k || p - centroids[k] ||^2
            local_sum[c] += p ; local_cnt[c] += 1

        # ---- communicate (tree reduction) ----
        global_sum <- MPI_Allreduce(local_sum, SUM)
        global_cnt <- MPI_Allreduce(local_cnt, SUM)

        # ---- compute: identical on every rank ----
        delta <- 0
        for k in 1..K where global_cnt[k] > 0:
            new <- global_sum[k] / global_cnt[k]
            delta += || new - centroids[k] ||^2
            centroids[k] <- new
        if delta <= epsilon: break                # uniform termination

    labels <- MPI_Gatherv(local labels) to rank 0
    MPI_Finalize
```

## 4. Implementation notes (1 pg)
- Dataset format (binary, float64) and why (bit-identical seq vs parallel input).
- Deterministic seeding (first K points) so the two solvers are comparable.
- Timing instrumentation: separate compute/comm `MPI_Wtime` spans, reduced with
  `MPI_MAX` to report the critical path.
- Build: `mpicc -O3`; one command (`make`) builds both binaries.

## 5. Results (3–5 pg) — fill from your cluster runs

### 5.1 Correctness
- State the experiment: same dataset/K/epsilon through `kmeans_seq` and
  `kmeans_mpi`, compare partitions up to relabeling.
- Report the `verify_correctness.sh` output ("PASS: … bit-identical …").
- One sentence: this proves the parallel program computes the same solution.

### 5.2 Choosing N (runtime vs input size)
- Insert **`fig_runtime_vs_size.png`** (with- and without-comm curves).
- State the N you picked where wall time ≈ 2–3 min on all physical cores, and
  the total process count (e.g. 3 machines × 4 cores = 12).

### 5.3 Granularity / load balance at N
- Insert **`fig_granularity.png`** (per-rank stacked compute+comm bars).
- Report the compute-time spread across ranks and the PASS/RETUNE verdict.
- If you re-tuned (changed dim/K/iters to shift the compute-to-comm ratio),
  describe the before/after.

### 5.4 Speedup at 2N
- Insert **`fig_runtime.png`** (runtime vs P, with/without comm) and
  **`fig_speedup.png`** (speedup vs P with the ideal line).
- Process ladder 1, 2, 4, 8, …, 2X. Discuss: where speedup tracks ideal, where
  communication overhead bends the curve, and the implied scalability limit.
- Tie back to Amdahl: the per-iteration `Allreduce` is the serial-ish fraction
  that caps speedup as P grows.

## 6. Discussion (1 pg)
- What limited speedup (comm overhead, small per-rank work at high P).
- Granularity lesson: bigger data per rank ⇒ better compute-to-comm ratio.
- Honest limitations: single dataset family (Gaussian blobs), fixed K seeding,
  WiFi-LAN latency vs wired.

## 7. Conclusion (½ pg)
- Restate: correct parallel K-means on a real ≥3-machine MPI cluster, measured
  speedup of ~X× at P=Y, with the load-balance and granularity behaviour
  characterised.

## Appendix (not counted toward the 20 pages if your instructor allows)
- `hostfile`, key commands from `RUNBOOK.md`, and the raw `results/*.csv`.

---

### Figure checklist (all produced by `plots/make_plots.py`)
- [ ] `fig_runtime_vs_size.png` — §5.2, from `size_sweep.csv`
- [ ] `fig_granularity.png` — §5.3, from `granularity.csv`
- [ ] `fig_runtime.png` — §5.4, from `scaling.csv`
- [ ] `fig_speedup.png` — §5.4, from `scaling.csv`
- [ ] cluster `hostname` screenshot — §2

### Required-section coverage map (tick before submitting)
- [ ] Parallelism level → §3.1
- [ ] Decomposition technique → §3.2
- [ ] Mapping technique → §3.3
- [ ] Communication strategy + topology → §3.4
- [ ] Load balancing → §3.5 + §5.3
- [ ] Pseudo-code → §3.6
- [ ] Correctness proof → §5.1
- [ ] N at 2–3 min → §5.2
- [ ] Granularity / 25% rule → §5.3
- [ ] Speedup curves → §5.4
