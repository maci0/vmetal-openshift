# Ideas: more enterprise baremetal to simulate

A backlog of higher-fidelity simulations that would make this single-host lab feel
more like a real enterprise baremetal environment. What is already faithful (Redfish
BMC, bonded NICs, VLAN trunks, jumbo MTU, VIPs, MetalLB L2/BGP, metal3, agent/IPI/UPI,
disconnected mirror + operators) is in [docs/fidelity.md](docs/fidelity.md); this file
is the "what next" list.

Feasibility marker (all on one KVM host): **[easy]** a container/config/libvirt knob ·
**[med]** a new host appliance or nontrivial wiring · **[hard]** stretches what one host
can emulate, partial fidelity only.

## Networking & switch fabric

The biggest current gap: libvirt bridges are flat L2, so there is no real switch, no
LACP partner, no per-VLAN gateway.

| Idea | What it adds | How on one host |
|------|--------------|-----------------|
| **Open vSwitch as the ToR** | a real switch: **true LACP/802.3ad** bonds (drop the `balance-tlb` workaround), STP, port mirroring, per-VLAN SVIs/DHCP | run OVS on the host, attach VMs to OVS ports, configure `lacp=active` bonds + VLAN tags. **[med]** |
| **Spine-leaf / MLAG** | rack-style redundancy: dual ToR, ECMP underlay | two OVS bridges as leaves + one as spine, BGP or static underlay between them. **[hard]** |
| **EVPN-VXLAN overlay** | modern DC fabric (L2 stretch over L3) | FRR EVPN on the OVS leaves; nodes stay unaware. **[hard]** |
| **Real per-VLAN gateway + DHCP relay** | L3 boundaries, DHCP across subnets (metal3 provisioning realism) | give the trunk VLANs libvirt gateways or an OVS SVI + `dnsmasq`/isc-dhcp-relay. **[med]** |
| **IPv6 / dual-stack** | enterprise dual-stack clusters | add v6 CIDRs to `networks`, dual-stack `install-config`. **[med]** |
| **Corporate egress proxy** | air-gap-adjacent: cluster egress via a proxy | a `squid` host appliance; set `proxy:` in install-config. **[easy]** |
| **802.1X / port security** | NAC on the access ports | OVS + hostapd on the ToR; mostly a talking point. **[hard]** |

## Firmware, Secure Boot & TPM

| Idea | What it adds | How on one host |
|------|--------------|-----------------|
| **Secure Boot enabled** | measured/verified boot (today OVMF is present but SB is off) | pre-enrolled `OVMF_VARS.secboot.fd`, `<loader secure='yes'>` + `<smm>` in the domain XML. **[easy]** |
| **vTPM 2.0** | TPM-backed measured boot, sealed secrets, attestation | `swtpm` + `<tpm model='tpm-crb'>` per domain; enables the NBDE idea below. **[easy]** |
| **NBDE (Tang + Clevis)** | network-bound disk encryption: LUKS root that auto-unlocks from a Tang server, no passphrase (very common in regulated enterprises) | a **Tang host appliance** (container) + a MachineConfig that LUKS-encrypts with Clevis pointing at the gateway Tang. **[med]** |
| **HostFirmwareSettings / BIOS via Redfish** | metal3 reads/sets BIOS knobs (SR-IOV, boot mode, hyperthreading) | sushy-tools BIOS resource + `HostFirmwareSettings` CRs; even nominal values exercise the flow. **[med]** |
| **Firmware update / inventory** | metal3 `HostFirmwareComponents`, RMA/update workflow | fake versions in the Redfish `UpdateService`; simulate an update job. **[hard]** |

## Storage & SAN

