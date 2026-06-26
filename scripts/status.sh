#!/usr/bin/env bash
# Show cluster health: nodes, cluster-operator rollup, and BareMetalHosts.
#   scripts/status.sh [cluster]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${1:-${CLUSTER:-cluster0}}"
kubeconfig="$ROOT/clusters/$CLUSTER/auth/kubeconfig"

[[ -f "$kubeconfig" ]] || { echo "no kubeconfig for '$CLUSTER' (not installed?)" >&2; exit 1; }
OC="$ROOT/build/openshift-install/oc"; [[ -x "$OC" ]] || OC="$(command -v oc || true)"
[[ -n "$OC" ]] || { echo "oc not found (run scripts/bootstrap.sh, or put oc on PATH)" >&2; exit 1; }
export KUBECONFIG="$kubeconfig"

echo "== nodes =="
"$OC" get nodes 2>/dev/null || echo "  API not reachable"

echo "== cluster operators =="
total="$("$OC" get co --no-headers 2>/dev/null | wc -l)"
avail="$("$OC" get co --no-headers 2>/dev/null | awk '$3=="True"' | wc -l)"
echo "  available: $avail/$total"
"$OC" get co --no-headers 2>/dev/null | awk '$3!="True"{print "  degraded/progressing: "$1}'

echo "== clusterversion =="
"$OC" get clusterversion 2>/dev/null | tail -1

echo "== baremetalhosts =="
"$OC" -n openshift-machine-api get bmh 2>/dev/null || echo "  none (metal3 not deployed; see make adopt)"
