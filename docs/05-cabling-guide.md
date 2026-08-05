# 05. Cabling Guide

Physical wiring for each topology. Match this to the BOM in `docs/02-hardware-bom.md`.

## The two networks, kept apart

Every node has two independent sets of ports:

- **CX7 QSFP112 ports** (two per node): the RoCE fabric. High-speed workload traffic only.
- **Management RJ45 / WiFi**: SSH, apt, telemetry, internet. Ordinary cabling.

Never bridge these two. They stay physically separate all the way to separate switches.

## Case A: two nodes, direct connect

```
   gb10-01                                   gb10-02
   ┌─────────────┐                           ┌─────────────┐
   │  CX7 port0 ●─┼───── QSFP112 400G DAC ────┼─● CX7 port0 │
   │  CX7 port1 ○ │       0.5 m passive       │  CX7 port1 ○│
   │  mgmt RJ45 ●─┼──┐                     ┌──┼─● mgmt RJ45  │
   └─────────────┘  │                     │  └─────────────┘
                    └──── mgmt switch ─────┘
```

1. Insert one QSFP112 400G passive DAC (0.5 m; Amphenol NJAAKK0006 or Luxshare
   LMTQF022-SD-R) into `CX7 port0` on gb10-01 and `CX7 port0` on gb10-02.
2. Push each connector until it clicks; the pull-tab should latch. A loose QSFP is the most
   common cause of a link that trains at the wrong rate or not at all.
3. Cable each node's management RJ45 to the ordinary management switch.
4. Leave `CX7 port1` unused (or use it later for a second link / bonding).

Verify: `ip -br link` on both nodes shows the port0 netdev `UP`; `ibv_devinfo` shows the
port `PhysState: LinkUp` and `State: ACTIVE`.

## Case B: N nodes, switched fabric

### B1: 400G switch with breakout (two nodes per switch port)

```
                    ┌──────── 400G RoCE switch ────────┐
                    │  swp1        swp2        swp3     │
                    └───┬───────────┬───────────┬───────┘
       QSFP-DD 400G ────┘           │           └──── QSFP-DD 400G
       to 2x QSFP56 200G            │            to 2x QSFP56 200G
        ┌──────┴──────┐             │             ┌──────┴──────┐
        ▼             ▼             ▼             ▼             ▼
     gb10-01       gb10-02      (swp2 ...)     gb10-05       gb10-06
     CX7 p0        CX7 p0                      CX7 p0        CX7 p0
```

1. Plug the QSFP-DD (400G) end of a breakout DAC into a switch port.
2. Plug the two QSFP56 (200G) legs into `CX7 port0` of two different nodes.
3. Repeat for each pair of nodes.
4. Put every switch port that has a node behind it into the fabric bridge, MTU 9000, PFC
   priority 3 (`switch/configure-bridge.md`).

### B2: 200G switch (one node per switch port)

```
   gb10-01   gb10-02   gb10-03   gb10-04
   CX7 p0    CX7 p0    CX7 p0    CX7 p0
     │         │         │         │
   QSFP56    QSFP56    QSFP56    QSFP56   (one 200G DAC each)
     ▼         ▼         ▼         ▼
   ┌───────────────────────────────────┐
   │  swp1   swp2   swp3   swp4  ...    │  200G RoCE switch
   └───────────────────────────────────┘
```

1. Run one QSFP56 200G DAC from each node's `CX7 port0` to its own switch port.
2. Add all those switch ports to the fabric bridge, MTU 9000, PFC priority 3.

Management cabling is identical for B1 and B2: one RJ45 per node to the separate
management switch.

## Labeling and discipline

- Label both ends of every fabric cable with the node and port (`gb10-03:p0 <-> sw:swp5`).
  When a link flaps at 3 a.m. you will want this.
- Keep fabric DAC runs short and unstrained. Do not exceed passive DAC reach; if a run is
  too long, use AOC or optics rather than forcing copper.
- After any recabling, re-run `scripts/validate-fabric.sh`. A reseated cable can renegotiate
  at a lower rate silently.

## Optional: second link per node

Each node has a second CX7 port. You can cable `CX7 port1` as well and either:

- **Bond** the two ports for higher aggregate bandwidth and redundancy (LACP on the switch
  side; requires matching bond config on the NIC), or
- Keep it as a **standby** link.

This is an enhancement, not required for a working cluster. If you bond, update
`NCCL_IB_HCA` to include both devices and re-validate.

Next: `docs/06-operations.md`.
