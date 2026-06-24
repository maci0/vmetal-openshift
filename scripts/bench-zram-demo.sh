#!/usr/bin/env bash
# Demonstrate where zram beats KSM: a compressible-but-unique memory workload.
#
# The main bench (scripts/bench-memory.sh) runs identical RHCOS nodes, KSM's best
# case (it dedups the identical pages). This is the opposite: scripts/memfill.py
# allocates pages that are unique (so KSM can merge nothing) but low-entropy (so
# zram compresses them). We run it under a cgroup memory.high squeeze and compare:
#
#   KSM phase   -> KSM on; report what it managed to merge (expected ~0)
#   zram phase  -> squeeze the cgroup; report what zram compressed and reclaimed
#
# Host-level, no cluster needed. Uses sudo for KSM/cgroup knobs (restored on exit).
#
#   scripts/bench-zram-demo.sh
# Env: DEMO_MIB (8192), HIGH_PCT (30 = squeeze cgroup to 30% of the alloc),
#      SETTLE (15), KSM_WAIT (60).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
MIB="${DEMO_MIB:-8192}"
HIGH_PCT="${HIGH_PCT:-30}"
SETTLE="${SETTLE:-15}"
KSM_WAIT="${KSM_WAIT:-60}"
SCOPE=zram-demo.scope
ZSYS=/sys/block/zram0
PY="$ROOT/.venv/bin/python"; [[ -x "$PY" ]] || PY=python3

die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
w()   { echo "$2" | sudo tee "$1" >/dev/null; }
mib() { echo $(( $1 / 1024 / 1024 )); }   # bytes -> MiB

[[ -b /dev/zram0 ]] || die "no /dev/zram0 (host has no zram swap)"
grep -q zram0 /proc/swaps || die "zram0 is not swapped on (swapon needed)"
command -v systemd-run >/dev/null || die "systemd-run required"

ORIG_SWAPPINESS="$(cat /proc/sys/vm/swappiness)"
cleanup() {
  sudo systemctl stop "$SCOPE" 2>/dev/null || true
  w /sys/kernel/mm/ksm/run 2; w /sys/kernel/mm/ksm/run 0
  w /sys/kernel/mm/ksm/pages_to_scan 100
  w /sys/kernel/mm/ksm/sleep_millisecs 20
  w /proc/sys/vm/swappiness "$ORIG_SWAPPINESS"
}
trap cleanup EXIT

# Anonymous pages must be allowed to reach swap when the squeeze hits.
w /proc/sys/vm/swappiness 100

log "launching memfill: ${MIB} MiB in a transient scope"
sudo systemd-run --scope --unit "$SCOPE" --quiet \
  -p MemoryHigh=infinity -p MemorySwapMax=infinity -p MemoryMax=infinity \
  "$PY" "$ROOT/scripts/memfill.py" --mib "$MIB" --seconds 0 &
CG=""
for _ in $(seq 1 30); do
  CG="$(systemctl show "$SCOPE" -p ControlGroup --value 2>/dev/null || true)"
  [[ -n "$CG" && -f "/sys/fs/cgroup${CG}/memory.current" ]] && break
  sleep 1
done
CGDIR="/sys/fs/cgroup${CG}"
[[ -f "$CGDIR/memory.current" ]] || die "could not find scope cgroup (got '$CG')"

log "waiting for the allocation to become resident"
for _ in $(seq 1 120); do
  cur=$(mib "$(cat "$CGDIR/memory.current")")
  [[ "$cur" -ge $(( MIB * 90 / 100 )) ]] && break
  sleep 1
done
log "resident: $(mib "$(cat "$CGDIR/memory.current")") MiB; letting pages go cold (${SETTLE}s)"
sleep "$SETTLE"

# --- KSM phase: can dedup merge any of these unique pages? (expect ~0) ---
log "KSM phase: scanning to see what dedup can merge"
w /sys/kernel/mm/ksm/pages_to_scan 20000
w /sys/kernel/mm/ksm/sleep_millisecs 5
w /sys/kernel/mm/ksm/run 1
sleep "$KSM_WAIT"
ksm_merged_mib=$(( $(cat /sys/kernel/mm/ksm/pages_sharing) * 4 / 1024 ))
rss_ksm=$(mib "$(cat "$CGDIR/memory.current")")
w /sys/kernel/mm/ksm/run 2; w /sys/kernel/mm/ksm/run 0   # unmerge + off, isolate zram

# --- zram phase: squeeze the cgroup so cold pages compress into zram ---
zc_before=$(awk '{print $2}' "$ZSYS/mm_stat")   # compr_data_size, bytes
high_mib=$(( MIB * HIGH_PCT / 100 ))
log "zram phase: squeezing cgroup to ${high_mib} MiB (memory.high)"
w "$CGDIR/memory.high" "$(( high_mib * 1024 * 1024 ))"
for _ in $(seq 1 60); do   # wait until reclaim settles
  cur=$(mib "$(cat "$CGDIR/memory.current")")
  [[ "$cur" -le $(( high_mib + high_mib / 5 )) ]] && break
  sleep 2
done
sleep 5
zc_after=$(awk '{print $2}' "$ZSYS/mm_stat")
rss_zram=$(mib "$(cat "$CGDIR/memory.current")")
zram_compr_mib=$(mib "$(( zc_after - zc_before ))")
evicted_mib=$(( rss_ksm - rss_zram ))
reclaimed_mib=$(( evicted_mib - zram_compr_mib ))
ratio="n/a"; [[ "$zram_compr_mib" -gt 0 ]] && ratio=$(awk "BEGIN{printf \"%.1fx\", $evicted_mib/$zram_compr_mib}")

echo
printf '%-26s %12s\n' "workload" "${MIB} MiB, unique compressible pages"
printf '%-26s %12s\n' "KSM merged" "${ksm_merged_mib} MiB"
printf '%-26s %12s\n' "zram evicted (RSS drop)" "${evicted_mib} MiB"
printf '%-26s %12s\n' "zram compressed to" "${zram_compr_mib} MiB (${ratio})"
printf '%-26s %12s\n' "net RAM reclaimed (zram)" "${reclaimed_mib} MiB"
echo
if [[ "$reclaimed_mib" -gt "$ksm_merged_mib" ]]; then
  log "zram reclaimed ${reclaimed_mib} MiB vs KSM's ${ksm_merged_mib} MiB: compression wins when pages are unique."
else
  log "unexpected: KSM (${ksm_merged_mib} MiB) >= zram (${reclaimed_mib} MiB) for this run."
fi
