# Topology: 2-Node Direct Connect

The simplest and lowest-latency cluster. Two GB10 nodes joined by one cable, no switch.
Pooled memory: 256 GB.

```
        ┌──────────────────────────┐          ┌──────────────────────────┐
        │        gb10-01           │          │        gb10-02           │
        │  GB10 Grace Blackwell    │          │  GB10 Grace Blackwell    │
        │  128 GB unified memory   │          │  128 GB unified memory   │
        │                          │          │                          │
        │  CX7 port0 (mlx5_0) ●────┼──────────┼────● CX7 port0 (mlx5_0)  │
        │  192.168.100.11/24       │  200 Gb/s│    192.168.100.12/24     │
        │  MTU 9000, RoCE v2       │  QSFP112 │    MTU 9000, RoCE v2     │
        │                          │  400G DAC│                          │
        │  mgmt (10GbE) ●──────────┼───┐  ┌───┼──────────● mgmt (10GbE)  │
        └──────────────────────────┘   │  │   └──────────────────────────┘
                                   ┌────┴──┴────┐
                                   │ mgmt switch│  (SSH, apt, internet)
                                   └────────────┘
```

## Facts

- Interconnect: one QSFP112 400G passive DAC, 0.5 m (Amphenol NJAAKK0006 / Luxshare
  LMTQF022-SD-R), `CX7 port0` to `CX7 port0`.
- Transport: point-to-point RoCE v2. No switch, so no switch-side PFC to configure; NIC is
  still set to RoCE v2 + jumbo frames.
- Fabric subnet: `192.168.100.0/24`, static, no gateway.
- Management: separate 10 GbE to a separate switch.

## Bring-up

1. Cable per `docs/05-cabling-guide.md`, Case A.
2. `sudo ./scripts/configure-interfaces.sh` and `sudo ./scripts/configure-roce.sh` on both,
   or `ansible-playbook -i inventory.ini site.yml`.
3. Validate: `./scripts/validate-fabric.sh` then
   `./scripts/run-nccl-test.sh gb10-01,gb10-02`.

## What runs well here

- A single large model that needs more than 128 GB but fits in 256 GB, served with vLLM
  pipeline parallelism across the two nodes (`workloads/vllm`).
- llama.cpp RPC pooling both nodes' memory for a large GGUF model (`workloads/llama-cpp-rpc`).
- 2-way distributed training / fine-tuning (`workloads/pytorch-ddp`).
