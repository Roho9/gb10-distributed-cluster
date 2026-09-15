#!/usr/bin/env bash
#SBATCH --job-name=gb10-ddp
#SBATCH --partition=fabric
#SBATCH --nodes=4
#SBATCH --ntasks-per-node=1
#SBATCH --gres=gpu:1
#SBATCH --time=01:00:00
#SBATCH --output=gb10-ddp-%j.out
#
# Launch the PyTorch DDP job across the allocated nodes with torchrun, over the RoCE fabric.
# Submit with: sbatch orchestration/slurm/train.sbatch
set -euo pipefail

# Bring in the RoCE NCCL settings so workers use the CX7 fabric.
if [[ -f /etc/nccl.conf ]]; then set -a; . /etc/nccl.conf; set +a; fi
export GLOO_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME:-enp1s0f0np0}"
export NCCL_DEBUG="${NCCL_DEBUG:-INFO}"

# Rendezvous on rank-0 node's FABRIC address so bootstrap rides the CX7 network.
NODES=($(scontrol show hostnames "$SLURM_JOB_NODELIST"))
HEAD_NODE="${NODES[0]}"
HEAD_FABRIC_IP=$(srun --nodes=1 --ntasks=1 -w "$HEAD_NODE" \
  bash -c "getent hosts \$(hostname) | awk '{print \$1; exit}'")
MASTER_PORT=29500

REPO_DIR="${REPO_DIR:-$SLURM_SUBMIT_DIR}"

echo "nodes: ${NODES[*]}   head fabric IP: $HEAD_FABRIC_IP"

# One torchrun per node; Slurm provides SLURM_NODEID as the node rank.
srun --ntasks-per-node=1 bash -c "
  torchrun \
    --nnodes=$SLURM_JOB_NUM_NODES \
    --node_rank=\$SLURM_NODEID \
    --nproc_per_node=1 \
    --master_addr=$HEAD_FABRIC_IP \
    --master_port=$MASTER_PORT \
    $REPO_DIR/workloads/pytorch-ddp/train.py
"
