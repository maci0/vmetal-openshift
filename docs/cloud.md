# Running on a cloud VM (AWS / GCP / Azure)

<sub>[Home](../README.md) · [Architecture](architecture.md) · [Requirements](requirements.md) · [IPI vs agent](ipi-vs-agent.md) · [Fidelity](fidelity.md) · [Disconnected](disconnected.md) · [Variables](variables.md) · [Examples](examples.md) · [Memory](memory-optimization.md) · [Virtualization](virtualization.md) · [Resilience](resilience.md) · **Cloud** · [Troubleshooting](troubleshooting.md)</sub>

The whole lab runs **inside one Linux host** as nested KVM guests, so it ports to a
single big cloud VM unchanged. The only hard requirement the cloud adds is **nested
virtualization** (the cloud VM must let its guests run KVM). Everything else
(libvirt networks, sushy, the cluster) stays internal to that VM.

## The one hard requirement: nested virt

The OCP nodes are KVM VMs *inside* the cloud VM, and they themselves run
containers/pods (and, with CNV, nested VMs). The host CPU must expose
`vmx`/`svm` to guests. Support differs sharply by cloud:

| Cloud | How nested virt is available | Pick |
|-------|------------------------------|------|
| **AWS** | Only on **bare-metal** instances (`*.metal`); ordinary EC2 does **not** expose nested KVM | `m5.metal`, `m5d.metal` (local NVMe), `m7i.metal-*`, `c5.metal` |
| **GCP** | On **Intel** instances with nested enabled (a per-image/VM license + flag); AMD (`n2d`/`c2d`) cannot | `n2-standard-32` / `n2-highmem-32` + `--enable-nested-virtualization` |
| **Azure** | On specific sizes (Dv3/Ev3 and newer: Dv4/Dv5, Ev4/Ev5, Dsv5, Esv5) | `Standard_D32s_v5`, memory-optimized `Standard_E32s_v5` |

Verify on the VM before anything else:

```bash
ls /dev/kvm                                  # must exist
cat /sys/module/kvm_intel/parameters/nested  # or kvm_amd: must be Y or 1
```

## Sizing

Match the cluster you want (see [requirements](requirements.md) / [memory](memory-optimization.md)).
A full **3 + 2** allocates ~92 GiB; SNO or compact need far less. Rule of thumb:

| Target cluster | vCPU | RAM | Disk (SSD/NVMe) |
|----------------|-----:|----:|----------------:|
| SNO | 12+ | 32 GiB | 200 GiB |
| 3-node compact | 24+ | 80 GiB | 400 GiB |
| 3 + 2 workers | 32+ | 128 GiB | 500 GiB |

Closest instances (≈128 GiB, for 3 + 2):

| Cloud | Instance | vCPU / RAM |
|-------|----------|-----------|
| AWS | `m5.metal` (or `m5d.metal` for local NVMe) | 96 / 384 GiB (metal is the floor) |
| GCP | `n2-standard-32` or `n2-highmem-32` | 32 / 128 GiB |
| Azure | `Standard_E32s_v5` | 32 / 256 GiB |

Notes:
* **AWS metal is the floor** (no smaller nested-capable option), so it is oversized
  and pricier; KSM + zram (`make optimize`) let a single metal host more clusters.
* Disk: use **SSD/NVMe** (`gp3`/`io2` on AWS, `pd-ssd`/local-SSD on GCP, Premium
  SSD on Azure). qcow2 is thin, so provisioned size is a ceiling, not upfront cost.
* The lab presents node disks as **SSD** (`disk_bus: scsi` + `rotation_rate`), which
  rides on whatever the cloud disk actually is.

## Setup (any cloud)

```bash
# 1. provision the VM per the table above (RHEL 9 / Fedora / Ubuntu 22.04+),
#    with nested virt enabled (GCP: --enable-nested-virtualization at create;
#    Azure: a nested-capable size; AWS: any *.metal is automatic).

# 2. confirm nested virt
ls /dev/kvm && cat /sys/module/kvm_*/parameters/nested

# 3. host deps (libvirt, qemu-kvm, NetworkManager+dnsmasq, python, etc) - see
#    docs/requirements.md; `make check` reports what is missing.

# 4. the lab itself - identical to a laptop host
git clone <repo> && cd vmetal-openshift
cp ~/pull-secret.json pull-secret.json
make bootstrap
make check                 # /dev/kvm, nested, KSM/zram, libvirt hook
make install               # or pick a topology in ansible/group_vars/all.yml first
```

GCP enable-nested example:

