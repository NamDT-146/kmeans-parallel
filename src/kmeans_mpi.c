/*
 * Parallel K-Means clustering with MPI.
 *
 * Parallelism level : data parallelism
 * Decomposition     : data decomposition, 1D block-row over the M points
 * Mapping           : rank r owns a contiguous block of ~M/P rows; the
 *                     remainder is spread one-row-per-rank by Scatterv so the
 *                     maximum load imbalance is at most a single point.
 * Communication     : master-slave hybrid built on MPI collectives
 *                       - Scatterv : rank 0 distributes the point block once
 *                       - Bcast    : rank 0 pushes current centroids each iter
 *                       - Allreduce: partial coordinate sums + counts are
 *                                    tree-reduced and shared with every rank
 *                     All collectives are blocking. The reduction topology is
 *                     whatever the MPI library picks internally (typically a
 *                     binomial tree), which is the "collective tree-reduction"
 *                     called for in the architecture.
 * Convergence       : every rank holds the identical global centroids after the
 *                     Allreduce, so each rank computes the same centroid delta
 *                     and the loop terminates uniformly without extra messages.
 *
 * Timing: each rank accumulates compute time and communication time with
 * separate MPI_Wtime() spans, so the experiment harness can plot runtime with
 * and without the communication component.
 *
 * Usage:
 *   mpirun -np <P> ./kmeans_mpi <dataset.bin> <K> <max_iters> <epsilon> \
 *          [labels_out] [centroids_out] [timing_csv]
 */

#include <mpi.h>
#include "common.h"

int main(int argc, char **argv) {
    MPI_Init(&argc, &argv);

    int rank, P;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &P);

    if (argc < 5) {
        if (rank == 0)
            fprintf(stderr,
                "usage: %s <dataset.bin> <K> <max_iters> <epsilon> "
                "[labels_out] [centroids_out] [timing_csv]\n", argv[0]);
        MPI_Abort(MPI_COMM_WORLD, 1);
    }

    const char *data_path     = argv[1];
    int          K            = atoi(argv[2]);
    int          max_iters    = atoi(argv[3]);
    double       epsilon      = atof(argv[4]);
    const char  *labels_out   = argc > 5 ? argv[5] : NULL;
    const char  *centroids_out= argc > 6 ? argv[6] : NULL;
    const char  *timing_csv   = argc > 7 ? argv[7] : NULL;

    double t_compute = 0.0, t_comm = 0.0, t_io = 0.0;
    double t_wall_start = MPI_Wtime();

    /* Opt-in verbose progress (rank 0, stderr). Detected HERE — before the
     * dataset read and the Scatterv — so the setup phase is narrated too, not
     * just the iteration loop. Enabled when KMEANS_PROGRESS is set to a
     * non-empty, non-"0" value; off by default so it never pollutes the stdout
     * summary or the SUMMARY-on-stderr line the experiment scripts parse.
     *
     * Note on startup cost: on a real cluster the dominant delay before the
     * first milestone below is mpirun's launch/wireup (SSH spawn + TCP connect
     * inside MPI_Init), which runs before any of this code. We can't print
     * during it, but PROG("MPI ready") landing late vs the rest landing fast
     * tells you the time is launch, not our work. */
    int show_progress = 0;
    if (rank == 0) {
        const char *pe = getenv("KMEANS_PROGRESS");
        show_progress = (pe && pe[0] != '\0' && pe[0] != '0');
    }
    /* PROG(msg): timestamped milestone from rank 0 when progress is on. The
     * leading \n closes any in-place bar line; flush so it appears immediately. */
