# Slurm on the GB10 cluster

Minimal Slurm setup to place multi-node jobs on the cluster and launch them over the RoCE
fabric. These files are examples: adapt node names, counts, and paths to your site.

## Files

- `slurm.conf.example`: controller + node/partition definitions, one GPU GRES per node.
- `gres.conf.example`: maps the GPU GRES to the device on each node.
- `train.sbatch`: launch the PyTorch DDP job across nodes with torchrun over RoCE.
- `vllm.sbatch`: launch multi-node vLLM serving via Ray over RoCE.

## Setup outline

1. Install Slurm (slurmctld on a controller, slurmd on every GB10 node).
2. Copy `slurm.conf.example` to `/etc/slurm/slurm.conf` on all nodes and edit the
   `NodeName`/`PartitionName` and controller host. Copy `gres.conf.example` to
   `/etc/slurm/gres.conf`.
3. Start `slurmctld` on the controller and `slurmd` on the nodes; confirm with `sinfo`.
4. Submit:

   ```bash
   sbatch orchestration/slurm/train.sbatch
   sbatch orchestration/slurm/vllm.sbatch
   ```

## Why GRES and not just node count

Declaring the GPU as a GRES lets Slurm schedule on GPUs and bind ranks correctly. With one
Blackwell GPU per GB10 node, the natural request is one GPU per node and as many nodes as
the job needs, which the sbatch scripts express with `--nodes` and `--gres=gpu:1`.

## Fabric note

The sbatch scripts set `NCCL_SOCKET_IFNAME` / `NCCL_IB_HCA` (from `/etc/nccl.conf`) and use
each node's fabric hostname, so all collective traffic uses the CX7 fabric, not the
management network. Confirm with `NCCL_DEBUG=INFO` in the job output showing `NET/IB`.
