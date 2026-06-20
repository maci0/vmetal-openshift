# Variables reference

<sub>[Home](../README.md) · [Architecture](architecture.md) · [Requirements](requirements.md) · [IPI vs agent](ipi-vs-agent.md) · [Fidelity](fidelity.md) · [Disconnected](disconnected.md) · **Variables** · [Examples](examples.md) · [Memory](memory-optimization.md) · [Resilience](resilience.md) · [Troubleshooting](troubleshooting.md)</sub>

All knobs live in `ansible/group_vars/all.yml`. Most installs only touch the
`clusters` list. Everything else has a sensible default and is derived.

## Connection / firmware

| Variable | Default | Meaning |
|----------|---------|---------|
| `libvirt_uri` | `qemu:///system` | libvirt connection |
| `storage_pool` | `default` | pool for node volumes |
| `images_dir` | `/var/lib/libvirt/images` | where qcow2 disks live |
| `ovmf_code` / `ovmf_vars` | `""` (auto-detect) | pin OVMF firmware paths |

## Addressing scheme

| Variable | Default | Meaning |
|----------|---------|---------|
| `base_domain` | `ocp.lab` | cluster base domain (override per cluster) |
| `node_ip_offset` | `10` | first node host octet (node0 = .10) |
| `api_vip_offset` | `5` | API VIP host octet |
| `ingress_vip_offset` | `6` | ingress VIP host octet |
| `dhcp_pool_start` / `dhcp_pool_end` | `128` / `254` | dynamic DHCP range |
| `mac_oui` | `52:54:00` | OUI for derived MACs |
| `networks` | machine/oob/provisioning/trunk/storage/migration | map of name -> {cidr, kind, dns, mtu}; `kind` is nat/isolated/l2/vlan |
| `nic_layout` | bond0 (machine + provisioning VLAN) + bond1 (trunk: storage + migration VLANs) | bonds: `nics`, `mode`, an untagged `network` and/or `trunk`, tagged `vlans`, optional `roles:` (which node roles attach it; bond1 is `[worker]` so non-schedulable masters skip the data plane) |

For single-node clusters both VIPs collapse onto the node IP (no LB).

## Install / BMC / bonding

| Variable | Default | Meaning |
|----------|---------|---------|
| `install_mode` | `agent` | `agent` or `ipi` (override per cluster) |
| `boot_via` | `redfish` | agent ISO delivery: `redfish` (sushy virtual media) or `iso` (attach directly) |
| `sushy_port` | `8000` | Redfish endpoint port |
| `bmc_username` / `bmc_password` | `admin` / `password` | BMC creds in configs (sushy ignores) |
| `provisioning_network_mode` | `Disabled` | IPI provisioning: `Disabled` or `Managed` |
| `control_plane_count_default` | `3` | masters when `node_count > 1` (workers = node_count - this) |
| `masters_schedulable` | `auto` | `auto` (schedulable only when no workers) / `true` / `false` |
| `default_bond_mode` | `active-backup` | fallback bond mode when a `nic_layout` bond omits `mode`. Use `active-backup` or `balance-tlb` (active-active TX, stable MAC); `balance-alb` / `802.3ad` / `balance-xor` break the agent install (IP collision, see [fidelity](fidelity.md)) |
| `ntp_servers` | `0/1.pool.ntp.org` | `additionalNTPSources`; empty to omit |

## Per-node sizing

| Variable | Default | Meaning |
|----------|---------|---------|
| `default_memory_mib` | `32768` | RAM per node |
| `default_vcpus` | `16` | vCPUs per node |
| `default_disks` | 128 + 1024 GiB | boot + storage qcow2 disks |
| `disk_cache` | `none` | qcow2 cache mode (`none` keeps host RAM free for VMs/zram; `writeback`/`unsafe` faster, more RAM, see [memory](memory-optimization.md)) |
| `disk_io` | `native` | qcow2 I/O mode (`native` with cache=none, `threads` with writeback) |

## Per-cluster keys (`clusters[]`)

| Key | Required | Meaning |
|-----|----------|---------|
| `name` | yes | cluster name (prefix for nets/domains) |
| `node_count` | yes | 1 (SNO) or >= 3; nodes beyond the control plane become workers |
| `control_plane_count` | no | 1 or 3 (default 3 for multi-node); workers = node_count - this |
| `masters_schedulable` | no | override global; run workloads on masters when workers exist |
| `install_mode` | no | override global `install_mode` |
| `boot_via` | no | override global `boot_via` |
| `base_domain` | no | override global `base_domain` |
| `api_vip_offset` / `ingress_vip_offset` | no | override VIP octets |
| `memory_mib` / `vcpus` / `disks` | no | override node sizing (all roles) |
| `master_memory_mib` / `worker_memory_mib` | no | per-role RAM (falls back to `memory_mib` -> `default_memory_mib`) |
| `master_vcpus` / `worker_vcpus` | no | per-role vCPUs (falls back to `vcpus` -> `default_vcpus`) |
| `day2_workers` | no | extra workers added after install with `make workers-add` (use worker sizing); `make workers-remove` tears them down. With `node_count: 1` this gives an edge-style single control plane + workers |
| `provisioning_network_mode` | no | per-cluster IPI provisioning mode |
| `subnet_index` | no | pin the `{c}` index for this cluster's subnets/MACs (stable if the list reorders) |

## Derived (computed in `templates/topology.yml.j2`, not set by hand)

subnets and gateways, bridge names, per-NIC MACs, DHCP reservations, both VIPs,
control-plane/worker replica counts, node roles, deterministic domain UUID,
per-node Redfish BMC URL, provisioning IPs, MTU propagation, MetalLB pool
(`.100-.119` on the machine net, applied via `make metallb`).
