#!/usr/bin/env bash
# One-shot single-node UPI install (platform: none):
#   build ignition ISO -> provision the VM -> boot it via Redfish -> wait.
# The node installs itself from the ignition-embedded RHCOS live ISO
# (bootstrap-in-place), so there is no separate bootstrap node and no external
# load balancer (api/ingress collapse onto the single node IP).
#
# Multi-node UPI is not implemented (see docs/upi-plan.md); this is SNO only and
# validate.yml enforces that.
#
#   scripts/install-upi.sh [cluster]      (or CLUSTER=...)
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

command -v jq >/dev/null || die "jq required"
if [[ "$(id -u)" == 0 ]] || id -nG | grep -qw libvirt; then BECOME=(-e use_become=false); else BECOME=(); fi
ap() { ( cd "$ROOT/ansible" && "$AP" "$@" ); }

log "Building single-node UPI ignition ISO"
./scripts/build-ignition.sh "$CLUSTER"

log "Provisioning libvirt (networks, volumes, VM)"
ap setup.yml "${BECOME[@]}"

# Topology facts for this cluster (via jq, no embedded code).
topo="$(mktemp)"; ap dump-topology.yml -e out="$topo" >/dev/null 2>&1
read -r BMC_HOST FQDN < <(
  jq -r --arg c "$CLUSTER" '.[] | select(.name==$c) | "\(.bmc_host) \(.fqdn)"' "$topo"
) || true
rm -f "$topo"
[[ -n "${FQDN:-}" ]] || die "cluster '$CLUSTER' not found in topology (check group_vars/all.yml clusters)"

log "Serving the ISO + driving the BMC"
curl -sk --max-time 5 "https://${BMC_HOST}:8000/redfish/v1/" | grep -q RedfishVersion \
  || die "sushy Redfish not reachable at ${BMC_HOST}:8000. Start it: make sushy-install"
"$PY" -m http.server "$HTTP_PORT" --directory "$ROOT/build" >/tmp/vmetal-iso-http.log 2>&1 &
http_pid=$!
trap 'kill "$http_pid" 2>/dev/null || true' EXIT
iso="upi_image_${CLUSTER}.iso"
for _ in $(seq 1 10); do curl -fsS --max-time 3 -o /dev/null "http://127.0.0.1:${HTTP_PORT}/${iso}" && break; sleep 1; done
curl -fsS --max-time 3 -o /dev/null "http://127.0.0.1:${HTTP_PORT}/${iso}" \
  || die "ISO HTTP server not serving on :${HTTP_PORT} (see /tmp/vmetal-iso-http.log)"
ap bmc.yml -e cluster="$CLUSTER" -e bmc_action=boot-iso \
  -e iso_base_url="http://127.0.0.1:${HTTP_PORT}" -e iso_name="$iso"

if ! getent hosts "api.${FQDN}" >/dev/null 2>&1; then
  log "note: host cannot resolve api.${FQDN} yet; run 'make host-dns' if wait-for stalls"
fi

log "Waiting for install to complete (this takes a while)"
"$OI" --dir "clusters/${CLUSTER}" wait-for install-complete --log-level=info

log "Install complete. Access details:"
./scripts/creds.sh "$CLUSTER" || true
