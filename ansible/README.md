# ansible/

Everything is driven by one derived topology; you normally edit only the
`clusters` list (and the scheme) in `group_vars/all.yml`.

```
ansible.cfg            local config (inventory, interpreter, no retry files)
inventory.ini          implicit localhost
requirements.yml       collections: community.libvirt, community.general
group_vars/all.yml     addressing scheme, networks, nic_layout, clusters  <-- edit this

playbooks (run from this dir, e.g. ansible-playbook setup.yml):
  setup.yml            create libvirt networks, volumes, VMs
  cleanup.yml          tear them down (scoped to the derived topology)
  generate-configs.yml render install-config / agent-config / BMH / Scheduler / Provisioning
  sushy.yml            render sushy Redfish config + systemd unit + BMC URL list
  bmc.yml              Redfish power / boot-device / virtual-media control
  host-dns.yml         point the host resolver at each cluster domain
  dump-topology.yml    render the derived topology to JSON (test oracle)

tasks/
  validate.yml         assert node_count / control_plane_count are valid
  detect_ovmf.yml      locate OVMF firmware across distros

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

Most tasks use the fully-qualified `community.libvirt.*` / `community.general.*` /
`ansible.builtin.*` modules and pass `become: "{{ use_become | default(true) }}"`,
so you can run with sudo or, in the libvirt group, `-e use_become=false`.
