# x86-64 Ubuntu environment for the parallel K-means MPI project.
#
# Purpose: give an Apple-Silicon Mac (or any machine) a Linux environment whose
# compiled binaries are byte-compatible with the x86-64 Ubuntu cluster/WSL nodes
# the rest of the team uses. On an ARM Mac this image runs under emulation
# (Rosetta/QEMU via `--platform linux/amd64`), which is fine for development and
# correctness testing but NOT representative for timing/speedup numbers — those
# must come from real x86 hardware.
#
# The toolchain here mirrors scripts/bootstrap_node.sh so a binary built in this
# container behaves like one built natively on a cluster node.
FROM --platform=linux/amd64 ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Same packages the cluster nodes install: C toolchain, OpenMPI, SSH, Python for
# dataset generation and plotting, plus net tools used during setup.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        libopenmpi-dev \
        openmpi-bin \
        openssh-client \
        python3 \
        python3-numpy \
        python3-matplotlib \
        make \
        ca-certificates \
        net-tools \
        iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Open MPI refuses to run as root by default. Create an unprivileged user so
# `mpirun` works without the --allow-run-as-root escape hatch.
RUN useradd -ms /bin/bash mpi
USER mpi
WORKDIR /work

# The repo is bind-mounted at /work at run time (see docker/run.sh), so we do not
# COPY sources in — edits on the host are visible immediately in the container.
CMD ["/bin/bash"]
