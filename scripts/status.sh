#!/usr/bin/env bash
# Show cluster health: nodes, cluster-operator rollup, and BareMetalHosts.
#   scripts/status.sh [cluster]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${1:-${CLUSTER:-cluster0}}"
kubeconfig="$ROOT/clusters/$CLUSTER/auth/kubeconfig"

[[ -f "$kubeconfig" ]] || { echo "no kubeconfig for '$CLUSTER' (not installed?)" >&2; exit 1; }
command -v oc >/dev/null || { echo "oc not found" >&2; exit 1; }
export KUBECONFIG="$kubeconfig"

echo "== nodes =="
oc get nodes 2>/dev/null || echo "  API not reachable"

echo "== cluster operators =="
total="$(oc get co --no-headers 2>/dev/null | wc -l)"
avail="$(oc get co --no-headers 2>/dev/null | awk '$3=="True"' | wc -l)"
echo "  available: $avail/$total"
oc get co --no-headers 2>/dev/null | awk '$3!="True"{print "  degraded/progressing: "$1}'

echo "== clusterversion =="
oc get clusterversion 2>/dev/null | tail -1

echo "== baremetalhosts =="
oc -n openshift-machine-api get bmh 2>/dev/null || echo "  none (metal3 not deployed; see make adopt)"
