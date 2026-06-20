# Architecture & Flow

<sub>[Home](../README.md) · **Architecture** · [Requirements](requirements.md) · [IPI vs agent](ipi-vs-agent.md) · [Fidelity](fidelity.md) · [Disconnected](disconnected.md) · [Variables](variables.md) · [Examples](examples.md) · [Memory](memory-optimization.md) · [Troubleshooting](troubleshooting.md)</sub>

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

```mermaid
flowchart LR
  subgraph node["Node (virtual baremetal): 6 vNICs"]
    direction TB
    e0["eth0"]; e1["eth1"]
    e2["eth2"]; e3["eth3"]; e4["eth4"]; e5["eth5"]
    subgraph onboard["2 onboard NICs"]
      b0["bond0 · active-backup"]
    end
    subgraph card["4-port data card"]
      b1["bond1 · active-active (LACP-style)"]
    end
    m["machine 10.x.0.10<br/>(untagged, VIP/DHCP/DNS)"]
    p["bond0.20<br/>provisioning"]
    s["bond1.30<br/>storage · MTU 9000"]
    mig["bond1.40<br/>live-migration · MTU 9000"]
  end
  e0 --> b0; e1 --> b0
  e2 --> b1; e3 --> b1; e4 --> b1; e5 --> b1
  b0 --> m
  b0 --> p
  b1 --> s
  b1 --> mig
  classDef nic fill:#e0e7ff,stroke:#3730a3,color:#1f2937;
  classDef bond fill:#6366f1,stroke:#3730a3,color:#fff;
  classDef untag fill:#3e8635,stroke:#1f5419,color:#fff;
  classDef vlan fill:#f0ab00,stroke:#b07e00,color:#1f2937;
  class e0,e1,e2,e3,e4,e5 nic; class b0,b1 bond; class m untag; class p,s,mig vlan;
```

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
and there is no LB. An external HAProxy is only needed for `platform: none`.

> Agent-based note: unlike IPI/metal3, the agent-based installer does **not**
> require a provisioning network, nodes boot the discovery ISO via **virtual
> media over the OOB/Redfish LAN**. The provisioning net is kept for realism and
> can be set to `nics: 0` to drop it.

### LoadBalancer services (MetalLB)

The VIPs cover the API and ingress. For app `Service type=LoadBalancer` (no cloud
LB on baremetal) the lab runs **MetalLB**, in either mode:

```mermaid
flowchart TB
  svc["Service type=LoadBalancer"] --> ctl["MetalLB controller<br/>assigns a pool IP"]
  ctl --> l2box
  ctl --> bgpbox
  subgraph l2box["L2 mode (make metallb)"]
    direction TB
    l2["speaker ARP-owns the IP<br/>pool on machine net (.100-.119)"]
    l2 --> l2n["one elected node answers ARP<br/>(fails over on node loss)"]
  end
  subgraph bgpbox["BGP mode (make metallb-bgp)"]
    direction TB
    bgp["speakers BGP-peer the router<br/>off-link pool 198.51.x.0/24"]
    bgp --> frr["FRR on host (ASN 64513)<br/>zebra installs /32 routes"]
    frr --> ecmp["ECMP multipath across all speakers"]
  end
  classDef ctl fill:#6366f1,stroke:#3730a3,color:#fff;
  classDef l2c fill:#3e8635,stroke:#1f5419,color:#fff;
  classDef bgpc fill:#0066cc,stroke:#004080,color:#fff;
  class svc,ctl ctl; class l2,l2n l2c; class bgp,frr,ecmp bgpc;
  style l2box fill:#f0fdf4,stroke:#d2d2d2;
  style bgpbox fill:#eff6ff,stroke:#d2d2d2;
```

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