```bash
gcloud compute instances create vmetal \
  --machine-type=n2-standard-32 --zone=... \
  --image-family=rhel-9 --image-project=rhel-cloud \
  --enable-nested-virtualization \
  --boot-disk-size=500GB --boot-disk-type=pd-ssd
```

## Networking

The crucial point: **all cluster networks are internal to the VM.** The machine,
storage, migration, provisioning, and OOB nets are libvirt bridges (NAT / isolated
/ L2 trunk) created *inside* the VM. The cloud VPC only ever sees the VM's own
primary NIC. So most cloud-network friction does not apply:

* **No VPC/subnet/route/LB wiring** for the cluster. VIPs, MetalLB pools, BGP/FRR,
  the off-link BGP range, jumbo VLANs all live on the internal bridges. The cloud
  network is untouched.
* **MAC/anti-spoof filtering** (AWS source/dest check, Azure/GCP anti-spoof) does
  **not** bite: cluster traffic is NAT'd out behind the VM's IP, so the bonded/VLAN
  MACs never appear on the cloud NIC. (Only relevant if you *bridged* a cluster net
  to the cloud NIC, which the lab does not.)
* **Jumbo frames** (storage/migration VLANs, MTU 9000) work regardless of the cloud
  NIC MTU, because those frames stay on internal bridges and never egress.
* **Security group / firewall**: open only **SSH (22)** to your IP. Nothing else
  needs inbound. Egress (443) is needed to pull the release images + pull secret.

Reaching the cluster from your laptop (it has no public endpoint):

```bash
# simplest: run oc on the VM itself (kubeconfig in clusters/<name>/auth/)

# from a laptop: route the cluster nets through the VM with sshuttle
sshuttle -r user@<vm-public-ip> 10.0.0.0/24 172.16.0.0/24
# resolve api/*.apps to the VIPs over the tunnel: add to /etc/hosts, or point at
# the lab's split-DNS (see docs/troubleshooting.md)

# or just forward the console
ssh -L 6443:api.cluster0.ocp.lab:6443 -L 443:<ingress-vip>:443 user@<vm-public-ip>
```

A `*.metal` AWS instance can also use **multiple ENIs / a dedicated NIC** if you
later want to bridge a cluster net to the VPC, but that needs ENI MAC allow-listing
and is not required for the default self-contained setup.

## Storage

Cluster disks are qcow2 files under `/var/lib/libvirt/images` on the VM, plus the
NFS appliance export (`build/nfs-export/`). Size and speed both matter:

* **Put `/var/lib/libvirt/images` on a dedicated fast volume**, separate from the OS
  disk, sized per the table above (qcow2 is thin, but etcd, the registry, and image
  pulls fill it). 500 GiB SSD/NVMe for 3 + 2.
* **IOPS, not just GB.** Five nodes doing etcd + image pulls hammer the disk. Cloud
  defaults throttle:
  * **AWS** `gp3` baselines 3000 IOPS / 125 MB/s; provision more, use `io2`, or an
    instance with **local NVMe** (`m5d.metal`, `i3en`). Local NVMe is fastest but
    **ephemeral** (lost on stop) which is fine for a throwaway lab.
  * **GCP** `pd-ssd` scales IOPS with size; **local SSD** is faster but ephemeral.
  * **Azure** `Premium SSD v2` / `Ultra Disk` for provisioned IOPS; ephemeral NVMe
    on the right sizes for speed.
* **Disk cache.** The lab defaults to `cache=none` (direct I/O) so the host page
  cache does not eat the RAM that KSM/zram free. On a slower cloud volume with RAM
  to spare you can trade that back: `disk_cache: writeback` + `disk_io: threads`
  (see [memory](memory-optimization.md)).
* **SSD presentation** (`disk_bus: scsi` + `rotation_rate=1`) is independent of the
  cloud disk: guests see SSD regardless of what backs the volume.
* **LVMS + NFS** both consume the same VM volume (the workers' `sdc` qcow2 and the
  host export dir), so count them in the volume size if you run `make lvms` / `make nfs`.

## Cost + lifecycle

* **Memory optimization pays for itself here**: RAM is the cost driver, and KSM +
  zram (`make optimize`) cut real usage ~40 % (see [memory](memory-optimization.md)),
  letting a smaller/cheaper VM hold the cluster.
* Use **spot / preemptible** instances for throwaway runs (the lab rebuilds from
  scratch with `make down` + `make install`).
* **Stop or terminate** the VM when idle; metal/large instances are expensive by
  the hour. `make down` first if you want a clean teardown (it also stops the FRR /
  NFS host appliances).
* The host-side appliances (FRR BGP peer, NFS-Ganesha) are just containers on the
  VM, so `make metallb-bgp` / `make nfs` work the same in the cloud.
