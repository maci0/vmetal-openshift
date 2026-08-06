#!/usr/bin/env bash
# Prepare UPI for PXE / iPXE network boot (no media). Single-node uses a
# bootstrap-in-place ignition; multi-node uses bootstrap/master/worker ignitions
# and a transient bootstrap node, with an iPXE script that hands each MAC its
# role's ignition.
#
#   ignition  -> create (single-node|cluster) ignition-config(s), served over HTTP
#   ipxe.efi  -> UEFI bootloader served over tftp (extracted from a fedora image)
#   kernel / initramfs / rootfs -> RHCOS PXE artifacts served over HTTP
#   boot.ipxe -> iPXE script: picks the role ignition by MAC, boots RHCOS live
#
# See docs/ipi-vs-agent.md (UPI).
#   ./build-pxe.sh [cluster]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

CLUSTER="${1:-${CLUSTER:-cluster0}}"
require_cluster_name "$CLUSTER"
CLUSTER_DIR="$ROOT/clusters/$CLUSTER"
BUILD="$ROOT/build"
HTTP_PORT="${HTTP_PORT:-8099}"
IPXE_IMAGE="${IPXE_IMAGE:-fedora:latest}"
ARCH="${ARCH:-x86_64}"

resolve_ansible
resolve_openshift_install
command -v jq >/dev/null || die "jq required"
DOCKER="$(command -v docker || command -v podman || true)"

mkdir -p "$BUILD/tftp" "$BUILD/$CLUSTER"

