# Workload: llama.cpp RPC (pooled memory inference)

llama.cpp can split one model across several machines using its RPC backend. Each node
runs an `rpc-server` that exposes its GPU and memory; a single client (`llama-cli` or
`llama-server`) connects to all of them and offloads layers across the pool. This is the
simplest way to run a GGUF model that is larger than one node's 128 GB.

```
   ┌──────── client (llama-server) ───────┐
   │  --rpc gb10-01:50052,gb10-02:50052   │
   │  offloads N layers across the pool   │
   └───────┬───────────────────┬──────────┘
           │ RoCE fabric        │ RoCE fabric
           ▼                    ▼
    rpc-server @gb10-01   rpc-server @gb10-02
    128 GB                128 GB
```

## Memory math

Usable pool is about `128 GB x N` minus overhead. A GGUF model's on-disk size is close to
its memory footprint, so a Q4_K_M quant of a 405B model (~230-240 GB) fits comfortably on
two nodes, and larger/less-quantized variants fit as you add nodes.

## Build

Build llama.cpp with CUDA and RPC enabled on every node (or on shared storage). Example:

```bash
git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
cmake -B build -DGGML_CUDA=ON -DGGML_RPC=ON
cmake --build build --config Release -j
```

## Run

1. On every node, start the RPC server bound to that node's fabric IP:

   ```bash
   ./start-server.sh          # binds to this node's fabric IP, port 50052
   ```

2. From any one node (the client), launch the model across the pool:

   ```bash
   MODEL=/models/bigmodel.gguf RPC_NODES=gb10-01,gb10-02 ./start-cluster.sh
   ```

`start-cluster.sh` resolves each node name to its fabric IP, builds the `--rpc` list, and
starts `llama-server` with `-ngl 999` so all layers are offloaded across the RPC backends.

## Note on performance

RPC offload moves activations between nodes every token, so throughput is sensitive to the
fabric. This is exactly why the link is RoCE at 200 Gb/s and not management Ethernet. If
tokens/sec is far below expectation, re-check the fabric with `scripts/validate-fabric.sh`.
