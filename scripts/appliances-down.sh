#!/usr/bin/env bash
# Stop the host-side "appliance" containers (FRR BGP peer, NFS-Ganesha) that the
# day-2 helpers start. Called by `make down` so a teardown leaves nothing running.
# Best-effort: never fails the teardown. Tries every available runtime so a
# container started via docker is still removed when podman is preferred (and
# vice versa). Matches ansible/tasks/container_runtime.yml socket probing.
set -uo pipefail

remove_vmetal() {
  local rt="$1"
  local ids
  ids="$($rt ps -aq --filter name=vmetal- 2>/dev/null || true)"
  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086
    $rt rm -f $ids >/dev/null 2>&1 && echo "==> removed host appliance containers ($rt)" || true
  fi
}

runtimes=()
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then runtimes+=("docker")
  elif command -v sudo >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then runtimes+=("sudo docker")
  fi
fi
if command -v podman >/dev/null 2>&1; then
  runtimes+=("podman")
  if command -v sudo >/dev/null 2>&1; then runtimes+=("sudo podman"); fi
fi

for rt in "${runtimes[@]+"${runtimes[@]}"}"; do
  remove_vmetal "$rt"
done
exit 0