```mermaid
flowchart LR
  installer["openshift-install<br/>(agent installer)"]

  subgraph host["KVM Host"]
    sushy["sushy-emulator<br/>Redfish BMC · TLS"]
    libvirt[("libvirtd<br/>qemu:///system")]

    subgraph oob["OOB / BMC LAN (&lt;cluster&gt;-oob)"]
      direction TB
      oobnote["out-of-band · no guest NIC"]
    end

    subgraph data["Data networks"]
      direction TB
      mnet["&lt;cluster&gt;-machine<br/>NAT · DHCP · DNS<br/>api VIP + ingress VIP"]
      tnet["&lt;cluster&gt;-trunk (L2, no IP)<br/>VLAN 30 storage · VLAN 40 migration"]
    end

    subgraph node0["KVM domain: &lt;cluster&gt;-node0 (virtual baremetal)"]
      direction TB
      b0["bond0 · 2× NIC onboard<br/>machine + VLAN 20 prov"]
      b1["bond1 · 4× NIC data card<br/>VLAN 30 storage · VLAN 40 migration"]
    end
  end

  installer == "Redfish HTTPS (OOB):<br/>PowerOn/Off · SetBoot ·<br/>VirtualMedia (discovery ISO)" ==> sushy
  sushy --> oob
  sushy -- "libvirt API:<br/>start/stop · attach CDROM" --> libvirt
  libvirt --> node0
  b0 --- mnet
  b1 --- tnet
  installer -. "resolve api / api-int / *.apps" .-> mnet
  classDef inst fill:#6366f1,stroke:#3730a3,color:#fff;
  classDef bmc fill:#06b6d4,stroke:#0e7490,color:#fff;
  classDef virt fill:#3e8635,stroke:#1f5419,color:#fff;
  classDef net fill:#f0ab00,stroke:#b07e00,color:#1f2937;
  classDef oobc fill:#8476d1,stroke:#5d4fa3,color:#fff;
  classDef vm fill:#ee0000,stroke:#a30000,color:#fff;
  class installer inst; class sushy bmc; class libvirt virt; class mnet,tnet net; class oobnote oobc; class b0,b1 vm;
```

## Install flow

End-to-end, from a bare host to a running cluster.

```mermaid
sequenceDiagram
  autonumber
  actor U as You
  participant B as scripts/bootstrap.sh
  participant OI as openshift-install
  participant A as Ansible
  participant S as sushy-emulator
  participant N as KVM nodes

  U->>B: scripts/bootstrap.sh
  Note over B: venv + ansible-core + collection<br/>self-contained installer + TLS cert

  U->>A: ansible-playbook generate-configs.yml
  A-->>U: clusters/<c>/{install,agent}-config.yaml<br/>(VIPs · roles · bond nmstate)
  U->>OI: agent create image
  OI-->>U: build/discovery_image_<cluster>.iso

  U->>A: ansible-playbook setup.yml
  Note over A: derive topology →<br/>networks · volumes · VMs w/ bonded NICs

  alt boot_via = redfish (default) / IPI
    U->>S: make bmc BMC_ACTION=boot-iso
    S->>N: Redfish VirtualMedia (ISO) + PowerOn
  else boot_via = iso
    A->>N: virsh start (boots the attached ISO, no BMC)
  end

  N->>N: bond up · rendezvous · bootstrap ·<br/>form control plane
  U->>OI: wait-for install-complete
  OI-->>U: kubeconfig + console URL
```

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

### SNO (`node_count: 1`)

Single node, control plane + workloads collapsed onto one box; both VIPs land on
the node IP. Schedulable, so it sits on both buses.

