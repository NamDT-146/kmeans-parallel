# Parallel K-Means MPI — build both binaries.
#
#   make            build kmeans_mpi (mpicc) and kmeans_seq (cc)
#   make clean      remove binaries and build artifacts
#
# Requires an MPI toolchain on PATH:
#   macOS : brew install open-mpi
#   Ubuntu: sudo apt install -y mpich   (or libopenmpi-dev openmpi-bin)

CC      ?= cc
MPICC   ?= mpicc
CFLAGS  ?= -O3 -Wall -Wextra -std=c11
LDLIBS  ?= -lm

# Overridable so an alien-arch build (e.g. the Linux Docker demo on an ARM Mac)
# can target its own dir and not collide with the host's native bin/.
BIN     ?= bin
TARGETS := $(BIN)/kmeans_mpi $(BIN)/kmeans_seq

.PHONY: all clean
all: $(TARGETS)

$(BIN):
	mkdir -p $(BIN)

$(BIN)/kmeans_mpi: src/kmeans_mpi.c src/common.h | $(BIN)
	$(MPICC) $(CFLAGS) -o $@ src/kmeans_mpi.c $(LDLIBS)

$(BIN)/kmeans_seq: src/kmeans_seq.c src/common.h | $(BIN)
	$(CC) $(CFLAGS) -o $@ src/kmeans_seq.c $(LDLIBS)

clean:
	rm -rf $(BIN)
