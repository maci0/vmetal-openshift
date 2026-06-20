# Storage & OpenShift Virtualization

<sub>[Home](../README.md) · [Architecture](architecture.md) · [Requirements](requirements.md) · [IPI vs agent](ipi-vs-agent.md) · [Fidelity](fidelity.md) · [Disconnected](disconnected.md) · [Variables](variables.md) · [Examples](examples.md) · [Memory](memory-optimization.md) · **Virtualization** · [Resilience](resilience.md) · [Troubleshooting](troubleshooting.md)</sub>

The lab exists to run **OpenShift Virtualization (CNV)** close to a baremetal
deployment: nested virt, bonded data networks, dedicated storage + live-migration
VLANs. This is the day-2 stack that uses them.

## Storage

Two backends, both day-2 and independent:

| | `make lvms` | `make nfs` |
|---|---|---|
| Backend | LVM Storage operator on each worker's `vdc` | host NFS-Ganesha appliance + in-cluster nfs-subdir provisioner |
| StorageClass | `lvms-vg1` (default) | `nfs-rwx` |
| Access | **RWO** (node-local) | **RWX** (shared) |
| Live migration | no (disk is node-bound) | **yes** (shared) |
| Backing | the worker's dedicated 512G `vdc` | a disk-backed dir on the host (`build/nfs-export/`) |

Workers carry a dedicated empty disk (`vdc`, `worker_disks` in group_vars) so
storage stays off the OS/data disks. The NFS path treats the **KVM host as a
storage appliance** (like the FRR BGP peer): a Ganesha container exports a dir on
the machine net, and `nfs-subdir-external-provisioner` turns it into the `nfs-rwx`
StorageClass. RWX is what makes CNV VMs live-migratable.

```bash
make lvms CLUSTER=cluster0    # RWO  -> lvms-vg1 (default)
make nfs  CLUSTER=cluster0    # RWX  -> nfs-rwx (host appliance)
make nfs-down CLUSTER=cluster0
```

## OpenShift Virtualization (CNV)

```bash
make virt CLUSTER=cluster0    # kubevirt-hyperconverged operator + HyperConverged
```

Needs nested virt (the lab's host-passthrough CPUs expose `/dev/kvm` + `vmx`/`svm`
in the guests; `make check` warns if host nesting is off). The HyperConverged CR
deploys KubeVirt + CDI.

### Dedicated live-migration network (opt-in)

By default migration runs on the machine net (validated, zero downtime). Red Hat
recommends isolating migration traffic on its own VLAN; this lab builds one
(`bond1.40`, isolated, jumbo 9000) and can pin migration to it. Enable with
`cnv_migration_network: true` (group_vars): `make virt` then applies an **ipvlan**
`NetworkAttachmentDefinition` (`migration`, on the migration VLAN, jumbo MTU,
cluster-wide **whereabouts** IPAM) and sets
`HyperConverged.spec.liveMigrationConfig.network: migration`.

ipvlan (not macvlan) is used so the migration NIC shares the parent MAC and is not
dropped by the guest vNIC's MAC filtering. The NAD must also exist in the VM's
namespace. **Caveat:** in this nested setup (ipvlan over a balance-tlb bond over a
libvirt L2 trunk) the dedicated network is finicky and can fail the migration
stream, so it ships **off**; on real hardware the pattern is standard. The default
(machine-net) path is what the lab validates.

### Live-migration test

```bash
# a VM with an RWX disk (so it can migrate) + evictionStrategy: LiveMigrate
oc apply -f - <<'YAML'
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata: {name: testvm, namespace: vmtest}
spec:
  running: true
  template:
    spec:
      evictionStrategy: LiveMigrate
      domain:
        resources: {requests: {memory: 512Mi}}
        devices: {disks: [{name: cd, disk: {bus: virtio}}, {name: data, disk: {bus: virtio}}]}
      volumes:
        - {name: cd, containerDisk: {image: quay.io/kubevirt/cirros-container-disk-demo}}
        - {name: data, dataVolume: {name: testvm-data}}
  dataVolumeTemplates:
    - metadata: {name: testvm-data}
      spec:
        storage: {accessModes: [ReadWriteMany], storageClassName: nfs-rwx, resources: {requests: {storage: 1Gi}}}
        source: {blank: {}}
YAML

# trigger live migration and watch the node change with phase staying Running
oc apply -f - <<'YAML'
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata: {name: m1, namespace: vmtest}
spec: {vmiName: testvm}
YAML
oc -n vmtest get vmi testvm -o jsonpath='{.status.phase} {.status.nodeName}{"\n"}'
```

Validated on the 3 + 2 cluster: the VM live-migrated worker-to-worker, phase stayed
`Running` (zero downtime), with the RWX disk on the host NFS appliance. See
[resilience](resilience.md) for draining a node (VMs migrate off automatically).
