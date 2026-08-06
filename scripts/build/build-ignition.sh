#!/usr/bin/env bash
# Build the UPI boot ISO for a single-node cluster (platform: none):
#   render configs -> openshift-install create single-node-ignition-config
#   -> embed the ignition into the RHCOS live ISO with coreos-installer.
#
# This is the ISO/Redfish path for single-node UPI (the counterpart of
# build-iso.sh for agent). Multi-node UPI, and any PXE boot, go through
# build-pxe.sh instead. See docs/ipi-vs-agent.md (UPI).
#
#   ./build-ignition.sh            # cluster0 (default)
#   ./build-ignition.sh sno-upi    # a named upi cluster from group_vars/all.yml
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

CLUSTER="${1:-${CLUSTER:-cluster0}}"
require_cluster_name "$CLUSTER"
CLUSTER_DIR="$ROOT/clusters/$CLUSTER"
ARCH="${ARCH:-x86_64}"

resolve_ansible
resolve_openshift_install

# coreos-installer (self-contained copy first, then PATH)
CI="$ROOT/build/coreos-installer"
[[ -x "$CI" ]] || CI="$(command -v coreos-installer || true)"
[[ -n "$CI" && -x "$CI" ]] || die "coreos-installer not found, run scripts/bootstrap.sh"

command -v jq >/dev/null || die "jq required"

clear_install_artifacts "$CLUSTER_DIR"

log "Rendering install config"
( cd ansible && "$AP" lifecycle/generate-configs.yml )

[[ -f "$CLUSTER_DIR/install-config.yaml" ]] \
  || die "no install-config for '$CLUSTER': add a upi cluster to group_vars/all.yml"

# Single-node ignition (bootstrap-in-place): no separate bootstrap node, the one
# node installs itself from the live ISO. create single-node-ignition-config
# consumes install-config.yaml, hence the re-render above.
log "Creating single-node ignition ($("$OI" version | head -1))"
"$OI" --dir "$CLUSTER_DIR" create single-node-ignition-config

ign="$CLUSTER_DIR/bootstrap-in-place-for-live-iso.ign"
[[ -f "$ign" ]] || die "openshift-install did not produce $ign (is this a single-node cluster?)"

# RHCOS live ISO matching the installer, cached under build/ by name.
rhcos="$ROOT/build/rhcos-live.iso"
if [[ ! -f "$rhcos" ]]; then
  url="$("$OI" coreos print-stream-json \
        | jq -r --arg a "$ARCH" '.architectures[$a].artifacts.metal.formats.iso.disk.location')"
  [[ -n "$url" && "$url" != null ]] || die "could not resolve RHCOS live ISO URL from coreos stream (arch=$ARCH)"
  log "Downloading RHCOS live ISO: $url"
  curl -fL --retry 3 -o "$rhcos.tmp" "$url"
  mv -f "$rhcos.tmp" "$rhcos"
fi

dest="$ROOT/build/upi_image_${CLUSTER}.iso"
rm -f "$dest"   # coreos-installer refuses to overwrite an existing --output file
log "Embedding ignition into a fresh boot ISO"
"$CI" iso ignition embed --force --ignition-file "$ign" --output "$dest" "$rhcos"
log "Wrote $dest"
echo "Next: scripts/install-upi.sh $CLUSTER   (or make install-upi CLUSTER=$CLUSTER)"
