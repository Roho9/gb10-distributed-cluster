# 06. Operations: Bring-up, Validation, Troubleshooting

The end-to-end runbook. Follow it in order the first time; each step gates the next.

## 0. Prerequisites on every node

- NVIDIA DGX OS / Ubuntu aarch64 image with MLNX_OFED or DOCA drivers installed
  (`ibv_devinfo` and `ibdev2netdev` must exist).
- Passwordless SSH from your control host to every node over the **management** network.
- The CUDA toolkit and NCCL present (they ship with the DGX software stack).
- `nccl-tests` built on at least one node for validation (the run script can build it).

## 1. Inventory and variables

```bash
cp ansible/inventory.example.ini ansible/inventory.ini
$EDITOR ansible/inventory.ini          # management IPs / hostnames of each node
$EDITOR ansible/group_vars/all.yml     # fabric IPs, iface names, RDMA dev, GID index
```

Fill in the real interface name (`ibdev2netdev`), RDMA device, and RoCEv2 GID index
(`show_gids`) you discovered per `docs/02` and `docs/03`. Getting these right now saves
debugging later.

## 2. Configure the fabric

With Ansible (recommended):

```bash
cd ansible && ansible-playbook -i inventory.ini site.yml
```

This runs three roles on every node: `network` (static fabric IP, MTU 9000, /etc/hosts),
`roce` (RoCE v2, PFC priority 3, ECN, traffic class), and `nccl` (writes /etc/nccl.conf).

Without Ansible, run the standalone scripts on each node:

```bash
sudo ./scripts/configure-interfaces.sh   # applies the netplan for this node
sudo ./scripts/configure-roce.sh         # RoCE v2 + PFC + ECN + MTU
```

If you use a switch, configure it now: `switch/configure-bridge.md`.

## 3. Validate bottom-up

```bash
./scripts/health-check.sh          # per-node: driver, link, MTU, GID, NCCL env
./scripts/validate-fabric.sh       # cross-node: jumbo ping + ib_write_bw
./scripts/run-nccl-test.sh gb10-01,gb10-02   # NCCL all_reduce_perf
```

Do not proceed to workloads until:

- jumbo ping (`-M do -s 8972`) succeeds between every pair,
- `ib_write_bw` reports close to line rate (~185-190 Gb/s),
- `all_reduce_perf` bus bandwidth is within ~10-15% of that.

## 4. Run a pooled-VRAM workload

```bash
make serve-vllm      # large model split across nodes (tensor + pipeline parallel)
make llama-rpc       # llama.cpp RPC pooling node memory for a GGUF model
make train-ddp       # PyTorch distributed training smoke test
```

Each workload directory has its own README with the model-size math and launch details.

## Troubleshooting

### Link will not come up / trains slow

- Reseat the QSFP connector at both ends until it clicks. A partially seated DAC is the
  number one cause.
- `ibv_devinfo`: `PhysState` should be `LinkUp`, `State` `ACTIVE`. If `PhysState` is
  `Polling`, the far end is not answering (cable, port, or far NIC down).
- Confirm both ends are the same rate. A reseated cable can renegotiate lower silently.

### Jumbo ping fails but small ping works

- An interface or switch port is still at MTU 1500. Set MTU 9000 everywhere on the path,
  including every switch port in the bridge. Re-test with `ping -M do -s 8972`.

### ib_write_bw slow (well under 185 Gb/s)

- PFC not actually active on the RoCE priority, or DSCP-to-priority mismatch between NIC
  and switch. Recheck `mlnx_qos -i $IFACE` and the switch mapping in
  `switch/configure-bridge.md`.
- ECN/DCQCN off, so drops under load. Confirm the ECN sysfs knobs are enabled.
- Only one of the two PCIe Gen5 x4 lanes engaged. Check `lspci -vv` link width for the CX7.

### NCCL slow though ib_write_bw is fast

- Wrong `NCCL_IB_HCA` or `NCCL_SOCKET_IFNAME` (it fell back to the management NIC or TCP).
  Run with `NCCL_DEBUG=INFO` and confirm it reports `NET/IB` not `NET/Socket`.
- Wrong `NCCL_IB_GID_INDEX` (not the RoCEv2 IPv4 GID). Re-derive with `show_gids`.
- GPUDirect RDMA disabled: set `NCCL_NET_GDR_LEVEL=PXB` and confirm `[GPU Direct RDMA]`
  appears in the NCCL debug output.

### NCCL cannot connect at all

- Bootstrap TCP blocked by a firewall on the fabric interface. Trust the fabric subnet or
  open the bootstrap/rendezvous ports (`docs/03`, firewall section).
- `/etc/hosts` fabric names missing or wrong on one node.

## Day-2 operations

- Re-run `scripts/health-check.sh` after any reboot, driver update, or recabling.
- After firmware or OFED/DOCA updates, re-confirm the RDMA device name and GID index; they
  can change, which would break the NCCL environment.
- Keep `NCCL_DEBUG=WARN` (not INFO) in steady state to cut log noise while still surfacing
  problems.
