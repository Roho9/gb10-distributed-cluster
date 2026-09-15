#!/usr/bin/env bash
# Install Prometheus node_exporter on THIS node with the textfile collector enabled, and
# schedule the RoCE textfile collector to run every 15s. Run with sudo on each node.
# dcgm-exporter (GPU metrics) ships with the DGX software stack; install it separately per
# NVIDIA's instructions and expose it on :9400 (see prometheus.yml).
#
# Usage: sudo ./install-exporters.sh [rdma-dev]
set -euo pipefail

DEV="${1:-mlx5_0}"
TEXTFILE_DIR="/var/lib/node_exporter/textfile"
COLLECTOR_SRC="$(cd "$(dirname "$0")/.." && pwd)/roce-textfile-collector.sh"
COLLECTOR_DST="/usr/local/bin/roce-textfile-collector.sh"

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)" >&2; exit 1; }
[[ -f "$COLLECTOR_SRC" ]] || { echo "cannot find $COLLECTOR_SRC" >&2; exit 1; }

echo "[exporters] creating textfile dir $TEXTFILE_DIR"
mkdir -p "$TEXTFILE_DIR"

echo "[exporters] installing collector to $COLLECTOR_DST"
install -m 0755 "$COLLECTOR_SRC" "$COLLECTOR_DST"

# node_exporter: install via your package manager if not present. This script assumes the
# binary is available; it only wires up the textfile collector and a systemd unit.
if ! command -v node_exporter >/dev/null 2>&1 && [[ ! -x /usr/local/bin/node_exporter ]]; then
  echo "[exporters] NOTE: node_exporter not found. Install it (apt/download) so that it runs"
  echo "            with: --collector.textfile.directory=$TEXTFILE_DIR --web.listen-address=:9100"
fi

echo "[exporters] installing systemd service + timer for the RoCE collector"
cat > /etc/systemd/system/roce-collector.service <<EOF
[Unit]
Description=RoCE textfile collector for node_exporter
[Service]
Type=oneshot
ExecStart=${COLLECTOR_DST} ${DEV} ${TEXTFILE_DIR}/roce.prom
EOF

cat > /etc/systemd/system/roce-collector.timer <<EOF
[Unit]
Description=Run RoCE textfile collector every 15s
[Timer]
OnBootSec=15
OnUnitActiveSec=15
AccuracySec=1s
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now roce-collector.timer
echo "[exporters] done. Verify: systemctl status roce-collector.timer ; cat ${TEXTFILE_DIR}/roce.prom"
echo "[exporters] ensure node_exporter runs with --collector.textfile.directory=$TEXTFILE_DIR"
