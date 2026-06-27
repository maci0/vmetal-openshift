# Architecture & Flow

<sub>[Home](../README.md) · **Architecture** · [Requirements](requirements.md) · [IPI vs agent](ipi-vs-agent.md) · [Fidelity](fidelity.md) · [Disconnected](disconnected.md) · [Variables](variables.md) · [Examples](examples.md) · [Memory](memory-optimization.md) · [Virtualization](virtualization.md) · [Resilience](resilience.md) · [Cloud](cloud.md) · [Troubleshooting](troubleshooting.md)</sub>

How the pieces fit: per-cluster networks, the node NIC/bond/VLAN layout, the
sushy Redfish emulation, the install flow, cluster topologies, BMC power
management, and the test layers. Diagrams render in light and dark mode.

## Networks

Each cluster gets a block of isolated libvirt networks, one per role (derived,
never hardcoded, see `ansible/group_vars/all.yml`):

| Network | Subnet (cluster `{c}`) | Carried on | Purpose |
|---------|------------------------|-----------|---------|
| `machine` | `10.{c}.0.0/24` | **bond0** (2 NICs onboard, untagged, NAT) | API + ingress VIP, DHCP, DNS, rendezvous |
| `provisioning` | `172.22.{c}.0/24` | **bond0.20** (VLAN, onboard) | optional PXE (metal3 range) |
| `oob` | `172.16.{c}.0/24` | host only (no guest NIC) | BMC / Redfish management LAN |
| `storage` | `10.{c}.10.0/24` | **bond1.30** (VLAN, MTU 9000) | storage (ODF/RWX) |
| `migration` | `10.{c}.20.0/24` | **bond1.40** (VLAN, MTU 9000) | VM live-migration (CNV) |

Diverse RFC1918 blocks per network (production-like), not one flat `192.168/16`.
The default `nic_layout` mirrors an OpenShift Virtualization reference design: a
2-NIC onboard bond (machine + provisioning VLAN) plus a 4-port data card
(`bond1`, active-active) carrying storage + live-migration VLANs. Cluster 0 →
`10.0.0.0/24`, cluster 1 → `10.1.0.0/24`, etc.

The data-plane card (`bond1`, `roles: [worker]`) is attached only to nodes that
run workloads: workers, and schedulable control-plane nodes (compact / SNO).
**Non-schedulable control-plane nodes get only `bond0`** (machine + provisioning),
no storage/live-migration NICs, matching a real split design.

### Node NIC layout (default `nic_layout`)

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="diagrams/architecture-01-dark.svg">
    <img alt="Node NIC layout (default nic_layout) diagram" src="diagrams/architecture-01.svg">
  </picture>
</p>

This is the full layout (6 vNICs), used by workers and schedulable control-plane
nodes. Non-schedulable control-plane nodes get only `bond0` (eth0/eth1), no `bond1`
storage/migration card.

### VIPs & load balancing

Two VIPs on the machine net, baremetal-style:

* **API VIP** (`api_vip_offset`), `api` / `api-int` (6443, 22623)
* **Ingress VIP** (`ingress_vip_offset`), `*.apps` (80, 443)

