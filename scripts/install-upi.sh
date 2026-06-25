#!/usr/bin/env bash
# One-shot single-node UPI install (platform: none, bootstrap-in-place).
# Two boot methods, chosen by the cluster's boot_via:
#   redfish/iso (default): ignition embedded in the RHCOS live ISO, mounted via
#                          the sushy Redfish virtual-media path.
#   pxe:                   UEFI netboot, ignition served over http (no media).
# The node installs itself from the live environment, so there is no separate
# bootstrap node and no external load balancer (api/ingress = the node IP).
#
# Multi-node UPI is not implemented (see docs/upi-plan.md); validate.yml enforces
# single-node.
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

# Topology facts: boot method, BMC host, fqdn, node domain names.
topo="$(mktemp)"; ap dump-topology.yml -e out="$topo" >/dev/null 2>&1
read -r PXE BMC_HOST FQDN < <(
  jq -r --arg c "$CLUSTER" '.[] | select(.name==$c) | "\(.pxe) \(.bmc_host) \(.fqdn)"' "$topo"
) || true
mapfile -t NODE_VMS < <(jq -r --arg c "$CLUSTER" '.[] | select(.name==$c) | .nodes[].fullname' "$topo")
rm -f "$topo"
[[ -n "${FQDN:-}" ]] || die "cluster '$CLUSTER' not found in topology (check group_vars/all.yml clusters)"

if [[ "$PXE" == "True" || "$PXE" == "true" ]]; then
  log "Preparing PXE artifacts (ignition, ipxe.efi, RHCOS kernel/initramfs/rootfs)"
  ./scripts/build-pxe.sh "$CLUSTER"
else
  log "Building single-node UPI ignition ISO"
  ./scripts/build-ignition.sh "$CLUSTER"
fi

log "Provisioning libvirt (networks, volumes, VM)"
ap setup.yml "${BECOME[@]}"

# Serve build/ over HTTP: the ISO (redfish) or the iPXE script + RHCOS artifacts (pxe).
"$PY" -m http.server "$HTTP_PORT" --directory "$ROOT/build" >/tmp/vmetal-iso-http.log 2>&1 &
http_pid=$!
trap 'kill "$http_pid" 2>/dev/null || true' EXIT

if [[ "$PXE" == "True" || "$PXE" == "true" ]]; then
  log "Netbooting the node(s) (UEFI PXE -> iPXE -> RHCOS live)"
  for vm in "${NODE_VMS[@]}"; do virsh -c qemu:///system start "$vm" >/dev/null 2>&1 || virsh -c qemu:///system reset "$vm" >/dev/null 2>&1 || true; done
else
  log "Serving the ISO + driving the BMC"
  curl -sk --max-time 5 "https://${BMC_HOST}:8000/redfish/v1/" | grep -q RedfishVersion \
    || die "sushy Redfish not reachable at ${BMC_HOST}:8000. Start it: make sushy-install"
  iso="upi_image_${CLUSTER}.iso"
  for _ in $(seq 1 10); do curl -fsS --max-time 3 -o /dev/null "http://127.0.0.1:${HTTP_PORT}/${iso}" && break; sleep 1; done
  ap bmc.yml -e cluster="$CLUSTER" -e bmc_action=boot-iso \
    -e iso_base_url="http://127.0.0.1:${HTTP_PORT}" -e iso_name="$iso"
fi

if ! getent hosts "api.${FQDN}" >/dev/null 2>&1; then
  log "note: host cannot resolve api.${FQDN} yet; run 'make host-dns' if wait-for stalls"
fi

log "Waiting for install to complete (this takes a while)"
"$OI" --dir "clusters/${CLUSTER}" wait-for install-complete --log-level=info

log "Install complete. Access details:"
./scripts/creds.sh "$CLUSTER" || true
