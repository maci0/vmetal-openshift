# Rendered config examples

<sub>[Home](../README.md) · [Architecture](architecture.md) · [Requirements](requirements.md) · [IPI vs agent](ipi-vs-agent.md) · [Fidelity](fidelity.md) · [Disconnected](disconnected.md) · [Variables](variables.md) · **Examples** · [Troubleshooting](troubleshooting.md)</sub>

Produced by `ansible-playbook generate-configs.yml` from the topology, not
written by hand. Pull secrets and passwords are redacted here. Regenerate with
`make configs` (output in `clusters/<name>/`). The default `nic_layout` is a
2-NIC onboard bond (machine + provisioning VLAN) plus a 4-port active-active card
carrying the storage + live-migration networks as VLANs.

## SNO, agent (`node_count: 1`)

`platform: none` (no VIPs, no load balancer); `api` and `*.apps` resolve to the
node IP.

```yaml
apiVersion: v1
baseDomain: ocp.lab
metadata:
  name: sno
controlPlane:
  name: master
  replicas: 1
  architecture: amd64
  hyperthreading: Enabled
compute:
- name: worker
  replicas: 0
  architecture: amd64
  hyperthreading: Enabled
networking:
  networkType: OVNKubernetes
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16
  machineNetwork:
  - cidr: 10.0.0.0/24
platform:
  none: {}
pullSecret: 'REDACTED'
sshKey: 'ssh-ed25519 AAAA...'
```

## 3-node, agent: `agent-config.yaml` (node0)

The nmstate is the production NIC shape: `bond0` (active-backup) over the 2
onboard NICs holds the static machine IP, default route, and DNS; `bond1`
(balance-tlb, active-active TX, MTU 9000) over the 4-port card is a VLAN trunk, no IP;
`bond0.20` carries the provisioning VLAN (onboard); `bond1.30` (storage) and
`bond1.40` (live-migration) ride the data card with static IPs, jumbo MTU.

```yaml
apiVersion: v1beta1
kind: AgentConfig
metadata:
  name: prod
rendezvousIP: 10.0.0.10
additionalNTPSources:
- 0.pool.ntp.org
- 1.pool.ntp.org
hosts:
- hostname: prod-node0
  role: master
  rootDeviceHints:
    deviceName: /dev/vda
  interfaces:
  - name: eth0
    macAddress: 52:54:00:00:00:0a
  - name: eth1
    macAddress: 52:54:00:00:01:0a
  - name: eth2
    macAddress: 52:54:00:00:10:0a
  - name: eth3
    macAddress: 52:54:00:00:11:0a
  - name: eth4
    macAddress: 52:54:00:00:12:0a
  - name: eth5
    macAddress: 52:54:00:00:13:0a
  networkConfig:
    interfaces:
    - name: bond0
      type: bond
      state: up
      ipv4:
        enabled: true
        dhcp: false
        address:
        - ip: 10.0.0.10
          prefix-length: 24
      link-aggregation:
        mode: active-backup
        options:
          miimon: "100"
        port:
        - eth0
        - eth1
    - name: eth0
      type: ethernet
      state: up
    - name: eth1
      type: ethernet
      state: up
    - name: bond0.20
      type: vlan
      state: up
      vlan:
        base-iface: bond0
        id: 20
      ipv4:
        enabled: true
        dhcp: false
        address:
        - ip: 172.22.0.10
          prefix-length: 24
    - name: bond1
      type: bond
      state: up
      mtu: 9000
      ipv4:
        enabled: false
      link-aggregation:
        mode: balance-tlb
        options:
          miimon: "100"
        port:
        - eth2
        - eth3
        - eth4
        - eth5
    - name: eth2
      type: ethernet
      state: up
      mtu: 9000
    - name: eth3
      type: ethernet
      state: up
      mtu: 9000
    - name: eth4
      type: ethernet
      state: up
      mtu: 9000
    - name: eth5
      type: ethernet
      state: up
      mtu: 9000
    - name: bond1.30
      type: vlan
      state: up
      mtu: 9000
      vlan:
        base-iface: bond1
        id: 30
      ipv4:
        enabled: true
        dhcp: false
        address:
        - ip: 10.0.10.10
          prefix-length: 24
    - name: bond1.40
      type: vlan
      state: up
      mtu: 9000
      vlan:
        base-iface: bond1
        id: 40
      ipv4:
        enabled: true
        dhcp: false
        address:
        - ip: 10.0.20.10
          prefix-length: 24
    dns-resolver:
      config:
        server:
        - 10.0.0.1
        search:
        - prod.ocp.lab
    routes:
      config:
      - destination: 0.0.0.0/0
        next-hop-address: 10.0.0.1
        next-hop-interface: bond0
```