#define PROG(...) do { \
    if (show_progress) { \
        fprintf(stderr, "[kmeans] %6.3fs  ", MPI_Wtime() - t_wall_start); \
        fprintf(stderr, __VA_ARGS__); \
        fputc('\n', stderr); fflush(stderr); \
    } } while (0)

    PROG("MPI ready: P=%d ranks wired up; reading dataset '%s'", P, data_path);

    /* ---- Rank 0 reads the dataset, then broadcasts the shape ------------- */
    Dataset ds = {0};
    int32_t shape[3] = {0, 0, 0};   /* M, dim, K_ground (K from argv wins) */

    if (rank == 0) {
        double t0 = MPI_Wtime();
        if (dataset_read(data_path, &ds) != 0)
            MPI_Abort(MPI_COMM_WORLD, 2);
        t_io += MPI_Wtime() - t0;
        shape[0] = ds.M;
        shape[1] = ds.dim;
        shape[2] = ds.K;
    }

    double tb = MPI_Wtime();
    MPI_Bcast(shape, 3, MPI_INT, 0, MPI_COMM_WORLD);
    t_comm += MPI_Wtime() - tb;

    int32_t M   = shape[0];
    int     dim = shape[1];

    if (K <= 0 || K > M) {
        if (rank == 0)
            fprintf(stderr, "kmeans_mpi: invalid K=%d for M=%d\n", K, M);
        MPI_Abort(MPI_COMM_WORLD, 3);
    }

    PROG("dataset loaded: M=%d points, dim=%d, K=%d (read %.3fs); scattering rows",
         M, dim, K, t_io);

    /* ---- 1D block-row mapping: counts + displacements for Scatterv ------- */
    int *row_counts = malloc((size_t)P * sizeof(int));  /* points per rank   */
    int *row_displs = malloc((size_t)P * sizeof(int));  /* point offset      */
    int *cnt        = malloc((size_t)P * sizeof(int));   /* doubles per rank  */
    int *displ      = malloc((size_t)P * sizeof(int));   /* double offset     */

    int base = M / P;
    int rem  = M % P;
    int off  = 0;
    for (int r = 0; r < P; r++) {
        int rows      = base + (r < rem ? 1 : 0);   /* spread remainder */
        row_counts[r] = rows;
        row_displs[r] = off;
        cnt[r]        = rows * dim;
        displ[r]      = off * dim;
        off          += rows;
    }
    int local_M = row_counts[rank];

    /* ---- Scatter the point block to every rank (one-time) --------------- */
    double *local = malloc((size_t)local_M * dim * sizeof(double));
    tb = MPI_Wtime();
    MPI_Scatterv(rank == 0 ? ds.data : NULL, cnt, displ, MPI_DOUBLE,
                 local, local_M * dim, MPI_DOUBLE, 0, MPI_COMM_WORLD);
    t_comm += MPI_Wtime() - tb;

    PROG("rows scattered: this rank owns %d points; seeding %d centroids",
         local_M, K);

    /* ---- Initial centroids: first K points, seeded on rank 0 then Bcast - */
    double *centroids     = malloc((size_t)K * dim * sizeof(double));
    if (rank == 0)
        seed_centroids(ds.data, centroids, K, dim);
    tb = MPI_Wtime();
    MPI_Bcast(centroids, K * dim, MPI_DOUBLE, 0, MPI_COMM_WORLD);
    t_comm += MPI_Wtime() - tb;

    /* ---- Work buffers ---------------------------------------------------- */
    double *local_sum  = malloc((size_t)K * dim * sizeof(double));
    double *global_sum = malloc((size_t)K * dim * sizeof(double));
    long   *local_cnt  = malloc((size_t)K * sizeof(long));
    long   *global_cnt = malloc((size_t)K * sizeof(long));
    int32_t *local_lab = malloc((size_t)local_M * sizeof(int32_t));

    int iters = 0;
    double final_delta = 0.0;

    /* Per-iteration WCSS (within-cluster sum of squares = the k-means objective,
     * i.e. total squared intra-cluster distance). Rank 0 keeps the history so it
     * can write a convergence CSV when KMEANS_CONV_CSV names a path. The CSV lets
     * make_plots.py draw WCSS-vs-iteration, the textbook convergence curve. */
    const char *conv_csv = (rank == 0) ? getenv("KMEANS_CONV_CSV") : NULL;
    if (conv_csv && conv_csv[0] == '\0') conv_csv = NULL;
    double *wcss_hist = (rank == 0) ? malloc((size_t)max_iters * sizeof(double)) : NULL;

    /* ===================== main iteration loop ========================== */
    for (int it = 0; it < max_iters; it++) {
        iters = it + 1;

        /* --- compute: assign points and tally local sums/counts --------- */
        /* WCSS is summed here for free: nearest_centroid_d hands back the squared
         * distance to the chosen centroid, so no extra distance passes. */
        double tc = MPI_Wtime();
        memset(local_sum, 0, (size_t)K * dim * sizeof(double));
        for (int k = 0; k < K; k++) local_cnt[k] = 0;

        double local_wcss = 0.0;
        for (int i = 0; i < local_M; i++) {
            const double *p = local + (size_t)i * dim;
            double d2;
            int c = nearest_centroid_d(p, centroids, K, dim, &d2);
            local_wcss += d2;
            local_lab[i] = c;
            double *acc = local_sum + (size_t)c * dim;
            for (int d = 0; d < dim; d++) acc[d] += p[d];
            local_cnt[c]++;
        }
        t_compute += MPI_Wtime() - tc;

        /* --- communicate: globally reduce sums and counts to all ranks -- */
        tb = MPI_Wtime();
        MPI_Allreduce(local_sum, global_sum, K * dim, MPI_DOUBLE,
                      MPI_SUM, MPI_COMM_WORLD);
        MPI_Allreduce(local_cnt, global_cnt, K, MPI_LONG,
                      MPI_SUM, MPI_COMM_WORLD);
        /* WCSS for this iteration, reduced to rank 0 (only it logs/plots it). */
        double global_wcss = 0.0;
        MPI_Reduce(&local_wcss, &global_wcss, 1, MPI_DOUBLE, MPI_SUM,
                   0, MPI_COMM_WORLD);
        t_comm += MPI_Wtime() - tb;

        if (rank == 0 && wcss_hist) wcss_hist[it] = global_wcss;

        /* --- compute: recompute centroids + convergence delta ----------- */
        tc = MPI_Wtime();
        double delta = 0.0;
        for (int k = 0; k < K; k++) {
            if (global_cnt[k] == 0) continue;     /* keep empty cluster put */
            double *cen = centroids + (size_t)k * dim;
            double *sum = global_sum + (size_t)k * dim;
            for (int d = 0; d < dim; d++) {
                double nv = sum[d] / (double)global_cnt[k];
                double diff = nv - cen[d];
                delta += diff * diff;
                cen[d] = nv;
            }
        }
        t_compute += MPI_Wtime() - tc;

        final_delta = delta;
        int converged = (delta <= epsilon);

        /* --- live progress bar (rank 0, opt-in, stderr) ----------------- */
        /* Drawn after the convergence delta is known so the bar reports the
         * real iteration count and delta. Uses \r to redraw one line in place;
         * no trailing newline until the run ends, so the terminal stays tidy.
         * max_iters is the only hard bound we can show a fraction against —
         * k-means usually converges earlier, so we also print the live delta
         * and WCSS, and finish the bar at 100% on convergence.
         *
         * NOTE: OpenMPI buffers each rank's stderr and flushes at exit, so the
         * redraws only appear live when mpirun is given --stream-buffering 0
         * (the cluster scripts pass it when the bar is on). */
        if (show_progress) {
            int total = max_iters;
            int done  = iters;
            double frac = total > 0 ? (double)done / (double)total : 1.0;
            if (converged) frac = 1.0;
            int width = 30;
            int fill  = (int)(frac * width + 0.5);
            fprintf(stderr, "\r  [");
            for (int b = 0; b < width; b++)
                fputc(b < fill ? '#' : '.', stderr);
            fprintf(stderr, "] %3.0f%%  iter %d/%d  delta=%.3e  WCSS=%.4e",
                    frac * 100.0, done, total, delta, global_wcss);
            fflush(stderr);
        }

        if (converged) break;   /* identical delta on every rank */
    }
    /* Close the progress line so the summary prints on a fresh row. */
    if (show_progress) fputc('\n', stderr);

    /* Write the WCSS convergence history (rank 0, opt-in via KMEANS_CONV_CSV). */
    if (rank == 0 && conv_csv && wcss_hist) {
        FILE *cf = fopen(conv_csv, "w");
        if (cf) {
            fprintf(cf, "iter,wcss\n");
            for (int it = 0; it < iters; it++)
                fprintf(cf, "%d,%.10g\n", it + 1, wcss_hist[it]);
            fclose(cf);
        } else {
            fprintf(stderr, "kmeans_mpi: WARN: could not write conv CSV '%s'\n",
                    conv_csv);
        }
    }
    free(wcss_hist);

    /* ---- Gather final labels back to rank 0 for the correctness check --- */
    int32_t *all_labels = NULL;
    if (rank == 0) all_labels = malloc((size_t)M * sizeof(int32_t));
    tb = MPI_Wtime();
    MPI_Gatherv(local_lab, local_M, MPI_INT,
                all_labels, row_counts, row_displs, MPI_INT,
                0, MPI_COMM_WORLD);
    t_comm += MPI_Wtime() - tb;

    double t_wall = MPI_Wtime() - t_wall_start;

    /* ---- Reduce timing across ranks (max = critical path) --------------- */
    double max_compute, max_comm, max_wall;
    MPI_Reduce(&t_compute, &max_compute, 1, MPI_DOUBLE, MPI_MAX, 0, MPI_COMM_WORLD);
    MPI_Reduce(&t_comm,    &max_comm,    1, MPI_DOUBLE, MPI_MAX, 0, MPI_COMM_WORLD);
    MPI_Reduce(&t_wall,    &max_wall,    1, MPI_DOUBLE, MPI_MAX, 0, MPI_COMM_WORLD);

    /* ---- Per-rank timing for the granularity / load-balance plot --------- */
    /* Gather each rank's timings to rank 0 and write the CSV there. A gather
     * (not per-rank fopen) is required because on a real cluster the ranks live
     * on different machines with separate filesystems, so only rank 0 can write
     * one coherent file. We pack (compute, comm, wall) per rank plus local_M.  */
    if (timing_csv) {
        double  my_t[3] = { t_compute, t_comm, t_wall };
        double *all_t   = (rank == 0) ? malloc((size_t)P * 3 * sizeof(double)) : NULL;
        int    *all_lm  = (rank == 0) ? malloc((size_t)P * sizeof(int))        : NULL;

        MPI_Gather(my_t, 3, MPI_DOUBLE, all_t, 3, MPI_DOUBLE, 0, MPI_COMM_WORLD);
        MPI_Gather(&local_M, 1, MPI_INT, all_lm, 1, MPI_INT, 0, MPI_COMM_WORLD);

        if (rank == 0) {
            FILE *f = fopen(timing_csv, "w");
            if (f) {
                fprintf(f, "rank,P,local_M,compute_s,comm_s,wall_s\n");
                for (int r = 0; r < P; r++)
                    fprintf(f, "%d,%d,%d,%.6f,%.6f,%.6f\n",
                            r, P, all_lm[r],
                            all_t[r * 3 + 0], all_t[r * 3 + 1], all_t[r * 3 + 2]);
                fclose(f);
            }
            free(all_t);
            free(all_lm);
        }
    }

    if (rank == 0) {
        printf("kmeans_mpi: P=%d M=%d dim=%d K=%d iters=%d delta=%.3e\n",
               P, M, dim, K, iters, final_delta);
        printf("  wall=%.4fs compute=%.4fs comm=%.4fs io=%.4fs (critical-path max)\n",
               max_wall, max_compute, max_comm, t_io);

        if (labels_out)    write_labels(labels_out, all_labels, M);
        if (centroids_out) write_centroids(centroids_out, centroids, K, dim);

        /* Machine-readable summary line for run_scaling.sh / run_size_sweep */
        fprintf(stderr, "SUMMARY P=%d M=%d wall=%.6f compute=%.6f comm=%.6f iters=%d\n",
                P, M, max_wall, max_compute, max_comm, iters);
    }

    /* ---- cleanup --------------------------------------------------------- */
    free(row_counts); free(row_displs); free(cnt); free(displ);
    free(local); free(centroids);
    free(local_sum); free(global_sum); free(local_cnt); free(global_cnt);
    free(local_lab);
    free(all_labels);
    if (rank == 0) dataset_free(&ds);

    MPI_Finalize();
    return 0;
}
