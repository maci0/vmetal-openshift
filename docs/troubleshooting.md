# Troubleshooting

<sub>[Home](../README.md) · [Architecture](architecture.md) · [Requirements](requirements.md) · [IPI vs agent](ipi-vs-agent.md) · [Fidelity](fidelity.md) · [Disconnected](disconnected.md) · [Variables](variables.md) · [Examples](examples.md) · [Memory](memory-optimization.md) · [Virtualization](virtualization.md) · [Resilience](resilience.md) · [Cloud](cloud.md) · **Troubleshooting**</sub>

Run `make check` first; it catches most environment problems up front.

## sushy / Redfish

* **`sushy-emulator` won't start or VMs not visible**: it must reach the same
  libvirt as the VMs. Confirm `SUSHY_EMULATOR_LIBVIRT_URI = "qemu:///system"` in
  `sushy/conf.py` and that you can `virsh -c qemu:///system list --all`.
* **Redfish unreachable** at `https://<host>:8000`: check the process is up and
  the TLS cert/key paths are right; `curl -sk https://localhost:8000/redfish/v1/`
  should return JSON with `RedfishVersion`.
* **`make bmc` virtual-media insert fails**: the ISO must be served over HTTP.
  From the repo root run `python -m http.server 8099` and pass
  `-e iso_base_url=http://<host-on-OOB-LAN>:8099`. sushy fetches the image by URL.
* **Wrong System URL**: BMC URLs use the deterministic domain UUID. If you
  redefined a VM, re-run `make sushy` to regenerate `sushy/bmc-urls.txt`.

## In-cluster BMH / power management (metal3)

* **BMH patch fails: `no endpoints available for "baremetal-operator-webhook-service"`**:
  metal3 was just (re)deployed and its admission webhook isn't ready. Wait for the
  webhook endpoints before patching (`make adopt` now does this).
* **Powering a node OFF via metal3 leaves you unable to power it back ON**:
  the single-replica `baremetal-operator` (which serves the BMH webhook) may be
  running *on the node you powered off*. With it down, `oc patch bmh` fails (no
  webhook), so you cannot set `online: true`. Recover **out-of-band via the BMC**,
  bypassing metal3:
  ```bash
  curl -sk -X POST -H 'Content-Type: application/json' -d '{"ResetType":"On"}' \
    https://<oob-ip>:8000/redfish/v1/Systems/<node-uuid>/Actions/ComputerSystem.Reset
  # or: make bmc CLUSTER=<c> BMC_ACTION=on
  ```
  Once the node rejoins and the webhook reschedules, set `online: true` again so
  metal3 stops trying to keep it off. This is a real baremetal consideration, not
  a lab artifact: never drive the node hosting your only baremetal-operator
  through its own BMH.
* **metal3 power-off is slow**: it issues a graceful ACPI shutdown; RHCOS can take
  60-90s to power off. `virsh -c qemu:///system domstate <node>` shows the truth.

## Boot / install

* **VM boots to UEFI shell, no disk**: expected on first boot of an agent ISO
  cluster only if the ISO is not attached. For `boot_via: iso` confirm
  `build/discovery_image_<cluster>.iso` exists (`make iso`). For `boot_via: redfish`
  insert media via `make bmc ... BMC_ACTION=boot-iso`.
* **OVMF / firmware error on define**: `tasks/detect_ovmf.yml` picked a missing
  path, or none was found. Install `edk2-ovmf` / `OVMF`, or pin `ovmf_code` /
  `ovmf_vars` in `group_vars/all.yml`.
* **Rendezvous never completes (agent)**: the rendezvous node IP (`.10`) must be
  reachable on the machine net and match `rendezvousIP`. Check the node got its
  static bond0 address and DHCP reservations match the bond's primary MAC.
* **`node_count: 2` rejected**: intentional. Use 1 (SNO) or >= 3.

## Networking / DNS

* **Host can't resolve `api.<cluster>.<base>`**: libvirt's dnsmasq answers for
  the guests, but the host resolver must forward the cluster domain to it.
  Enable the NetworkManager dnsmasq plugin (`dns=dnsmasq`), then run
  `make host-dns ANSIBLE_ARGS="-K"` (writes `server=/<fqdn>/<machine-gateway>`).
  Verify with `scripts/test-dns.sh`.
* **Wrong VIP returned**: `api`/`api-int` resolve to the API VIP, `*.apps` to the
  ingress VIP. For SNO both equal the node IP by design.
* **Jumbo frames not working**: MTU 9000 is set on the storage network, bond, and
  slaves. The host bridge must also be 9000 (it is, via the network `<mtu>`).
* **Subnet clash with existing libvirt nets**: cleanup only touches the derived
  topology. If a pre-existing network uses 10.0.0.0/24 etc., change the role
  `cidr`s in `network_profile`.

## Ansible / libvirt

* **`cannot reach qemu:///system`**: join the `libvirt` group (re-login), or run
  with `-K` (sudo) / drop `-e use_become=false`.
* **Playbook can't find inventory**: run playbooks from `ansible/` (the
  `Makefile` and scripts already do).
* **Volume already exists / stale domain**: `make down` (cleanup.yml) removes the
  derived VMs, volumes (incl. nvram), and networks, then retry `make up`.
