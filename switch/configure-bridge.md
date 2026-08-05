# Switch Configuration: Bridge / L2 Domain for the RoCE Fabric

For the N-node switched topology. The switch must do three things:

1. Put every node-facing port into **one bridge** (a single flat layer-2 domain).
2. Be **lossless** for the RoCE priority: **PFC on priority 3**, plus **ECN**.
3. Use **MTU 9000** (jumbo frames) on every fabric port.

The 2-node direct-connect topology has no switch; skip this file.

## Vendor-neutral checklist

Whatever switch you use, confirm all of these before validating the fabric:

- [ ] All ports with a GB10 node behind them are members of the same bridge / VLAN.
- [ ] Bridge / those ports set to MTU 9000.
- [ ] PFC enabled on priority 3 (802.1Qbb) on those ports.
- [ ] The DSCP-to-priority map sends DSCP 26 to priority 3, matching the NIC
      (`docs/04-roce-tuning.md`).
- [ ] ECN (WRED/ECN marking) enabled on the fabric queues so congestion is marked,
      not dropped.
- [ ] No routing / no default gateway on this domain. The switch bridges only.
- [ ] Management traffic is NOT on this switch. It has its own switch.

## Worked example: MikroTik CRS-class (RouterOS)

A MikroTik CRS812 (QSFP-DD) is a common, affordable RoCE-capable switch for GB10 clusters.
This is illustrative; adapt port names to your unit. Review each line before applying.

```rsc
# 1. Create the fabric bridge and disable L2 learning surprises we do not want
/interface bridge
add name=fabric vlan-filtering=no protocol-mode=none

# 2. Set jumbo MTU on the physical fabric ports (adjust qsfp names to your ports)
/interface ethernet
set [ find default-name=qsfp28-1-1 ] l2mtu=9200 mtu=9000
set [ find default-name=qsfp28-2-1 ] l2mtu=9200 mtu=9000
set [ find default-name=qsfp28-3-1 ] l2mtu=9200 mtu=9000
set [ find default-name=qsfp28-4-1 ] l2mtu=9200 mtu=9000

# 3. Add every node-facing port to the bridge (one flat L2 domain)
/interface bridge port
add bridge=fabric interface=qsfp28-1-1
add bridge=fabric interface=qsfp28-2-1
add bridge=fabric interface=qsfp28-3-1
add bridge=fabric interface=qsfp28-4-1

# 4. Enable PFC on priority 3 for the fabric ports.
#    On RouterOS this is the switch QoS / flow-control area; on switchdev-based
#    or Cumulus/SONiC switches you configure PFC in the DCB stack instead
#    (see the notes below). Confirm PFC is active per your firmware.
```

Note: RouterOS PFC/DCB support varies by model and version. If your unit does not expose
PFC/ECN, it is not suitable as a lossless RoCE switch, and you will see throughput collapse
under load even though links come up. Prefer a switch with documented RoCE / DCB support.

## Worked example: Cumulus Linux / SONiC (switchdev DCB)

On a Spectrum-based switch running Cumulus or SONiC, PFC and ECN are configured through the
DCB stack. Sketch (adapt to NVUE / config_db):

```bash
# Bridge: put swp1..swpN in one VLAN-unaware bridge
# PFC: enable on priority 3 (lossless), egress ECN/RED on the same queue
# Trust: map DSCP -> switch-priority so DSCP 26 lands on the lossless priority
# MTU: 9216 (jumbo) on all fabric ports
```

The specifics differ by NOS, but the intent is exactly the vendor-neutral checklist above:
one bridge, MTU 9000, PFC prio 3, ECN, DSCP 26 -> prio 3.

## Verifying from the nodes

After configuring the switch, prove it from the hosts, not just the switch CLI:

```bash
# jumbo frames end to end through the switch
ping -M do -s 8972 -c 3 192.168.100.12
# RDMA bandwidth through the switch should still be near line rate
./scripts/validate-fabric.sh
```

If jumbo ping fails, a switch port is still at 1500. If bandwidth collapses under the NCCL
test but ib_write_bw is fine on an idle fabric, PFC/ECN is not actually working on the
switch.
