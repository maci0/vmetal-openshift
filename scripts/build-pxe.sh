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
# See docs/upi-plan.md (virtual-media vs PXE; multi-node tiers).
#   ./build-pxe.sh [cluster]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CLUSTER="${1:-${CLUSTER:-cluster0}}"
CLUSTER_DIR="$ROOT/clusters/$CLUSTER"
BUILD="$ROOT/build"
HTTP_PORT="${HTTP_PORT:-8099}"
IPXE_IMAGE="${IPXE_IMAGE:-fedora:latest}"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }

[[ -x "$ROOT/.venv/bin/ansible-playbook" ]] && AP="$ROOT/.venv/bin/ansible-playbook" || AP="ansible-playbook"
OI="$BUILD/openshift-install/openshift-install"; [[ -x "$OI" ]] || OI="$(command -v openshift-install || true)"
[[ -n "$OI" && -x "$OI" ]] || die "openshift-install not found, run scripts/bootstrap.sh"
command -v jq >/dev/null || die "jq required"
DOCKER="$(command -v docker || command -v podman || true)"

mkdir -p "$BUILD/tftp"

# Topology facts: gateway + each node's mac/role (for the per-MAC iPXE script).
topo="$(mktemp)"; ( cd ansible && "$AP" dump-topology.yml -e out="$topo" ) >/dev/null 2>&1
gw="$(jq -r --arg c "$CLUSTER" '.[] | select(.name==$c) | .machine_gateway' "$topo")"
[[ -n "$gw" ]] || die "could not resolve machine_gateway for '$CLUSTER'"
nodes_json="$(jq -c --arg c "$CLUSTER" '[.[] | select(.name==$c) | .nodes[] | {mac, role}]' "$topo")"
rm -f "$topo"
multinode=false; grep -q '"role":"bootstrap"' <<<"$nodes_json" && multinode=true

# 1. ipxe.efi (UEFI), extracted from a fedora image (no reliable upstream binary).
if [[ ! -s "$BUILD/tftp/ipxe.efi" ]]; then
  [[ -n "$DOCKER" ]] || die "need docker/podman to obtain ipxe.efi (or drop one at build/tftp/ipxe.efi)"
  log "Extracting ipxe.efi from $IPXE_IMAGE"
  "$DOCKER" run --rm -v "$BUILD/tftp:/out" "$IPXE_IMAGE" bash -c \
    "dnf install -y -q ipxe-bootimgs >/dev/null 2>&1 && cp /usr/share/ipxe/ipxe-x86_64.efi /out/ipxe.efi"
  [[ -s "$BUILD/tftp/ipxe.efi" ]] || die "failed to extract ipxe.efi"
fi

# 2. ignition(s).
if [[ -d "$CLUSTER_DIR" ]]; then
  rm -rf "$CLUSTER_DIR/openshift" "$CLUSTER_DIR/auth"
  rm -f "$CLUSTER_DIR"/*.ign "$CLUSTER_DIR/.openshift_install_state.json" "$CLUSTER_DIR/.openshift_install.log"
fi
rm -f "$BUILD/${CLUSTER}.ign" "$BUILD/bootstrap.ign" "$BUILD/master.ign" "$BUILD/worker.ign"
log "Rendering install config"
( cd ansible && "$AP" generate-configs.yml )
[[ -f "$CLUSTER_DIR/install-config.yaml" ]] || die "no install-config for '$CLUSTER'"
if $multinode; then
  log "Creating cluster ignition configs (bootstrap/master/worker)"
  "$OI" --dir "$CLUSTER_DIR" create ignition-configs
  for r in bootstrap master worker; do
    [[ -f "$CLUSTER_DIR/$r.ign" ]] || die "missing $r.ign"
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
pxe_json="$("$OI" coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe')"
get() {
  local url; url="$(jq -r ".${1}.location" <<<"$pxe_json")"
  [[ -n "$url" && "$url" != null ]] || die "no PXE $1 in coreos stream"
  if [[ ! -s "$BUILD/$2" ]]; then log "Downloading $2"; curl -fL --retry 3 -o "$BUILD/$2.tmp" "$url"; mv -f "$BUILD/$2.tmp" "$BUILD/$2"; fi
}
get kernel    rhcos-live-kernel
get initramfs rhcos-live-initramfs.img
get rootfs    rhcos-live-rootfs.img

# 4. boot.ipxe. Common kargs; the ignition URL is chosen per role / per MAC.
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
    echo "kernel ${base}/rhcos-live-kernel ${common} coreos.inst.install_dev=/dev/sda coreos.inst.ignition_url=\${ign}"
  else
    # Single-node: the bootstrap-in-place ignition already does the install, applied
    # via the firstboot path.
    echo "kernel ${base}/rhcos-live-kernel ${common} ignition.firstboot ignition.platform.id=metal ignition.config.url=${base}/${CLUSTER}.ign"
  fi
  echo "initrd --name main ${base}/rhcos-live-initramfs.img"
  echo "boot"
} > "$BUILD/boot.ipxe"
log "Wrote $BUILD/boot.ipxe (gateway $gw, multinode=$multinode)"
echo "Next: scripts/install-upi.sh $CLUSTER"
