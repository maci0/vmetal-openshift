#!/usr/bin/env bash
# One-shot UPI install (platform: none).
#   single-node: bootstrap-in-place, one VM, no LB. boot_via iso (Redfish) or pxe.
#   multi-node:  transient bootstrap node + control plane + workers, an external
#                host HAProxy for api/ingress, and CSR approval. pxe only.
# See docs/ipi-vs-agent.md (UPI).
#
#   scripts/install-upi.sh [cluster]      (or CLUSTER=...)
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
resolve_virsh
command -v jq >/dev/null || die "jq required"
libvirt_become_args
ap() { ( cd "$ROOT/ansible" && "$AP" "$@" ); }

# Topology facts.
topo="$(dump_topology)"
IFS=$'\t' read -r MODE PXE BMC_HOST FQDN GW < <(
  jq -r --arg c "$CLUSTER" '.[] | select(.name==$c) | [.mode, .pxe, .bmc_host, .fqdn, .machine_gateway] | @tsv' "$topo"
) || true
mapfile -t ALL_VMS  < <(jq -r --arg c "$CLUSTER" '.[] | select(.name==$c) | .nodes[].fullname' "$topo")
mapfile -t BOOT_VMS < <(jq -r --arg c "$CLUSTER" '.[] | select(.name==$c) | .nodes[] | select(.role=="bootstrap") | .fullname' "$topo")
EXPECT="$(jq -r --arg c "$CLUSTER" '[.[] | select(.name==$c) | .nodes[] | select(.role!="bootstrap")] | length' "$topo")"
rm -f "$topo"
[[ -n "${FQDN:-}" ]] || die "cluster '$CLUSTER' not found in topology"
[[ "$MODE" == "upi" ]] || die "cluster '$CLUSTER' is mode=$MODE; use make install (agent) or openshift-install create cluster (ipi)"
is_pxe() { [[ "$PXE" == "True" || "$PXE" == "true" ]]; }
MULTINODE=false; [[ "${#BOOT_VMS[@]}" -gt 0 ]] && MULTINODE=true
$MULTINODE && ! is_pxe && die "multi-node upi requires boot_via: pxe"

if is_pxe; then
  log "Preparing PXE artifacts"; ./scripts/build/build-pxe.sh "$CLUSTER"
else
  log "Building single-node UPI ignition ISO"; ./scripts/build/build-ignition.sh "$CLUSTER"
fi

log "Provisioning libvirt (networks, volumes, VMs)"
# setup.yml provisions every cluster in group_vars; CLUSTER selects which we boot.
ap lifecycle/setup.yml "${BECOME[@]}"

if $MULTINODE; then
  log "Starting external HAProxy (api/ingress load balancer)"
  ap appliances/haproxy.yml -e cluster="$CLUSTER"
fi

trap 'kill "${http_pid:-}" 2>/dev/null || true; kill "${csr_pid:-}" 2>/dev/null || true' EXIT

if is_pxe; then
  log "Netbooting ${#ALL_VMS[@]} node(s) (UEFI PXE -> iPXE -> RHCOS live)"
  # Guests pull iPXE artifacts from the machine gateway, not loopback.
  start_http_server "$HTTP_PORT" "$ROOT/build" "${GW:-0.0.0.0}" "boot.ipxe"
  for vm in "${ALL_VMS[@]}"; do "${VIRSH[@]}" start "$vm" >/dev/null 2>&1 || "${VIRSH[@]}" reset "$vm" >/dev/null 2>&1 || true; done
else
  log "Serving the ISO + driving the BMC"
  curl -sk --max-time 5 "https://${BMC_HOST}:8000/redfish/v1/" | grep -q RedfishVersion \
    || die "sushy Redfish not reachable at ${BMC_HOST}:8000. Start it: make sushy-install"
  iso="upi_image_${CLUSTER}.iso"
  start_http_server "$HTTP_PORT" "$ROOT/build" "127.0.0.1" "$iso"
  ap lifecycle/bmc.yml -e cluster="$CLUSTER" -e bmc_action=boot-iso \
    -e iso_base_url="http://127.0.0.1:${HTTP_PORT}" -e iso_name="$iso" "${BECOME[@]}"
fi

getent hosts "api.${FQDN}" >/dev/null 2>&1 || log "note: host cannot resolve api.${FQDN}; run 'make host-dns' if wait-for stalls"

if $MULTINODE; then
  log "Waiting for bootstrap to complete"
  "$OI" --dir "clusters/${CLUSTER}" wait-for bootstrap-complete --log-level=info
  log "Removing the bootstrap node (HAProxy health-checks it out automatically)"
  for vm in "${BOOT_VMS[@]}"; do
    "${VIRSH[@]}" destroy "$vm" >/dev/null 2>&1 || true
    "${VIRSH[@]}" undefine "$vm" --nvram --remove-all-storage >/dev/null 2>&1 || true
  done
  log "Approving node CSRs in the background (until $EXPECT nodes Ready)"
  ./scripts/approve-csrs.sh "$CLUSTER" "$EXPECT" 3000 >/tmp/vmetal-csr-approve.log 2>&1 &
  csr_pid=$!
fi

log "Waiting for install to complete (this takes a while)"
"$OI" --dir "clusters/${CLUSTER}" wait-for install-complete --log-level=info

if [[ -n "${csr_pid:-}" ]]; then
  # Give CSR approver a moment to finish after install-complete, then stop it.
  wait "$csr_pid" 2>/dev/null || true
  csr_pid=
fi

log "Install complete. Access details:"
./scripts/creds.sh "$CLUSTER" || true
