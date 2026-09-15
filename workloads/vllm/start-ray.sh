#!/usr/bin/env bash
# Start (or join) a Ray cluster over the RoCE fabric so vLLM can span nodes.
# Run on EVERY node. On the head node call with role=head; on the others role=worker
# and pass the head's fabric IP.
#
# Usage:
#   ./start-ray.sh head
#   ./start-ray.sh worker <head-fabric-ip>
set -euo pipefail

ROLE="${1:-head}"
HEAD_IP="${2:-}"
PORT="${RAY_PORT:-6379}"

# Bind Ray to THIS node's fabric IP so its traffic stays on the CX7 network.
MY_FABRIC_IP="$(getent hosts "$(hostname)" | awk '{print $1; exit}')"
if [[ -z "$MY_FABRIC_IP" ]]; then
  echo "could not resolve this host's fabric IP from /etc/hosts" >&2; exit 1
fi

# Inherit NCCL RoCE env for any actor started by Ray.
[[ -f /etc/nccl.conf ]] && { set -a; . /etc/nccl.conf; set +a; }
export GLOO_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME:-enp1s0f0np0}"

case "$ROLE" in
  head)
    echo "== Ray head on $MY_FABRIC_IP:$PORT =="
    ray start --head --node-ip-address="$MY_FABRIC_IP" --port="$PORT"
    echo "workers: ./start-ray.sh worker $MY_FABRIC_IP"
    ;;
  worker)
    [[ -z "$HEAD_IP" ]] && { echo "usage: $0 worker <head-fabric-ip>" >&2; exit 2; }
    echo "== Ray worker $MY_FABRIC_IP joining head $HEAD_IP:$PORT =="
    ray start --address="$HEAD_IP:$PORT" --node-ip-address="$MY_FABRIC_IP"
    ;;
  *)
    echo "usage: $0 head | $0 worker <head-fabric-ip>" >&2; exit 2 ;;
esac
