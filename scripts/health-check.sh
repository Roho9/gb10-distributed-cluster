#!/usr/bin/env bash
# Per-node health check. Read-only: it inspects, it does not change anything.
# Confirms driver presence, link state, MTU, RoCEv2 GID, and NCCL env before you
# try to run workloads. Run on each node (no sudo needed for most checks).
#
# Usage: ./health-check.sh [rdma-dev] [iface]
set -uo pipefail

RDMA_DEV="${1:-${RDMA_DEV:-mlx5_0}}"
IFACE="${2:-${IFACE:-}}"

pass() { echo "  [ok]   $*"; }
fail() { echo "  [FAIL] $*"; RC=1; }
info() { echo "  [info] $*"; }
RC=0

echo "== GB10 node health check =="
echo "host: $(hostname)   rdma-dev: $RDMA_DEV   iface: ${IFACE:-<auto>}"

# Auto-discover the fabric netdev from the RDMA device if not supplied
if [[ -z "$IFACE" ]] && command -v ibdev2netdev >/dev/null 2>&1; then
  IFACE=$(ibdev2netdev 2>/dev/null | awk -v d="$RDMA_DEV" '$1==d {print $5; exit}')
  info "auto-detected fabric netdev: ${IFACE:-<none>}"
fi

echo "-- drivers / tools --"
for t in ibv_devinfo ibdev2netdev; do
  command -v "$t" >/dev/null 2>&1 && pass "$t present" || fail "$t missing (install MLNX_OFED/DOCA)"
done

echo "-- RDMA device / link --"
if command -v ibv_devinfo >/dev/null 2>&1; then
  STATE=$(ibv_devinfo -d "$RDMA_DEV" 2>/dev/null | awk '/state:/{print $2; exit}')
  PHYS=$(ibv_devinfo -d "$RDMA_DEV" 2>/dev/null | awk '/phys_state:/{print $2; exit}')
  [[ "$STATE" == "PORT_ACTIVE" ]] && pass "port state ACTIVE" || fail "port state=${STATE:-unknown} (want PORT_ACTIVE)"
  info "phys_state=${PHYS:-unknown}"
fi

echo "-- netdev / MTU --"
if [[ -n "$IFACE" ]] && ip link show "$IFACE" >/dev/null 2>&1; then
  OPER=$(cat /sys/class/net/"$IFACE"/operstate 2>/dev/null)
  MTU=$(cat /sys/class/net/"$IFACE"/mtu 2>/dev/null)
  [[ "$OPER" == "up" ]] && pass "$IFACE is up" || fail "$IFACE operstate=$OPER"
  [[ "$MTU" == "9000" ]] && pass "MTU 9000" || fail "MTU=$MTU (want 9000 jumbo)"
else
  fail "fabric netdev not found (pass it as arg 2 or fix ibdev2netdev)"
fi

echo "-- RoCEv2 GID --"
if command -v show_gids >/dev/null 2>&1; then
  show_gids "$RDMA_DEV" 2>/dev/null | grep -i "v2" | grep -v "::" | head -4 \
    && pass "RoCEv2 GID(s) listed above (use the IPv4 one's Index for NCCL_IB_GID_INDEX)" \
    || info "no v2 GID rows shown; check show_gids output manually"
else
  info "show_gids not found; derive GID index from /sys/class/infiniband/$RDMA_DEV/ports/1/gids"
fi

echo "-- NCCL env --"
for v in NCCL_IB_HCA NCCL_IB_GID_INDEX NCCL_SOCKET_IFNAME; do
  if [[ -n "${!v:-}" ]]; then pass "$v=${!v}"; \
  elif [[ -f /etc/nccl.conf ]] && grep -q "^$v=" /etc/nccl.conf; then \
    pass "$v set in /etc/nccl.conf ($(grep "^$v=" /etc/nccl.conf))"; \
  else info "$v not set in env or /etc/nccl.conf (workload launchers set it too)"; fi
done

echo "-- GPU --"
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null \
    | sed 's/^/  [info] gpu: /' || info "nvidia-smi ran but returned nothing"
else
  info "nvidia-smi not found"
fi

echo "== result: $([[ $RC -eq 0 ]] && echo HEALTHY || echo PROBLEMS FOUND) =="
exit $RC
