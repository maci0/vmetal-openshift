#!/usr/bin/env bash
# Build the agent-based discovery ISO for a cluster:
#   render configs -> openshift-install agent create image -> place the ISO.
#
#   ./build-iso.sh                 # cluster0 (default)
#   ./build-iso.sh prod            # a named cluster from group_vars/all.yml
#   CLUSTER=prod ./build-iso.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
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

# Clear stale artifacts from a prior build BEFORE rendering, so old manifests
# (e.g. openshift/cluster-scheduler-02-config.yml) never leak into a new ISO.
# generate-configs re-renders the install/agent yamls fresh.
if [[ -d "$CLUSTER_DIR" ]]; then
  log "Clearing previous build artifacts in $CLUSTER_DIR"
  rm -rf "$CLUSTER_DIR/openshift" "$CLUSTER_DIR/auth"
  rm -f "$CLUSTER_DIR"/agent.*.iso \
        "$CLUSTER_DIR/.openshift_install_state.json" \
        "$CLUSTER_DIR/.openshift_install.log"
fi

log "Rendering install + agent configs"
( cd ansible && "$AP" lifecycle/generate-configs.yml )

[[ -f "$CLUSTER_DIR/install-config.yaml" ]] \
  || die "no config for '$CLUSTER': add it to the clusters list in ansible/group_vars/all.yml"

# IPI clusters have no agent-config and build no ISO (metal3 drives the BMC).
if [[ ! -f "$CLUSTER_DIR/agent-config.yaml" ]]; then
  die "'$CLUSTER' is an IPI cluster (no discovery ISO). Provision with:
       openshift-install --dir clusters/$CLUSTER create cluster"
fi

log "Building discovery ISO ($("$OI" version | head -1))"
"$OI" --dir "$CLUSTER_DIR" agent create image

iso="$(find "$CLUSTER_DIR" -maxdepth 1 -name 'agent.*.iso' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-)"
[[ -n "$iso" ]] || die "openshift-install did not produce an ISO"

dest="$ROOT/build/discovery_image_${CLUSTER}.iso"
mv -f "$iso" "$dest"
log "Wrote $dest"
echo "Next: cd ansible && ansible-playbook lifecycle/setup.yml   # VMs boot this ISO"