```mermaid
flowchart TB
  subgraph mgmt["Management / OOB"]
    sushy{{"sushy Redfish BMC"}}
  end
  subgraph cluster["OpenShift SNO"]
    n0[["node0<br/>control plane + worker (schedulable)"]]
  end
  subgraph fabric["Network fabric (libvirt bridges)"]
    mach[("machine bus · bond0<br/>API + ingress VIP · DHCP · DNS")]
    data[("data bus · bond1<br/>storage VLAN 30 · migration VLAN 40")]
  end
  store[("persistent storage<br/>ODF / PVs")]
  sushy -. boot .-> n0
  n0 -- bond0 --- mach
  n0 -- bond1 --- data
  n0 --- store
  classDef cp fill:#ee0000,stroke:#a30000,color:#fff;
  classDef bmc fill:#8476d1,stroke:#5d4fa3,color:#fff;
  classDef net fill:#f0ab00,stroke:#b07e00,color:#1f2937;
  classDef stor fill:#3e8635,stroke:#1f5419,color:#fff;
  class n0 cp; class sushy bmc; class mach,data net; class store stor;
  style mgmt fill:#faf0f0,stroke:#d2d2d2;
  style cluster fill:#f5faff,stroke:#d2d2d2;
  style fabric fill:#fffaf0,stroke:#d2d2d2;
```

### SNO + day-2 workers (`node_count: 1`, `day2_workers: N`)

Edge shape: one control-plane node plus workers joined after install with
`make workers-add` (`oc adm node-image`). One etcd, so the control plane stays at
one while compute scales out. Every node runs workloads, so all sit on both buses.

```mermaid
flowchart TB
  subgraph mgmt["Management / OOB"]
    sushy{{"sushy Redfish BMC"}}
  end
  subgraph cluster["OpenShift edge"]
    cp[["node0<br/>control plane + worker"]]
    co[["compute<br/>N × day-2 worker"]]
  end
  subgraph fabric["Network fabric (libvirt bridges)"]
    mach[("machine bus · bond0<br/>API + ingress VIP · DHCP · DNS")]
    data[("data bus · bond1<br/>storage VLAN 30 · migration VLAN 40")]
  end
  store[("persistent storage<br/>ODF / PVs")]
  sushy -. boot .-> cp
  sushy -. "make workers-add" .-> co
  cp -- bond0 --- mach
  co -- bond0 --- mach
  cp -- bond1 --- data
  co -- bond1 --- data
  co --- store
  classDef cp fill:#ee0000,stroke:#a30000,color:#fff;
  classDef wk fill:#0066cc,stroke:#004080,color:#fff;
  classDef bmc fill:#8476d1,stroke:#5d4fa3,color:#fff;
  classDef net fill:#f0ab00,stroke:#b07e00,color:#1f2937;
  classDef stor fill:#3e8635,stroke:#1f5419,color:#fff;
  class cp cp; class co wk; class sushy bmc; class mach,data net; class store stor;
  style mgmt fill:#faf0f0,stroke:#d2d2d2;
  style cluster fill:#f5faff,stroke:#d2d2d2;
  style fabric fill:#fffaf0,stroke:#d2d2d2;
```

### 3-node compact (`node_count: 3`)

Three masters, **schedulable** (auto, no separate workers), so the control plane
also runs workloads and every node sits on both buses.

```mermaid
flowchart TB
  subgraph mgmt["Management / OOB"]
    sushy{{"sushy Redfish BMC"}}
  end
  subgraph cluster["OpenShift compact"]
    cp[["control plane<br/>3 × master (schedulable) + worker"]]
  end
  subgraph fabric["Network fabric (libvirt bridges)"]
    mach[("machine bus · bond0<br/>API + ingress VIP · DHCP · DNS")]
    data[("data bus · bond1<br/>storage VLAN 30 · migration VLAN 40")]
  end
  store[("persistent storage<br/>ODF / PVs")]
  sushy -. boot .-> cp
  cp -- bond0 --- mach
  cp -- bond1 --- data
  cp --- store
  classDef cp fill:#ee0000,stroke:#a30000,color:#fff;
  classDef bmc fill:#8476d1,stroke:#5d4fa3,color:#fff;
  classDef net fill:#f0ab00,stroke:#b07e00,color:#1f2937;
  classDef stor fill:#3e8635,stroke:#1f5419,color:#fff;
  class cp cp; class sushy bmc; class mach,data net; class store stor;
  style mgmt fill:#faf0f0,stroke:#d2d2d2;
  style cluster fill:#f5faff,stroke:#d2d2d2;
  style fabric fill:#fffaf0,stroke:#d2d2d2;
```

