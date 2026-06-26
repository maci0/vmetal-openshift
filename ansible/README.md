# ansible/

Everything is driven by one derived topology; you normally edit only the
`clusters` list (and the scheme) in `group_vars/all.yml`.

```
ansible.cfg            local config (inventory, interpreter, no retry files)
inventory.ini          implicit localhost
requirements.yml       collections: community.libvirt, community.general,
                       kubernetes.core, community.docker
group_vars/all.yml     addressing scheme, networks, nic_layout, clusters  <-- edit this

playbooks (run from this dir, e.g. ansible-playbook setup.yml):
  setup.yml            create libvirt networks, volumes, VMs
  cleanup.yml          tear them down (scoped to the derived topology)
  generate-configs.yml render install-config / agent-config / BMH / Scheduler / Provisioning
  sushy.yml            render sushy Redfish config + systemd unit + BMC URL list
  bmc.yml              Redfish power / boot-device / virtual-media control
  workers.yml          provision / remove day-2 worker VMs (worker_action=add|remove)
  host-dns.yml         point the host resolver at each cluster domain
  dump-topology.yml    render the derived topology to JSON (test oracle)
  operators.yml        day-2 operator install (op=lvms|virt|metallb, kubernetes.core)
  haproxy.yml          host HAProxy appliance for multi-node UPI (community.docker)
  nfs.yml              NFS-Ganesha host appliance + RWX provisioner
  metallb-bgp.yml      MetalLB BGP: host FRR peer + BGP config
  adopt.yml            in-cluster BMH adoption (metal3 power mgmt, kubernetes.core)
  optimize.yml         host memory tuning: KSM + zram + hook (mode=apply|undo, become)

tasks/
  validate.yml         assert control_plane (1 or 3) and workers are valid
  preflight.yml        host gate: kvm, OVMF firmware, nested virt
  detect_ovmf.yml      locate OVMF firmware across distros
  container_runtime.yml resolve the docker/podman API socket (host appliances)

templates/
  topology.yml.j2      the heart: derives the whole topology from group_vars
  libvirt/             network.xml.j2, domain.xml.j2
  install/             install-config (agent + ipi), agent-config, baremetalhosts,
                       provisioning, scheduler, and the shared nmstate.j2 macro
  sushy/               sushy-emulator conf + systemd unit
```

## How the topology flows

`group_vars/all.yml` (scheme + `clusters`) → `templates/topology.yml.j2` →
parsed into the `topology` fact → consumed by every playbook and template. Adding
a cluster or changing `nic_layout` requires no other edits: subnets, bridges,
MACs, VIPs, node roles, replica counts, domain UUIDs, and BMC URLs are all derived.

Tasks use fully-qualified modules only (no `command`/`shell`): `community.libvirt.*`
for libvirt (incl. `virt_volume`), `kubernetes.core.*` for cluster objects,
`community.docker.*` for host-appliance containers, plus `community.general.*` /
`ansible.builtin.*`. Provisioning playbooks pass `become: "{{ use_become |
default(true) }}"`, so run with sudo or, in the libvirt group, `-e use_become=false`.
