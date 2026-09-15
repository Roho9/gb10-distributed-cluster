#!/usr/bin/env bash
# Live view of RDMA / PFC / ECN counters on THIS node. Read-only. Ctrl-C to stop.
# Shows deltas per interval so you can see rates, not just totals, while a job runs.
#
# Usage: ./fabric-watch.sh [rdma-dev] [iface] [interval-seconds]
set -uo pipefail

DEV="${1:-mlx5_0}"
IFACE="${2:-}"
INTERVAL="${3:-2}"

CDIR="/sys/class/infiniband/${DEV}/ports/1/counters"
HWDIR="/sys/class/infiniband/${DEV}/ports/1/hw_counters"

if [[ ! -d "$CDIR" ]]; then
  echo "no counters at $CDIR. Is '$DEV' the right RDMA device? (ibdev2netdev)" >&2
  exit 1
fi

# Auto-detect the netdev if not provided
if [[ -z "$IFACE" ]] && command -v ibdev2netdev >/dev/null 2>&1; then
  IFACE=$(ibdev2netdev 2>/dev/null | awk -v d="$DEV" '$1==d {print $5; exit}')
fi

read_ctr() { cat "$1" 2>/dev/null || echo 0; }

# Sum PFC pause counters across priorities from ethtool (names vary; grep broadly)
read_pfc() {
  [[ -z "$IFACE" ]] && { echo 0; return; }
  ethtool -S "$IFACE" 2>/dev/null \
    | grep -Ei 'prio3.*pause|pause.*prio3|pfc.*prio.?3|rx_prio3_pause' \
    | awk '{s+=$NF} END{print s+0}'
}

# ib_write_data counters are in units of 4 bytes (RDMA convention)
prev_xmit=$(read_ctr "$CDIR/port_xmit_data")
prev_rcv=$(read_ctr "$CDIR/port_rcv_data")
prev_pfc=$(read_pfc)
prev_ecn=$(read_ctr "$HWDIR/np_ecn_marked_roce_packets")

printf "watching dev=%s iface=%s every %ss (Ctrl-C to stop)\n" "$DEV" "${IFACE:-?}" "$INTERVAL"
printf "%-9s %12s %12s %10s %10s %12s\n" "time" "tx_Gb/s" "rx_Gb/s" "pfc/s" "ecn/s" "rdma_errs"

while true; do
  sleep "$INTERVAL"
  xmit=$(read_ctr "$CDIR/port_xmit_data"); rcv=$(read_ctr "$CDIR/port_rcv_data")
  pfc=$(read_pfc); ecn=$(read_ctr "$HWDIR/np_ecn_marked_roce_packets")
  errs=$(( $(read_ctr "$CDIR/port_rcv_errors") + $(read_ctr "$CDIR/port_xmit_discards") ))

  # counters are 4-byte words -> bytes = delta*4 ; Gb/s = bytes*8 / interval / 1e9
  tx_gbps=$(awk -v a="$prev_xmit" -v b="$xmit" -v t="$INTERVAL" 'BEGIN{printf "%.1f",(b-a)*4*8/t/1e9}')
  rx_gbps=$(awk -v a="$prev_rcv" -v b="$rcv" -v t="$INTERVAL" 'BEGIN{printf "%.1f",(b-a)*4*8/t/1e9}')
  pfc_rate=$(awk -v a="$prev_pfc" -v b="$pfc" -v t="$INTERVAL" 'BEGIN{printf "%.0f",(b-a)/t}')
  ecn_rate=$(awk -v a="$prev_ecn" -v b="$ecn" -v t="$INTERVAL" 'BEGIN{printf "%.0f",(b-a)/t}')

  printf "%-9s %12s %12s %10s %10s %12s\n" "$(date +%H:%M:%S)" "$tx_gbps" "$rx_gbps" "$pfc_rate" "$ecn_rate" "$errs"

  prev_xmit=$xmit; prev_rcv=$rcv; prev_pfc=$pfc; prev_ecn=$ecn
done
