#!/usr/bin/env bash
# Build and use an x86-64 Ubuntu MPI environment on any host (including ARM Macs).
#
# This wraps Docker so you do not have to remember the --platform and bind-mount
# flags. The repo is mounted at /work inside the container, so edits you make on
# the host (in your editor) are immediately visible in the container, and build
# artifacts written in the container land back in your working tree.
#
# Commands:
#   docker/run.sh build              build the x86-64 image (one time, or after Dockerfile edits)
#   docker/run.sh shell              drop into an interactive Ubuntu shell at /work
#   docker/run.sh make               run `make` inside the container
#   docker/run.sh verify             run scripts/verify_correctness.sh inside the container
#   docker/run.sh run -- <cmd...>    run an arbitrary command inside the container
#
# Examples:
#   docker/run.sh build
#   docker/run.sh make
#   docker/run.sh run -- mpirun -np 4 ./bin/kmeans_mpi data/verify.bin 8 100 1e-8
#   docker/run.sh shell
#
# Note on Apple Silicon: this image is amd64 and runs under emulation. Use it for
# building the Linux binary and checking correctness. Do NOT trust its timings —
# the speedup/granularity numbers for the report must come from real x86 hardware.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="parallel-kmeans-x64"

# bin/ holds host-native (e.g. ARM) binaries from a local `make`. Mounting the
# repo would let those collide with the container's x86 build. We keep a separate
# build dir inside the container by pointing BIN at bin-linux when in-container,
# but the simplest robust approach is: always rebuild inside the container before
# running. The Makefile's bin/ is fine because we never mix the two in one MPI job.

run_container() {
    docker run --rm -it \
        --platform linux/amd64 \
        -v "$ROOT":/work \
        -w /work \
        "$IMAGE" "$@"
}

run_container_noninteractive() {
    docker run --rm \
        --platform linux/amd64 \
        -v "$ROOT":/work \
        -w /work \
        "$IMAGE" "$@"
}

cmd="${1:-shell}"
shift || true

case "$cmd" in
    build)
        echo "[docker] building x86-64 image '$IMAGE' (this is slow the first time)"
        docker build --platform linux/amd64 -t "$IMAGE" "$ROOT/docker"
        echo "[docker] done. Try: docker/run.sh make"
        ;;
    shell)
        run_container /bin/bash
        ;;
    make)
        # Clean first so any host-native objects in bin/ do not shadow the x86 build.
        run_container_noninteractive bash -lc 'make clean >/dev/null 2>&1 || true; make'
        ;;
    verify)
        run_container_noninteractive bash -lc 'make clean >/dev/null 2>&1 || true; bash scripts/verify_correctness.sh'
        ;;
    run)
        # Everything after `--` is the command to run inside the container.
        if [[ "${1:-}" == "--" ]]; then shift; fi
        if [[ $# -eq 0 ]]; then
            echo "usage: docker/run.sh run -- <command...>" >&2
            exit 1
        fi
        run_container "$@"
        ;;
    *)
        echo "usage: docker/run.sh {build|shell|make|verify|run -- <cmd...>}" >&2
        exit 1
        ;;
esac
