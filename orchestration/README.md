# Orchestration

Submit jobs to the cluster instead of hand-launching a process on every node. Two options,
pick one:

- **Slurm** (`slurm/`): the standard HPC scheduler. Lightest weight for a single-rack GB10
  cluster. You `sbatch` a job and Slurm places it across nodes; the batch script launches
  torchrun or vLLM with the RoCE NCCL env. Best fit if this is primarily a batch
  training/inference cluster.
- **Kubernetes** (`kubernetes/`): if the cluster is part of a wider k8s estate or you want
  long-running services and autoscaling. Needs the NVIDIA GPU Operator and Network Operator
  so pods can request GPUs and RDMA devices. Heavier, but integrates with k8s tooling.

Both still rely on everything in `docs/` being correct: the RoCE fabric, `/etc/nccl.conf`,
and fabric-resolvable hostnames. Orchestration only decides where processes run, not how
the fabric works.

## Which to choose

| You want | Use |
| --- | --- |
| Batch training / inference jobs, minimal moving parts | Slurm |
| Multi-node LLM serving as a long-lived, restartable service | Kubernetes |
| Fair-share queueing across users on a shared rack | Slurm |
| Integration with existing k8s CI/CD, ingress, autoscaling | Kubernetes |

## Common requirement: NCCL env reaches the workers

However you launch, the workers must inherit the RoCE NCCL settings
(`docs/04-roce-tuning.md`). Slurm inherits `/etc/nccl.conf` and the sbatch scripts export
the key variables explicitly. On Kubernetes the manifests set them as env and request the
RDMA resource so the CX7 is visible in the pod.
