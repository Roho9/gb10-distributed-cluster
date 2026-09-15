#!/usr/bin/env bash
# Measure PyTorch DDP training throughput (steps/sec and samples/sec) across node counts.
# Wraps the workloads/pytorch-ddp job with timing so you can see training scaling on the
# fabric. Run on each node with a unique NODE_RANK (like workloads/pytorch-ddp/launch.sh),
# or drive it from Slurm (orchestration/slurm/train.sbatch).
#
# Usage (per node):
#   NNODES=4 NODE_RANK=0 MASTER_ADDR=192.168.100.11 STEPS=200 ./bench-train.sh
set -euo pipefail

NNODES="${NNODES:-2}"
NODE_RANK="${NODE_RANK:?set NODE_RANK}"
MASTER_ADDR="${MASTER_ADDR:?set MASTER_ADDR to node 0 fabric IP}"
MASTER_PORT="${MASTER_PORT:-29500}"
STEPS="${STEPS:-200}"
BATCH="${BATCH:-64}"
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"

[[ -f /etc/nccl.conf ]] && { set -a; . /etc/nccl.conf; set +a; }
export NCCL_DEBUG="${NCCL_DEBUG:-WARN}" STEPS BATCH

echo "== DDP throughput: $NNODES nodes, $STEPS steps, batch $BATCH/node =="
START=$(date +%s.%N)
torchrun --nnodes "$NNODES" --node_rank "$NODE_RANK" --nproc_per_node 1 \
  --master_addr "$MASTER_ADDR" --master_port "$MASTER_PORT" \
  "$REPO_DIR/workloads/pytorch-ddp/train.py"
END=$(date +%s.%N)

# rank 0 reports the aggregate figure
if [[ "$NODE_RANK" == "0" ]]; then
  awk -v s="$START" -v e="$END" -v steps="$STEPS" -v b="$BATCH" -v n="$NNODES" 'BEGIN{
    dur=e-s; sps=steps/dur; samples=steps*b*n/dur;
    printf "nodes=%d  wall=%.1fs  steps/s=%.2f  samples/s=%.0f\n", n, dur, sps, samples;
  }'
fi
