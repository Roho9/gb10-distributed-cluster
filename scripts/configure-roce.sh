#!/usr/bin/env bash
# Configure RoCE v2 on THIS node's ConnectX-7: RoCE mode v2, PFC on priority 3,
# DSCP-based traffic class, ECN/DCQCN, jumbo MTU. Idempotent, defensive: if a given
# knob is not present on this OFED/DOCA version it warns and continues rather than
# aborting. Run with sudo. For a fleet, prefer the Ansible roce role.
#
# Usage:
#   sudo ./configure-roce.sh <rdma-dev> <iface> [pfc-priority] [dscp]
#   sudo ./configure-roce.sh mlx5_0 enp1s0f0np0 3 26
set -euo pipefail

RDMA_DEV="${1:-${RDMA_DEV:-mlx5_0}}"
IFACE="${2:-${IFACE:-}}"
PRIO="${3:-3}"
DSCP="${4:-26}"

if [[ -z "$IFACE" ]]; then
  echo "usage: sudo $0 <rdma-dev> <iface> [pfc-priority] [dscp]" >&2
  echo "example: sudo $0 mlx5_0 enp1s0f0np0 3 26" >&2
  exit 2
fi
if [[ $EUID -ne 0 ]]; then echo "must run as root (use sudo)" >&2; exit 1; fi

warn() { echo "[roce][warn] $*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# TC value carried by NCCL_IB_TC and the NIC traffic_class: DSCP<<2 (26<<2 = 104..106 range)
TC_VALUE=$(( DSCP << 2 ))

echo "[roce] device=$RDMA_DEV iface=$IFACE priority=$PRIO dscp=$DSCP tc=$TC_VALUE"

# 1. RoCE mode v2 on port 1
if have cma_roce_mode; then
  cma_roce_mode -d "$RDMA_DEV" -p 1 -m 2 || warn "cma_roce_mode failed"
  echo "[roce] set RoCE mode v2"
else
  warn "cma_roce_mode not found; ensure RoCE v2 is the default for $RDMA_DEV"
fi

# 2. Trust DSCP and enable PFC on the chosen priority only
if have mlnx_qos; then
  # build a pfc mask like 0,0,0,1,0,0,0,0 with a 1 at position $PRIO
  PFC_MASK=$(python3 - "$PRIO" <<'PY' 2>/dev/null || true
import sys
p=int(sys.argv[1]); print(",".join("1" if i==p else "0" for i in range(8)))
PY
)
  [[ -z "$PFC_MASK" ]] && PFC_MASK="0,0,0,1,0,0,0,0"
  mlnx_qos -i "$IFACE" --trust dscp || warn "mlnx_qos --trust dscp failed"
  mlnx_qos -i "$IFACE" --pfc "$PFC_MASK" || warn "mlnx_qos --pfc failed"
  echo "[roce] trust=dscp pfc=$PFC_MASK"
else
  warn "mlnx_qos not found; cannot set trust/PFC (install MLNX_OFED userspace)"
fi

# 3. Traffic class mapping on the RDMA port (DSCP -> priority for RoCE QPs)
TC_PATH="/sys/class/infiniband/${RDMA_DEV}/tc/1/traffic_class"
if [[ -w "$TC_PATH" ]]; then
  echo "$TC_VALUE" > "$TC_PATH" && echo "[roce] traffic_class=$TC_VALUE"
else
  warn "no writable $TC_PATH; NCCL_IB_TC=$TC_VALUE still applies at the app layer"
fi

# 4. ECN / DCQCN on the RoCE priority (paths vary by version; try the common ones)
enable_ecn() {
  local base="/sys/class/net/${IFACE}/ecn"
  local set_any=0
  for role in roce_np roce_rp; do
    local f="${base}/${role}/enable/${PRIO}"
    if [[ -w "$f" ]]; then echo 1 > "$f" && set_any=1; fi
  done
  if [[ $set_any -eq 1 ]]; then echo "[roce] ECN enabled on priority $PRIO"; \
    else warn "ECN sysfs knobs not found under $base; enable DCQCN per your OFED docs"; fi
}
enable_ecn

# 5. Jumbo MTU (belt-and-suspenders; interfaces script also sets this)
ip link set "$IFACE" mtu 9000 || warn "could not set MTU 9000 on $IFACE"
echo "[roce] MTU set to 9000 on $IFACE"

echo "[roce] done. Verify with: mlnx_qos -i $IFACE ; show_gids ; ibv_devinfo -d $RDMA_DEV"
