# Kubernetes on the GB10 cluster

Run multi-node GPU + RDMA workloads on Kubernetes. This is heavier than Slurm and only
worth it if the cluster is part of a wider k8s estate or you want long-lived, restartable
services. These manifests are examples; adapt names, images, and resource names to your
cluster.

## Prerequisites

1. **NVIDIA GPU Operator**: exposes each node's Blackwell GPU as the `nvidia.com/gpu`
   resource and installs the driver/toolkit/DCGM.
2. **NVIDIA Network Operator**: exposes the ConnectX-7 for RDMA in pods. Install it with the
   values in `network-operator-values.yaml`, which enable the RDMA shared device plugin and
   a secondary (macvlan) network on the CX7 so pods get an interface on the fabric subnet.
3. For the NCCL test: the **Kubeflow MPI Operator** (provides the `MPIJob` CRD).

## What each manifest is

| File | Purpose |
| --- | --- |
| `network-operator-values.yaml` | Helm values: RDMA shared device plugin + CX7 macvlan network |
| `nccl-test-mpijob.yaml` | MPIJob running NCCL all_reduce_perf across worker pods over RoCE |
| `vllm-statefulset.yaml` | Multi-node vLLM via a Ray head + worker StatefulSet |

## Fabric access from pods

Two ways a pod reaches the RoCE fabric:

- **Secondary network (recommended)**: the Network Operator attaches a macvlan interface on
  the CX7 to the pod (annotation `k8s.v1.cni.cncf.io/networks`), and the pod requests the
  RDMA resource (`rdma/rdma_shared_device_a`). NCCL is pointed at that interface.
- **hostNetwork**: simpler, the pod shares the node's network namespace and sees the fabric
  netdev directly. Fine for a dedicated cluster; less isolation.

The manifests here use the RDMA resource plus the secondary network. Set
`NCCL_SOCKET_IFNAME` / `NCCL_IB_HCA` in the pod env to the in-pod fabric interface and the
CX7 device, mirroring `docs/04-roce-tuning.md`.

## Run the NCCL test

```bash
kubectl apply -f nccl-test-mpijob.yaml
kubectl logs -f job/gb10-nccl-test-launcher    # watch the all_reduce_perf busbw
```

Confirm the log shows `NET/IB` (RDMA over CX7), not `NET/Socket`.
