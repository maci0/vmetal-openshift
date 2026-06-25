# Disconnected (air-gapped) install

<sub>[Home](../README.md) · [Architecture](architecture.md) · [Requirements](requirements.md) · [IPI vs agent](ipi-vs-agent.md) · [Fidelity](fidelity.md) · **Disconnected** · [Variables](variables.md) · [Examples](examples.md) · [Memory](memory-optimization.md) · [Virtualization](virtualization.md) · [Resilience](resilience.md) · [Cloud](cloud.md) · [Troubleshooting](troubleshooting.md)</sub>

By default the machine network NATs to the host uplink, so the lab is
**connected**: nodes pull the release payload and operator images from the
internet. Production baremetal is frequently disconnected. This documents what
that requires; the lab does not wire it automatically yet.

## What disconnected needs

1. **A mirror registry** reachable by the cluster (and the installer host):
   `mirror-registry` (mini Quay) or any registry, with TLS.
2. **Mirrored content** via `oc-mirror` (v2) or `oc adm release mirror`:
   * the OpenShift release payload for the target version
   * operator catalog(s) and any operators you need
   * additional images (samples, must-gather) as desired
3. **install-config additions**:
   * `imageDigestSources` (or an `ImageDigestMirrorSet` manifest) mapping the
     upstream registries to your mirror
   * `additionalTrustBundle`: the mirror registry CA PEM
   * the pull secret restricted to the mirror (plus Red Hat entitlement for
     mirroring)
4. **Local infra on the management/OOB side**:
   * DNS (already provided by libvirt dnsmasq here)
   * NTP from a local source (set `ntp_servers` to an internal host, not a pool)
   * an HTTP server for boot artifacts if you use a minimal ISO / PXE
5. **Telemetry disabled** (no Insights/phone-home) and any proxy via
   install-config `proxy:` if egress is through one.

## Emulating it in this lab

1. Run a registry on the host, e.g. `mirror-registry install` or a podman Quay,
   listening on the OOB or machine gateway IP.
2. Mirror a release with `oc-mirror` to that registry.
3. Drop NAT on the machine network so the nodes truly have no internet: change
   its `kind` from `nat` to `isolated` in the `networks` map
   (`ansible/group_vars/all.yml`). `isolated` renders a libvirt network with no
   forward, keeping DHCP/DNS but no route out:
   ```yaml
   networks:
     machine: { cidr: "10.{c}.0.0/24", kind: isolated, dns: true }
   ```
4. Add to install-config (a `disconnected:` block of vars would drive this; not
   yet templated). Minimum, by hand in the generated `install-config.yaml`:
   ```yaml
   additionalTrustBundle: |
     -----BEGIN CERTIFICATE-----
     ... mirror registry CA ...
     -----END CERTIFICATE-----
   imageDigestSources:
   - mirrors:
     - registry.example.lab:8443/openshift/release
     source: quay.io/openshift-release-dev/ocp-v4.0-art-dev
   - mirrors:
     - registry.example.lab:8443/openshift/release-images
     source: quay.io/openshift-release-dev/ocp-release
   ```
5. Point `ntp_servers` at the internal source and rebuild configs.

## Not yet implemented

A first-class `disconnected: true` switch that injects `additionalTrustBundle`,
`imageDigestSources`, internal NTP, and flips the machine net to `forward: none`
would make this one variable. It is intentionally left as a documented manual
step for now.
