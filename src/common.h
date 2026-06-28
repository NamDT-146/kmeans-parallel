#ifndef KMEANS_COMMON_H
#define KMEANS_COMMON_H

/*
 * Shared helpers for the sequential and MPI K-means programs.
 *
 * Dataset binary format (little-endian, written by scripts/gen_dataset.py):
 *   int32   M     number of points
 *   int32   dim   dimensionality of each point
 *   int32   K     intended number of clusters (ground truth)
 *   float64 data[M * dim]    row-major point coordinates
 *   int32   labels[M]        ground-truth cluster id per point (for diagnostics)
 *
 * Coordinates are stored as double so the sequential and parallel runs operate
 * on bit-identical inputs, which keeps the correctness comparison exact.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>

typedef struct {
    int32_t M;        /* number of points                  */
    int32_t dim;      /* coordinates per point             */
    int32_t K;        /* ground-truth cluster count        */
    double *data;     /* M * dim, row-major (owned)        */
    int32_t *labels;  /* M ground-truth labels (owned)     */
} Dataset;

/* Read the whole dataset on a single rank. Returns 0 on success, -1 on error. */
static inline int dataset_read(const char *path, Dataset *ds) {
    FILE *f = fopen(path, "rb");
    if (!f) { perror("fopen"); return -1; }

    int32_t header[3];
    if (fread(header, sizeof(int32_t), 3, f) != 3) {
        fprintf(stderr, "dataset_read: bad header in %s\n", path);
        fclose(f);
        return -1;
    }
    ds->M = header[0];
    ds->dim = header[1];
    ds->K = header[2];

    size_t n = (size_t)ds->M * (size_t)ds->dim;
    ds->data = malloc(n * sizeof(double));
    ds->labels = malloc((size_t)ds->M * sizeof(int32_t));
    if (!ds->data || !ds->labels) {
        fprintf(stderr, "dataset_read: out of memory\n");
        free(ds->data); free(ds->labels);
        fclose(f);
        return -1;
    }

    if (fread(ds->data, sizeof(double), n, f) != n) {
        fprintf(stderr, "dataset_read: short read on data\n");
        free(ds->data); free(ds->labels);
        fclose(f);
        return -1;
    }
    if (fread(ds->labels, sizeof(int32_t), (size_t)ds->M, f) != (size_t)ds->M) {
        /* labels are optional/diagnostic; tolerate their absence */
        memset(ds->labels, 0, (size_t)ds->M * sizeof(int32_t));
    }

    fclose(f);
    return 0;
}

static inline void dataset_free(Dataset *ds) {
    free(ds->data);
    free(ds->labels);
    ds->data = NULL;
    ds->labels = NULL;
}

/* Squared Euclidean distance between two dim-length vectors. */
static inline double dist2(const double *a, const double *b, int dim) {
    double s = 0.0;
    for (int d = 0; d < dim; d++) {
        double diff = a[d] - b[d];
        s += diff * diff;
    }
    return s;
}

/* Assign one point to the nearest of K centroids; returns the centroid index. */
static inline int nearest_centroid(const double *point, const double *centroids,
                                   int K, int dim) {
    int best = 0;
    double best_d = dist2(point, centroids, dim);
    for (int k = 1; k < K; k++) {
        double d = dist2(point, centroids + (size_t)k * dim, dim);
        if (d < best_d) { best_d = d; best = k; }
    }
    return best;
}

/* Like nearest_centroid but also returns the squared distance to the chosen
 * centroid via *out_d2. Summing this over all points gives WCSS (within-cluster
 * sum of squares) — the k-means objective — for free during assignment. */
static inline int nearest_centroid_d(const double *point, const double *centroids,
                                     int K, int dim, double *out_d2) {
    int best = 0;
    double best_d = dist2(point, centroids, dim);
    for (int k = 1; k < K; k++) {
        double d = dist2(point, centroids + (size_t)k * dim, dim);
        if (d < best_d) { best_d = d; best = k; }
    }
    *out_d2 = best_d;
    return best;
}

/* Write final cluster labels (one int per line) for correctness comparison. */
static inline int write_labels(const char *path, const int32_t *labels, int32_t M) {
    FILE *f = fopen(path, "w");
    if (!f) { perror("fopen labels"); return -1; }
    for (int32_t i = 0; i < M; i++) fprintf(f, "%d\n", labels[i]);
    fclose(f);
    return 0;
}

/* Write final centroids (one point per line, space-separated coords). */
static inline int write_centroids(const char *path, const double *centroids,
                                  int K, int dim) {
    FILE *f = fopen(path, "w");
    if (!f) { perror("fopen centroids"); return -1; }
    for (int k = 0; k < K; k++) {
        for (int d = 0; d < dim; d++)
            fprintf(f, "%.10g%c", centroids[(size_t)k * dim + d],
                    d + 1 == dim ? '\n' : ' ');
    }
    fclose(f);
    return 0;
}

/*
 * Deterministic centroid seeding: pick the first K points as initial centroids.
 * Both the sequential and parallel programs use this identical rule so their
 * results are directly comparable without worrying about RNG divergence.
 */
static inline void seed_centroids(const double *data, double *centroids,
                                  int K, int dim) {
    memcpy(centroids, data, (size_t)K * dim * sizeof(double));
}

#endif /* KMEANS_COMMON_H */
