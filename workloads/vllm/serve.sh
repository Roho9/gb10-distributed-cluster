#!/usr/bin/env bash
# Launch vLLM serving a model split across the cluster with pipeline parallelism
# (one GB10 GPU per node) over the RoCE fabric via Ray + NCCL.
#
# Run this on the HEAD node after starting Ray on all nodes (see start-ray.sh).
# Adjust MODEL, PP_SIZE, and TP_SIZE to your model and cluster.
set -euo pipefail

MODEL="${MODEL:-meta-llama/Llama-3.1-70B-Instruct}"
PP_SIZE="${PP_SIZE:-2}"          # pipeline-parallel size = number of nodes
TP_SIZE="${TP_SIZE:-1}"          # tensor-parallel size = GPUs per node
MAX_LEN="${MAX_LEN:-8192}"
PORT="${PORT:-8000}"

# Pull NCCL RoCE settings from the ansible-managed file so vLLM's workers use the fabric.
# nccl.conf is KEY=VALUE lines (with # comments), which is valid shell; set -a exports them.
if [[ -f /etc/nccl.conf ]]; then
  set -a; . /etc/nccl.conf; set +a
fi
export GLOO_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME:-enp1s0f0np0}"

echo "== vLLM: $MODEL  pp=$PP_SIZE tp=$TP_SIZE  (world size = $((PP_SIZE * TP_SIZE))) =="
echo "   NCCL_IB_HCA=${NCCL_IB_HCA:-unset}  NCCL_SOCKET_IFNAME=${NCCL_SOCKET_IFNAME:-unset}"
echo "   Ensure Ray is already running on all $PP_SIZE nodes (./start-ray.sh)."

exec vllm serve "$MODEL" \
  --distributed-executor-backend ray \
  --pipeline-parallel-size "$PP_SIZE" \
  --tensor-parallel-size "$TP_SIZE" \
  --max-model-len "$MAX_LEN" \
  --host 0.0.0.0 --port "$PORT" \
  --trust-remote-code
