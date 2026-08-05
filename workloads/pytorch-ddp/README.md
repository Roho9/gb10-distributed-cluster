# Workload: PyTorch distributed training

A minimal, self-contained multi-node training job that exercises NCCL collectives over the
RoCE fabric. It is both a smoke test (does distributed training actually use the fabric?)
and a template you can grow into real training or FSDP fine-tuning.

- `train.py`: a tiny model trained with `DistributedDataParallel`. It prints, from rank 0,
  the NCCL backend in use and a per-step all-reduce so you can confirm cross-node comms.
- `launch.sh`: wraps `torchrun` with the rendezvous and NCCL env pointed at the fabric.

## Run

Run `launch.sh` on **every** node, giving each a unique `NODE_RANK`. Node 0 is the
rendezvous host (use its fabric IP).

```bash
# on gb10-01 (rank 0):
NNODES=2 NODE_RANK=0 MASTER_ADDR=192.168.100.11 ./launch.sh
# on gb10-02 (rank 1):
NNODES=2 NODE_RANK=1 MASTER_ADDR=192.168.100.11 ./launch.sh
```

`MASTER_ADDR` must be node 0's **fabric** IP so the rendezvous and NCCL bootstrap ride the
CX7 network, not management.

## What success looks like

Rank 0 prints the world size, the device, and confirms `torch.distributed` is initialized
with the `nccl` backend. With `NCCL_DEBUG=INFO` you should see `NET/IB` in the logs. Loss
should decrease across steps, and all ranks should stay in lockstep (the all-reduce would
hang if the fabric were misconfigured, which is exactly the failure this catches early).

## Scaling to real work

Swap the toy model and random data in `train.py` for your model and dataset, and switch
`DistributedDataParallel` for `FullyShardedDataParallel` (FSDP) when the model is large
enough that you want to shard parameters/optimizer state across the 128 GB units rather
than replicate. The launch and fabric plumbing stays identical.
