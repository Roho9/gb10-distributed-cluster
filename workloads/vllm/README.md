# Workload: vLLM tensor + pipeline parallel serving

Serve one large model split across the cluster. vLLM shards the model two ways:

- **Tensor parallelism (`--tensor-parallel-size`)**: splits each layer's weights across
  GPUs. Heavy on collective communication, so it wants the fastest link. Keep TP within a
  node where possible, or across nodes only on the RoCE fabric.
- **Pipeline parallelism (`--pipeline-parallel-size`)**: splits the model by layer groups
  across nodes. Lighter communication (activations at stage boundaries), which suits a
  multi-node fabric well.

Because each GB10 node has one Blackwell GPU with 128 GB unified memory, the natural
mapping is **1 GPU per node, pipeline-parallel across nodes**, optionally with tensor
parallelism if you later add multiple GPUs per node.

## Memory math

Total usable pooled memory is roughly `128 GB x N` minus KV-cache and framework overhead.
A dense model needs about `2 bytes x params` at FP16/BF16 (1 byte at FP8/INT8), plus KV
cache that grows with context length and batch size. Examples:

| Model | Approx weights (BF16) | Fits on |
| --- | --- | --- |
| 70B | ~140 GB | 2 nodes (256 GB pooled) |
| 405B | ~810 GB | 7-8 nodes, or fewer at FP8/INT8 quant |
| 405B (FP8) | ~405 GB | 4 nodes (512 GB pooled) |

Leave headroom for the KV cache. If a model is close to the pooled ceiling, quantize or
add nodes.

## Launch

vLLM uses Ray to span nodes. Start a Ray head on node 0, join the others, then launch the
server with pipeline-parallel size equal to the node count.

```bash
# on every node, so vLLM/Ray/NCCL use the fabric, not management
export $(grep -v '^#' /etc/nccl.conf | xargs)   # NCCL_* from the ansible-managed file
export GLOO_SOCKET_IFNAME=$NCCL_SOCKET_IFNAME
export VLLM_HOST_IP=$(getent hosts $(hostname) | awk '{print $1}')  # this node's fabric IP

# then, from the head node:
./serve.sh
```

Edit `serve.sh` to set `MODEL`, `HEAD_FABRIC_IP`, and the node list. It is commented so you
can see exactly what each flag does.

## Verifying it used the fabric

Watch the vLLM/NCCL startup log for `NET/IB` (RDMA over the CX7), not `NET/Socket`. If you
see `NET/Socket`, `NCCL_SOCKET_IFNAME`/`NCCL_IB_HCA` are wrong and traffic is crawling over
management Ethernet. Fix per `docs/04-roce-tuning.md`.
