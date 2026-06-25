#!/usr/bin/env bash
# Prepare single-node UPI for PXE / iPXE network boot (no media):
#   ignition  -> create single-node-ignition-config, served over HTTP
#   ipxe.efi  -> UEFI bootloader served over tftp (extracted from a fedora image)
#   kernel / initramfs / rootfs -> RHCOS PXE artifacts served over HTTP
#   boot.ipxe -> the iPXE script that boots the kernel with the ignition URL
#
# The libvirt machine network's dnsmasq (configured by setup.yml when the cluster
# is boot_via: pxe) hands ipxe.efi to UEFI firmware, then an http boot.ipxe to
# iPXE. See docs/upi-plan.md (virtual-media vs PXE).
#
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

# 1. ipxe.efi (UEFI). No reliable upstream binary, so extract it from a fedora
# image's ipxe-bootimgs (matches the lab's other docker/podman host appliances).
if [[ ! -s "$BUILD/tftp/ipxe.efi" ]]; then
  [[ -n "$DOCKER" ]] || die "need docker/podman to obtain ipxe.efi (or drop one at build/tftp/ipxe.efi)"
  log "Extracting ipxe.efi from $IPXE_IMAGE"
  "$DOCKER" run --rm -v "$BUILD/tftp:/out" "$IPXE_IMAGE" bash -c \
    "dnf install -y -q ipxe-bootimgs >/dev/null 2>&1 && cp /usr/share/ipxe/ipxe-x86_64.efi /out/ipxe.efi"
  [[ -s "$BUILD/tftp/ipxe.efi" ]] || die "failed to extract ipxe.efi"
fi

# 2. ignition (single-node bootstrap-in-place), served over http as <cluster>.ign.
if [[ -d "$CLUSTER_DIR" ]]; then
  rm -rf "$CLUSTER_DIR/openshift" "$CLUSTER_DIR/auth"
  rm -f "$CLUSTER_DIR"/*.ign "$CLUSTER_DIR/.openshift_install_state.json" "$CLUSTER_DIR/.openshift_install.log"
fi
log "Rendering install config"
( cd ansible && "$AP" generate-configs.yml )
[[ -f "$CLUSTER_DIR/install-config.yaml" ]] || die "no install-config for '$CLUSTER'"
log "Creating single-node ignition"
"$OI" --dir "$CLUSTER_DIR" create single-node-ignition-config
ign="$CLUSTER_DIR/bootstrap-in-place-for-live-iso.ign"
[[ -f "$ign" ]] || die "no $ign (is this a single-node cluster?)"
cp -f "$ign" "$BUILD/${CLUSTER}.ign"

# 3. RHCOS PXE artifacts (kernel / initramfs / rootfs), cached by name.
log "Resolving RHCOS PXE artifacts"
pxe_json="$("$OI" coreos print-stream-json | jq -r '.architectures.x86_64.artifacts.metal.formats.pxe')"
get() {  # key dest
  local url; url="$(jq -r ".${1}.location" <<<"$pxe_json")"
  [[ -n "$url" && "$url" != null ]] || die "no PXE $1 in coreos stream"
  if [[ ! -s "$BUILD/$2" ]]; then log "Downloading $2"; curl -fL --retry 3 -o "$BUILD/$2.tmp" "$url"; mv -f "$BUILD/$2.tmp" "$BUILD/$2"; fi
}
get kernel    rhcos-live-kernel
get initramfs rhcos-live-initramfs.img
get rootfs    rhcos-live-rootfs.img

# 4. boot.ipxe (served over http to iPXE). Gateway = the machine net .1 (the host).
topo="$(mktemp)"; ( cd ansible && "$AP" dump-topology.yml -e out="$topo" ) >/dev/null 2>&1
gw="$(jq -r --arg c "$CLUSTER" '.[] | select(.name==$c) | .machine_gateway' "$topo")"; rm -f "$topo"
[[ -n "$gw" ]] || die "could not resolve machine_gateway for '$CLUSTER'"
base="http://${gw}:${HTTP_PORT}"
cat > "$BUILD/boot.ipxe" <<EOF
#!ipxe
kernel ${base}/rhcos-live-kernel initrd=main coreos.live.rootfs_url=${base}/rhcos-live-rootfs.img ignition.firstboot ignition.platform.id=metal ignition.config.url=${base}/${CLUSTER}.ign console=tty0 console=ttyS0,115200n8
initrd --name main ${base}/rhcos-live-initramfs.img
boot
EOF
log "Wrote $BUILD/boot.ipxe (gateway $gw)"
echo "Next: scripts/install-upi.sh $CLUSTER   (boot_via: pxe drives the netboot)"
