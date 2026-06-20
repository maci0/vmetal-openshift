#!/usr/bin/env bash
# NFS RWX via a host "storage appliance": an NFS-Ganesha container runs on the
# host and exports a disk-backed directory on the machine net; an in-cluster
# nfs-subdir provisioner offers a ReadWriteMany StorageClass (nfs-rwx), which
# lets CNV VMs live-migrate. Independent of LVMS (uses host disk, not vdc).
#   scripts/nfs.sh [cluster] [up|down]   (default: up)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${1:-${CLUSTER:-cluster0}}"
ACTION="${2:-up}"
DIR="$ROOT/clusters/$CLUSTER"
NAME="vmetal-nfs-$CLUSTER"
EXPORT_DIR="${NFS_EXPORT_DIR:-$ROOT/build/nfs-export/$CLUSTER}"   # disk-backed, never /tmp (tmpfs)
GANESHA_IMG="${GANESHA_IMG:-docker.io/janeczku/nfs-ganesha:latest}"

die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

command -v oc >/dev/null || die "oc not found"
export KUBECONFIG="$DIR/auth/kubeconfig"

# container runtime (host netns + privileged so ganesha can serve NFS)
if command -v podman >/dev/null; then RT="sudo podman"
elif command -v docker >/dev/null; then RT="docker"; docker info >/dev/null 2>&1 || RT="sudo docker"
else die "need podman or docker for the NFS appliance"; fi

if [[ "$ACTION" == down ]]; then
  log "Removing the NFS appliance + provisioner"
  $RT rm -f "$NAME" >/dev/null 2>&1 || true
  [[ -f "$DIR/nfs-ganesha.yaml" ]] && oc delete -f "$DIR/nfs-ganesha.yaml" --ignore-not-found >/dev/null 2>&1 || true
  log "done (export dir $EXPORT_DIR kept)"
  exit 0
fi

[[ -f "$KUBECONFIG" ]] || die "no kubeconfig for '$CLUSTER'"
[[ -f "$DIR/ganesha.conf" && -f "$DIR/nfs-ganesha.yaml" ]] || die "run 'make configs' first"

log "Starting the NFS-Ganesha appliance on the host ($GANESHA_IMG, export $EXPORT_DIR)"
mkdir -p "$EXPORT_DIR"
chmod 0777 "$EXPORT_DIR"
$RT rm -f "$NAME" >/dev/null 2>&1 || true
$RT run -d --name "$NAME" --network host --privileged --restart unless-stopped \
  -v "$EXPORT_DIR:/export" \
  -v "$DIR/ganesha.conf:/etc/ganesha/ganesha.conf:ro" \
  "$GANESHA_IMG" >/dev/null
sleep 5
ss -ltn 2>/dev/null | grep -q ':2049' || log "warning: nothing listening on :2049 yet (check: $RT logs $NAME)"

log "Applying the in-cluster NFS RWX provisioner + StorageClass"
oc get ns openshift-storage >/dev/null 2>&1 || oc create ns openshift-storage >/dev/null
oc label ns openshift-storage pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null 2>&1 || true
for _ in $(seq 1 30); do oc apply -f "$DIR/nfs-ganesha.yaml" >/dev/null 2>&1 && break; sleep 5; done
oc -n openshift-storage rollout status deploy/nfs-client-provisioner --timeout=180s >/dev/null 2>&1 || true

log "Done. RWX StorageClass:"
oc get sc nfs-rwx 2>/dev/null || log "nfs-rwx not created yet (check the provisioner pod logs)"
