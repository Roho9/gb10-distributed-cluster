#!/usr/bin/env bash
# Launch the DDP smoke test with torchrun, pinned to the RoCE fabric. Run on EVERY node
# with a unique NODE_RANK; node 0's fabric IP is the rendezvous MASTER_ADDR.
#
# Usage (2 nodes):
#   on gb10-01:  NNODES=2 NODE_RANK=0 MASTER_ADDR=192.168.100.11 ./launch.sh
#   on gb10-02:  NNODES=2 NODE_RANK=1 MASTER_ADDR=192.168.100.11 ./launch.sh
set -euo pipefail

NNODES="${NNODES:-2}"
NODE_RANK="${NODE_RANK:?set NODE_RANK: 0 on the master node, 1 and up on the others}"
MASTER_ADDR="${MASTER_ADDR:?set MASTER_ADDR to the fabric IP of node 0}"
MASTER_PORT="${MASTER_PORT:-29500}"
NPROC_PER_NODE="${NPROC_PER_NODE:-1}"   # GPUs per GB10 node

# Bring in the fabric NCCL settings so torchrun's workers use RoCE, not management.
if [[ -f /etc/nccl.conf ]]; then
  set -a; . /etc/nccl.conf; set +a
fi
export GLOO_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME:-enp1s0f0np0}"
export NCCL_DEBUG="${NCCL_DEBUG:-INFO}"   # INFO so you can confirm NET/IB during the test

echo "== torchrun DDP: node $NODE_RANK/$NNODES, master $MASTER_ADDR:$MASTER_PORT =="
echo "   NCCL_IB_HCA=${NCCL_IB_HCA:-unset} NCCL_SOCKET_IFNAME=${NCCL_SOCKET_IFNAME:-unset}"

exec torchrun \
  --nnodes "$NNODES" \
  --node_rank "$NODE_RANK" \
  --nproc_per_node "$NPROC_PER_NODE" \
  --master_addr "$MASTER_ADDR" \
  --master_port "$MASTER_PORT" \
  "$(dirname "$0")/train.py"
