# Topology: N-Node Switched RoCE Fabric

Scale past two nodes. Every node connects to one shared RoCE switch; all node-facing ports
sit in a single layer-2 bridge, so every node reaches every other at full 200 Gb/s.
Pooled memory: 128 GB x N.

```
   gb10-01        gb10-02        gb10-03        gb10-04
   192.168.100.11 192.168.100.12 192.168.100.13 192.168.100.14
   CX7 p0         CX7 p0         CX7 p0         CX7 p0
   MTU 9000       MTU 9000       MTU 9000       MTU 9000
     │              │              │              │
     │  200 Gb/s    │              │              │   RoCE v2, DSCP 26 / prio 3
     ▼              ▼              ▼              ▼
   ┌────────────────────────────────────────────────────┐
   │  RoCE switch                                        │
   │  bridge "fabric": swp1..swp4                        │
   │  MTU 9000, PFC on priority 3, ECN/DCQCN on          │
   │  single flat L2 domain, no routing                  │
   └────────────────────────────────────────────────────┘

   Management (separate): each node's 10GbE -> ordinary mgmt switch -> internet
```

## Facts

- Switch must support RoCE: PFC (802.1Qbb) and ECN. It bridges, it does not route.
- All node-facing ports go into one bridge (`switch/configure-bridge.md`), MTU 9000, PFC on
  priority 3, matching the NIC DSCP-to-priority mapping.
- Cabling per `docs/05-cabling-guide.md`: 400G switch uses QSFP-DD to 2x200G breakout
  (two nodes per switch port); 200G switch uses one QSFP56 DAC per node.
- Fabric subnet `192.168.100.0/24`, static, no gateway. Add one host line per node.
- Management stays on a separate switch and interface.

## Scaling notes

- A 400G switch with breakout supports 2 nodes per switch port, so an M-port switch reaches
  up to 2M nodes in one bridge.
- Everything in this repo assumes a single-switch, single-rack, flat L2 fabric. Multi-switch
  leaf/spine with routed RoCE is a larger design (per-hop PFC, routed GID handling) and is
  intentionally out of scope.

## Bring-up

1. Cable and configure the switch bridge (`switch/configure-bridge.md`).
2. `ansible-playbook -i inventory.ini site.yml` across all nodes.
3. Validate pairwise, then run a multi-node NCCL test:
   `./scripts/run-nccl-test.sh gb10-01,gb10-02,gb10-03,gb10-04`.

## What runs well here

- One very large model sharded with vLLM tensor + pipeline parallelism across all N nodes.
- Data-parallel / FSDP training across N nodes with torchrun (`workloads/pytorch-ddp`).
- llama.cpp RPC with N backends pooling 128 GB x N of memory.
