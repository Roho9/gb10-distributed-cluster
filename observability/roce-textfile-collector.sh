#!/usr/bin/env bash
# Emit RoCE / RDMA counters in Prometheus text exposition format for the node_exporter
# textfile collector. Run periodically (cron or a systemd timer) writing to the
# textfile directory node_exporter watches (default /var/lib/node_exporter/textfile).
#
# Usage:
#   ./roce-textfile-collector.sh <rdma-dev> [out-file]
#   ./roce-textfile-collector.sh mlx5_0 /var/lib/node_exporter/textfile/roce.prom
#
# It writes atomically (tmp then mv) so node_exporter never reads a half-written file.
set -uo pipefail

DEV="${1:-mlx5_0}"
OUT="${2:-/var/lib/node_exporter/textfile/roce.prom}"
CDIR="/sys/class/infiniband/${DEV}/ports/1/counters"
HWDIR="/sys/class/infiniband/${DEV}/ports/1/hw_counters"

if [[ ! -d "$CDIR" ]]; then
  echo "no counters at $CDIR (wrong device '$DEV'?)" >&2
  exit 1
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

emit() {  # name, help, type, value, label
  local name="$1" help="$2" type="$3" value="$4" label="$5"
  printf '# HELP %s %s\n# TYPE %s %s\n%s{device="%s"%s} %s\n' \
    "$name" "$help" "$name" "$type" "$name" "$DEV" "$label" "$value"
}

read_ctr() { cat "$1" 2>/dev/null || echo 0; }

{
  # Standard port counters (units of 4-byte words for the *_data counters)
  emit roce_port_xmit_bytes_total "RoCE bytes transmitted" counter \
    "$(( $(read_ctr "$CDIR/port_xmit_data") * 4 ))" ""
  emit roce_port_rcv_bytes_total "RoCE bytes received" counter \
    "$(( $(read_ctr "$CDIR/port_rcv_data") * 4 ))" ""
  emit roce_port_xmit_packets_total "RoCE packets transmitted" counter \
    "$(read_ctr "$CDIR/port_xmit_packets")" ""
  emit roce_port_rcv_packets_total "RoCE packets received" counter \
    "$(read_ctr "$CDIR/port_rcv_packets")" ""
  emit roce_port_rcv_errors_total "RoCE receive errors" counter \
    "$(read_ctr "$CDIR/port_rcv_errors")" ""
  emit roce_port_xmit_discards_total "RoCE transmit discards" counter \
    "$(read_ctr "$CDIR/port_xmit_discards")" ""

  # RoCE-specific hw_counters (present on ConnectX; skip silently if missing)
  for hc in np_ecn_marked_roce_packets np_cnp_sent rp_cnp_handled \
            out_of_sequence packet_seq_err local_ack_timeout_err rx_icrc_encapsulated; do
    if [[ -r "$HWDIR/$hc" ]]; then
      emit "roce_${hc}_total" "RoCE hw_counter ${hc}" counter "$(read_ctr "$HWDIR/$hc")" ""
    fi
  done

  # Link rate in Gb/s parsed from ibv_devinfo, if available, as a gauge
  if command -v ibv_devinfo >/dev/null 2>&1; then
    rate=$(ibv_devinfo -d "$DEV" 2>/dev/null | awk '/active_speed|rate:/{print $2; exit}')
    [[ -n "${rate:-}" ]] && emit roce_link_rate_gbps "RoCE active link rate (Gb/s)" gauge "${rate%% *}" ""
  fi
} > "$TMP"

# node_exporter reads whole files; move into place atomically
mkdir -p "$(dirname "$OUT")"
mv "$TMP" "$OUT"
trap - EXIT
echo "wrote $(grep -c '^roce_' "$OUT") metrics to $OUT"