(node1/node2 follow with `.11` / `.12` on each network.)

## 3-node, IPI: `install-config.yaml` (Managed provisioning)

`platform: baremetal` with both VIPs and a `hosts[]` entry per node carrying the
Redfish BMC URL and the same bond/VLAN `networkConfig`. With
`provisioning_network_mode: Managed`, metal3 runs DHCP/PXE on the provisioning
VLAN interface.

```yaml
platform:
  baremetal:
    apiVIPs:
    - 10.0.0.5
    ingressVIPs:
    - 10.0.0.6
    provisioningNetwork: Managed
    provisioningNetworkCIDR: 172.22.0.0/24
    provisioningDHCPRange: 172.22.0.10,172.22.0.100
    clusterProvisioningIP: 172.22.0.2
    bootstrapProvisioningIP: 172.22.0.3
    provisioningInterface: bond0.20
    hosts:
    - name: ipi0-node0
      role: master
      bootMACAddress: 52:54:00:00:00:0a
      bmc:
        address: redfish-virtualmedia://172.16.0.1:8000/redfish/v1/Systems/00000000-0000-4000-8000-00000000000a
        username: admin
        password: REDACTED
        disableCertificateVerification: true
      rootDeviceHints:
        deviceName: /dev/vda
      networkConfig:
        # ... bond0 + bond1 trunk + VLANs, same nmstate as the agent-config above ...
```

## Day-2 (agent baremetal): `provisioning.yaml` + `baremetalhosts.yaml`

`make adopt` applies these on a `platform: baremetal` cluster so metal3 deploys
and adopts the nodes via the Redfish BMC. The `Provisioning` CR:

```yaml
apiVersion: metal3.io/v1alpha1
kind: Provisioning
metadata:
  name: provisioning-configuration
spec:
  provisioningNetwork: Disabled
  watchAllNamespaces: true
  virtualMediaViaExternalNetwork: true
```

One `BareMetalHost` + its BMC secret (per node):

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: prod-node0-bmc-secret
  namespace: openshift-machine-api
type: Opaque
stringData:
  username: admin
  password: REDACTED
---
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: prod-node0
  namespace: openshift-machine-api
spec:
  online: true
  bootMACAddress: 52:54:00:00:00:0a
  bmc:
    address: redfish-virtualmedia://172.16.0.1:8000/redfish/v1/Systems/00000000-0000-4000-8000-00000000000a
    credentialsName: prod-node0-bmc-secret
    disableCertificateVerification: true
  rootDeviceHints:
    deviceName: /dev/vda
```

## libvirt networks (rendered XML)

`setup.yml` creates the machine NAT network (DHCP reservations + split-DNS) and
the L2 trunk carrier (no IP) that the 4-port bond rides:

```xml
<network xmlns:dnsmasq="http://libvirt.org/schemas/network/dnsmasq/1.0">
  <name>cluster0-machine</name>
  <forward mode="nat"><nat><port start="1024" end="65535"/></nat></forward>
  <bridge name="br0m" stp="on" delay="0"/>
  <domain name="cluster0.ocp.lab" localOnly="yes"/>
  <ip address="10.0.0.1" netmask="255.255.255.0">
    <dhcp>
      <range start="10.0.0.128" end="10.0.0.254"/>
      <host mac="52:54:00:00:00:0a" name="cluster0-node0" ip="10.0.0.10"/>
    </dhcp>
  </ip>
  <dnsmasq:options>
    <dnsmasq:option value="address=/.apps.cluster0.ocp.lab/10.0.0.6"/>
    <dnsmasq:option value="address=/api.cluster0.ocp.lab/10.0.0.5"/>
    <dnsmasq:option value="address=/api-int.cluster0.ocp.lab/10.0.0.5"/>
  </dnsmasq:options>
</network>

<network>
  <name>cluster0-trunk</name>
  <bridge name="br0t" stp="on" delay="0"/>
  <mtu size="9000"/>
</network>
```
