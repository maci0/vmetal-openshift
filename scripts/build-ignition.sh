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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CLUSTER="${1:-${CLUSTER:-cluster0}}"
CLUSTER_DIR="$ROOT/clusters/$CLUSTER"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }

# ansible-playbook (prefer project venv)
if [[ -x "$ROOT/.venv/bin/ansible-playbook" ]]; then
  AP="$ROOT/.venv/bin/ansible-playbook"
else
  command -v ansible-playbook >/dev/null 2>&1 || die "ansible-playbook not found, run scripts/bootstrap.sh"
  AP="ansible-playbook"
fi

# openshift-install (self-contained copy first, then PATH)
OI="$ROOT/build/openshift-install/openshift-install"
[[ -x "$OI" ]] || OI="$(command -v openshift-install || true)"
[[ -n "$OI" && -x "$OI" ]] || die "openshift-install not found, run scripts/bootstrap.sh"

# coreos-installer (self-contained copy first, then PATH)
CI="$ROOT/build/coreos-installer"
[[ -x "$CI" ]] || CI="$(command -v coreos-installer || true)"
[[ -n "$CI" && -x "$CI" ]] || die "coreos-installer not found, run scripts/bootstrap.sh"

command -v jq >/dev/null || die "jq required"

# Clear stale artifacts so a re-build never reuses an old ignition or state.
if [[ -d "$CLUSTER_DIR" ]]; then
  log "Clearing previous build artifacts in $CLUSTER_DIR"
  rm -rf "$CLUSTER_DIR/openshift" "$CLUSTER_DIR/auth"
  rm -f "$CLUSTER_DIR"/*.ign \
        "$CLUSTER_DIR/.openshift_install_state.json" \
        "$CLUSTER_DIR/.openshift_install.log"
fi

log "Rendering install config"
( cd ansible && "$AP" generate-configs.yml )

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
        | jq -r '.architectures.x86_64.artifacts.metal.formats.iso.disk.location')"
  [[ -n "$url" && "$url" != null ]] || die "could not resolve RHCOS live ISO URL from coreos stream"
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
