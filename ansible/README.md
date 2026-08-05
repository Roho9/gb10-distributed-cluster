# Ansible: fabric configuration for the GB10 cluster

Configures the CX7 RoCE fabric on every node. Ansible connects over the **management**
network (the `ansible_host` in the inventory), never over the fabric it is configuring.

## Layout

```
inventory.example.ini   Copy to inventory.ini and fill in your nodes
group_vars/all.yml       Cluster-wide fabric / RoCE / NCCL settings
site.yml                 Top-level playbook: runs network -> roce -> nccl
roles/
  network/               Static fabric IP, MTU 9000, /etc/hosts
  roce/                  RoCE v2, PFC on the RoCE priority, DSCP TC, ECN
  nccl/                  Renders /etc/nccl.conf
```

## Use

```bash
cp inventory.example.ini inventory.ini
$EDITOR inventory.ini        # management IPs, fabric IPs, iface + rdma_dev per node
$EDITOR group_vars/all.yml   # gid index, priorities, debug level

ansible -i inventory.ini gb10 -m ping     # confirm management reachability
ansible-playbook -i inventory.ini site.yml --check   # dry run
ansible-playbook -i inventory.ini site.yml           # apply
```

## Notes

- Per-node values (`fabric_ip`, `fabric_iface`, `rdma_dev`) live in the inventory because
  they can differ per node. Cluster-wide values live in `group_vars/all.yml`.
- The `roce` role is deliberately non-fatal on knobs that vary by OFED/DOCA version: it
  reports what it could not set instead of aborting. Read its debug output and apply any
  missing knob by hand per `docs/04-roce-tuning.md`.
- After a run, validate from the control host with `scripts/validate-fabric.sh` and
  `scripts/run-nccl-test.sh`. The playbook does not validate; validation is a separate,
  explicit step.
