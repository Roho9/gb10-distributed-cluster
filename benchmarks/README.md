# Benchmarking

A repeatable way to measure how the cluster performs and, crucially, how it scales as you
add nodes. Three benches plus an aggregator that turns raw results into a table and a chart.

## The benches

| Script | Measures | Needs |
| --- | --- | --- |
| `nccl-sweep.sh` | NCCL all-reduce bus bandwidth vs message size, per node count | nccl-tests, mpirun |
| `bench-train.sh` | PyTorch DDP steps/sec and samples/sec across nodes | the pytorch-ddp workload |
| `bench-vllm.sh` | vLLM serving throughput and latency | a running multi-node vLLM server |

## The one that matters most: NCCL scaling

`nccl-sweep.sh` runs the collective on 2, 4, 8, ... nodes and records busbw per message
size. Feed the CSV to `aggregate.py`:

```bash
./nccl-sweep.sh gb10-01,gb10-02,gb10-03,gb10-04 results/nccl-sweep.csv
python3 aggregate.py results/nccl-sweep.csv --out results/nccl-scaling.png
```

`aggregate.py` prints a markdown table of peak busbw per node count, writes
`results/summary.md`, and renders `results/nccl-scaling.png`: bus bandwidth vs message
size, one line per node count.

### Reading the chart

Large-message busbw should stay high and close together as node count grows. If each added
node-count line sits well below the last at large sizes, collective bandwidth is not
scaling: that is almost always PFC/ECN on the switch, not the NICs (see `docs/07-rack-scale.md`
and watch `observability/fabric-watch.sh` during the sweep).

## Chart design note

The chart uses a validated, colorblind-safe categorical palette (worst adjacent CVD
delta-E 24.2, well past the >=12 target). Because two of the light-mode hues fall below 3:1
contrast on the surface, every line is directly labeled at its end and the markdown table
is always produced, so the results are readable without relying on color. Use `--dark` to
render the dark-mode variant of the palette.

## Requirements

The aggregator needs Python with `matplotlib` for the chart (the table works without it):

```bash
pip install matplotlib
```
