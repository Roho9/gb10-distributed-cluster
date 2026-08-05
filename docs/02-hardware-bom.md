# 02. Hardware Bill of Materials

Parts needed to build the cluster. Quantities are given per topology. Confirm exact SKUs
against your NVIDIA/vendor documentation before purchasing, since cable and switch
availability changes.

## Compute nodes

| Item | Spec | Qty |
| --- | --- | --- |
| NVIDIA GB10 system (DGX Spark class) | Grace Blackwell, 128 GB unified LPDDR5x, onboard ConnectX-7 (2x QSFP112) | N (>= 2) |

Every node already includes the ConnectX-7 NIC and its two QSFP112 ports, so no add-in
NIC is required.

## Case A: two nodes, direct connect

| Item | Spec | Qty | Notes |
| --- | --- | --- | --- |
| QSFP112 400G passive DAC | 0.5 m passive direct-attach copper | 1 | NVIDIA specifies Amphenol NJAAKK0006 or Luxshare LMTQF022-SD-R for GB10 stacking |

That single cable is the entire high-speed interconnect for a two-node cluster. Plug it
into the QSFP112 port on each machine. No switch, no transceivers.

## Case B: N nodes, switched fabric

### Option B1: 400G RoCE switch (port-efficient)

| Item | Spec | Qty | Notes |
| --- | --- | --- | --- |
| 400G RoCE-capable Ethernet switch | Supports PFC + ECN, QSFP-DD ports, L2 bridging | 1 | Example: NVIDIA Spectrum SN-class, or MikroTik CRS812 with QSFP-DD |
| QSFP-DD to 2x200G QSFP56 breakout DAC | 400G port to switch, two 200G legs to two nodes | ceil(N/2) | One breakout feeds two nodes |

A 400G switch port fans out to two nodes through the breakout DAC, so an M-port switch
supports up to 2M nodes.

### Option B2: 200G RoCE switch (one port per node)

| Item | Spec | Qty | Notes |
| --- | --- | --- | --- |
| 200G RoCE-capable Ethernet switch | Supports PFC + ECN, QSFP56 ports, L2 bridging | 1 | |
| QSFP56 200G DAC | One per node, node CX7 port to its own switch port | N | Straight DAC, no breakout |

### Shared for either switched option

| Item | Spec | Qty | Notes |
| --- | --- | --- | --- |
| Management switch | 1-10 GbE, ordinary | 1 | Separate from the RoCE fabric |
| Management cables | Cat6/Cat6a | N | One per node to the management switch |

## Cable length and DAC vs optics

- **DAC (direct-attach copper)** is correct for a single rack. It is cheaper, lower power,
  lower latency, and needs no separate transceiver. Passive DAC is fine at these lengths.
  Keep runs at or under ~2-3 m for 200-400G passive DAC.
- **AOC (active optical) or transceivers + fiber** are only needed if a run exceeds the
  DAC reach or crosses racks. If you go optical, both ends must use matched, switch-and-NIC
  supported transceivers.

## Power and cooling (planning note)

Size the PDU and cooling for N nodes plus the switch. Each GB10 system is a compact,
desktop-class unit, but the RoCE switch can draw meaningfully more than the nodes,
especially a 400G switch. Confirm per-device wattage from the vendor sheets and keep the
RoCE switch on the same clean power as the nodes it serves.

## Discovering your actual device names

The configs in this repo use variables because names vary by firmware and OS image. On a
node, discover them with:

```bash
ibdev2netdev            # maps RDMA device (mlx5_0) to netdev (e.g. enp1s0f0np0)
ip -br link             # lists netdev names and states
lspci | grep -i mellanox# confirms the ConnectX-7 is present
sudo mst status -v      # Mellanox device status, PCI mapping
```

Record the RDMA device name (for `NCCL_IB_HCA`) and the netdev name (for interface and
`NCCL_SOCKET_IFNAME`) for each node before running the automation.

Next: `docs/03-network-design.md`.
