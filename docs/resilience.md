# Resilience testing

<sub>[Home](../README.md) · [Architecture](architecture.md) · [Requirements](requirements.md) · [IPI vs agent](ipi-vs-agent.md) · [Fidelity](fidelity.md) · [Disconnected](disconnected.md) · [Variables](variables.md) · [Examples](examples.md) · [Memory](memory-optimization.md) · [Virtualization](virtualization.md) · **Resilience** · [Cloud](cloud.md) · [Troubleshooting](troubleshooting.md)</sub>

Failure tests that exercise the baremetal-fidelity bits: bonded NICs, the VIP
load balancer, etcd quorum, and node loss. The KVM host stands in for the
hardware, so a "pulled cable" is a libvirt link toggle and a "dead server" is a
`virsh destroy`. All tests below are recoverable.

> These drills assume a 3 control-plane + 2 worker `cluster0` (node0-node4). The
> default `cluster0` is SNO + 2 day-2 workers (one master), so the etcd/master
> drills do not apply and `node3`/`node4` do not exist. Switch to the
> `control_plane: 3, workers: 2` variant (commented in `group_vars/all.yml`) first.

Set once:

```bash
export KUBECONFIG=clusters/cluster0/auth/kubeconfig
OC=build/openshift-install/oc   # the bundled client; the system oc works for most of this
V() { virsh -c qemu:///system "$@"; }
```

Node MACs are derived: `52:54:00:<cluster-index>:<bond*16+nic>:<node-octet>`, node
N is octet `10+N`. So for cluster0 (index 0) node4's bond0 NIC0 =
`52:54:00:00:00:0e`, NIC1 = `52:54:00:00:01:0e`.

## 1. Bond failover (active-backup, bond0)

Pull the active slave and confirm the bond fails over to the standby with no node
impact.

```bash
# baseline: which slave is active
ssh core@10.0.0.14 'cat /proc/net/bonding/bond0 | grep -E "Currently Active|MII Status"'

# pull the active NIC (host-side link down)
V domif-setlink cluster0-node4 52:54:00:00:00:0e down

# expect: Currently Active Slave flips to eth1, bond MII still up, node Ready
ssh core@10.0.0.14 'cat /proc/net/bonding/bond0 | grep -E "Currently Active|Slave Interface|MII Status"'
$OC get node cluster0-node4 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'

# restore
V domif-setlink cluster0-node4 52:54:00:00:00:0e up
```

Pass: active slave changes, node stays `Ready`, SSH/API never drop. The data bond
(`bond1`, balance-tlb) survives a slave loss the same way; with 4 NICs it also
keeps transmitting on the rest.

## 2. MetalLB L2 VIP failover

In L2 mode one elected node ARP-owns each LoadBalancer IP. Kill that node and the
IP must move.

```bash
make metallb CLUSTER=cluster0      # ensure L2 mode is active
# expose a Service and find its IP
$OC new-project lbtest
$OC create deployment web --image=registry.access.redhat.com/ubi9/httpd-24
$OC expose deployment web --type=LoadBalancer --port=8080 --target-port=8080
IP=$($OC get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# who owns the ARP entry, on the host
ip neigh show "$IP"                 # lladdr = a node MAC (e.g. ...:0e = node4)

# kill that node
V destroy cluster0-node4

# within ~10-20s another speaker takes over; the curl recovers
for i in $(seq 1 30); do curl -s -o /dev/null -w "%{http_code}\n" --max-time 3 "http://$IP:8080/" ; sleep 2; done

# recover
V start cluster0-node4
```

Pass: `curl` returns to a non-000 code after the failover, the ARP `lladdr`
changes to a surviving node. (BGP mode fails over differently: routes are
withdrawn and ECMP re-spreads, see [architecture](architecture.md).)

## 3. etcd quorum (control-plane loss)

Three control-plane nodes tolerate one failure (quorum 2/3). Kill one master and
confirm the API stays up.

```bash
$OC get nodes -l node-role.kubernetes.io/control-plane

# kill one master
V destroy cluster0-node0

# API must keep serving on the remaining two
$OC get nodes        # node0 goes NotReady, the rest keep working
$OC -n openshift-etcd get pods -l app=etcd   # 2 running, quorum held

# recover: the node rejoins and etcd re-syncs
V start cluster0-node0
$OC get nodes -w     # node0 returns to Ready
```

Pass: `oc` keeps responding throughout (quorum held); node0 returns to `Ready`
and etcd reports 3 healthy members again. Killing a **second** master would lose
quorum and freeze the API, the point of three.

## 4. Node drain + reboot (graceful)

```bash
$OC adm cordon cluster0-node3
$OC adm drain cluster0-node3 --ignore-daemonsets --delete-emptydir-data --force
V reboot cluster0-node3            # or: V destroy && V start
$OC adm uncordon cluster0-node3
```

Pass: workloads reschedule off node3, it reboots, rejoins `Ready`, uncordon
restores scheduling. With OpenShift Virtualization, VMs on the node should
**live-migrate off first** if they are on RWX storage (`make nfs`); RWO-backed
VMs (`lvms-vg1`) cannot migrate and are restarted elsewhere only if their PVC
allows it.

## Notes

* `virsh destroy` is a hard power-off (pulls the plug); `virsh shutdown` is an ACPI
  soft stop. Use `destroy` to simulate a crash.
* The optimized host (KSM + zram) keeps merged pages across a VM reboot but frees
  them on `virsh destroy` + `start` (a fresh qemu), see [memory](memory-optimization.md).
* After any `virsh destroy`/`start` of a node, give cluster operators a minute to
  settle (`oc get co`) before the next test.
