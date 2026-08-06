#!/usr/bin/env bash
# Show cluster health: nodes, cluster-operator rollup, and BareMetalHosts.
#   scripts/status.sh [cluster]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

CLUSTER="${1:-${CLUSTER:-cluster0}}"
require_cluster_name "$CLUSTER"
kubeconfig="$ROOT/clusters/$CLUSTER/auth/kubeconfig"

[[ -f "$kubeconfig" ]] || { echo "no kubeconfig for '$CLUSTER' (not installed?)" >&2; exit 1; }
resolve_oc
export KUBECONFIG="$kubeconfig"

echo "== nodes =="
"$OC" get nodes 2>/dev/null || echo "  API not reachable"

echo "== cluster operators =="
if cos="$("$OC" get co --no-headers 2>/dev/null || true)"; [[ -n "$cos" ]]; then
  total="$(printf '%s\n' "$cos" | wc -l)"; total="${total// /}"
  avail="$(printf '%s\n' "$cos" | awk '$3=="True"' | wc -l)"; avail="${avail// /}"
  echo "  available: $avail/$total"
  printf '%s\n' "$cos" | awk '$3!="True"{print "  degraded/progressing: "$1}'
else
  echo "  API not reachable"
fi

echo "== clusterversion =="
"$OC" get clusterversion 2>/dev/null | tail -1

echo "== baremetalhosts =="
"$OC" -n openshift-machine-api get bmh 2>/dev/null || echo "  none (metal3 not deployed; see make adopt)"
