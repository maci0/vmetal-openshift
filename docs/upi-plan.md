# Adding UPI with the fewest new components

<sub>[Home](../README.md) · [IPI vs agent](ipi-vs-agent.md) · [Architecture](architecture.md) · [Variables](variables.md)</sub>

> Status: **proposal, not yet implemented.** This is a design for a future
> `install_mode: upi`; the lab currently supports `agent` and `ipi` only.

Plan for a User Provisioned Infrastructure (UPI) install mode alongside the
existing `agent` and `ipi` modes, reusing as much of the current lab as possible.

## What UPI requires, and what the lab already provides

UPI means the installer creates nothing: you provide the nodes, DHCP, DNS, the
API/ingress load balancer, and you generate ignition configs and boot RHCOS
yourself. The flow is `create manifests` then `create ignition-configs`, then
boot each node (bootstrap, masters, workers) with its ignition.

| UPI needs | Lab already has | Gap |
|-----------|-----------------|-----|
| Nodes (VMs) | libvirt domains from topology (`setup.yml`, `libvirt/domain.xml.j2`) | none |
| DHCP + reservations | libvirt network dnsmasq (`libvirt/network.xml.j2`) | none |
| DNS `api` / `api-int` / `*.apps` | libvirt dnsmasq `address=` plus host split-DNS (`host-dns.yml`) | repoint the targets |
| Boot media + ignition serving | sushy Redfish virtual media plus the HTTP server on `:8099` (`install.sh`, `bmc.yml`) | per-role ignition ISO |
| `openshift-install` | present under `build/` | none |
| pull secret / ssh key | present | none |
| API + ingress load balancer | only the in-cluster keepalived + HAProxy on `platform: baremetal`; MetalLB serves Service LBs, not api/ingress | the one real gap |
| Bootstrap node | not modeled in topology | transient VM (multi-node only) |
| Worker CSR approval | not needed for agent/IPI | small post-install step |

Today DNS maps `api` and `api-int` to `api_vip` and `*.apps` to `ingress_vip`
(`topology.yml.j2` lines 109-112). SNO collapses both VIPs onto the single node
IP (lines 28-29). Multi-node relies on the in-cluster keepalived owning those
VIPs, which a `platform: none` UPI cluster does not have. That is the crux.

## Key insight: two tiers, very different cost

**Tier 0, SNO-UPI (almost free).** One node, `platform: none`, `api` and
`*.apps` already resolve to the node IP, so there is no load balancer, no
bootstrap VM, and no CSR step. The only new work is generating ignition instead
of an agent ISO and embedding it into the boot ISO.

**Tier 1, multi-node UPI (the real feature).** Adds exactly three things: a
host-side load balancer, a transient bootstrap VM, and CSR approval.

## Minimal-component design (multi-node)

Two choices keep the cost down:

1. **Load balancer = one host HAProxy container on the machine gateway (`.1`),
   not new VIPs or keepalived.** The host already owns `.1`. Repoint `api`,
   `api-int`, and `*.apps` DNS at `.1` for UPI clusters. This reuses the existing
   host-appliance pattern (`nfs.sh` for NFS-Ganesha, `metallb-bgp.sh` for FRR),
   so it adds no new kind of moving part.

2. **Ignition delivery reuses the existing boot path.** Build per-role RHCOS
   ISOs with `coreos-installer iso customize --dest-ignition <role>.ign`, serve
   them over the existing `:8099`, and mount them via the existing Redfish path.
   `coreos-installer` is the only new host tool (a single static binary, added in
   `bootstrap.sh` the same way `oc` and `openshift-install` are).

## bmc.yml finding (verified)

`bmc.yml` takes one `iso_name` per invocation (default
`discovery_image_<cluster>.iso`) and applies it to every node in the loop
(InsertMedia body, line 125). It has no per-role or per-node ISO selection today.
Nodes already carry a `role` attribute (`master` / `worker`; bootstrap would be
`bootstrap`). So the per-role ISO need is a roughly one-line extension: when a
`per_role_iso` flag is set, build the Image URL as
`{{ iso_base_url }}/{{ item.role }}.ign.iso` instead of the shared `iso_name`.
No restructuring of the play.

## File-by-file changes

### New (6)

