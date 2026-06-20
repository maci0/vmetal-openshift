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
  classDef bond fill:#6366f1,stroke:#3730a3,color:#fff,stroke-width:2px;
  classDef untag fill:#10b981,stroke:#065f46,color:#fff,stroke-width:2px;
  classDef vlan fill:#f59e0b,stroke:#92400e,color:#1f2937,stroke-width:2px;
  class e0,e1,e2,e3,e4,e5 nic;
  class b0,b1 bond;
  class m untag;
  class p,s,mig vlan;
```

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

  classDef inst fill:#6366f1,stroke:#3730a3,color:#fff,stroke-width:2px;
  classDef bmc fill:#0ea5e9,stroke:#075985,color:#fff,stroke-width:2px;
  classDef virt fill:#10b981,stroke:#065f46,color:#fff,stroke-width:2px;
  classDef net fill:#f59e0b,stroke:#92400e,color:#1f2937,stroke-width:2px;
  classDef oobc fill:#a855f7,stroke:#6b21a8,color:#fff,stroke-width:2px;
  classDef vm fill:#ef4444,stroke:#7f1d1d,color:#fff,stroke-width:2px;

  class installer inst;
  class sushy bmc;
  class libvirt virt;
  class mnet,tnet net;
  class oobnote oobc;
  class b0,b1 vm;
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

```mermaid
flowchart LR
  subgraph sno["node_count: 1 (SNO)"]
    direction TB
    s0["master+worker<br/>schedulable"]
  end
  subgraph compact["node_count: 3 (compact)"]
    direction TB
    c0["master"]; c1["master"]; c2["master"]
    cn["masters schedulable (auto)"]
  end
  subgraph workers["node_count: 5"]
    direction TB
    w0["master"]; w1["master"]; w2["master"]
    w3["worker"]; w4["worker"]
    wn["masters NOT schedulable<br/>(set masters_schedulable: true to override)"]
  end

  classDef m fill:#6366f1,stroke:#3730a3,color:#fff,stroke-width:2px;
  classDef w fill:#0ea5e9,stroke:#075985,color:#fff,stroke-width:2px;
  classDef note fill:#fef3c7,stroke:#f59e0b,color:#92400e;
  class s0,c0,c1,c2,w0,w1,w2 m;
  class w3,w4 w;
  class cn,wn note;
```

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

  classDef a fill:#10b981,stroke:#065f46,color:#fff,stroke-width:2px;
  classDef b fill:#6366f1,stroke:#3730a3,color:#fff,stroke-width:2px;
  class lint,sc,rc a;
  class e2e,dump,asserts b;
```
