# Cluster Setup — Command Cheat Sheet

Copy-paste commands for each node. Use the **same Linux username** on every VM
(e.g. `mpiuser`). The old repo folder `~/parallel-kmeans-mpi` is left untouched;
clone the new repo into `~/kmeans-parallel`.

Full background: [`CLUSTER_SETUP.md`](CLUSTER_SETUP.md).

---

## On every node (master + slaves)

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/NamDT-146/kmeans-parallel.git kmeans-parallel
cd kmeans-parallel
```

---

## On each slave (node1, node2, …)

```bash
cd ~/kmeans-parallel
ROLE=slave scripts/bootstrap_node.sh
```

Record the **LAN IP** and **public key** printed at the end.

---

## On the master (node0 — the machine that will run `mpirun`)

### 1. Bootstrap

Replace the IPs with your real LAN addresses, **master first**:

```bash
cd ~/kmeans-parallel
ROLE=master NODE_IPS="192.168.1.50 192.168.1.51 192.168.1.52" scripts/bootstrap_node.sh
```

You can also pass hostnames if they already resolve (e.g. after a partial setup):

```bash
ROLE=master NODE_IPS="node0 node1 node2" scripts/bootstrap_node.sh
```

If VM IPs change after a reboot, re-run with the updated list.

### 2. Exchange SSH keys (master only)

```bash
cd ~/kmeans-parallel
NODE_USER=mpiuser scripts/exchange_keys.sh
```

Type each worker's password once when prompted.

### 3. Verify SSH (master only)

```bash
ssh node1 hostname
ssh node2 hostname
```

No password prompt should appear.

### 4. Quick cluster proof

```bash
cd ~/kmeans-parallel
QUICK=1 NODE_USER=mpiuser scripts/run_demo.sh
```

This builds the hostfile, syncs all nodes, runs preflight + correctness, and
stops before the long experiments.

### 5. Full demo (when ready)

```bash
cd ~/kmeans-parallel
NODE_USER=mpiuser scripts/run_demo.sh
```

---

## Notes

- **Repo path:** scripts auto-detect the folder name (`kmeans-parallel`). If your
  clone lives elsewhere, pass `REPO_DIR=<folder-name-under-home>`.
- **Old install:** `~/parallel-kmeans-mpi` is not deleted; only use
  `~/kmeans-parallel` for new runs.
- **Firewall:** if `mpirun` hangs, try `sudo ufw disable` on lab VMs.
- **Wrong interface:** if MPI aborts with "Unable to find reachable pairing",
  run with `MPI_IF=<iface>` (find iface via `ip -4 route get 1.1.1.1`).
