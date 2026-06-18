# Fidelity: what this lab does and does not emulate

<sub>[Home](../README.md) · [Architecture](architecture.md) · [Requirements](requirements.md) · [IPI vs agent](ipi-vs-agent.md) · **Fidelity** · [Disconnected](disconnected.md) · [Variables](variables.md) · [Examples](examples.md) · [Troubleshooting](troubleshooting.md)</sub>

This is a single-host KVM lab. It reproduces the OpenShift baremetal **control
and config surface** faithfully, but the physical layer underneath is emulated.
Know the gaps before trusting a result.

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
| UEFI + Secure Boot | OVMF secboot firmware, matches RHCOS expectations |

## Not faithful (and why)

| Gap | Reality in this lab | Implication |
|-----|---------------------|-------------|
| Physical switch | libvirt bridges are flat L2 segments | no real switch features |
| LACP (`802.3ad`) | no LACP partner on a bridge | config is faithful but will not truly aggregate; use `balance-alb` for working active-active |
| VLAN gateway/DHCP | trunk VLANs ride a no-IP L2 bridge | VLANs are guest-to-guest only (real isolation by tag), no per-VLAN libvirt gateway/DHCP; the machine net stays untagged so it keeps NAT/DHCP/DNS/VIP |
| NIC bonding failover timing | virtio links do not flap like real ports | failover tests are not representative |
| Out-of-band isolation | sushy runs on the host, BMCs are virtual | OOB LAN is logical, not a separate management plane |
| Firmware/RAID/disk hints | qcow2 virtio disks | `rootDeviceHints` is nominal (`/dev/vda`) |
| Hardware inspection (IPI) | Ironic inspects a VM | no real DMI/NIC/firmware data |
| Performance | shared host CPU/RAM/disk | not a sizing or perf benchmark |
| Internet | machine net NAT to the host uplink | "connected" by default; see [disconnected.md](disconnected.md) |

## Bonding modes

Each bond in `nic_layout` sets its own `mode` (or inherits `default_bond_mode`):

* `802.3ad`: LACP, the common enterprise mode with a real switch (the default for
  the 4-port trunk bond). Renders correct nmstate but cannot aggregate here (no
  LACP partner). Validates config, not throughput.
* `balance-alb`: active-active, adaptive load balancing, needs no switch support,
  so it actually load-balances over libvirt bridges (good for a working demo).
* `active-backup`: one active NIC, simplest, always works (default for bond0).
* `balance-xor` / `balance-rr`: also active-active.

## Bottom line

Trust this lab for: install flow, config correctness, BMC/Redfish integration,
DNS/VIP/LB behaviour, nmstate/bond config, Day-2 BareMetalHost wiring, multi-
cluster topology. Do not trust it for: switch/L2 behaviour, LACP aggregation,
failover timing, hardware inspection accuracy, or performance.