### 3 + N workers (`node_count: 3+N`)

Dedicated control plane, **not schedulable**, so it sits on the machine bus only
(`bond0`); the data bus carries **workers only**. The control-plane tier having no
link to the data bus is the role-aware split. Set `masters_schedulable: true` to
override.

```mermaid
flowchart TB
  subgraph mgmt["Management / OOB"]
    sushy{{"sushy Redfish BMC"}}
  end
  subgraph cluster["OpenShift 3 + N"]
    cp[["control plane<br/>3 × master · not schedulable"]]
    co[["compute<br/>N × worker"]]
  end
  subgraph fabric["Network fabric (libvirt bridges)"]
    mach[("machine bus · bond0<br/>API + ingress VIP · DHCP · DNS")]
    data[("data bus · bond1<br/>storage VLAN 30 · migration VLAN 40")]
  end
  store[("persistent storage<br/>ODF / PVs")]
  sushy -. boot .-> cp
  cp -- bond0 --- mach
  co -- bond0 --- mach
  co -- bond1 --- data
  co --- store
  classDef cp fill:#ee0000,stroke:#a30000,color:#fff;
  classDef wk fill:#0066cc,stroke:#004080,color:#fff;
  classDef bmc fill:#8476d1,stroke:#5d4fa3,color:#fff;
  classDef net fill:#f0ab00,stroke:#b07e00,color:#1f2937;
  classDef stor fill:#3e8635,stroke:#1f5419,color:#fff;
  class cp cp; class co wk; class sushy bmc; class mach,data net; class store stor;
  style mgmt fill:#faf0f0,stroke:#d2d2d2;
  style cluster fill:#f5faff,stroke:#d2d2d2;
  style fabric fill:#fffaf0,stroke:#d2d2d2;
```

The control plane in **3 + N** links to the machine bus only, never the data bus
or storage, matching the rendered NICs (masters = 2, workers = 6).

The control-plane tier in **3 + N** connects only to the machine bus, never to the
data bus, exactly as rendered (masters = 2 NICs, workers = 6).

## BMC power management (metal3 → Redfish → libvirt)

Setting `online` on a `BareMetalHost` (or `make bmc`) drives the whole emulated
chain. This is what powered node2 off/on in the lab.

```mermaid
sequenceDiagram
  autonumber
  actor U as Admin
  participant BMO as baremetal-operator
  participant IR as Ironic
  participant S as sushy-emulator (BMC)
  participant L as libvirt
  participant N as node VM

  U->>BMO: oc patch bmh ... online=false
  BMO->>IR: reconcile desired power
  IR->>S: Redfish ComputerSystem.Reset (ForceOff/Graceful)
  S->>L: virsh destroy / shutdown
  L->>N: power off
  Note over BMO,N: online=true reverses it (PowerOn). Status: poweredOn + state.
  Note over U: If the BMO/webhook pod was on that node,<br/>recover out-of-band via the BMC (curl Redfish / make bmc).
```

## Test layers

```mermaid
flowchart TD
  lint["scripts/lint.sh<br/>offline · no libvirt"] --> e2e["scripts/e2e.sh<br/>live provision + assert + teardown"]
  subgraph offline["Offline (CI-safe)"]
    sc["ansible --syntax-check"]
    rc["render_check.py<br/>xmllint + unique subnet/bridge/MAC"]
  end
  subgraph live["Live"]
    dump["dump-topology.yml → JSON oracle"]
    asserts["virsh: nets active · domains running ·<br/>NIC counts (bonding) · DNS · Redfish"]
  end
  lint --- offline
  e2e --- live

```
