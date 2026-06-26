#!/usr/bin/env bash
# One-shot agent install: build ISO -> provision libvirt -> boot -> wait for the
# cluster. For boot_via=redfish it serves the ISO over HTTP and drives the BMC;
# for boot_via=iso the VMs boot the attached ISO directly.
#   scripts/install.sh [cluster]      (or CLUSTER=...)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CLUSTER="${1:-${CLUSTER:-cluster0}}"
HTTP_PORT="${HTTP_PORT:-8099}"

die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

[[ -x "$ROOT/.venv/bin/ansible-playbook" ]] && AP="$ROOT/.venv/bin/ansible-playbook" || AP="ansible-playbook"
[[ -x "$ROOT/.venv/bin/python" ]] && PY="$ROOT/.venv/bin/python" || PY=python3
OI="$ROOT/build/openshift-install/openshift-install"; [[ -x "$OI" ]] || OI="$(command -v openshift-install || true)"
[[ -n "$OI" && -x "$OI" ]] || die "openshift-install not found; run scripts/bootstrap.sh"

if [[ "$(id -u)" == 0 ]] || id -nG | grep -qw libvirt; then BECOME=(-e use_become=false); else BECOME=(); fi
ap() { ( cd "$ROOT/ansible" && "$AP" "$@" ); }

log "Building discovery ISO"
./scripts/build-iso.sh "$CLUSTER"      # dies for IPI clusters with guidance

log "Provisioning libvirt (networks, volumes, VMs)"
ap lifecycle/setup.yml "${BECOME[@]}"

# Topology facts for this cluster (via jq, no embedded code).
command -v jq >/dev/null || die "jq required"
topo="$(mktemp)"; ap lifecycle/dump-topology.yml -e out="$topo" >/dev/null 2>&1
# tab-delimited so an empty field never collapses and shifts the columns
IFS=$'\t' read -r STATIC_ISO BMC_HOST FQDN < <(
  jq -r --arg c "$CLUSTER" '.[] | select(.name==$c) | [.static_iso, .bmc_host, .fqdn] | @tsv' "$topo"
) || true
rm -f "$topo"
[[ -n "${FQDN:-}" ]] || die "cluster '$CLUSTER' not found in topology (check group_vars/all.yml clusters)"

if [[ "$STATIC_ISO" == "true" ]]; then
  log "boot_via=iso: VMs are booting the attached ISO"
else
  log "boot_via=redfish: serving ISO + driving the BMC"
  curl -sk --max-time 5 "https://${BMC_HOST}:8000/redfish/v1/" | grep -q RedfishVersion \
    || die "sushy Redfish not reachable at ${BMC_HOST}:8000. Start it: make sushy-install"
  "$PY" -m http.server "$HTTP_PORT" --directory "$ROOT/build" >/tmp/vmetal-iso-http.log 2>&1 &
  http_pid=$!
  trap 'kill "$http_pid" 2>/dev/null || true' EXIT
  for _ in $(seq 1 10); do curl -fsS --max-time 3 -o /dev/null "http://127.0.0.1:${HTTP_PORT}/discovery_image_${CLUSTER}.iso" && break; sleep 1; done
  curl -fsS --max-time 3 -o /dev/null "http://127.0.0.1:${HTTP_PORT}/discovery_image_${CLUSTER}.iso" \
    || die "ISO HTTP server not serving on :${HTTP_PORT} (port in use? see /tmp/vmetal-iso-http.log)"
  ap lifecycle/bmc.yml -e cluster="$CLUSTER" -e bmc_action=boot-iso -e iso_base_url="http://127.0.0.1:${HTTP_PORT}"
fi

if ! getent hosts "api.${FQDN}" >/dev/null 2>&1; then
  log "note: host cannot resolve api.${FQDN} yet; run 'make host-dns' if wait-for stalls"
fi

log "Waiting for install to complete (this takes a while)"
"$OI" --dir "clusters/${CLUSTER}" agent wait-for install-complete --log-level=info

log "Install complete. Access details:"
./scripts/creds.sh "$CLUSTER" || true
