#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME=${CLUSTER_NAME:-cluster0}
BASE_DOMAIN=${BASE_DOMAIN:-ocp.lab}

names=(
  "api.${CLUSTER_NAME}.${BASE_DOMAIN}"
  "api-int.${CLUSTER_NAME}.${BASE_DOMAIN}"
  "test.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
)

resolver=${RESOLVER:-}
if [[ -n "$resolver" ]]; then
  dig_args=("@${resolver}")
else
  dig_args=()
fi

echo "Testing DNS resolution for ${CLUSTER_NAME}.${BASE_DOMAIN}"
for name in "${names[@]}"; do
  if command -v dig >/dev/null 2>&1; then
    if dig "${dig_args[@]}" +short "${name}" | grep -qE '^[0-9]+'; then
      echo "OK  ${name}"
    else
      echo "FAIL ${name}"
      exit 1
    fi
  else
    if getent ahosts "${name}" >/dev/null 2>&1; then
      echo "OK  ${name}"
    else
      echo "FAIL ${name}"
      exit 1
    fi
  fi
done

echo "All required names resolved."