| Idea | What it adds | How on one host |
|------|--------------|-----------------|
| **iSCSI SAN + multipath** | boot-from-SAN / attached LUNs with `dm-multipath` (classic enterprise storage) | `targetcli` iSCSI target on the host exporting LUNs over two VLANs; nodes multipath. **[med]** |
| **ODF / Ceph** | the real hyperconverged storage most baremetal clusters run (vs the lab's LVMS/NFS) | give workers 3+ spare disks (already have `sdc`); deploy ODF as a day-2 operator like CNV. **[med]** |
| **RAID presentation** | hardware-RAID `rootDeviceHints`, mixed disk classes | multiple qcow2 disks + `mdraid`, or model disks as different `rotation_rate`/serial so hints match. **[easy]** |
| **NVMe presentation** | NVMe-backed nodes | QEMU emulated NVMe (`<disk type='nvme'>`) instead of virtio-scsi. **[easy]** |
| **Local Storage Operator + PVs** | discrete local PVs per disk | LSO day-2 over the spare disks. **[easy]** |

## Compute & performance (telco / AI fidelity)

| Idea | What it adds | How on one host |
|------|--------------|-----------------|
| **NUMA topology + CPU pinning + hugepages** | the telco/RAN performance story: `PerformanceProfile`, isolated cores, hugepages, real-time kernel | multi-socket guest topology (`<numa>`), host hugepages, deploy the Node Tuning / Performance Addon operator. **[med]** |
| **SR-IOV networking** | VF passthrough for line-rate pods (DPDK) | libvirt SR-IOV is limited without real hardware; approximate with `macvtap`/emulated VFs + the SR-IOV operator CRs (partial). **[hard]** |
| **GPU passthrough / vGPU + NFD** | AI/ML worker nodes: Node Feature Discovery labels + GPU operator | PCI passthrough a host GPU to one worker (needs IOMMU), or emulate NFD labels for the flow. **[hard]** |
| **Mixed node shapes** | heterogeneous fleet (fat storage nodes, GPU nodes, small edge) | per-node `memory_mib`/`vcpus`/`disks` already support this; add role/label conventions + MachineSets. **[easy]** |

## BMC / out-of-band realism

| Idea | What it adds | How on one host |
|------|--------------|-----------------|
| **Richer Redfish: SEL, sensors, power telemetry** | monitoring the "hardware" (thermal, power draw, event log) via Redfish | extend the sushy config / a small Redfish shim; feed fake sensor data. **[med]** |
| **Serial-over-LAN / virtual console** | console access the enterprise way | libvirt serial console + a Redfish SOL endpoint. **[med]** |
| **True OOB isolation** | the management plane on its own L2, unreachable from workloads | put sushy + the OOB net in a dedicated netns/VRF so BMC traffic is genuinely separate. **[med]** |
| **Persistent boot order + one-time overrides** | closer BMC boot semantics | already partial via `set-boot`; extend `bmc.yml` to model persistent vs one-time. **[easy]** |

## Site infrastructure services

Move the "given" services (DNS/DHCP/NTP) off libvirt convenience and into real
appliances, like a datacenter would run.

| Idea | What it adds | How on one host |
|------|--------------|-----------------|
| **BIND authoritative DNS** | real zones, PTR records, delegation (vs dnsmasq split-DNS) | a `named` host appliance serving the cluster zones. **[med]** |
| **chrony stratum + NTP fidelity** | a real time source with drift, `additionalNTPSources` end to end | a `chrony` host appliance on the gateway; already have the `ntp_servers` knob. **[easy]** |
| **PXE/TFTP + HTTPBoot server** | UEFI HTTPBoot alongside iPXE (modern provisioning) | extend `build-pxe.sh` to also serve HTTPBoot. **[med]** |
| **Load-balancer appliance** | an external LB separate from the host (F5/keepalived pair) for UPI | second HAProxy/keepalived appliance instead of the single host HAProxy. **[med]** |

## Identity & security

| Idea | What it adds | How on one host |
|------|--------------|-----------------|
| **LDAP / Keycloak OIDC** | enterprise SSO: OpenShift OAuth backed by an IdP, group-mapped RBAC | a Keycloak (or 389-ds) host appliance; wire the OpenShift OAuth `identityProviders`. **[med]** |
| **Custom CA + cert-manager** | private PKI everywhere (ingress, API, mirror) | a root CA on the host + cert-manager day-2; the mirror already uses a self-signed CA. **[med]** |
| **FIPS mode** | regulated deployments | `fips: true` in install-config. **[easy]** |
| **Compliance Operator (CIS / STIG)** | scan + remediate to a benchmark | day-2 operator + a scan profile. **[easy]** |
| **HashiCorp Vault** | external secrets, dynamic creds, PKI | a Vault host appliance + the Secrets Store CSI / External Secrets operator. **[med]** |

## Fleet, lifecycle & GitOps

| Idea | What it adds | How on one host |
|------|--------------|-----------------|
| **Failure domains / racks / AZs** | zone-aware scheduling, spread, anti-affinity | topology labels per node (rack/zone) derived from the topology; optionally a bridge per "rack". **[easy]** |
| **RHACM hub-spoke** | multi-cluster management (already multi-cluster capable) | one cluster as the ACM hub importing the others. **[med]** |
| **GitOps (Argo CD)** | declarative cluster + app config from git | the OpenShift GitOps operator day-2. **[easy]** |
| **HyperShift hosted control planes** | control planes as pods, baremetal workers only (dense fleets) | HyperShift operator on a management cluster + agent workers. **[hard]** |
| **Cluster upgrades (z / y-stream)** | the upgrade lifecycle, mirrored in a true air gap | mirror two releases, `oc adm upgrade`. **[med]** |
| **Backup / restore (OADP + etcd)** | DR drills beyond the current resilience tests | OADP operator to an S3 appliance (minio) + etcd snapshot/restore. **[med]** |
| **Machine autoscaling** | `MachineSet` / Cluster API scale-out on baremetal | extend the day-2 worker flow into a MachineSet-driven scale. **[hard]** |
| **Observability off-cluster** | remote-write metrics + log forwarding to a sink | a Thanos/Loki host appliance; configure cluster forwarding. **[med]** |

## Quick wins to start with

If picking a few high-fidelity, low-effort items first:

1. **Secure Boot + vTPM** [easy] then **NBDE/Tang** [med] - the encrypted-boot story.
2. **Open vSwitch ToR** [med] - unlocks *true* LACP and per-VLAN gateways, closing the
   biggest networking gap in fidelity.md.
3. **chrony + BIND appliances** [easy/med] - real site services, reuse the host-appliance
   pattern (FRR/NFS/HAProxy/mirror).
4. **ODF/Ceph** [med] - the storage most real baremetal clusters actually run.
5. **Failure-domain labels + GitOps** [easy] - fleet realism for almost no cost.
