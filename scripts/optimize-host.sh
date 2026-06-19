#!/usr/bin/env bash
# Host memory-optimization stack for the lab VMs:
#   1. KSM         - dedup identical guest pages (same RHCOS on every node)
#   2. zram        - compressed-RAM swap (zstd); evicted pages compress in RAM, no disk
#   3. libvirt hook - per-VM memory.high so cold pages get pushed into zram early,
#                     host OS untouched
# Runtime settings (reset on reboot); the script prints how to persist them.
#
#   scripts/optimize-host.sh [apply|undo]      (default: apply)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-apply}"
ZRAM_COMP="${ZRAM_COMP:-zstd}"
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
w()   { echo "$2" | sudo tee "$1" >/dev/null; }

apply() {
  log "1. KSM (kernel samepage merging)"
  if systemctl list-unit-files ksmtuned.service >/dev/null 2>&1; then
    sudo systemctl enable --now ksmtuned; echo "   ksmtuned enabled"
  else
    w /sys/kernel/mm/ksm/run 1; w /sys/kernel/mm/ksm/pages_to_scan 1000
    echo "   KSM run=1 (no ksmtuned packaged; persist via a systemd unit)"
  fi

  log "2. zram (compressed-RAM swap, $ZRAM_COMP)"
  if [[ -b /dev/zram0 ]] && grep -q zram0 /proc/swaps; then
    echo "   /dev/zram0 already active: $(zramctl --output NAME,ALGORITHM,DISKSIZE /dev/zram0 2>/dev/null | tail -1)"
    echo "   (change the algorithm with scripts/bench-memory.sh's reset, or zramctl)"
  elif command -v zramctl >/dev/null; then
    sudo modprobe zram 2>/dev/null || true
    ramk=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    dev=$(sudo zramctl --find --size "$(( ramk * 1024 ))" --algorithm "$ZRAM_COMP")
    sudo mkswap "$dev" >/dev/null && sudo swapon "$dev" -p 100
    echo "   created $dev ($ZRAM_COMP, ${ramk}KiB). Persist via systemd zram-generator."
  else
    echo "   zram tools missing (install zram-generator / util-linux); skipping"
  fi

  log "3. libvirt qemu hook (per-VM memory.high -> cold pages to zram)"
  sudo install -D -m 0755 "$ROOT/hooks/qemu" /etc/libvirt/hooks/qemu
  sudo systemctl reload-or-restart libvirtd 2>/dev/null \
    || sudo systemctl reload-or-restart virtqemud 2>/dev/null || true
  echo "   installed /etc/libvirt/hooks/qemu (applies on next VM start)"
  log "Done. Reboot VMs (make down/up) so the hook squeezes them. Verify: make status / zramctl"
}

undo() {
  log "1. KSM off (+ unmerge)"
  systemctl list-unit-files ksmtuned.service >/dev/null 2>&1 && sudo systemctl disable --now ksmtuned 2>/dev/null || true
  w /sys/kernel/mm/ksm/run 2

  log "2. lift per-VM memory.high + remove hook"
  sudo rm -f /etc/libvirt/hooks/qemu
  sudo systemctl reload-or-restart libvirtd 2>/dev/null \
    || sudo systemctl reload-or-restart virtqemud 2>/dev/null || true
  shopt -s nullglob
  for s in /sys/fs/cgroup/machine.slice/*qemu*node*.scope; do
    [[ -f "$s/memory.high" ]] && w "$s/memory.high" max || true
  done
  echo "   (host zram swap is left as-is; it is host-managed, not torn down here)"
  log "Reverted KSM + the per-VM squeeze."
}

case "$ACTION" in
  apply) apply ;;
  undo)  undo ;;
  *) echo "usage: $0 [apply|undo]" >&2; exit 2 ;;
esac
