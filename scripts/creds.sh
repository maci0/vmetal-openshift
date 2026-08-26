#!/usr/bin/env bash
# Print access details for an installed cluster: console URL + kubeadmin password
# + kubeconfig path.
#   scripts/creds.sh [cluster]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

CLUSTER="${1:-${CLUSTER:-cluster0}}"
require_cluster_name "$CLUSTER"
AUTH="$ROOT/clusters/$CLUSTER/auth"

[[ -f "$AUTH/kubeconfig" ]] || die "no kubeconfig for '$CLUSTER' (not installed?)"

kubeconfig="$AUTH/kubeconfig"
# The console URL is a bonus: print the rest even with no oc or no API.
console=""
if resolve_oc; then
  console="$(KUBECONFIG="$kubeconfig" "$OC" -n openshift-console get route console \
             -o jsonpath='{.spec.host}' 2>/dev/null || true)"
fi

echo "cluster:    $CLUSTER"
echo "kubeconfig: export KUBECONFIG=$kubeconfig"
[[ -n "$console" ]] && echo "console:    https://$console"
echo "username:   kubeadmin"
[[ -f "$AUTH/kubeadmin-password" ]] && echo "password:   $(cat "$AUTH/kubeadmin-password")" || true
