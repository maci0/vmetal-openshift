#!/usr/bin/env bash
# Host memory-optimization stack for the lab VMs:
#   1. KSM        - dedup identical guest pages (same RHCOS on every node)
#   2. zswap      - compress evicted pages into a RAM pool (zstd) instead of disk
#   3. libvirt hook - put each lab VM in a cgroup with memory.high + zswap.max so
#                     its cold pages get compressed early, host OS untouched
# Runtime settings (reset on reboot); the script prints how to persist them.
#
#   scripts/optimize-host.sh [apply|undo]      (default: apply)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-apply}"
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
ZSWAP_PCT="${ZSWAP_PCT:-30}"
ZSWAP_COMP="${ZSWAP_COMP:-zstd}"

w() { echo "$2" | sudo tee "$1" >/dev/null; }   # write $2 to sysfs path $1 as root

scopes() { echo /sys/fs/cgroup/machine.slice/machine-qemu*"-node"*.scope \
                /sys/fs/cgroup/machine.slice/machine-qemu*"-day2-worker"*.scope; }

apply() {
  log "1. KSM (kernel samepage merging)"
  if systemctl list-unit-files ksmtuned.service >/dev/null 2>&1; then
    sudo systemctl enable --now ksmtuned
    echo "   ksmtuned enabled (dynamic)"
  else
    w /sys/kernel/mm/ksm/run 1
    w /sys/kernel/mm/ksm/pages_to_scan 1000
    echo "   KSM run=1 (no ksmtuned packaged; persist via a systemd unit or tmpfiles)"
  fi

  log "2. zswap (compressed RAM swap, $ZSWAP_COMP, ${ZSWAP_PCT}% pool cap)"
  if [[ -d /sys/module/zswap/parameters ]]; then
    w /sys/module/zswap/parameters/compressor "$ZSWAP_COMP"
    w /sys/module/zswap/parameters/max_pool_percent "$ZSWAP_PCT"
    [[ -f /sys/module/zswap/parameters/shrinker_enabled ]] && w /sys/module/zswap/parameters/shrinker_enabled Y || true
    w /sys/module/zswap/parameters/enabled Y
    echo "   zswap enabled=$(cat /sys/module/zswap/parameters/enabled) compressor=$(cat /sys/module/zswap/parameters/compressor)"
    echo "   persist via kernel cmdline: zswap.enabled=1 zswap.compressor=$ZSWAP_COMP zswap.max_pool_percent=$ZSWAP_PCT"
  else
    echo "   zswap not available in this kernel (build with CONFIG_ZSWAP)"
  fi

  log "3. libvirt qemu hook (per-VM cgroup: memory.high + memory.zswap.max)"
  sudo install -D -m 0755 "$ROOT/hooks/qemu" /etc/libvirt/hooks/qemu
  sudo systemctl reload-or-restart libvirtd 2>/dev/null \
    || sudo systemctl reload-or-restart virtqemud 2>/dev/null || true
  echo "   installed /etc/libvirt/hooks/qemu (applies on next VM start)"
  log "Done. Reboot VMs (or make down/up) so the hook squeezes them."
}

undo() {
  log "1. KSM off (+ unmerge)"
  systemctl list-unit-files ksmtuned.service >/dev/null 2>&1 && sudo systemctl disable --now ksmtuned 2>/dev/null || true
  w /sys/kernel/mm/ksm/run 2   # unmerge all shared pages, then stop

  log "2. zswap off"
  [[ -f /sys/module/zswap/parameters/enabled ]] && w /sys/module/zswap/parameters/enabled N || true

  log "3. remove libvirt hook + lift per-VM limits"
  sudo rm -f /etc/libvirt/hooks/qemu
  sudo systemctl reload-or-restart libvirtd 2>/dev/null \
    || sudo systemctl reload-or-restart virtqemud 2>/dev/null || true
  shopt -s nullglob
  for s in $(scopes); do
    [[ -f "$s/memory.high" ]] && w "$s/memory.high" max || true
  done
  log "Reverted. (KSM run reset to 0 after unmerge; zswap pool drains as pages fault back in.)"
}

case "$ACTION" in
  apply) apply ;;
  undo)  undo ;;
  *) echo "usage: $0 [apply|undo]" >&2; exit 2 ;;
esac
