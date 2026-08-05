# 01. Reference Architecture

This document describes how multiple NVIDIA GB10 Grace Blackwell systems are combined
into one distributed compute cluster, and why the interconnect is built the way it is.

## 1. The building block: one GB10 node

Each node is a GB10 Grace Blackwell system (DGX Spark class) with:

- A Grace CPU (20 Arm cores: 10x Cortex-X925 plus 10x Cortex-A725) and a Blackwell GPU
  on one package, joined by NVLink-C2C.
- 128 GB of LPDDR5x memory that is coherent and unified between CPU and GPU. There is no
  separate "VRAM" pool to copy into; the GPU addresses the same 128 GB the CPU sees.
- An onboard NVIDIA ConnectX-7 SmartNIC, exposed to the OS as two QSFP112 network ports.
  The CX7 is fed by the GB10 SoC over two PCIe Gen5 x4 links (~100 Gb/s each), and each
  physical port carries two 100G MACs, giving 200 Gb/s per port.
- Onboard conventional Ethernet (10 GbE class) and WiFi for management and internet.

Because the 128 GB is unified, the single most useful thing a cluster does is pool that
memory across nodes. Two nodes present 256 GB, four nodes present 512 GB, and so on. That
is what lets the cluster hold and serve models that do not fit on one node.

## 2. Why the ConnectX-7 fabric, not plain Ethernet

Pooling memory and running collective operations (all-reduce, all-gather) means moving
tensors between nodes constantly. Two properties matter:

1. **Bandwidth.** At 200 Gb/s per link the CX7 fabric is 20x to 200x faster than the
   management Ethernet. Collectives are bandwidth-bound, so this is the difference between
   a usable cluster and a slideshow.
2. **Latency and CPU cost.** RDMA over Converged Ethernet (RoCE v2) lets one node's NIC
   write directly into another node's memory without waking the remote CPU or copying
   through the kernel network stack. NCCL, the library every distributed GPU framework
   uses underneath, runs its collectives over this RDMA path.

So the CX7 ports run **RoCE v2**, and the management Ethernet stays on its own separate
network. Mixing workload traffic and management traffic on the same wire would let SSH,
apt, and telemetry steal bandwidth from collectives, and would break the lossless
requirements RoCE depends on.

## 3. Two topologies

### 3.1 Two nodes: direct connect (no switch)

For exactly two nodes you do not need a switch. A single QSFP112 direct-attach copper
(DAC) cable joins one CX7 port on node A to one CX7 port on node B. This is the topology
NVIDIA documents as "Spark stacking."

```
   ┌──────────────┐                         ┌──────────────┐
   │   gb10-01    │   QSFP112 400G DAC      │   gb10-02    │
   │  CX7 port0 ──┼─────────────────────────┼── CX7 port0  │
   │  128 GB      │   200 Gb/s point-to-point│  128 GB      │
   └──────┬───────┘                         └──────┬───────┘
          │ mgmt (10GbE/WiFi)                      │ mgmt
          └───────────────── LAN ──────────────────┘
```

- Pooled memory: 256 GB.
- The link is a point-to-point RoCE fabric. NCCL runs all-reduce and all-gather straight
  across it. No switch means no PFC/ECN negotiation with a switch, though you still enable
  RoCE v2 and jumbo frames on both NICs.
- This is the lowest-latency, lowest-cost option and is the right default for two nodes.

Details and cabling: `topology/2-node-direct.md`, `docs/05-cabling-guide.md`.

### 3.2 N nodes: switched RoCE fabric

Beyond two nodes, every node connects to a shared 200G or 400G Ethernet switch that
supports RoCE (PFC and ECN). All CX7-facing ports on the switch are placed in one bridge,
forming a single flat layer-2 domain. Every node can then reach every other node's memory
at full rate.

```
   gb10-01   gb10-02   gb10-03   gb10-04
     │CX7      │CX7      │CX7      │CX7
     └────┐    └────┐    └────┐    └────┐
          ▼         ▼         ▼         ▼
     ┌─────────────────────────────────────┐
     │  200/400G RoCE switch                │
     │  single L2 bridge, PFC prio 3, ECN   │
     └─────────────────────────────────────┘
```

- Pooled memory scales linearly with node count.
- The switch must be lossless for the RoCE priority (PFC), with ECN enabled so congestion
  is signalled rather than dropped. A dropped RoCE packet triggers an expensive
  go-back-N retransmit and collapses throughput.
- With a 400G switch, one switch port feeds two nodes through a QSFP-DD to 2x200G QSFP56
  breakout DAC. With a 200G switch, each node takes its own QSFP56 DAC to its own port.

Details and cabling: `topology/n-node-switched.md`, `switch/configure-bridge.md`.

## 4. The software stack that consumes the fabric

The interconnect exists so that distributed frameworks can treat the cluster as one
machine. From the bottom up:

| Layer | Component | Role |
| --- | --- | --- |
| Transport | RoCE v2 over ConnectX-7 | RDMA read/write between node memories |
| Collectives | NCCL | all-reduce, all-gather, broadcast over RDMA |
| Inference | vLLM (tensor + pipeline parallel) | serve one large model split across nodes |
| Inference | llama.cpp RPC | pool memory of many nodes for GGUF models |
| Training | PyTorch DDP / FSDP via torchrun | data- and sharded-parallel training |
| Orchestration | Ansible, optional Ray | bring-up, config, multi-node job launch |

NCCL is the pivot: get NCCL running at line rate over the fabric (validated with
`nccl-tests` all_reduce_perf) and every framework above it inherits that performance.
The whole point of the RoCE tuning in `docs/04-roce-tuning.md` is to make NCCL fast.

## 5. Design decisions and trade-offs

- **RoCE v2 over InfiniBand.** The GB10 CX7 is wired and provisioned for Ethernet/RoCE on
  these systems, so the cluster uses RoCE v2. It needs a lossless Ethernet fabric (PFC +
  ECN); the cost is switch configuration care, the benefit is commodity Ethernet switches.
- **Flat layer-2 domain over routed layer-3.** A single L2 bridge keeps NCCL's peer
  discovery and GID handling simple and keeps latency minimal. For a single-rack cluster
  this is the right call. Multi-rack scale-out (routed RoCE, multiple leaf/spine switches)
  is out of scope here and would need per-hop PFC and a routed GID design.
- **Separate management network.** Non-negotiable. It protects fabric bandwidth and keeps
  the lossless domain clean. See `docs/03-network-design.md`.
- **Unified memory changes the parallelism math.** Because each node already has 128 GB
  coherent to the GPU, the cluster favors pipeline/tensor parallelism that shards a model
  across the 128 GB units, rather than fighting a small discrete VRAM budget per GPU.

Next: `docs/02-hardware-bom.md` for the exact parts, then `docs/03-network-design.md`.
