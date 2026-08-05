#!/usr/bin/env bash
# Configure the CX7 fabric interface on THIS node: static IP, MTU 9000, /etc/hosts.
# Idempotent. Run with sudo. For a fleet, prefer the Ansible network role.
#
# Usage:
#   sudo ./configure-interfaces.sh <iface> <fabric-ip/cidr>
#   sudo ./configure-interfaces.sh enp1s0f0np0 192.168.100.11/24
#
# If args are omitted, the script reads IFACE and FABRIC_CIDR from the environment.
set -euo pipefail

IFACE="${1:-${IFACE:-}}"
FABRIC_CIDR="${2:-${FABRIC_CIDR:-}}"

if [[ -z "$IFACE" || -z "$FABRIC_CIDR" ]]; then
  echo "usage: sudo $0 <iface> <fabric-ip/cidr>" >&2
  echo "example: sudo $0 enp1s0f0np0 192.168.100.11/24" >&2
  exit 2
fi

if [[ $EUID -ne 0 ]]; then
  echo "must run as root (use sudo)" >&2
  exit 1
fi

if ! ip link show "$IFACE" >/dev/null 2>&1; then
  echo "interface '$IFACE' not found. Run 'ibdev2netdev' to find your CX7 netdev." >&2
  exit 1
fi

echo "[interfaces] configuring $IFACE -> $FABRIC_CIDR, MTU 9000"

# Apply live so it works immediately, and persist via netplan so it survives reboot.
ip addr flush dev "$IFACE" || true
ip addr add "$FABRIC_CIDR" dev "$IFACE"
ip link set "$IFACE" mtu 9000 up

NETPLAN_FILE="/etc/netplan/60-fabric.yaml"
echo "[interfaces] writing $NETPLAN_FILE"
cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${IFACE}:
      dhcp4: no
      dhcp6: no
      addresses:
        - ${FABRIC_CIDR}
      mtu: 9000
EOF
chmod 600 "$NETPLAN_FILE"
netplan apply

echo "[interfaces] done. Current state:"
ip -br addr show "$IFACE"
echo "[interfaces] reminder: ensure /etc/hosts has all fabric names (gb10-0x)."
