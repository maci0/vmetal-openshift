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
CLUSTER="${1:-${CLUSTER:-cluster0}}"
HTTP_PORT="${HTTP_PORT:-8099}"
VIRSH=(virsh -c qemu:///system)

die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

[[ -x "$ROOT/.venv/bin/ansible-playbook" ]] && AP="$ROOT/.venv/bin/ansible-playbook" || AP="ansible-playbook"
[[ -x "$ROOT/.venv/bin/python" ]] && PY="$ROOT/.venv/bin/python" || PY=python3
OI="$ROOT/build/openshift-install/openshift-install"; [[ -x "$OI" ]] || OI="$(command -v openshift-install || true)"
[[ -n "$OI" && -x "$OI" ]] || die "openshift-install not found; run scripts/bootstrap.sh"
command -v jq >/dev/null || die "jq required"
if [[ "$(id -u)" == 0 ]] || id -nG | grep -qw libvirt; then BECOME=(-e use_become=false); else BECOME=(); fi
ap() { ( cd "$ROOT/ansible" && "$AP" "$@" ); }

# Topology facts.
topo="$(mktemp)"; ap lifecycle/dump-topology.yml -e out="$topo" >/dev/null 2>&1
# tab-delimited so an empty field never collapses and shifts the columns
IFS=$'\t' read -r PXE BMC_HOST FQDN < <(jq -r --arg c "$CLUSTER" '.[] | select(.name==$c) | [.pxe, .bmc_host, .fqdn] | @tsv' "$topo") || true
mapfile -t ALL_VMS  < <(jq -r --arg c "$CLUSTER" '.[] | select(.name==$c) | .nodes[].fullname' "$topo")
mapfile -t BOOT_VMS < <(jq -r --arg c "$CLUSTER" '.[] | select(.name==$c) | .nodes[] | select(.role=="bootstrap") | .fullname' "$topo")
EXPECT="$(jq -r --arg c "$CLUSTER" '[.[] | select(.name==$c) | .nodes[] | select(.role!="bootstrap")] | length' "$topo")"
rm -f "$topo"
[[ -n "${FQDN:-}" ]] || die "cluster '$CLUSTER' not found in topology"
is_pxe() { [[ "$PXE" == "True" || "$PXE" == "true" ]]; }
MULTINODE=false; [[ "${#BOOT_VMS[@]}" -gt 0 ]] && MULTINODE=true
$MULTINODE && ! is_pxe && die "multi-node upi requires boot_via: pxe"

if is_pxe; then
  log "Preparing PXE artifacts"; ./scripts/build-pxe.sh "$CLUSTER"
else
  log "Building single-node UPI ignition ISO"; ./scripts/build-ignition.sh "$CLUSTER"
fi

log "Provisioning libvirt (networks, volumes, VMs)"
ap lifecycle/setup.yml "${BECOME[@]}"

if $MULTINODE; then
  log "Starting external HAProxy (api/ingress load balancer)"
  ap appliances/haproxy.yml -e cluster="$CLUSTER"
fi

# Serve build/ over HTTP (the ISO, or the iPXE script + RHCOS artifacts + ignitions).
"$PY" -m http.server "$HTTP_PORT" --directory "$ROOT/build" >/tmp/vmetal-iso-http.log 2>&1 &
http_pid=$!
trap 'kill "$http_pid" 2>/dev/null || true' EXIT

if is_pxe; then
  log "Netbooting ${#ALL_VMS[@]} node(s) (UEFI PXE -> iPXE -> RHCOS live)"
  for vm in "${ALL_VMS[@]}"; do "${VIRSH[@]}" start "$vm" >/dev/null 2>&1 || "${VIRSH[@]}" reset "$vm" >/dev/null 2>&1 || true; done
else
  log "Serving the ISO + driving the BMC"
  curl -sk --max-time 5 "https://${BMC_HOST}:8000/redfish/v1/" | grep -q RedfishVersion \
    || die "sushy Redfish not reachable at ${BMC_HOST}:8000. Start it: make sushy-install"
  iso="upi_image_${CLUSTER}.iso"
  for _ in $(seq 1 10); do curl -fsS --max-time 3 -o /dev/null "http://127.0.0.1:${HTTP_PORT}/${iso}" && break; sleep 1; done
  ap lifecycle/bmc.yml -e cluster="$CLUSTER" -e bmc_action=boot-iso -e iso_base_url="http://127.0.0.1:${HTTP_PORT}" -e iso_name="$iso"
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
  # nohup + disown so it survives even if wait-for install-complete errors out
  # (workers join via CSR while the control plane is still settling).
  nohup ./scripts/approve-csrs.sh "$CLUSTER" "$EXPECT" 3000 >/tmp/vmetal-csr-approve.log 2>&1 &
  disown
fi

log "Waiting for install to complete (this takes a while)"
"$OI" --dir "clusters/${CLUSTER}" wait-for install-complete --log-level=info

log "Install complete. Access details:"
./scripts/creds.sh "$CLUSTER" || true
