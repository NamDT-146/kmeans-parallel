# Multi-node MPI "cluster" node image for the 3-node Docker compose demo.
#
# Purpose: rehearse the REAL distributed code path — three separate hosts, each
# with its own hostname and IP, talking OpenMPI over TCP and launched by SSH from
# a hostfile — without needing three physical machines. This is the same
# `mpirun --hostfile ...` path the cluster uses, so it proves the distributed
# plumbing and produces the per-node `hostname` topology evidence the report's
# cluster-setup section requires.
#
# NOT for timing. All three containers share this host's physical cores, so
# adding "nodes" is just oversubscription. The speedup/granularity numbers in the
# report come from native single-host runs; see docs/RUNBOOK.md.
#
# We do NOT pin --platform here: for a correctness + topology demo the byte-for-
# byte x86 match does not matter, and a native build avoids slow emulation on an
# ARM Mac. (The x86 byte-compat image is the separate docker/Dockerfile.)
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Same toolchain as a real cluster node (mirrors scripts/bootstrap_node.sh),
# plus an SSH *server* so mpirun can launch ranks on the other containers.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        libopenmpi-dev \
        openmpi-bin \
        openssh-server \
        openssh-client \
        python3 \
        python3-numpy \
        iproute2 \
        iputils-ping \
    && rm -rf /var/lib/apt/lists/*

# Open MPI refuses to run as root, so all work happens as an unprivileged user.
# Every container is built from this image, so they all share the same UID and
# the same SSH keypair generated below — which is what makes passwordless SSH
# between the nodes work out of the box for the demo.
RUN useradd -ms /bin/bash mpi \
    && mkdir -p /home/mpi/.ssh /run/sshd

# A single keypair baked into the image and trusted by itself. Every node has the
# identical key, so any node can SSH to any other without a password. This is a
# THROWAWAY demo credential — acceptable here precisely because the cluster is
# ephemeral and isolated on a private Docker network; never reuse this pattern for
# anything reachable from outside.
RUN ssh-keygen -t ed25519 -N "" -f /home/mpi/.ssh/id_ed25519 \
    && cp /home/mpi/.ssh/id_ed25519.pub /home/mpi/.ssh/authorized_keys \
    && printf 'Host *\n    StrictHostKeyChecking no\n    UserKnownHostsFile /dev/null\n    LogLevel ERROR\n' \
        > /home/mpi/.ssh/config \
    && chmod 700 /home/mpi/.ssh \
    && chmod 600 /home/mpi/.ssh/id_ed25519 /home/mpi/.ssh/authorized_keys /home/mpi/.ssh/config \
    && chown -R mpi:mpi /home/mpi/.ssh

# Let sshd accept the demo key and run without host-key prompts.
RUN sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && ssh-keygen -A

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /work
EXPOSE 22
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
