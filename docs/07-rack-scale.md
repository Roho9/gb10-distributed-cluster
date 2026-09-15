# 07. Rack-Scale: 8 to 16 Nodes on One Switch

The 2-node and small-N designs in `docs/01-architecture.md` scale directly to a single
rack of 8 to 16 GB10 nodes on one RoCE switch. This document covers what changes at that
size: port planning, dual-port CX7 bonding, rank placement, and the deeper PFC/ECN and
DCQCN tuning that matters once many nodes share buffers.

## 1. Port and switch planning

Two node-facing cabling styles (see `docs/05-cabling-guide.md`):

| Switch | Per-node wiring | Nodes per switch port | 16 nodes needs |
| --- | --- | --- | --- |
| 400G, QSFP-DD | QSFP-DD to 2x200G breakout | 2 | 8 switch ports |
| 200G, QSFP56 | one QSFP56 DAC per node | 1 | 16 switch ports |
| 400G + bonding | two QSFP-DD breakout legs per node | 1 (both node ports used) | 16 legs, 8 ports |

Rules at this size:

- Keep all node-facing ports in **one bridge** (one flat L2 domain). Do not split into
  multiple VLANs; NCCL wants every rank one L2 hop from every other.
- Reserve at least one management port on a separate switch per node. Never fold management
  into the RoCE bridge.
- Leave 1 to 2 spare fabric ports for a replacement node or a diagnostics laptop with a
  CX-class NIC.

## 2. Using both CX7 ports: bonding

Each GB10 node has two QSFP112 ports. At rack scale you can put both to work in an LACP
bond for more aggregate bandwidth and link redundancy. This is optional; a single-port
fabric is fully functional.

### When to bond

- Bond if collective bandwidth is your bottleneck and the switch has the ports. A bond of
  the two 200 Gb/s ports gives up to ~400 Gb/s aggregate per node.
- Do not bond if you are port-constrained on the switch; one port per node to more nodes is
  usually the better use of ports.

### NIC side (netplan)

Use `netplan/node-bonded.yaml`: an 802.3ad (LACP) bond over both CX7 netdevs, MTU 9000,
the fabric IP on the bond. Hash policy `layer3+4` spreads flows across both members.

```yaml
bonds:
  bond-fabric:
    interfaces: [enp1s0f0np0, enp1s0f1np1]
    parameters:
      mode: 802.3ad
      lacp-rate: fast
      transmit-hash-policy: layer3+4
      mii-monitor-interval: 100
    addresses: [192.168.100.11/24]
    mtu: 9000
```

### Switch side

Create one LACP link-aggregation group (LAG / port-channel / bond) per node from its two
ports, put the LAG in the fabric bridge, and set MTU 9000 and PFC priority 3 on the LAG.
The NIC `transmit-hash-policy` and the switch hash policy should both key on L3+L4 so a
single node-to-node pair can use both members.

### NCCL with a bond

Point NCCL at both RDMA devices so it can use both rails:

```
NCCL_IB_HCA=mlx5_0,mlx5_1
NCCL_SOCKET_IFNAME=bond-fabric
```

Re-run `scripts/run-nccl-test.sh` after bonding and confirm busbw rose. If it did not, the
hash policy is collapsing traffic onto one member, or one member is not in the LAG.

## 3. Rank placement

At 8 to 16 nodes the mapping of ranks to nodes starts to matter for collective performance.

- **One GPU per GB10 node**, so global rank == node index in the simplest case. Keep the
  rank order the same as physical/switch-port order so ring and tree collectives follow the
  cabling rather than crossing the switch back and forth needlessly.
- For pipeline parallelism (vLLM), order the pipeline stages along the rank order so
  stage-to-stage activation traffic stays between adjacent ranks.
- Set `NCCL_ALGO` only if a sweep shows a win. On a single non-blocking switch, NCCL's
  default ring/tree selection is usually right. Measure with `benchmarks/nccl-sweep.sh`
  before pinning an algorithm.

## 4. PFC / ECN / DCQCN tuning at scale

With 2 nodes a single dropped packet is rare; with 16 nodes doing all-reduce, many senders
converge on the switch and congestion is constant, so the lossless and congestion-control
config has to be right or throughput collapses.

Targets:

- **PFC on priority 3 only**, on every node LAG/port and the matching NIC priority. Confirm
  PFC counters increment under load but do not dominate: sustained heavy PFC pause means the
  switch buffers are too small or ECN is not slowing senders.
- **ECN / DCQCN on**: the switch must ECN-mark on the RoCE queue before buffers fill.
  Set the WRED/ECN minimum threshold low enough that marking starts early and PFC is the
  last resort, not the first.
- **Headroom buffers**: ensure per-port PFC headroom accounts for the cable length and MTU
  9000 so a pause frame arrives before the buffer overruns. Vendor defaults for 200/400G
  DAC at these lengths are usually adequate; confirm no ingress drops on the fabric queue.
- **DCQCN parameters** (rate increase/decrease, alpha update) are firmware defaults on the
  CX7 and rarely need changing at single-rack scale. Change them only with before/after
  benchmark evidence.

How to tell it is working (`observability/`):

- `fabric-watch.sh` shows PFC pause counters rising modestly under load, not exploding.
- ECN-marked packet counters increment (senders are being told to slow down).
- No ingress/egress discards on the fabric queue.
- `benchmarks/nccl-sweep.sh` busbw stays high (within ~10 to 15% of the 2-node figure) as
  node count grows. A cliff as you add nodes points straight at PFC/ECN.

## 5. Bring-up order at rack scale

1. Cable all nodes and, if bonding, form the LAGs first.
2. Configure the switch bridge, LAGs, MTU 9000, PFC, ECN (`switch/configure-bridge.md`).
3. `ansible-playbook -i inventory.ini site.yml` across all 8 to 16 nodes.
4. Validate pairwise first (`scripts/validate-fabric.sh` between a few pairs), then run the
   full-cluster NCCL sweep (`benchmarks/nccl-sweep.sh`).
5. Stand up observability (`observability/`) before the first big job so you can see PFC/ECN
   behavior under real load.

## 6. What is still out of scope

Multiple switches (leaf-spine), routed RoCE across racks, and per-hop PFC across a spine are
a separate, larger design. Everything here assumes one non-blocking switch and one L2
domain. If you outgrow a single switch, that is the point to design a routed RoCE fabric,
which this repository does not yet cover.