1. `scripts/build-ignition.sh` -- the UPI analog of `build-iso.sh`: render
   configs, `openshift-install create manifests`, `create ignition-configs` (or
   `create single-node-ignition-config` for SNO), then `coreos-installer iso
   customize` per role (bootstrap / master / worker) into `build/<role>.ign.iso`.
2. `ansible/templates/install/haproxy.cfg.j2` -- frontends `6443 -> masters`,
   `22623 -> masters`, `443` and `80 -> ingress nodes`, backends from topology
   node IPs.
3. `scripts/haproxy.sh` -- `up` / `down` for the host HAProxy container bound to
   the machine gateway, copied from the `nfs.sh` appliance shape.
4. `scripts/install-upi.sh` -- orchestration (see flow below), or a `mode==upi`
   branch inside `install.sh`.
5. `scripts/approve-csrs.sh` -- `oc adm certificate approve` loop until every
   worker is `Ready` (UPI only).
6. `Makefile` targets: `install-upi`, `haproxy`, `haproxy-down`.

### Modified (5, all small)

1. `ansible/templates/topology.yml.j2` -- accept `install_mode: upi`; add a
   `bootstrap` node to the node list when `mode == upi and not sno`; for UPI set
   `dns_options` so `api`, `api-int`, and `apps` point at `machine_gateway`
   instead of the VIPs (one conditional).
2. `ansible/templates/install/install-config.yaml.j2` -- widen the `none: {}`
   branch from `if cluster.sno` to `if cluster.sno or mode == 'upi'` (UPI has no
   VIPs). Replicas, machineNetwork, and OVN are already correct.
3. `ansible/generate-configs.yml` -- render `haproxy.cfg` for UPI clusters (one
   templated task mirroring the existing FRR-config task).
4. `ansible/bmc.yml` -- add the `per_role_iso` path described above.
5. `ansible/tasks/validate.yml` -- allow `install_mode` in
   {`agent`, `ipi`, `upi`}.

### Reused unchanged

libvirt networks, DHCP, `domain.xml.j2`, sushy and the `bmc.yml` virtual-media
boot, HTTP serving, `host-dns.yml`, pull secret and ssh key, the
`control_plane` / `workers` derivation, and all day-2 operators (MetalLB, LVMS,
NFS, CNV).

## Orchestration (`install-upi.sh`)

1. `build-ignition.sh` (manifests, ignition, per-role ISOs).
2. `setup.yml` (VMs including the transient bootstrap node).
3. `haproxy.sh up` (multi-node only).
4. Boot nodes via `bmc.yml` with `per_role_iso=true`, so each node mounts its
   role ISO.
5. `openshift-install wait-for bootstrap-complete`, then `virsh destroy` and
   `undefine` the bootstrap VM and drop it from the HAProxy api backend.
6. `approve-csrs.sh` (loop while worker CSRs are pending).
7. `openshift-install wait-for install-complete`.

SNO-UPI skips steps 3, 5, and 6: `create single-node-ignition-config`, a single
ISO, no load balancer, no bootstrap node.

## Validation

`make lint` already render-checks every mode by feeding synthetic clusters. Add a
`{"install_mode":"upi"}` fixture to `lint.sh` and `check-examples.sh` so UPI
rendering is covered offline, with no live cluster.

## Effort, risk, recommendation

- **SNO-UPI: about half a day**, near-zero risk, roughly two new files. It proves
  the ignition path end to end.
- **Multi-node UPI: about two to three days.** Main risks: HAProxy backend health
  while the bootstrap node is removed mid-install, and per-role ISO selection in
  `bmc.yml`. Both are mechanical.
- **Recommended phasing:** land SNO-UPI first (it reuses the SNO DNS collapse and
  adds almost nothing), then add the HAProxy appliance and bootstrap lifecycle
  for multi-node. The HAProxy-on-the-gateway choice is what keeps multi-node down
  to three additions instead of a keepalived/VIP subsystem.

## Open items to confirm during implementation

- `coreos-installer iso customize` flags for the installed RHCOS version (pin the
  version in `bootstrap.sh`).
- Whether to keep the bootstrap node in the topology permanently (marked
  transient) or synthesize it only inside `install-upi.sh`.
- HAProxy health-check tuning so a not-yet-joined master does not blackhole api
  traffic during bootstrap.
