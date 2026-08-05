#!/usr/bin/env bash
# Run NCCL all_reduce_perf across the cluster to confirm collective bandwidth over RoCE.
# This is the top-of-stack test: if this is fast, every framework above NCCL is fast.
#
# Usage:
#   ./run-nccl-test.sh <comma-separated-hosts> [gpus-per-node]
#   ./run-nccl-test.sh gb10-01,gb10-02
#   ./run-nccl-test.sh gb10-01,gb10-02,gb10-03,gb10-04 1
#
# Requires: OpenMPI (mpirun) reachable, nccl-tests built at $NCCL_TESTS_DIR on each node,
# passwordless SSH between nodes over the fabric, and /etc/nccl.conf in place.
set -uo pipefail

HOSTS="${1:-gb10-01,gb10-02}"
GPUS_PER_NODE="${2:-1}"
NCCL_TESTS_DIR="${NCCL_TESTS_DIR:-$HOME/nccl-tests}"

IFS=',' read -ra HARR <<< "$HOSTS"
NNODES=${#HARR[@]}
NP=$(( NNODES * GPUS_PER_NODE ))

echo "== NCCL all_reduce_perf =="
echo "hosts: $HOSTS   nodes: $NNODES   gpus/node: $GPUS_PER_NODE   total ranks: $NP"

BIN="$NCCL_TESTS_DIR/build/all_reduce_perf"
if [[ ! -x "$BIN" ]]; then
  echo "[info] $BIN not found. Build nccl-tests first, for example:" >&2
  echo "   git clone https://github.com/NVIDIA/nccl-tests \$HOME/nccl-tests" >&2
  echo "   cd \$HOME/nccl-tests && make MPI=1 MPI_HOME=/usr/lib/aarch64-linux-gnu/openmpi" >&2
  echo "   (build on every node, or on shared storage all nodes can see)" >&2
  exit 1
fi

# Build the mpirun host list (one slot per GPU per node)
HOSTLIST=""
for h in "${HARR[@]}"; do HOSTLIST+="${h}:${GPUS_PER_NODE},"; done
HOSTLIST=${HOSTLIST%,}

# NCCL env: prefer /etc/nccl.conf on each node, but export the critical ones explicitly
# so a missing conf still routes over RoCE. Adjust to your discovered values.
export NCCL_DEBUG="${NCCL_DEBUG:-INFO}"
export NCCL_IB_HCA="${NCCL_IB_HCA:-mlx5_0}"
export NCCL_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME:-enp1s0f0np0}"
export NCCL_IB_GID_INDEX="${NCCL_IB_GID_INDEX:-3}"
export NCCL_NET_GDR_LEVEL="${NCCL_NET_GDR_LEVEL:-PXB}"

echo "-- launching (size 8B .. 8GB, doubling) --"
mpirun --allow-run-as-root \
  -np "$NP" -H "$HOSTLIST" \
  -x NCCL_DEBUG -x NCCL_IB_HCA -x NCCL_SOCKET_IFNAME \
  -x NCCL_IB_GID_INDEX -x NCCL_NET_GDR_LEVEL \
  --mca btl_tcp_if_include "${NCCL_SOCKET_IFNAME}" \
  "$BIN" -b 8 -e 8G -f 2 -g 1 | tee "nccl-test-$(date +%Y%m%d-%H%M%S).txt"

echo "== done =="
echo "Read the 'busbw' column at large sizes: it should be within ~10-15% of your"
echo "ib_write_bw figure. Confirm the log shows 'NET/IB' (RDMA), not 'NET/Socket' (TCP)."
