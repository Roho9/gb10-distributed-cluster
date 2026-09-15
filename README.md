# GB10 Distributed Compute Cluster

A complete reference architecture and deployment toolkit for building a distributed
compute cluster from multiple NVIDIA GB10 (Grace Blackwell) systems, such as the
NVIDIA DGX Spark. It covers routing, network switching, cabling, and the RoCE/NCCL
interconnect required to pool VRAM across nodes and run distributed inference and
training workloads.

Each GB10 node carries 128 GB of coherent LPDDR5x unified memory. By linking nodes
over the built-in NVIDIA ConnectX-7 fabric at 200 Gb/s per link, the cluster presents
a single pooled memory space large enough to hold models that do not fit on one node
(for example a 405B-parameter model across a two-node pair), and to scale data-parallel
and pipeline-parallel jobs across many nodes.

## What this repository gives you

- A validated **reference architecture** for both a 2-node direct-connect pair and an
  N-node switched RoCE fabric (`docs/01-architecture.md`).
- A concrete **bill of materials and cabling plan** with the exact QSFP cable specs
  NVIDIA calls out for GB10 stacking (`docs/02-hardware-bom.md`, `docs/05-cabling-guide.md`).
- A **network design**: IP addressing, the single layer-2 bridge domain, management/fabric
  separation, and routing (`docs/03-network-design.md`).
- **RoCE v2 tuning**: PFC, ECN, jumbo frames, and the NCCL environment that gets you close
  to line rate (`docs/04-roce-tuning.md`).
- **Automation**: an Ansible project and standalone shell scripts to configure interfaces,
  RoCE, and NCCL, then validate the fabric end to end (`ansible/`, `scripts/`).
- **Switch configuration** for the bridge/L2 domain, with a worked MikroTik example
  (`switch/`).
- Runnable **pooled-VRAM workloads**: vLLM tensor/pipeline parallel serving, llama.cpp RPC
  pooled-memory inference, and PyTorch distributed training (`workloads/`).

## Cluster at a glance

```
                 Management / internet (1-10 GbE, WiFi)
        ┌───────────────┬───────────────┬───────────────┐
        │               │               │               │
   ┌────┴────┐     ┌────┴────┐     ┌────┴────┐     ┌────┴────┐
   │ gb10-01 │     │ gb10-02 │     │ gb10-03 │     │ gb10-04 │
   │ GB10    │     │ GB10    │     │ GB10    │     │ GB10    │
   │ 128 GB  │     │ 128 GB  │     │ 128 GB  │     │ 128 GB  │
   └──┬───┬──┘     └──┬───┬──┘     └──┬───┬──┘     └──┬───┬──┘
      │CX7│           │CX7│           │CX7│           │CX7│    200 Gb/s RoCE
      └─┬─┘           └─┬─┘           └─┬─┘           └─┬─┘
        └───────────────┴──────┬────────┴───────────────┘
                         ┌──────┴───────┐
                         │ 200/400G     │   single L2 bridge domain
                         │ RoCE switch  │   (lossless, PFC + ECN)
                         └──────────────┘
```

For exactly two nodes, drop the switch and use one QSFP112 direct-attach cable between
the two CX7 ports. See `topology/2-node-direct.md`.

## Quickstart

The end-to-end path is documented in `docs/06-operations.md`. In short:

```bash
# 1. Fill in your node addresses and CX7 interface names
cp ansible/inventory.example.ini ansible/inventory.ini
$EDITOR ansible/inventory.ini ansible/group_vars/all.yml

# 2. Configure interfaces, RoCE, and NCCL on every node
cd ansible && ansible-playbook -i inventory.ini site.yml

# 3. Validate the fabric (link, RDMA bandwidth, NCCL all-reduce)
./scripts/validate-fabric.sh
./scripts/run-nccl-test.sh

# 4. Launch a pooled-VRAM workload
make serve-vllm        # or: make llama-rpc / make train-ddp
```

If you are not using Ansible, the `scripts/` directory contains standalone equivalents
you can run node by node.

## Hardware assumptions

| Item | Assumption |
| --- | --- |
| Node | NVIDIA GB10 Grace Blackwell system (DGX Spark class) |
| Per-node memory | 128 GB coherent LPDDR5x unified memory |
| High-speed NIC | Onboard NVIDIA ConnectX-7, two QSFP112 ports |
| Per-link rate | 200 Gb/s (2x PCIe Gen5 x4 to the SoC, ~185-190 Gb/s realized over RoCE) |
| OS | NVIDIA DGX OS / Ubuntu-based aarch64 with MLNX_OFED / DOCA drivers |
| Management net | Onboard 10 GbE and/or WiFi, kept separate from the CX7 fabric |

See `docs/02-hardware-bom.md` for the full list including switches and cables.

## Repository layout

```
docs/           Architecture, BOM, network design, RoCE tuning, cabling, operations, rack-scale
topology/       Wiring diagrams for the 2-node and N-node cases
ansible/        Playbook + roles: network, roce, nccl
scripts/        Standalone configuration and validation scripts
switch/         Switch bridge / L2 domain configuration
workloads/      vLLM, llama.cpp RPC, and PyTorch DDP pooled-VRAM examples
netplan/        Example netplan configs for direct, switched, and bonded topologies
observability/  Live fabric counters, Prometheus RoCE collector, Grafana dashboard
orchestration/  Slurm and Kubernetes job submission over the fabric
benchmarks/     NCCL scaling sweep, train/serve benches, results aggregator + chart
tests/          pytest suite (pfc_mask, config invariants); CI in .github/workflows
```

## Scaling to a rack (8 to 16 nodes)

The 2-node and small-N designs scale straight to a single rack on one RoCE switch.
`docs/07-rack-scale.md` covers port planning, using both ConnectX-7 ports in an LACP bond
(`netplan/node-bonded.yaml`), rank placement, and the deeper PFC/ECN/DCQCN tuning that
matters once many nodes share switch buffers. Multi-rack leaf-spine (routed RoCE) is
deliberately out of scope.

## Observability, orchestration, benchmarks, tests

- **Observability** (`observability/`): `fabric-watch.sh` prints live RDMA/PFC/ECN counters
  during a job; a Prometheus RoCE textfile collector plus a Grafana dashboard give the
  continuous view. The failure mode at scale is silent throughput collapse from PFC/ECN, and
  these make it visible.
- **Orchestration** (`orchestration/`): submit jobs instead of hand-launching per node.
  Slurm (`sbatch` for DDP and vLLM) or Kubernetes (RDMA device plugin + multi-node manifests).
- **Benchmarks** (`benchmarks/`): `nccl-sweep.sh` measures collective bandwidth as node count
  grows; `aggregate.py` emits a table and a scaling chart. Plus train and serve benches.
- **Tests / CI** (`tests/`, `.github/workflows/ci.yml`): pytest for the trickiest templating
  and config invariants, plus shellcheck, yamllint, ansible-lint, and a markdown link check.

## Scope and honesty note

This repository is the design, configuration, and automation layer for the cluster. It
cannot physically rack, cable, or power hardware for you. Every command that touches a
NIC, switch, or driver is written so you can review it before running it, and the
validation scripts are there to confirm each layer works before you move to the next.
Interface names, GID indexes, and driver package names vary by firmware and OS image,
so the configs use variables and each doc says how to discover the correct value on your
units with `ibdev2netdev`, `ip link`, and `show_gids`.

## License

MIT. See `LICENSE`.
