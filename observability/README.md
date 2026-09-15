# Observability

See what the fabric and GPUs are doing, especially under load. Two levels:

1. **Ad hoc**: `fabric-watch.sh` prints live RDMA, PFC, and ECN counters on one node. No
   dependencies, run it in a terminal while a job runs.
2. **Continuous**: a Prometheus + Grafana stack. `roce-textfile-collector.sh` emits RoCE
   counters in Prometheus format for the node_exporter textfile collector; `dcgm-exporter`
   provides GPU metrics; the Grafana dashboard in `grafana/` visualizes both.

## Why this matters here

At rack scale the failure mode is not "the link is down", it is "throughput quietly
collapsed because PFC is pausing constantly or RoCE is dropping and retransmitting". Those
are invisible without counters. The metrics below make them obvious:

| Symptom | Metric to watch |
| --- | --- |
| Congestion, senders not backing off | PFC pause frames rising fast on the RoCE priority |
| RoCE drops / retransmits | port_rcv_errors, out_of_sequence, packet_seq_err rising |
| ECN working | RoCE ECN-marked counters increasing (good: senders being told to slow) |
| Under-utilized fabric | port xmit/rcv data far below line rate during a collective |
| GPU stalls waiting on comms | GPU util dropping while a distributed job runs |

## 1. Ad hoc: fabric-watch.sh

```bash
./fabric-watch.sh mlx5_0 enp1s0f0np0        # device + fabric netdev, 2s refresh
./fabric-watch.sh mlx5_0 enp1s0f0np0 5      # 5s refresh
```

It shows, per interval: link rate, port xmit/rcv throughput (derived from the byte
counters), PFC pause counts on priority 3, ECN marks, and RoCE error counters, with deltas
so you see rate of change, not just totals.

## 2. Continuous: Prometheus + Grafana

On every node:

```bash
sudo ./prometheus/install-exporters.sh     # node_exporter (textfile dir) + a cron entry
                                           # that runs roce-textfile-collector.sh
```

Install `dcgm-exporter` for GPU metrics per NVIDIA's instructions (it ships with the DGX
software stack). Then, on a monitoring host:

```bash
# point prometheus at your nodes, then run it (container or binary)
$EDITOR prometheus/prometheus.yml          # list your node targets
prometheus --config.file=prometheus/prometheus.yml
```

Import `grafana/gb10-fabric-dashboard.json` into Grafana and select your Prometheus data
source. Panels: fabric throughput per node, PFC pauses, ECN marks, RoCE errors, GPU
utilization, and GPU memory used (the pooled-VRAM view across the cluster).

## Counter reference

RoCE / RDMA counters live under sysfs and are what the collector scrapes:

```
/sys/class/infiniband/<dev>/ports/1/counters/            # port_xmit_data, port_rcv_data, errors
/sys/class/infiniband/<dev>/ports/1/hw_counters/         # RoCE-specific: np_ecn_marked_roce_packets, etc.
/sys/class/net/<iface>/statistics/                       # netdev-level rx/tx
ethtool -S <iface> | grep -Ei 'pause|prio|pfc|ecn'       # PFC/priority pause counters
```

Counter names vary slightly by MLNX_OFED / DOCA version; the collector probes for what
exists and skips what does not, so it works across versions.
