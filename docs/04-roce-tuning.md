# 04. RoCE v2 and NCCL Tuning

The goal of this document is one number: NCCL all-reduce bus bandwidth close to the
~185-190 Gb/s the CX7 link can realize. Everything here exists to get NCCL there.

## The lossless requirement

RoCE v2 assumes the network does not drop packets. A single drop forces a go-back-N
retransmit that collapses throughput. On a switched fabric you make the network lossless
with two mechanisms working together:

- **PFC (Priority Flow Control, IEEE 802.1Qbb)**: pauses a specific traffic priority
  instead of dropping when a buffer fills. RoCE traffic is tagged to one priority (this
  repo uses **priority 3**) and PFC is enabled for exactly that priority on both NIC and
  switch.
- **ECN (Explicit Congestion Notification) with DCQCN**: marks packets under congestion so
  senders slow down before buffers overflow. This keeps PFC from having to pause often.

On a **2-node direct cable** there is no switch, so there is no switch PFC to configure,
but you still set the NIC to RoCE v2, tag the priority, and use jumbo frames. PFC on the
NIC is harmless and recommended for consistency.

## NIC-side configuration (every node)

The `scripts/configure-roce.sh` script applies these; they are listed here so you know
what each does. `mlx5_0` is the RDMA device, `$IFACE` the fabric netdev.

```bash
# 1. Trust DSCP and map RoCE to priority 3 (DCQCN uses DSCP by default on CX7)
sudo mlnx_qos -i $IFACE --trust dscp
sudo mlnx_qos -i $IFACE --pfc 0,0,0,1,0,0,0,0     # PFC on priority 3 only

# 2. Force RoCE v2 and DSCP-based traffic class
sudo cma_roce_mode -d mlx5_0 -p 1 -m 2            # RoCE mode v2
echo 106 | sudo tee /sys/class/infiniband/mlx5_0/tc/1/traffic_class  # DSCP 26 -> prio 3

# 3. Enable ECN / DCQCN congestion control
sudo mlx5_ecn_control ... (or) echo 1 | sudo tee \
  /sys/class/net/$IFACE/ecn/roce_np/enable/3
echo 1 | sudo tee /sys/class/net/$IFACE/ecn/roce_rp/enable/3

# 4. Jumbo frames
sudo ip link set $IFACE mtu 9000
```

Notes:

- The exact sysfs paths (`.../ecn/...`, `.../tc/...`) depend on the MLNX_OFED / DOCA
  version. The script probes for the available path and warns if a knob is missing rather
  than failing hard.
- DSCP 26 maps to priority 3 in the default CX7 DSCP-to-prio table; keep the switch mapping
  consistent (see `switch/configure-bridge.md`).

## NCCL environment

NCCL reads these from the environment. They are defined once in
`ansible/group_vars/all.yml`, rendered into `/etc/nccl.conf` and into each workload's
launcher. The important ones:

| Variable | Value (example) | Why |
| --- | --- | --- |
| `NCCL_IB_HCA` | `mlx5_0` | Use the ConnectX-7 RDMA device, not any other |
| `NCCL_IB_GID_INDEX` | `3` | Select the RoCEv2 IPv4 GID (confirm per node, see doc 03) |
| `NCCL_SOCKET_IFNAME` | `enp1s0f0np0` | Bootstrap/control over the fabric netdev, not mgmt |
| `NCCL_NET_GDR_LEVEL` | `PXB` | Allow GPUDirect RDMA so the NIC DMAs GPU memory directly |
| `NCCL_IB_DISABLE` | `0` | Keep the IB/RoCE transport enabled |
| `NCCL_IB_TC` | `106` | Traffic class / DSCP so NCCL traffic lands on priority 3 |
| `NCCL_IB_QPS_PER_CONNECTION` | `4` | More queue pairs saturate the dual PCIe x4 path |
| `NCCL_DEBUG` | `INFO` | During bring-up, so you can see the transport it chose |

`NCCL_SOCKET_IFNAME` and `NCCL_IB_HCA` are the two that most often get set wrong. If NCCL
picks the management interface for bootstrap, or a non-CX7 HCA, it either fails to connect
or silently falls back to slow TCP. Always confirm from `NCCL_DEBUG=INFO` output that it
reports `[send] via NET/IB/0` (RDMA) and not `NET/Socket`.

## Verifying, layer by layer

Do not skip straight to a training run. Validate bottom-up (the scripts automate this):

1. **Link up + MTU**: `ip -br link` shows the fabric netdev `UP` at mtu 9000; jumbo ping
   works (`docs/03`).
2. **RDMA reachability**: `ibv_devinfo` shows the port `ACTIVE`; `show_gids` lists your
   RoCEv2 IPv4 GID.
3. **Raw RDMA bandwidth**: `ib_write_bw` between two nodes should report close to line
   rate. `scripts/validate-fabric.sh` runs this.
4. **NCCL collective**: `all_reduce_perf` from nccl-tests should show bus bandwidth near
   the RDMA number. `scripts/run-nccl-test.sh` runs this across your hosts.

If step 3 is fast but step 4 is slow, the problem is NCCL environment (HCA, GID, IFNAME,
GDR), not the fabric. If step 3 is slow, the problem is PFC/ECN/MTU or cabling.

## Expected numbers

| Measurement | Healthy range on a 200 Gb/s CX7 link |
| --- | --- |
| `ib_write_bw` | ~185-190 Gb/s (~23-24 GB/s) |
| NCCL `all_reduce_perf` busbw (2 nodes) | within ~10-15% of the ib_write_bw figure |
| Jumbo ping RTT (direct cable) | tens of microseconds |

If you are far below these, work back down the layers in the list above.

Next: `docs/05-cabling-guide.md`.
