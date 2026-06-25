# Disconnected (air-gapped) install

<sub>[Home](../README.md) · [Architecture](architecture.md) · [Requirements](requirements.md) · [IPI vs agent](ipi-vs-agent.md) · [Fidelity](fidelity.md) · **Disconnected** · [Variables](variables.md) · [Examples](examples.md) · [Memory](memory-optimization.md) · [Virtualization](virtualization.md) · [Resilience](resilience.md) · [Cloud](cloud.md) · [Troubleshooting](troubleshooting.md)</sub>

By default the machine network NATs to the host uplink, so the lab is
**connected**: nodes pull the release payload and operator images from the
internet. Production baremetal is frequently disconnected. `make mirror` plus a
`disconnected: true` switch wire most of this up; the release payload is covered,
operator catalogs are the remaining manual piece.

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

## Doing it in this lab

1. **Mirror the release**: `make mirror CLUSTER=c`. This starts a TLS `registry:2`
   container on the machine gateway (`<gw>:5000`, a host appliance like NFS/FRR/
   HAProxy) and runs `oc adm release mirror` to copy the release payload for the
   bootstrapped version into `<gw>:5000/openshift/release`. It emits a self-signed
   CA at `certs/mirror/ca.pem`. (`make mirror-down` stops the registry; `OCP_VERSION`
   overrides the version.)
2. **Flip the switch**: set `disconnected: true` (global in `group_vars`, or per
   cluster). `generate-configs` then injects into `install-config.yaml`:
   * `imageDigestSources` mapping `ocp-release` / `ocp-v4.0-art-dev` to the mirror,
   * `additionalTrustBundle` from `certs/mirror/ca.pem`.
3. **Cut the cord** (optional, for a true air gap): change the machine network's
   `kind` from `nat` to `isolated` in the `networks` map. `isolated` renders a
   libvirt network with no forward, keeping DHCP/DNS but no route out:
   ```yaml
   networks:
     machine: { cidr: "10.{c}.0.0/24", kind: isolated, dns: true }
   ```
4. Build and install as usual (`make iso` / `make install` / `make install-upi`).

## Remaining manual pieces

`make mirror` covers the **release payload**, which is what an install needs.
Still manual:

* **Operator catalogs**: mirror with `oc-mirror` (an `ImageSetConfiguration`) into
  the same registry and apply the generated `CatalogSource` / `ImageDigestMirrorSet`.
  The Day-2 operators here (MetalLB, LVMS, CNV) need this in a true air gap.
* **NTP**: point `ntp_servers` at an internal source (not a pool) for a real air gap.
* **Proxy / telemetry**: add `proxy:` to install-config if egress is via a proxy;
  Insights is disabled by the disconnected pull secret.
