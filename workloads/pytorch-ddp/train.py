#!/usr/bin/env python3
"""Minimal multi-node DDP smoke test for the GB10 RoCE fabric.

Launched by torchrun (see launch.sh). Each rank initializes the NCCL process group,
wraps a tiny model in DistributedDataParallel, and runs a few training steps. The point
is to confirm that cross-node NCCL collectives work over the CX7 fabric and stay in
lockstep. Grow this into real training by swapping the model and data.
"""
import os
import datetime

import torch
import torch.distributed as dist
import torch.nn as nn
from torch.nn.parallel import DistributedDataParallel as DDP


def env_int(name: str, default: int) -> int:
    return int(os.environ.get(name, default))


def main() -> None:
    rank = env_int("RANK", 0)
    world_size = env_int("WORLD_SIZE", 1)
    local_rank = env_int("LOCAL_RANK", 0)

    # NCCL over the RoCE fabric. torchrun sets RANK/WORLD_SIZE/LOCAL_RANK; the NCCL_*
    # env (IB_HCA, SOCKET_IFNAME, GID_INDEX) comes from /etc/nccl.conf via launch.sh.
    dist.init_process_group(
        backend="nccl",
        timeout=datetime.timedelta(seconds=60),
    )

    torch.cuda.set_device(local_rank)
    device = torch.device("cuda", local_rank)

    if rank == 0:
        print(f"[rank0] world_size={world_size} backend={dist.get_backend()} "
              f"device={torch.cuda.get_device_name(local_rank)}", flush=True)

    # Tiny model so the test is fast; the all-reduce of gradients is what we care about.
    model = nn.Sequential(
        nn.Linear(1024, 4096), nn.ReLU(),
        nn.Linear(4096, 4096), nn.ReLU(),
        nn.Linear(4096, 1024),
    ).to(device)
    ddp_model = DDP(model, device_ids=[local_rank])
    opt = torch.optim.SGD(ddp_model.parameters(), lr=1e-3)
    loss_fn = nn.MSELoss()

    steps = env_int("STEPS", 20)
    batch = env_int("BATCH", 64)
    for step in range(steps):
        x = torch.randn(batch, 1024, device=device)
        y = torch.randn(batch, 1024, device=device)
        opt.zero_grad(set_to_none=True)
        out = ddp_model(x)
        loss = loss_fn(out, y)
        loss.backward()   # triggers the cross-node gradient all-reduce over NCCL/RoCE
        opt.step()

        # Reduce the loss to rank 0 so we can see all ranks stayed in lockstep.
        loss_detached = loss.detach()
        dist.all_reduce(loss_detached, op=dist.ReduceOp.AVG)
        if rank == 0 and step % 5 == 0:
            print(f"[rank0] step {step:3d}  avg_loss={loss_detached.item():.4f}", flush=True)

    dist.barrier()
    if rank == 0:
        print("[rank0] all steps completed, ranks stayed in sync. Fabric OK.", flush=True)
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
