#!/usr/bin/env bash
# Host-side HAProxy for a platform:none (upi) cluster: the external load balancer
# that upi has no in-cluster equivalent for. Runs as a host-network container on
# the machine gateway, balancing api (6443), machine-config (22623) and ingress
# (80/443). Config comes from clusters/<cluster>/haproxy.cfg (rendered by
# generate-configs). Mirrors the nfs.sh / metallb-bgp.sh host-appliance pattern.
#
#   scripts/haproxy.sh [cluster] [up|down]   (default: up)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${1:-${CLUSTER:-cluster0}}"
ACTION="${2:-up}"
CFG="$ROOT/clusters/$CLUSTER/haproxy.cfg"
NAME="vmetal-haproxy-$CLUSTER"
IMG="${HAPROXY_IMG:-docker.io/library/haproxy:lts}"

die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

# Bash, not an Ansible module, on purpose: the docker/podman CLIs are drop-in
# compatible for `run`, so this works with either. The Ansible container modules
# do not: community.docker needs a Docker API socket (podman only via
# `podman system service`), and containers.podman is podman-only.
ENGINE="$(command -v docker || command -v podman || true)"
[[ -n "$ENGINE" ]] || die "need docker or podman for the HAProxy appliance"

if [[ "$ACTION" == "down" ]]; then
  if "$ENGINE" rm -f "$NAME" >/dev/null 2>&1; then log "removed $NAME"; else log "$NAME not running"; fi
  exit 0
fi

[[ -f "$CFG" ]] || die "no $CFG (run 'make configs' / install-upi first)"
"$ENGINE" rm -f "$NAME" >/dev/null 2>&1 || true
log "Starting HAProxy ($IMG) on the host network for '$CLUSTER'"
# --user 0 + NET_BIND_SERVICE: bind the privileged ports (80/443) on the host
# network. The container is isolated; this is a lab load balancer.
"$ENGINE" run -d --name "$NAME" --restart unless-stopped --network host \
  --user 0 --cap-add NET_BIND_SERVICE \
  -v "$CFG:/usr/local/etc/haproxy/haproxy.cfg:ro" "$IMG" >/dev/null
# Fail fast on a bad config rather than a silently-dead container.
sleep 2
"$ENGINE" ps --filter "name=$NAME" --filter status=running --format '{{.Names}}' | grep -q "$NAME" \
  || die "HAProxy container exited; check: $ENGINE logs $NAME"
log "HAProxy up: api :6443, machine-config :22623, ingress :80/:443 -> cluster nodes"
