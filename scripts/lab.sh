#!/usr/bin/env bash
# Spin up the lab infra for an agent install but DO NOT run the install, so you
# can practice driving openshift-install yourself. Builds the agent ISO,
# provisions the VMs and boots them off the ISO (boot_via=iso, self-contained:
# no host HTTP server or BMC to keep alive), wires host DNS, then prints the
# commands to watch and finish the install. Tear down with `make down`.
#
#   scripts/lab.sh [cluster]      (or CLUSTER=...)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

CLUSTER="${1:-${CLUSTER:-cluster0}}"
require_cluster_name "$CLUSTER"

resolve_ansible
resolve_openshift_install
command -v jq >/dev/null || die "jq required"
libvirt_become_args
ap() { ( cd "$ROOT/ansible" && "$AP" "$@" ); }

topo="$(dump_topology)"
trap 'rm -f "$topo"' EXIT
IFS=$'\t' read -r MODE FQDN < <(jq -r --arg c "$CLUSTER" '.[] | select(.name==$c) | [.mode, .fqdn] | @tsv' "$topo") || true
[[ -n "${FQDN:-}" ]] || die "cluster '$CLUSTER' not found in topology"

# Practice mode targets the agent flow (discovery ISO + `agent wait-for`).
[[ "$MODE" == "agent" ]] || die "lab is for agent clusters (got mode '$MODE'); ipi/upi have their own install (see docs/ipi-vs-agent.md)"

log "Building the agent discovery ISO"
./scripts/build/build-iso.sh "$CLUSTER"

log "Provisioning libvirt (VMs boot the ISO directly, no host services needed)"
ap lifecycle/setup.yml -e boot_via=iso "${BECOME[@]}"

log "Wiring host split-DNS for the cluster domain"
ap lifecycle/host-dns.yml || log "host-dns failed (needs sudo); run 'make host-dns' before wait-for"

node0="${CLUSTER}-node0"
cat <<EOF

$(printf '\033[1;32m==>\033[0m') Lab infra is up. The node(s) are booting the agent discovery ISO.
Now practice driving the install yourself:

  # watch a node boot into the live agent (Ctrl-] to exit the console)
  virsh -c qemu:///system console ${node0}

  # drive / monitor the install (this is the part to practice)
  ${OI} --dir clusters/${CLUSTER} agent wait-for bootstrap-complete --log-level=info
  ${OI} --dir clusters/${CLUSTER} agent wait-for install-complete  --log-level=info

  # once the API is up
  make status CLUSTER=${CLUSTER}      # nodes, operators, BMCs
  make creds  CLUSTER=${CLUSTER}      # console URL + kubeadmin

  # check DNS resolves (host split-DNS)
  getent hosts api.${FQDN}

Tear it all down with:  make down
EOF
