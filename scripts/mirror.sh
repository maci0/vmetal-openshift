#!/usr/bin/env bash
# Mirror registry for disconnected installs. Runs a TLS registry:2 container on
# the host (machine gateway), then mirrors the OpenShift release into it with
# `oc adm release mirror`. The CA it emits (certs/mirror/ca.pem) is injected into
# install-config as additionalTrustBundle when a cluster has `disconnected: true`.
# Mirrors the FRR/NFS/HAProxy host-appliance pattern.
#
#   scripts/mirror.sh [cluster] up        # start the registry only
#   scripts/mirror.sh [cluster] down      # stop the registry
#   scripts/mirror.sh [cluster] release   # start + mirror the release (default)
#
# Env: MIRROR_PORT (5000), OCP_VERSION (else the bootstrapped installer's version).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CLUSTER="${1:-${CLUSTER:-cluster0}}"
ACTION="${2:-release}"
PORT="${MIRROR_PORT:-5000}"
NAME="vmetal-mirror"
CERTS="$ROOT/certs/mirror"
DATA="$ROOT/build/mirror/data"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }

[[ -x "$ROOT/.venv/bin/ansible-playbook" ]] && AP="$ROOT/.venv/bin/ansible-playbook" || AP="ansible-playbook"
OI="$ROOT/build/openshift-install/openshift-install"; [[ -x "$OI" ]] || OI="$(command -v openshift-install || true)"
OC="$ROOT/build/oc422/oc"; [[ -x "$OC" ]] || OC="$ROOT/build/openshift-install/oc"; [[ -x "$OC" ]] || OC="$(command -v oc || true)"
# This script stays bash (the registry container is not split into a playbook)
# because its main job, `oc adm release mirror`, has no Ansible module. The CLI is
# docker/podman compatible for `run`. The host appliances that are pure containers
# (haproxy/nfs/frr) use community.docker via ansible/tasks/container_runtime.yml.
ENGINE="$(command -v docker || command -v podman || true)"
[[ -n "$ENGINE" ]] || die "need docker or podman for the mirror registry"
command -v jq >/dev/null || die "jq required"

# Machine gateway = where the registry listens and what the nodes pull from.
gw() {
  local topo; topo="$(mktemp)"
  ( cd ansible && "$AP" dump-topology.yml -e out="$topo" ) >/dev/null 2>&1
  jq -r --arg c "$CLUSTER" '.[] | select(.name==$c) | .machine_gateway' "$topo"; rm -f "$topo"
}

if [[ "$ACTION" == "down" ]]; then
  if "$ENGINE" rm -f "$NAME" >/dev/null 2>&1; then log "removed $NAME"; else log "$NAME not running"; fi
  exit 0
fi

GW="$(gw)"; [[ -n "$GW" ]] || die "could not resolve machine_gateway for '$CLUSTER'"
REG="${GW}:${PORT}"

# Self-signed TLS cert valid for the gateway IP (and localhost); the cert is its
# own CA, injected as the install-config trust bundle.
if [[ ! -s "$CERTS/cert.pem" || ! -s "$CERTS/key.pem" ]]; then
  log "Generating mirror TLS cert (SAN: $GW)"
  mkdir -p "$CERTS"
  openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
    -keyout "$CERTS/key.pem" -out "$CERTS/cert.pem" -subj "/CN=$GW" \
    -addext "subjectAltName=IP:${GW},IP:127.0.0.1,DNS:localhost"
  cp -f "$CERTS/cert.pem" "$CERTS/ca.pem"   # self-signed: cert == CA (the trust bundle)
fi

# Start (or restart) the registry on the host network.
if ! "$ENGINE" ps --filter "name=$NAME" --filter status=running --format '{{.Names}}' | grep -q "$NAME"; then
  mkdir -p "$DATA"
  "$ENGINE" rm -f "$NAME" >/dev/null 2>&1 || true
  log "Starting mirror registry ($REG)"
  "$ENGINE" run -d --name "$NAME" --restart unless-stopped --network host \
    -v "$DATA:/var/lib/registry" -v "$CERTS:/certs:ro" \
    -e "REGISTRY_HTTP_ADDR=0.0.0.0:${PORT}" \
    -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/cert.pem \
    -e REGISTRY_HTTP_TLS_KEY=/certs/key.pem \
    docker.io/library/registry:2 >/dev/null
  sleep 2
fi
# The registry binds 0.0.0.0, so it is reachable on localhost from the host always,
# and at $REG (the machine gateway) from cluster nodes once that network is up.
curl -sk --max-time 5 "https://127.0.0.1:${PORT}/v2/" >/dev/null \
  || die "registry not responding at https://127.0.0.1:${PORT}/v2/"
log "Registry up: https://${REG} (CA: $CERTS/ca.pem)"
[[ "$ACTION" == "up" ]] && exit 0

# Mirror the release. Version = OCP_VERSION or the bootstrapped installer's version.
[[ -n "$OI" && -x "$OI" ]] || die "openshift-install not found; run scripts/bootstrap.sh"
[[ -n "$OC" && -x "$OC" ]] || die "oc not found; run scripts/bootstrap.sh"
[[ -s pull-secret.json ]] || die "pull-secret.json required to mirror from quay.io"
VER="${OCP_VERSION:-$("$OI" version | awk '/^openshift-install/{print $2; exit}')}"
[[ -n "$VER" ]] || die "could not determine OCP version"
log "Mirroring OpenShift $VER release into $REG/openshift/release (large, slow)"
"$OC" adm release mirror --insecure \
  --registry-config=pull-secret.json \
  --from="quay.io/openshift-release-dev/ocp-release:${VER}-x86_64" \
  --to="${REG}/openshift/release" \
  --to-release-image="${REG}/openshift/release:${VER}"
log "Mirror complete. Set 'disconnected: true' on the cluster and rebuild configs."
