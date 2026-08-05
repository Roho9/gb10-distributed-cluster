# 03. Network Design

Two physically and logically separate networks:

1. **Management network**: onboard 1-10 GbE / WiFi. Carries SSH, apt, telemetry, and
   internet. Ordinary switch, ordinary L3, DHCP or static, whatever your site uses.
2. **RoCE fabric**: the ConnectX-7 QSFP112 ports. Carries only NCCL/RDMA workload traffic.
   Its own subnet, its own switch (or a direct cable), lossless, jumbo frames.

Keeping these apart is a hard requirement. If management traffic shares the CX7 wire it
steals collective bandwidth and pollutes the lossless domain that RoCE needs.

## Addressing plan

Use a dedicated, non-routable subnet for the fabric. Nothing on the fabric needs a
default gateway; it is a closed, flat layer-2 domain.

### Fabric subnet: `192.168.100.0/24`

| Host | Fabric IP (CX7) | Management IP | RDMA dev | Fabric netdev |
| --- | --- | --- | --- | --- |
| gb10-01 | 192.168.100.11 | from mgmt DHCP | mlx5_0 | enp1s0f0np0 |
| gb10-02 | 192.168.100.12 | from mgmt DHCP | mlx5_0 | enp1s0f0np0 |
| gb10-03 | 192.168.100.13 | from mgmt DHCP | mlx5_0 | enp1s0f0np0 |
| gb10-04 | 192.168.100.14 | from mgmt DHCP | mlx5_0 | enp1s0f0np0 |

Rules:

- Fabric IPs are **static**. No DHCP on the fabric.
- `/24` with no gateway. The nodes are all in one subnet and reach each other directly.
- The netdev and RDMA device names above are examples. Confirm each node's real names
  with `ibdev2netdev` and `ip -br link` (see `docs/02-hardware-bom.md`) and put the real
  values in `ansible/group_vars/all.yml` and your netplan file.
- Keep `/etc/hosts` on every node populated with the fabric names so NCCL and launch
  scripts can use `gb10-0x` names:

```
192.168.100.11  gb10-01
192.168.100.12  gb10-02
192.168.100.13  gb10-03
192.168.100.14  gb10-04
```

## MTU / jumbo frames

Set MTU to **9000** on every CX7 interface and on every switch port in the fabric bridge.
RoCE throughput drops sharply if the path MTU is inconsistent, and a single 1500-byte hop
caps the whole path. Verify end to end after configuration:

```bash
# from gb10-01, do-not-fragment ping at 8972 payload (9000 - 28 headers)
ping -M do -s 8972 -c 3 192.168.100.12
```

If that fails but a small ping succeeds, an interface or switch port is still at 1500.

## Routing

- **2-node direct connect**: no routing. The two fabric IPs are link-local neighbors on
  the point-to-point cable. Just the two static addresses and MTU 9000.
- **N-node switched**: still no L3 routing on the fabric. All nodes share
  `192.168.100.0/24` inside one switch bridge, so every pair is one L2 hop away. The switch
  does not route; it bridges. See `switch/configure-bridge.md`.
- **Internet / management routing** stays entirely on the management interface, which keeps
  its own default route. The fabric interface has no default route, so normal traffic never
  touches it.

Confirm the split after bring-up:

```bash
ip route            # default route should be via the MGMT interface only
ip route get 192.168.100.12   # fabric peer should resolve via the CX7 netdev
ip route get 8.8.8.8          # internet should resolve via the MGMT netdev
```

## RoCE addressing detail: GID index

RoCE v2 uses a RoCEv2 GID tied to the fabric IP. NCCL must be told which GID index to use
(`NCCL_IB_GID_INDEX`), otherwise it may pick a RoCEv1 or link-local GID and fail or run
slow. Discover the RoCEv2 IPv4 GID index on each node:

```bash
show_gids            # look for the row: version v2, your 192.168.100.x, note the Index
# if show_gids is unavailable:
for i in $(seq 0 7); do
  echo -n "index $i: "; cat /sys/class/infiniband/mlx5_0/ports/1/gids/$i
done
# and check /sys/class/infiniband/mlx5_0/ports/1/gid_attrs/types/$i for "RoCE v2"
```

The RoCEv2 IPv4 GID index is commonly 3 on these NICs, but confirm it. Put the value in
`ansible/group_vars/all.yml` as `nccl_ib_gid_index`.

## Firewall

RDMA does not pass through iptables the way TCP does, but NCCL's bootstrap and the
frameworks' control planes use TCP over the fabric interface. Either leave the fabric
interface out of any restrictive firewall zone (it is a private, closed subnet) or open
the port ranges the frameworks use (NCCL bootstrap, torchrun rendezvous, vLLM/Ray ports).
The simplest correct choice for a closed lab fabric is to trust the fabric subnet.

Next: `docs/04-roce-tuning.md`.
