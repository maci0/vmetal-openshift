#!/usr/bin/env bash
# One-shot agent install: build ISO -> provision libvirt -> boot -> wait for the
# cluster. For boot_via=redfish it serves the ISO over HTTP and drives the BMC;
# for boot_via=iso the VMs boot the attached ISO directly.
#   scripts/install.sh [cluster]      (or CLUSTER=...)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

CLUSTER="${1:-${CLUSTER:-cluster0}}"
require_cluster_name "$CLUSTER"
HTTP_PORT="${HTTP_PORT:-8099}"

resolve_ansible
resolve_openshift_install
command -v jq >/dev/null || die "jq required"

libvirt_become_args
ap() { ( cd "$ROOT/ansible" && "$AP" "$@" ); }

log "Building discovery ISO"
./scripts/build/build-iso.sh "$CLUSTER"      # dies for IPI/UPI clusters with guidance

log "Provisioning libvirt (networks, volumes, VMs)"
# setup.yml provisions every cluster in group_vars (by design); CLUSTER selects
# which one we boot and wait on below.
ap lifecycle/setup.yml "${BECOME[@]}"

topo="$(dump_topology)"
IFS=$'\t' read -r MODE STATIC_ISO BMC_HOST FQDN < <(
  jq -r --arg c "$CLUSTER" '.[] | select(.name==$c) | [.mode, .static_iso, .bmc_host, .fqdn] | @tsv' "$topo"
) || true
rm -f "$topo"
[[ -n "${FQDN:-}" ]] || die "cluster '$CLUSTER' not found in topology (check group_vars/all.yml clusters)"
[[ "$MODE" == "agent" ]] || die "cluster '$CLUSTER' is mode=$MODE; use make install-upi (upi) or openshift-install create cluster (ipi)"

if [[ "$STATIC_ISO" == "true" || "$STATIC_ISO" == "True" ]]; then
  log "boot_via=iso: VMs are booting the attached ISO"
else
  log "boot_via=redfish: serving ISO + driving the BMC"
  curl -sk --max-time 5 "https://${BMC_HOST}:8000/redfish/v1/" | grep -q RedfishVersion \
    || die "sushy Redfish not reachable at ${BMC_HOST}:8000. Start it: make sushy-install"
  trap 'kill "${http_pid:-}" 2>/dev/null || true' EXIT
  # Redfish virtual media is fetched by sushy on the host -> bind loopback only.
  start_http_server "$HTTP_PORT" "$ROOT/build" "127.0.0.1" "discovery_image_${CLUSTER}.iso"
  ap lifecycle/bmc.yml -e cluster="$CLUSTER" -e bmc_action=boot-iso \
    -e iso_base_url="http://127.0.0.1:${HTTP_PORT}" "${BECOME[@]}"
fi

if ! getent hosts "api.${FQDN}" >/dev/null 2>&1; then
  log "note: host cannot resolve api.${FQDN} yet; run 'make host-dns' if wait-for stalls"
fi

log "Waiting for install to complete (this takes a while)"
"$OI" --dir "clusters/${CLUSTER}" agent wait-for install-complete --log-level=info

log "Install complete. Access details:"
./scripts/creds.sh "$CLUSTER" || true
