#!/usr/bin/env bash
# Start a llama.cpp rpc-server on THIS node, bound to its fabric IP so all cross-node
# traffic rides the RoCE network. Run on every node that contributes memory to the pool.
#
# Usage: LLAMA_DIR=~/llama.cpp PORT=50052 ./start-server.sh
set -euo pipefail

LLAMA_DIR="${LLAMA_DIR:-$HOME/llama.cpp}"
PORT="${PORT:-50052}"

RPC_BIN="$LLAMA_DIR/build/bin/rpc-server"
[[ -x "$RPC_BIN" ]] || { echo "rpc-server not found at $RPC_BIN (build with -DGGML_RPC=ON)" >&2; exit 1; }

MY_FABRIC_IP="$(getent hosts "$(hostname)" | awk '{print $1; exit}')"
[[ -z "$MY_FABRIC_IP" ]] && { echo "cannot resolve this host's fabric IP from /etc/hosts" >&2; exit 1; }

echo "== llama.cpp rpc-server on $MY_FABRIC_IP:$PORT (GPU-backed) =="
exec "$RPC_BIN" --host "$MY_FABRIC_IP" --port "$PORT"
