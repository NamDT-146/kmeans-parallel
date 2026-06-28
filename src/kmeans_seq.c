/*
 * Sequential K-means baseline.
 *
 * Purpose in this project:
 *   1. Provides the correctness reference. The parallel program must produce
 *      the same final cluster assignment as this program (up to a relabeling
 *      of cluster ids) for the same dataset, K and iteration count.
 *   2. Provides T1, the single-process runtime used as the numerator of the
 *      speedup metric S(P) = T1 / T(P).
 *
 * Usage:
 *   ./kmeans_seq <dataset.bin> <K> <max_iters> <epsilon> [out_labels] [out_centroids]
 *
 * The algorithm is Lloyd's iteration with deterministic seeding (first K
 * points), identical to the MPI version, so the two are directly comparable.
 */

/* clock_gettime / CLOCK_MONOTONIC require POSIX.1-2008 to be requested before
 * any header is included. macOS exposes them without this, but strict -std=c11
 * on Linux glibc hides them unless this feature-test macro is set first. */
#define _POSIX_C_SOURCE 200809L

#include "common.h"
#include <time.h>

static double now_sec(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr,
            "usage: %s <dataset.bin> <K> <max_iters> <epsilon> "
            "[out_labels] [out_centroids]\n", argv[0]);
        return 1;
    }
    const char *path = argv[1];
    int K = atoi(argv[2]);
    int max_iters = atoi(argv[3]);
    double epsilon = atof(argv[4]);
    const char *out_labels = (argc > 5) ? argv[5] : NULL;
    const char *out_centroids = (argc > 6) ? argv[6] : NULL;

    Dataset ds;
    if (dataset_read(path, &ds) != 0) return 1;
    int M = ds.M, dim = ds.dim;
    if (K <= 0 || K > M) {
        fprintf(stderr, "invalid K=%d for M=%d\n", K, M);
        return 1;
    }

    double *centroids = malloc((size_t)K * dim * sizeof(double));
    double *new_sums = malloc((size_t)K * dim * sizeof(double));
    long *counts = malloc((size_t)K * sizeof(long));
    int32_t *labels = malloc((size_t)M * sizeof(int32_t));
    seed_centroids(ds.data, centroids, K, dim);

    double t0 = now_sec();
    int iter = 0;
    for (; iter < max_iters; iter++) {
        memset(new_sums, 0, (size_t)K * dim * sizeof(double));
        memset(counts, 0, (size_t)K * sizeof(long));

        /* Assignment + partial accumulation. */
        for (int i = 0; i < M; i++) {
            const double *p = ds.data + (size_t)i * dim;
            int c = nearest_centroid(p, centroids, K, dim);
            labels[i] = c;
            counts[c]++;
            double *acc = new_sums + (size_t)c * dim;
            for (int d = 0; d < dim; d++) acc[d] += p[d];
        }

        /* Update + convergence check (max centroid shift vs epsilon). */
        double max_shift = 0.0;
        for (int k = 0; k < K; k++) {
            if (counts[k] == 0) continue; /* keep empty centroid put */
            double shift = 0.0;
            for (int d = 0; d < dim; d++) {
                double nv = new_sums[(size_t)k * dim + d] / (double)counts[k];
                double diff = nv - centroids[(size_t)k * dim + d];
                shift += diff * diff;
                centroids[(size_t)k * dim + d] = nv;
            }
            if (shift > max_shift) max_shift = shift;
        }
        if (sqrt(max_shift) < epsilon) { iter++; break; }
    }
    double t1 = now_sec();

    printf("SEQ M=%d dim=%d K=%d iters=%d total_time=%.6f\n",
           M, dim, K, iter, t1 - t0);

    if (out_labels) write_labels(out_labels, labels, M);
    if (out_centroids) write_centroids(out_centroids, centroids, K, dim);

    free(centroids); free(new_sums); free(counts); free(labels);
    dataset_free(&ds);
    return 0;
}
