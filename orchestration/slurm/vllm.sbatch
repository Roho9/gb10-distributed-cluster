#!/usr/bin/env bash
#SBATCH --job-name=gb10-vllm
#SBATCH --partition=fabric
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --gres=gpu:1
#SBATCH --time=02:00:00
#SBATCH --output=gb10-vllm-%j.out
#
# Launch multi-node vLLM serving via Ray over the RoCE fabric.
# The number of nodes becomes the pipeline-parallel size.
# Submit with: sbatch orchestration/slurm/vllm.sbatch
set -euo pipefail

MODEL="${MODEL:-meta-llama/Llama-3.1-70B-Instruct}"
REPO_DIR="${REPO_DIR:-$SLURM_SUBMIT_DIR}"

if [[ -f /etc/nccl.conf ]]; then set -a; . /etc/nccl.conf; set +a; fi
export GLOO_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME:-enp1s0f0np0}"

NODES=($(scontrol show hostnames "$SLURM_JOB_NODELIST"))
HEAD_NODE="${NODES[0]}"
HEAD_FABRIC_IP=$(srun --nodes=1 --ntasks=1 -w "$HEAD_NODE" \
  bash -c "getent hosts \$(hostname) | awk '{print \$1; exit}'")

echo "vLLM head: $HEAD_NODE ($HEAD_FABRIC_IP)   nodes: ${NODES[*]}"

# 1. Start Ray head on node 0, workers on the rest, all bound to fabric IPs.
srun --nodes=1 --ntasks=1 -w "$HEAD_NODE" \
  bash "$REPO_DIR/workloads/vllm/start-ray.sh" head &
sleep 10
for n in "${NODES[@]:1}"; do
  srun --nodes=1 --ntasks=1 -w "$n" \
    bash "$REPO_DIR/workloads/vllm/start-ray.sh" worker "$HEAD_FABRIC_IP" &
done
sleep 10

# 2. Launch the server on the head node with pipeline-parallel size = node count.
srun --nodes=1 --ntasks=1 -w "$HEAD_NODE" \
  env MODEL="$MODEL" PP_SIZE="$SLURM_JOB_NUM_NODES" TP_SIZE=1 \
  bash "$REPO_DIR/workloads/vllm/serve.sh"
