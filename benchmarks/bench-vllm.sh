#!/usr/bin/env bash
# Benchmark a running multi-node vLLM server (throughput + latency) using vLLM's own
# benchmark client. Start the server first (workloads/vllm or orchestration/*), then point
# this at its host:port.
#
# Usage:
#   MODEL=meta-llama/Llama-3.1-70B-Instruct HOST=gb10-01 PORT=8000 ./bench-vllm.sh
set -euo pipefail

MODEL="${MODEL:?set MODEL to the served model id}"
HOST="${HOST:-gb10-01}"
PORT="${PORT:-8000}"
NUM_PROMPTS="${NUM_PROMPTS:-500}"
CONCURRENCY="${CONCURRENCY:-32}"
IN_LEN="${IN_LEN:-1024}"
OUT_LEN="${OUT_LEN:-256}"

echo "== vLLM serving benchmark against http://$HOST:$PORT =="
echo "   model=$MODEL prompts=$NUM_PROMPTS concurrency=$CONCURRENCY in=$IN_LEN out=$OUT_LEN"

# Prefer the modern `vllm bench serve` CLI; fall back to the bundled benchmark script.
if vllm bench serve --help >/dev/null 2>&1; then
  exec vllm bench serve \
    --model "$MODEL" \
    --host "$HOST" --port "$PORT" \
    --dataset-name random \
    --random-input-len "$IN_LEN" --random-output-len "$OUT_LEN" \
    --num-prompts "$NUM_PROMPTS" --max-concurrency "$CONCURRENCY"
else
  echo "vllm bench serve not available; use vllm's benchmark_serving.py from its repo:"
  echo "  python benchmarks/benchmark_serving.py --backend vllm --model $MODEL \\"
  echo "    --host $HOST --port $PORT --num-prompts $NUM_PROMPTS --request-rate inf"
  exit 1
fi
