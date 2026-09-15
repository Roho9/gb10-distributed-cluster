#!/usr/bin/env bash
# Sweep NCCL all_reduce_perf across increasing node counts and record busbw vs message
# size into a CSV. This shows how collective bandwidth holds (or does not) as the cluster
# grows, which is the single most useful scaling signal for the fabric.
#
# Usage:
#   ./nccl-sweep.sh <comma-separated-hosts> [out.csv]
#   ./nccl-sweep.sh gb10-01,gb10-02,gb10-03,gb10-04 results/nccl.csv
#
# For each power-of-two node count k (2,4,8,...) up to the number of hosts, it runs the
# collective on the first k hosts and appends rows: nodes,size_bytes,busbw_gbps.
set -uo pipefail

HOSTS="${1:-gb10-01,gb10-02}"
OUT="${2:-results/nccl-sweep.csv}"
NCCL_TESTS_DIR="${NCCL_TESTS_DIR:-$HOME/nccl-tests}"
BIN="$NCCL_TESTS_DIR/build/all_reduce_perf"

IFS=',' read -ra ALL <<< "$HOSTS"
TOTAL=${#ALL[@]}

[[ -x "$BIN" ]] || { echo "build nccl-tests first: $BIN not found (see scripts/run-nccl-test.sh)" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"
echo "nodes,size_bytes,busbw" > "$OUT"

[[ -f /etc/nccl.conf ]] && { set -a; . /etc/nccl.conf; set +a; }
export NCCL_DEBUG="${NCCL_DEBUG:-WARN}"

k=2
while (( k <= TOTAL )); do
  SUBSET=$(IFS=,; echo "${ALL[*]:0:k}")
  HOSTLIST=""
  for h in ${SUBSET//,/ }; do HOSTLIST+="${h}:1,"; done
  HOSTLIST=${HOSTLIST%,}
  echo "== $k nodes: $SUBSET =="

  # all_reduce_perf columns: size count type redop root  time algbw busbw #wrong ...
  # out-of-place busbw is column 8. Capture the data rows (leading whitespace + digit).
  mpirun --allow-run-as-root -np "$k" -H "$HOSTLIST" \
    -x NCCL_DEBUG -x NCCL_IB_HCA -x NCCL_SOCKET_IFNAME -x NCCL_IB_GID_INDEX -x NCCL_NET_GDR_LEVEL \
    "$BIN" -b 8 -e 8G -f 2 -g 1 2>/dev/null \
    | awk -v n="$k" '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]/ {print n","$1","$8}' \
    >> "$OUT" || echo "[warn] run for $k nodes failed; continuing"

  k=$(( k * 2 ))
done

echo "wrote $OUT"
echo "aggregate + chart: python3 benchmarks/aggregate.py $OUT"
