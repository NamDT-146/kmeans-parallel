# Remote access: teammates on different networks + Mac as driver

The cluster guides ([`CLUSTER_SETUP.md`](CLUSTER_SETUP.md),
[`WSL_SETUP.md`](WSL_SETUP.md)) assume everyone is on the **same Wi-Fi/LAN**. If
the four of you are **not in the same room**, a private LAN IP on one machine
can't be reached from another network. This doc covers two things:

1. **Tailscale** — put every machine on one private mesh network so SSH and MPI
   work as if you were all on the same LAN, from anywhere.
2. **Mac-as-driver** — how your ARM Mac orchestrates the x86 cluster and does the
   plotting, without joining the MPI job.

---

## 1. Tailscale: one virtual LAN across the internet

[Tailscale](https://tailscale.com) is a zero-config mesh VPN. Each machine gets a
stable private IP (e.g. `100.x.y.z`) that every other machine on your tailnet can
reach, regardless of physical network or NAT. It's free for personal use and far
simpler than port-forwarding or a manual VPN.

### Setup (every machine — Mac, and each friend's WSL/VM)

- **Mac:** `brew install tailscale` then `sudo tailscale up` (or the menu-bar app).
- **Ubuntu / WSL:**
  ```bash
  curl -fsSL https://tailscale.com/install.sh | sh
  sudo tailscale up
  ```
  Follow the printed URL to authenticate. Have everyone join the **same tailnet**
  (one person creates it and invites the others, or use a shared login).

> **WSL note:** Tailscale needs the daemon running. After `sudo tailscale up`, keep
> the WSL session alive, or add `tailscaled` to the `/etc/wsl.conf` `[boot]`
> command alongside `service ssh start`. Mirrored networking (see
> [`WSL_SETUP.md`](WSL_SETUP.md)) also helps Tailscale see the right interface.

### Find each machine's Tailscale IP

```bash
tailscale ip -4        # prints this machine's 100.x.y.z address
tailscale status       # lists every machine on the tailnet and its IP
```

### Use Tailscale IPs everywhere the LAN guides say "LAN IP"

The hostfile uses Tailscale IPs instead of `192.168.x.x`:
```
100.64.0.1 slots=4
100.64.0.2 slots=4
100.64.0.3 slots=4
```
SSH key exchange, the smoke test, and the run scripts are all identical — only the
addresses change. Because the tailnet IPs are stable, you don't have the
"WSL IP changed on reboot" problem from NAT mode.

> **Performance caveat:** MPI traffic now crosses the internet between homes, so
> latency is much higher than a real LAN. This is fine for **correctness and
> functional testing** of a multi-node run, but the **timing/speedup numbers for
> the report are meaningless** over a WAN — collect those on co-located machines
> on a real LAN (or the bridged-VM cluster). Use Tailscale to develop and prove
> the cluster works end-to-end, not to measure performance.

---

## 2. Mac as the driver (not an MPI node)

Your Mac is ARM; the cluster is x86. The Mac can't be an MPI rank, but it makes an
excellent **control + analysis** machine:

- **Author code** locally, `git push`.
- **Launch runs** by SSHing into the master node.
- **Pull results** back and plot them locally (matplotlib is already installed).

### One-shot remote run

```bash
# from the Mac, after pushing code:
ssh <user>@<master-tailscale-ip> \
  'cd parallel-kmeans && git pull && make && \
   mpirun --hostfile hostfile -np 12 ./bin/kmeans_mpi data/train.bin 16 50 1e-9'
```

### Pull results and plot on the Mac

```bash
scp '<user>@<master-tailscale-ip>:parallel-kmeans/results/*.csv' results/
python3 plots/make_plots.py
open results/fig_speedup.png
```

### Why the master fans out (you only SSH to one node)

You don't SSH to all four machines. You connect to the **master**, and `mpirun`
uses the hostfile + passwordless SSH to launch workers on the others itself. That's
the whole point of the key-exchange step — the master must reach every worker
without a password, but *you* only need to reach the master.

---

## Recommended workflow by situation

| Situation | Network | What to use |
|---|---|---|
| All four in one room | Same Wi-Fi | LAN IPs, [`WSL_SETUP.md`](WSL_SETUP.md) / [`CLUSTER_SETUP.md`](CLUSTER_SETUP.md) |
| Spread across homes, **testing** | Tailscale mesh | This doc — prove it runs, ignore timings |
| Collecting **graded** numbers | Same LAN, real machines | Co-locate; bridged-VM cluster is grade-safe |

The honest bottom line: **Tailscale unblocks development from anywhere**, but the
report's performance measurements must come from machines on a genuine local
network. Plan one in-person session (or one shared LAN) for the final data
collection; do everything else remotely.
