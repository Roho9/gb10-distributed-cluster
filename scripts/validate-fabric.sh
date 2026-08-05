#!/usr/bin/env bash
# Cross-node fabric validation: jumbo-frame reachability plus raw RDMA bandwidth
# with ib_write_bw. Run from a control host that has passwordless SSH to the nodes
# over the fabric or management network.
#
# Usage:
#   ./validate-fabric.sh [server_host] [client_host] [rdma-dev]
#   ./validate-fabric.sh gb10-01 gb10-02 mlx5_0
#
# Defaults to gb10-01 (server) and gb10-02 (client). The server runs ib_write_bw
# and the client connects to it over the fabric.
set -uo pipefail

SERVER="${1:-gb10-01}"
CLIENT="${2:-gb10-02}"
RDMA_DEV="${3:-mlx5_0}"
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"

echo "== fabric validation: server=$SERVER client=$CLIENT dev=$RDMA_DEV =="

# Resolve the server's fabric IP from /etc/hosts on the client (fabric name -> IP)
SERVER_IP=$($SSH "$CLIENT" "getent hosts $SERVER | awk '{print \$1; exit}'" 2>/dev/null)
if [[ -z "$SERVER_IP" ]]; then
  echo "[FAIL] could not resolve $SERVER to a fabric IP from $CLIENT's /etc/hosts" >&2
  echo "       ensure the fabric names/IPs are in /etc/hosts on every node" >&2
  exit 1
fi
echo "[info] $SERVER fabric IP = $SERVER_IP"

echo "-- 1. jumbo-frame reachability ($CLIENT -> $SERVER_IP, 8972B DF) --"
if $SSH "$CLIENT" "ping -M do -s 8972 -c 3 -W 2 $SERVER_IP" >/tmp/_ping.$$ 2>&1; then
  echo "[ok]   jumbo ping succeeded (MTU 9000 path is clean)"
else
  echo "[FAIL] jumbo ping failed. An interface or switch port is likely at MTU 1500:"
  sed 's/^/       /' /tmp/_ping.$$
  rm -f /tmp/_ping.$$
  exit 1
fi
rm -f /tmp/_ping.$$

echo "-- 2. raw RDMA bandwidth (ib_write_bw) --"
# Start the server side in the background, give it a moment, then run the client.
$SSH "$SERVER" "pkill -f 'ib_write_bw' 2>/dev/null; nohup ib_write_bw -d $RDMA_DEV -F --report_gbits >/tmp/ibw_srv.log 2>&1 &" || {
  echo "[FAIL] could not start ib_write_bw on $SERVER (is perftest installed?)" >&2; exit 1; }
sleep 2

CLIENT_OUT=$($SSH "$CLIENT" "ib_write_bw -d $RDMA_DEV -F --report_gbits $SERVER_IP 2>&1" || true)
echo "$CLIENT_OUT" | sed 's/^/       /'

# Pull the peak Gb/s figure from the client output (last numeric column of the data row)
BW=$(echo "$CLIENT_OUT" | awk '/[0-9]+[[:space:]]+[0-9]/ {v=$(NF-1)} END{print v}')
$SSH "$SERVER" "pkill -f 'ib_write_bw' 2>/dev/null" || true

if [[ -n "$BW" ]]; then
  echo "[info] measured RDMA bandwidth: ${BW} Gb/s"
  # 200 Gb/s link realizes ~185-190; warn under ~150 as a rough floor
  awk -v b="$BW" 'BEGIN{ if (b+0 >= 150) exit 0; else exit 1 }' \
    && echo "[ok]   bandwidth is in the healthy range for a 200 Gb/s CX7 link" \
    || echo "[warn] bandwidth below ~150 Gb/s: check PFC/ECN/MTU and PCIe link width (docs/04, docs/06)"
else
  echo "[warn] could not parse a bandwidth figure; review the raw output above"
fi

echo "== fabric validation complete =="
echo "   next: ./scripts/run-nccl-test.sh ${SERVER},${CLIENT}"
