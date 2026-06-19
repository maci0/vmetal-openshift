#!/usr/bin/env bash
# Print access details for an installed cluster: console URL + kubeadmin password
# + kubeconfig path.
#   scripts/creds.sh [cluster]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${1:-${CLUSTER:-cluster0}}"
AUTH="$ROOT/clusters/$CLUSTER/auth"

[[ -f "$AUTH/kubeconfig" ]] || { echo "no kubeconfig for '$CLUSTER' (not installed?)" >&2; exit 1; }

kubeconfig="$AUTH/kubeconfig"
console=""
if command -v oc >/dev/null; then
  console="$(KUBECONFIG="$kubeconfig" oc -n openshift-console get route console \
             -o jsonpath='{.spec.host}' 2>/dev/null || true)"
fi

echo "cluster:    $CLUSTER"
echo "kubeconfig: export KUBECONFIG=$kubeconfig"
[[ -n "$console" ]] && echo "console:    https://$console"
echo "username:   kubeadmin"
[[ -f "$AUTH/kubeadmin-password" ]] && echo "password:   $(cat "$AUTH/kubeadmin-password")"
