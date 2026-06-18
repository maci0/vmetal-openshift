# System requirements

<sub>[Home](../README.md) · [Architecture](architecture.md) · **Requirements** · [IPI vs agent](ipi-vs-agent.md) · [Fidelity](fidelity.md) · [Disconnected](disconnected.md) · [Variables](variables.md) · [Examples](examples.md) · [Troubleshooting](troubleshooting.md)</sub>

All nodes here are libvirt VMs on one KVM host, so "node sizing" is per-VM and
the host must fit the sum. The lab defaults are generous (16 vCPU, 32 GiB,
128 + 1024 GiB disk per node); the numbers below are the OpenShift minimums you
can drop to via per-cluster `memory_mib` / `vcpus` / `disks` overrides.

## Per-node minimums (OpenShift)

| Role | vCPU | RAM | Disk | Notes |
|------|------|-----|------|-------|
| SNO (single node) | 8 | 16 GiB | 120 GiB | runs control plane + workload on one node |
| Control plane (3-node) | 4 | 16 GiB | 100 GiB | 8 vCPU recommended |
| Worker / infra | 2 | 8 GiB | 100 GiB | size to workload |
| Bootstrap (transient) | 4 | 16 GiB | 100 GiB | exists only during install |

Lab default per node: **16 vCPU, 32 GiB, 128 GiB (boot) + 1024 GiB (storage)**,
thin-provisioned qcow2, so disk is allocated on use.

## Host sizing by mode

The host needs roughly the sum of the VMs that run at once, plus a few GiB for
the host OS, libvirt, and sushy.

| Mode | VMs at peak | RAM (lab default) | RAM (minimums) |
|------|-------------|-------------------|----------------|
| SNO (`node_count: 1`) | 1 node | ~34 GiB | ~18 GiB |
| Agent 3-node | 3 nodes (bootstrap runs on the rendezvous node, no extra VM) | ~98 GiB | ~52 GiB |
| IPI 3-node | 3 nodes + 1 bootstrap VM on the host | ~114 GiB | ~68 GiB |
| Workers (e.g. `node_count: 5`) | 3 masters + N workers | + ~32 GiB/worker | + ~10 GiB/worker |

Nodes beyond `control_plane_count` (1 or 3) become workers. With workers present,
masters are not schedulable unless `masters_schedulable: true`.

vCPU is oversubscribable (KVM time-slices), so total vCPU can exceed host cores;
RAM and disk cannot. `scripts/check-prereqs.sh` reports host RAM and free space in
the image pool.

Storage: each node has a 128 GiB boot disk and a 1024 GiB data disk (for ODF /
LSO on the storage network). Thin-provisioned, but plan real headroom in
`/var/lib/libvirt/images` for what actually gets written.

## Host software

* libvirt + qemu-kvm, hardware virtualization (`/dev/kvm`)
* OVMF (UEFI) firmware, auto-detected across distros
* NetworkManager with the dnsmasq plugin (or systemd-resolved) for split-DNS
* `nmstate` (provides `nmstatectl`), required to build an agent ISO with static /
  bonded networking; not pip-installable, use the distro/AUR package
* Python 3 + `uv`/`pip`; `curl`, `jq`, `tar`, `openssl`
* `ansible-core` + `community.libvirt` + `community.general`, and the
  `libvirt-python` + `lxml` bindings (all installed into the venv by bootstrap)
* `openshift-install` (self-contained, fetched by bootstrap)
* Optional, docs only: `pandoc`, `mmdc`, `chromium`

Run `make check` (`scripts/check-prereqs.sh`) to validate all of the above.
