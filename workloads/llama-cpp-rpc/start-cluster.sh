#!/usr/bin/env bash
# Launch a llama.cpp client that pools memory across all rpc-server nodes and serves the
# model over an OpenAI-compatible HTTP endpoint. Run on one node after start-server.sh is
# up on every node.
#
# Usage:
#   MODEL=/models/model.gguf RPC_NODES=gb10-01,gb10-02 ./start-cluster.sh
set -euo pipefail

LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"
MODEL="${MODEL:?set MODEL=/path/to/model.gguf}"
RPC_NODES="${RPC_NODES:-gb10-01,gb10-02}"
RPC_PORT="${RPC_PORT:-50052}"
HTTP_PORT="${HTTP_PORT:-8080}"
CTX="${CTX:-8192}"

SERVER_BIN="$LLAMA_DIR/build/bin/llama-server"
[[ -x "$SERVER_BIN" ]] || { echo "llama-server not found at $SERVER_BIN" >&2; exit 1; }

# Resolve each node name to its fabric IP and build the host:port,host:port RPC list.
RPC_LIST=""
IFS=',' read -ra NODES <<< "$RPC_NODES"
for n in "${NODES[@]}"; do
  ip="$(getent hosts "$n" | awk '{print $1; exit}')"
  [[ -z "$ip" ]] && { echo "cannot resolve $n from /etc/hosts" >&2; exit 1; }
  RPC_LIST+="${ip}:${RPC_PORT},"
done
RPC_LIST="${RPC_LIST%,}"

echo "== llama-server: $MODEL =="
echo "   pooling across: $RPC_LIST"
echo "   serving OpenAI-compatible API on :$HTTP_PORT, context $CTX"

# -ngl 999 offloads all layers; they are distributed across the RPC backends in order.
exec "$SERVER_BIN" \
  --model "$MODEL" \
  --rpc "$RPC_LIST" \
  --gpu-layers 999 \
  --ctx-size "$CTX" \
  --host 0.0.0.0 --port "$HTTP_PORT"
