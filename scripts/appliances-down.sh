#!/usr/bin/env bash
# Stop the host-side "appliance" containers (FRR BGP peer, NFS-Ganesha) that the
# day-2 helpers start. Called by `make down` so a teardown leaves nothing running.
# Best-effort: never fails the teardown.
set -uo pipefail

RT=""
if command -v podman >/dev/null 2>&1; then RT="sudo podman"
elif command -v docker >/dev/null 2>&1; then RT="docker"; docker info >/dev/null 2>&1 || RT="sudo docker"
else exit 0
fi

ids="$($RT ps -aq --filter name=vmetal- 2>/dev/null || true)"
if [[ -n "$ids" ]]; then
  # shellcheck disable=SC2086
  $RT rm -f $ids >/dev/null 2>&1 && echo "==> removed host appliance containers" || true
fi
exit 0
