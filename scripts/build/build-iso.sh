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
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

CLUSTER="${1:-${CLUSTER:-cluster0}}"
require_cluster_name "$CLUSTER"
CLUSTER_DIR="$ROOT/clusters/$CLUSTER"

resolve_ansible
resolve_openshift_install

# Clear stale artifacts from a prior build BEFORE rendering, so old manifests
# (e.g. openshift/cluster-scheduler-02-config.yml) never leak into a new ISO.
# Never wipe auth/ — that holds the live kubeconfig after install.
clear_install_artifacts "$CLUSTER_DIR"

log "Rendering install + agent configs"
( cd ansible && "$AP" lifecycle/generate-configs.yml )

[[ -f "$CLUSTER_DIR/install-config.yaml" ]] \
  || die "no config for '$CLUSTER': add it to the clusters list in ansible/group_vars/all.yml"

# Detect install mode: agent has agent-config; IPI/UPI do not.
if [[ ! -f "$CLUSTER_DIR/agent-config.yaml" ]]; then
  if grep -qE '^\s*bootstrapInPlace:' "$CLUSTER_DIR/install-config.yaml" 2>/dev/null \
     || grep -qE '^\s*none:\s*\{\}' "$CLUSTER_DIR/install-config.yaml" 2>/dev/null; then
    die "'$CLUSTER' looks like a UPI cluster (no discovery ISO). Use:
       make install-upi CLUSTER=$CLUSTER"
  fi
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
