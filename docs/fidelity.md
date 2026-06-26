# Fidelity: what this lab does and does not emulate

<sub>[Home](../README.md) · [Architecture](architecture.md) · [Requirements](requirements.md) · [IPI vs agent](ipi-vs-agent.md) · **Fidelity** · [Disconnected](disconnected.md) · [Variables](variables.md) · [Examples](examples.md) · [Memory](memory-optimization.md) · [Virtualization](virtualization.md) · [Resilience](resilience.md) · [Cloud](cloud.md) · [Troubleshooting](troubleshooting.md)</sub>

The goal of this lab is to come **as close as practical to a real baremetal
OpenShift install** on a single host: Redfish BMCs, bonded NICs with VLAN trunks,
separate API/ingress VIPs, metal3 BareMetalHosts, and the agent-based / IPI flows,
all without the hardware. It is a single-host KVM lab, so it reproduces the
OpenShift baremetal **control and config surface** faithfully, but the physical
layer underneath is emulated. Know the gaps before trusting a result.

## Emulated faithfully

| Area | How |
|------|-----|
| BMC / Redfish | sushy-emulator exposes a real Redfish API; power + virtual media work |
| Agent + IPI flows | real `install-config` / `agent-config` / BareMetalHost, same installer |
| VIPs + LB | integrated keepalived + HAProxy via `platform: baremetal` (api + ingress VIP) |
| DNS | libvirt dnsmasq, authoritative split-DNS for `api`, `api-int`, `*.apps` |
| Bonding | real nmstate bonds; `nic_layout` models onboard + add-in-card bonds |
| VLAN trunk | real 802.1Q subinterfaces on a bond; guest-to-guest isolation by tag |
| Diverse subnets | per-role RFC1918 ranges (machine 10.x, OOB 172.16.x, prov 172.22.x) |
| Jumbo frames | MTU 9000 on the storage VLAN + bond + slaves end to end |
| UEFI | OVMF firmware (Secure Boot available in the firmware but not enabled on the domains) |

## Not faithful (and why)

| Gap | Reality in this lab | Implication |
|-----|---------------------|-------------|
| Physical switch | libvirt bridges are flat L2 segments | no real switch features |
| LACP (`802.3ad`) | no LACP partner on a bridge | config is faithful but will not truly aggregate |
| Active-active bonds | balance-alb/802.3ad expose the bond IP on multiple slave MACs | trips the agent installer's "no IP collision" host validation on bonded VLANs and blocks install; the data bond uses `balance-tlb` (active-active TX, stable single MAC) instead |
| VLAN gateway/DHCP | trunk VLANs ride a no-IP L2 bridge | VLANs are guest-to-guest only (real isolation by tag), no per-VLAN libvirt gateway/DHCP; the machine net stays untagged so it keeps NAT/DHCP/DNS/VIP |
| NIC bonding failover timing | virtio links do not flap like real ports | failover tests are not representative |
| Out-of-band isolation | sushy runs on the host, BMCs are virtual | OOB LAN is logical, not a separate management plane |
| Firmware/RAID/disk hints | qcow2 virtio disks | `rootDeviceHints` is nominal (`/dev/sda`) |
| Hardware inspection (IPI) | Ironic inspects a VM | no real DMI/NIC/firmware data |
| Performance | shared host CPU/RAM/disk | not a sizing or perf benchmark |
| Internet | machine net NAT to the host uplink | "connected" by default; see [disconnected.md](disconnected.md) |

## Bonding modes

Each bond in `nic_layout` sets its own `mode` (or inherits `default_bond_mode`):

* `balance-tlb` (default for the data bond): active-active on transmit, needs no
  switch, and keeps a **stable single MAC** (RX on one slave). Outbound traffic is
  load-balanced, and because the bond IP maps to one MAC it passes the agent
  installer's IP-collision validation. The sweet spot for active-active here.
* `active-backup` (default for the machine bond): one active NIC, single MAC.
  Simplest, always works.
* `balance-alb` / `802.3ad` / `balance-xor`: active-active that put the bond IP on
  **multiple slave MACs**, which the assisted-service host validation reads as an
  IP collision and **blocks the install**. `balance-alb` adds receive-side ARP MAC
  rewriting; `802.3ad` also needs a real switch. They also cannot truly aggregate
  over a libvirt bridge, so they are cosmetic here. Avoid for a working install.

## Bottom line

Trust this lab for: install flow, config correctness, BMC/Redfish integration,
DNS/VIP/LB behaviour, nmstate/bond config, Day-2 BareMetalHost wiring, multi-
cluster topology. Do not trust it for: switch/L2 behaviour, LACP aggregation,
failover timing, hardware inspection accuracy, or performance.