With `platform: baremetal` (what the agent-based installer uses on-prem),
OpenShift runs its **own** load balancer for these, `keepalived` floats each VIP
to a live node, `HAProxy` balances across the control plane / ingress nodes. No
external LB appliance. For single-node (SNO) both VIPs collapse onto the node IP
and there is no LB. An external HAProxy is only needed for `platform: none`
(`upi`); see [ipi-vs-agent.md](ipi-vs-agent.md#why-platform-none-and-not-baremetal)
for the `none` vs `baremetal` comparison.

> Agent-based note: unlike IPI/metal3, the agent-based installer does **not**
> require a provisioning network, nodes boot the discovery ISO via **virtual
> media over the OOB/Redfish LAN**. The provisioning net is kept for realism and
> can be set to `nics: 0` to drop it.

### LoadBalancer services (MetalLB)

The VIPs cover the API and ingress. For app `Service type=LoadBalancer` (no cloud
LB on baremetal) the lab runs **MetalLB**, in either mode:

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="diagrams/architecture-02-dark.svg">
    <img alt="LoadBalancer services (MetalLB) diagram" src="diagrams/architecture-02.svg">
  </picture>
</p>

L2 needs no router (ARP, single owner). BGP uses an off-link pool so reachability
*requires* the BGP route, and gets ECMP load-spreading + fast failover.

`make metallb-bgp` starts the FRR peer (podman or docker) and applies the BGP CRs;
`make metallb-bgp-down` stops it. Verify the path:

```bash
docker exec vmetal-frr-<cluster> vtysh -c 'show bgp summary'        # speakers as dynamic neighbours, Established
docker exec vmetal-frr-<cluster> vtysh -c 'show bgp ipv4 unicast'   # the LB /32, multipath
ip route show 198.51.100.0                                          # zebra-installed, N ECMP next-hops
curl http://<assigned-LB-IP>:8080                                   # reachable only via the BGP route
```

Tested on a 3 + 2 cluster: five eBGP sessions, the LB `/32` advertised by every
node with five ECMP next-hops in the host kernel, and the off-link IP reachable.

## Sushy Redfish emulation

`openshift-install` thinks it is driving real baremetal BMCs over the **OOB LAN**.
`sushy-emulator` exposes a **Redfish API** (TLS) and translates power /
virtual-media calls into **libvirt** operations. The KVM domains *are* the
"baremetal" nodes, each with **bonded NICs** on the data networks.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="diagrams/architecture-03-dark.svg">
    <img alt="Sushy Redfish emulation diagram" src="diagrams/architecture-03.svg">
  </picture>
</p>

## Install flow

End-to-end, from a bare host to a running cluster (the **agent** path shown; the
IPI metal3/bootstrap-VM and UPI PXE/HAProxy paths are in
[IPI vs agent](ipi-vs-agent.md)).

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="diagrams/architecture-04-dark.svg">
    <img alt="Install flow diagram" src="diagrams/architecture-04.svg">
  </picture>
</p>

## Cluster topologies

Four supported shapes, drawn as layered reference architectures: a **management /
OOB zone** (sushy Redfish, the BMC LAN), the **OpenShift cluster** (control-plane
and compute tiers), and the **network fabric** as two bridge buses. `bond0`
carries the machine net (+ provisioning VLAN); `bond1` carries the data VLANs
(storage + migration) and is present **only on nodes that run workloads**, so a
node with no link to the data bus has no storage/migration NIC.

Shape + colour key: hexagon = management/BMC (purple), stacked box (subroutine) =
a node tier / replica set (red = control plane, blue = compute), cylinders =
network buses (amber: `bond0` machine, `bond1` data) and persistent storage
(green). Zones are tinted subgraphs.

### SNO (`control_plane: 1`, `workers: 0`)

Single node, control plane + workloads collapsed onto one box; both VIPs land on
the node IP. Schedulable, so it sits on both buses.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="diagrams/architecture-05-dark.svg">
    <img alt="SNO (control_plane: 1, workers: 0) diagram" src="diagrams/architecture-05.svg">
  </picture>
</p>

### SNO + day-2 workers (`control_plane: 1`, `workers: 0`, `day2_workers: N`)

Edge shape: one control-plane node plus workers joined after install with
`make workers-add` (`oc adm node-image`). One etcd, so the control plane stays at
one while compute scales out. Every node runs workloads, so all sit on both buses.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="diagrams/architecture-06-dark.svg">
    <img alt="SNO + day-2 workers (control_plane: 1, workers: 0, day2_workers: N) diagram" src="diagrams/architecture-06.svg">
  </picture>
</p>

### 3-node compact (`control_plane: 3`, `workers: 0`)

Three masters, **schedulable** (auto, no separate workers), so the control plane
also runs workloads and every node sits on both buses.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="diagrams/architecture-07-dark.svg">
    <img alt="3-node compact (control_plane: 3, workers: 0) diagram" src="diagrams/architecture-07.svg">
  </picture>
</p>

### 3 + N workers (`control_plane: 3`, `workers: N`)

Dedicated control plane, **not schedulable**, so it sits on the machine bus only
(`bond0`); the data bus carries **workers only**. The control-plane tier having no
link to the data bus is the role-aware split. Set `masters_schedulable: true` to
override.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="diagrams/architecture-08-dark.svg">
    <img alt="3 + N workers (control_plane: 3, workers: N) diagram" src="diagrams/architecture-08.svg">
  </picture>
</p>

The control plane in **3 + N** links to the machine bus only, never the data bus
or storage, matching the rendered NICs (masters = 2, workers = 6).

## BMC power management (metal3 → Redfish → libvirt)

Setting `online` on a `BareMetalHost` (or `make bmc`) drives the whole emulated
chain. This is what powered node2 off/on in the lab.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="diagrams/architecture-09-dark.svg">
    <img alt="BMC power management (metal3 → Redfish → libvirt) diagram" src="diagrams/architecture-09.svg">
  </picture>
</p>

## Test layers

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="diagrams/architecture-10-dark.svg">
    <img alt="Test layers diagram" src="diagrams/architecture-10.svg">
  </picture>
</p>
