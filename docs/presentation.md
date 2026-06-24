---
marp: true
theme: default
paginate: true
size: 16:9
header: 'vmetal-openshift'
footer: 'Virtual baremetal OpenShift on one host'
style: |
  section { font-size: 26px; }
  section.lead h1 { font-size: 56px; }
  code { font-size: 0.85em; }
  table { font-size: 0.8em; }
  h1, h2 { color: #c00; }
---

<!-- _class: lead -->
<!-- _paginate: false -->

# vmetal-openshift

### Virtual baremetal OpenShift clusters on a single KVM host

Data-driven Ansible topology. No hardware required.

---

## The pitch

A single-host lab that deploys **virtual baremetal OpenShift** on libvirt/KVM.

- Emulates production baremetal features on one Linux machine
- Tests agent-based **and** IPI installs with realistic networking
- Minimal, reproducible, fully configurable
- Ideal for dev, CI, edge scenarios, and learning advanced OCP features

> One sentence: virtual baremetal OpenShift, fully data-driven, from one topology file.

---

## Why it matters

- **No hardware investment.** Nodes are KVM VMs, not physical servers.
- **Reproducible.** Everything derived from one topology, version-controlled.
- **Realistic.** Bonded NICs, VLAN trunks, jumbo MTU, Redfish BMC, VIPs, real BGP.
- **Portable.** Runs on a workstation or cloud nested virt (AWS/GCP/Azure).
- **Complete.** Day-2 storage, load balancing, and virtualization included.

---

## Architecture

**Platform:** libvirt/KVM nested virtualization on a single Linux host.

- **Redfish BMC emulation** (sushy-tools): TLS Redfish API → libvirt power/virtual-media
- **Bonded NICs + VLAN trunks:**
  - `bond0`: 2 onboard NICs (machine net + provisioning VLAN, active-backup)
  - `bond1`: 4-port active-active trunk (storage + live-migration, MTU 9000)
- **Two VIPs** (api/ingress): keepalived + HAProxy
- **libvirt split-DNS** for cluster domain resolution

---

## Real BGP peering

Not a mock. `make metallb-bgp` runs an **FRR router on the host** that peers with the MetalLB speaker on every node.

- **eBGP session**: speakers AS **64512** ↔ host FRR AS **64513**
- **Off-link pool proves the route**: LoadBalancer pool is TEST-NET-2 (`198.51.x.0/24`), reachable *only* via the BGP-learned path, so a working `curl` proves the advertisement
- **ECMP multipath**: `zebra` installs the learned `/32`s into the host kernel with equal-cost next-hops across all speakers; drain a node, only its next-hop withdraws

Plain L2/ARP (`make metallb`) too, but BGP is the one that exercises real routing.

---

## Install modes

Both derived from the **same topology**.

| Mode | Driver | Boot |
|------|--------|------|
| **agent** (default) | openshift-install agent | Discovery ISO via Redfish virtual media |
| **IPI** | metal3 / Ironic | Redfish-driven, `platform: baremetal` |

Switch by changing config, not by rewriting the lab.

---

## Supported topologies

| Config | Masters | Workers | Notes |
|--------|---------|---------|-------|
| **SNO** | 1 | 0 | `platform: none`, VIPs collapse to node IP |
| **Compact** | 3 | 0 | `platform: baremetal`, VIPs + HAProxy |
| **Dedicated workers** | 3 | 2+ | workers run workloads only |
| **Edge / SNO + day-2** | 1 | 2 (post-install) | single control plane + day-2 join |

Default lab `cluster0` = **SNO + 2 day-2 workers** (edge pattern).

---

## Tech stack

| Tool | Role |
|------|------|
| libvirt + qemu-kvm | VM host (the nodes) |
| Ansible | Derives all networking/configs from one topology |
| sushy-tools | Redfish BMC emulation |
| nmstate | Bond/VLAN static config |
| metal3-io | Day-2 baremetal mgmt (IPI via Ironic) |
| MetalLB | LoadBalancer pool (L2 or BGP+FRR) |
| LVMS / NFS-Ganesha | RWO + RWX storage |
| OpenShift Virtualization | VMs on the cluster, live migration |

---

## Day-2 operators

Layer features after install, each independent:

- **MetalLB**: LoadBalancer services (L2 ARP, or BGP+FRR ECMP multipath)
- **LVMS**: local RWO StorageClass, auto-selects unused disks per node
- **NFS-Ganesha**: host appliance serving RWX (NFSv4)
- **CNV**: OpenShift Virtualization, live migration on dedicated VLAN
- **Day-2 workers**: agent node-image join, scale up post-install

---

## Memory optimization

VMs run concurrently; RAM does not oversubscribe. So the host gets tuned.

- **KSM** dedup identical RHCOS pages; **zram** compress cold pages
- **cgroup tuning** via `optimize-host.sh`
- Measured per-VM via cgroup `memory.current` (`make bench`)

Measured, 3 masters + 2 workers (92 GiB allocated):

| setting | footprint | saved | CPU |
|---------|----------:|------:|----:|
| baseline | 85.9 GiB | : | 24.2M |
| **KSM** | **46.2 GiB** | **39.7 GiB (~46%)** | 24.4M |
| zram (zstd) | 53.5 GiB | 32.4 GiB | 24.6M |
| KSM + zram (zstd) | 49.2 GiB | 36.8 GiB | 24.4M |

KSM alone wins for identical nodes; throughput flat across all.

---

## KSM vs zram: complementary

Two mechanisms, opposite workloads. Not competing.

| workload | KSM (dedup) | zram (compress) |
|----------|------------:|----------------:|
| identical RHCOS nodes (`make bench`) | **40 GiB** reclaimed | ~0 |
| unique compressible pages (`make bench-zram`) | 0 | **3.8 GiB** reclaimed |

- **KSM** reclaims *identical* pages: best for same-image nodes.
- **zram** reclaims *compressible* pages: best for diverse guests or overcommit.
- Run both: little cost, covers both shapes.

---

## Quick start

```bash
make check                      # verify host prerequisites
make bootstrap                  # venv, sushy-tools, ansible, installer, cert
make sushy-install              # start Redfish BMC (systemd --user)
make install CLUSTER=cluster0   # ISO -> provision -> boot -> wait
make status                     # nodes, operators, BMCs
make creds                      # console URL + kubeadmin password
make down                       # tear it all down
```

Cluster up in ~30-40 min (size-dependent; 3 masters + 2 workers measured ~38 min).

---

## Configuration: edit once

Everything derives from **`ansible/group_vars/all.yml`**.

```yaml
clusters:        # list of clusters
control_plane:   # 1 (SNO) or 3 (HA)
workers:         # N worker nodes (default 0)
masters_schedulable:          # auto | true | false
day2_workers:    # N extra workers, joined post-install
```

Subnets, MACs, VIPs, node roles, replicas, BMC URLs: **all derived**.

---

## Testing & validation

- `make lint` (offline): ansible-lint (production), yamllint, shellcheck, render
- `make e2e` (live): provision, assert, teardown end-to-end
- `make bench`: memory optimization benchmark
- Resilience guide: bond failure, etcd quorum, VIP failover, node drain, live migration

---

<!-- _class: lead -->

# Summary

- Virtual baremetal OpenShift on **one** KVM host
- Agent + IPI from a **single** data-driven topology
- Realistic networking: bonds, VLANs, Redfish, VIPs
- Full day-2: MetalLB, LVMS, NFS, CNV
- `make bootstrap && make install` → cluster

### Questions?
