#!/usr/bin/env bash
# End-to-end test: provision the lab, assert it matches the derived topology,
# then tear it down. Mutates libvirt: needs root or libvirt-group membership.
#
#   scripts/e2e.sh              # full cycle, cleans up at the end
#   KEEP=1 scripts/e2e.sh       # leave the lab running after asserts
#   scripts/e2e.sh --cleanup    # just tear down and exit
#
# Env: LIBVIRT_URI (default qemu:///system), SUSHY_URL (default https://localhost:8000)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

SUSHY_URL="${SUSHY_URL:-https://localhost:8000}"
TOPO=""
trap 'rm -f "$TOPO"' EXIT

resolve_ansible
libvirt_become_args
resolve_virsh
# setup.yml/cleanup.yml need root for qemu:///system unless we are in libvirt.
SUDO=""; have_libvirt_access || SUDO="sudo"

ok()   { printf '\033[1;32mok  \033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

# Playbooks must run from ansible/ (ansible.cfg + inventory live there).
provision() { ( cd "$ROOT/ansible" && $SUDO "$AP" lifecycle/setup.yml "${BECOME[@]}" ); }
teardown()  { ( cd "$ROOT/ansible" && $SUDO "$AP" lifecycle/cleanup.yml "${BECOME[@]}" ); }

if [[ "${1:-}" == "--cleanup" ]]; then
  teardown; ok "cleanup done"; exit 0
fi

command -v jq >/dev/null || fail "jq required"
command -v virsh >/dev/null || fail "virsh required"

echo "== offline lint =="
scripts/lint.sh >/dev/null && ok "lint"

echo "== render topology =="
TOPO="$(dump_topology)"
clusters=$(jq 'length' "$TOPO"); ok "topology rendered ($clusters cluster(s))"

echo "== provision =="
provision; ok "lifecycle/setup.yml applied"

# setup.yml only auto-starts ISO-boot clusters; power the rest on so the infra
# asserts below hold regardless of boot_via (redfish/ipi/upi normally boot via BMC).
echo "== power on domains =="
while read -r dom; do "${VIRSH[@]}" start "$dom" >/dev/null 2>&1 || true; done \
  < <(jq -r '.[].nodes[].fullname' "$TOPO")
sleep 2; ok "domains started"

echo "== assert networks active =="
while read -r net; do
  state=$("${VIRSH[@]}" net-info "$net" 2>/dev/null | awk '/Active:/{print $2}')
  [[ "$state" == "yes" ]] || fail "network $net not active"
done < <(jq -r '.[].networks[].name' "$TOPO")
ok "all networks active"

echo "== assert domains running + NIC counts (bonding) =="
while read -r row; do
  dom=${row%%|*}; want=${row##*|}
  st=$("${VIRSH[@]}" domstate "$dom" 2>/dev/null || true)
  [[ "$st" == "running" ]] || fail "domain $dom not running ($st)"
  got=$("${VIRSH[@]}" domiflist "$dom" | awk 'NR>2 && NF' | wc -l)
  got=${got// /}
  [[ "$got" == "$want" ]] || fail "$dom NIC count: want $want got $got"
done < <(jq -r '.[].nodes[] | "\(.fullname)|\(.interfaces|length)"' "$TOPO")
ok "domains running with expected NIC counts"

# Query the cluster's libvirt dnsmasq directly (@gateway), so the assert does not
# depend on the host resolver being pointed at it (that is `make host-dns`).
if command -v dig >/dev/null; then
  echo "== assert DNS resolves to the right VIPs (api vs ingress) =="
  while IFS='|' read -r fqdn api ing gw; do
    for pair in "api.$fqdn=$api" "api-int.$fqdn=$api" "console-openshift-console.apps.$fqdn=$ing"; do
      rec=${pair%=*}; want=${pair#*=}
      got=$(dig +short @"$gw" "$rec" 2>/dev/null | grep -m1 -E '^[0-9.]+$' || true)
      [[ "$got" == "$want" ]] || fail "DNS $rec @$gw -> '${got:-NXDOMAIN}', want $want"
    done
    ok "DNS ok for $fqdn (api=$api, ingress=$ing)"
  done < <(jq -r '.[] | "\(.fqdn)|\(.api_vip)|\(.ingress_vip)|\(.machine_gateway)"' "$TOPO")
else
  printf '\033[1;33mSKIP\033[0m dig not installed; DNS assertion skipped\n'
fi

echo "== sushy Redfish endpoint (optional) =="
if curl -sk --max-time 5 "$SUSHY_URL/redfish/v1/" | grep -q RedfishVersion; then
  ok "Redfish reachable at $SUSHY_URL"
else
  printf '\033[1;33mSKIP\033[0m sushy-emulator not reachable at %s\n' "$SUSHY_URL"
fi

if [[ -n "${KEEP:-}" ]]; then
  ok "KEEP set, leaving lab running"
else
  echo "== teardown =="
  teardown; ok "cleanup done"
fi

echo; ok "e2e PASS"