# Topology facts: gateway + each node's mac/role (for the per-MAC iPXE script).
topo="$(dump_topology)"
gw="$(jq -r --arg c "$CLUSTER" '.[] | select(.name==$c) | .machine_gateway' "$topo")"
[[ -n "$gw" && "$gw" != null ]] || die "could not resolve machine_gateway for '$CLUSTER'"
# Prefer topology pxe_http_port if ever exported; fall back to HTTP_PORT.
pxe_port="$(jq -r --arg c "$CLUSTER" '.[] | select(.name==$c) | .pxe_http_port // empty' "$topo" 2>/dev/null || true)"
[[ -n "${pxe_port:-}" ]] && HTTP_PORT="$pxe_port"
nodes_json="$(jq -c --arg c "$CLUSTER" '[.[] | select(.name==$c) | .nodes[] | {mac, role}]' "$topo")"
# install device: per-cluster override, else first node's OS disk target
install_dev="$(jq -r --arg c "$CLUSTER" '
  .[] | select(.name==$c) |
  ( .upi_install_disk // ("/dev/" + .nodes[0].disks[0].target) )
' "$topo")"
[[ -n "$install_dev" && "$install_dev" != "/dev/null" && "$install_dev" != "null" ]] || install_dev="/dev/sda"
rm -f "$topo"
multinode=false; grep -q '"role":"bootstrap"' <<<"$nodes_json" && multinode=true

# 1. ipxe.efi (UEFI), extracted from a fedora image (no reliable upstream binary).
if [[ ! -s "$BUILD/tftp/ipxe.efi" ]]; then
  [[ -n "$DOCKER" ]] || die "need docker/podman to obtain ipxe.efi (or drop one at build/tftp/ipxe.efi)"
  log "Extracting ipxe.efi from $IPXE_IMAGE"
  "$DOCKER" run --rm -v "$BUILD/tftp:/out:Z" "$IPXE_IMAGE" bash -c \
    "dnf install -y -q ipxe-bootimgs >/dev/null 2>&1 && cp /usr/share/ipxe/ipxe-x86_64.efi /out/ipxe.efi"
  [[ -s "$BUILD/tftp/ipxe.efi" ]] || die "failed to extract ipxe.efi"
fi

# 2. ignition(s). Keep auth/; wipe only regenerateable installer state.
clear_install_artifacts "$CLUSTER_DIR"
rm -f "$BUILD/${CLUSTER}.ign" "$BUILD/$CLUSTER"/{bootstrap,master,worker}.ign \
      "$BUILD/bootstrap.ign" "$BUILD/master.ign" "$BUILD/worker.ign"
log "Rendering install config"
( cd ansible && "$AP" lifecycle/generate-configs.yml )
[[ -f "$CLUSTER_DIR/install-config.yaml" ]] || die "no install-config for '$CLUSTER'"
if $multinode; then
  log "Creating cluster ignition configs (bootstrap/master/worker)"
  "$OI" --dir "$CLUSTER_DIR" create ignition-configs
  for r in bootstrap master worker; do
    [[ -f "$CLUSTER_DIR/$r.ign" ]] || die "missing $r.ign"
    # Namespace under build/<cluster>/ and keep legacy top-level copies for
    # single-cluster labs (dnsmasq points at /boot.ipxe + top-level ign paths).
    cp -f "$CLUSTER_DIR/$r.ign" "$BUILD/$CLUSTER/$r.ign"
    cp -f "$CLUSTER_DIR/$r.ign" "$BUILD/$r.ign"
  done
else
  log "Creating single-node ignition"
  "$OI" --dir "$CLUSTER_DIR" create single-node-ignition-config
  [[ -f "$CLUSTER_DIR/bootstrap-in-place-for-live-iso.ign" ]] || die "no single-node ignition"
  cp -f "$CLUSTER_DIR/bootstrap-in-place-for-live-iso.ign" "$BUILD/${CLUSTER}.ign"
fi

# 3. RHCOS PXE artifacts (kernel / initramfs / rootfs), cached by name.
log "Resolving RHCOS PXE artifacts"
pxe_json="$("$OI" coreos print-stream-json | jq -r --arg a "$ARCH" '.architectures[$a].artifacts.metal.formats.pxe')"
[[ -n "$pxe_json" && "$pxe_json" != null ]] || die "no PXE artifacts in coreos stream for arch=$ARCH"
get() {
  local url; url="$(jq -r ".${1}.location" <<<"$pxe_json")"
  [[ -n "$url" && "$url" != null ]] || die "no PXE $1 in coreos stream"
  if [[ ! -s "$BUILD/$2" ]]; then log "Downloading $2"; curl -fL --retry 3 -o "$BUILD/$2.tmp" "$url"; mv -f "$BUILD/$2.tmp" "$BUILD/$2"; fi
}
get kernel    rhcos-live-kernel
get initramfs rhcos-live-initramfs.img
get rootfs    rhcos-live-rootfs.img

# 4. boot.ipxe. Common kargs; the ignition URL is chosen per role / per MAC.
#    Written to build/boot.ipxe (global; last cluster wins for multi-cluster PXE)
#    and build/<cluster>/boot.ipxe for namespaced use.
base="http://${gw}:${HTTP_PORT}"
common="initrd=main coreos.live.rootfs_url=${base}/rhcos-live-rootfs.img console=tty0 console=ttyS0,115200n8"
{
  echo "#!ipxe"
  if $multinode; then
    # Multi-node: each node's ignition is a pointer config for an already-installed
    # RHCOS, so the live env must install to disk (coreos.inst.*) then reboot. The
    # ignition is chosen per role by the machine-net MAC (default worker).
    echo "set ign ${base}/worker.ign"
    jq -r '.[] | select(.role!="worker") | "iseq ${net0/mac} \(.mac) && set ign '"${base}"'/\(.role).ign ||"' <<<"$nodes_json"
    echo "kernel ${base}/rhcos-live-kernel ${common} coreos.inst.install_dev=${install_dev} coreos.inst.ignition_url=\${ign}"
  else
    # Single-node: the bootstrap-in-place ignition already does the install, applied
    # via the firstboot path.
    echo "kernel ${base}/rhcos-live-kernel ${common} ignition.firstboot ignition.platform.id=metal ignition.config.url=${base}/${CLUSTER}.ign"
  fi
  echo "initrd --name main ${base}/rhcos-live-initramfs.img"
  echo "boot"
} | tee "$BUILD/boot.ipxe" > "$BUILD/$CLUSTER/boot.ipxe"
log "Wrote $BUILD/boot.ipxe (gateway $gw, port $HTTP_PORT, multinode=$multinode)"
echo "Next: scripts/install-upi.sh $CLUSTER"
