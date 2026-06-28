#!/usr/bin/env bash
# Container entrypoint for a demo "cluster node".
#
# The container starts as root so it can launch the SSH daemon (mpirun on the
# head node SSHes into the workers to spawn ranks). All MPI work itself runs as
# the unprivileged 'mpi' user, because Open MPI refuses to run as root without
# the --allow-run-as-root escape hatch and we want the demo to mirror a real
# cluster where you are a normal user.
set -euo pipefail

# Bring up sshd as root (the image already generated host keys with ssh-keygen -A).
if [[ "$(id -u)" -eq 0 ]]; then
    /usr/sbin/sshd
fi

# Hand control to compose's command. Worker nodes pass "sleep infinity" to stay
# alive; the head node passes the demo driver or an interactive shell. We keep
# running as root here so sshd stays up — commands that must run as the mpi user
# (mpirun) drop privileges themselves with `su - mpi`.
exec "$@"
