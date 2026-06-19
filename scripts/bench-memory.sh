#!/usr/bin/env bash
# Validate the memory-optimization stack on this host (KSM + zram). Runs an
# identical stress-ng workload on the cluster under each setting and compares
# memory use AND performance.
#   baseline        no KSM, no squeeze, swap drained -> RAM only (must fit)
#   ksm             KSM only
#   zram-<algo>     cgroup squeeze (memory.high) -> cold pages into zram (algo)
#   ksm+zram-<algo> both
#
# zram is the host's compressed-RAM swap (/dev/zram0). The algo sweep resets the
# device per algorithm, so the cluster must fit in RAM at baseline (shrink it).
#
#   scripts/bench-memory.sh [cluster]
# Env: BENCH_PODS (=node count), BENCH_SECS (60),
#      KSM_SETTLE (90), SQUEEZE_PCT (55), BENCH_ALGOS ("zstd lz4 lzo"), STRESS_IMG.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${1:-${CLUSTER:-cluster0}}"
SECS="${BENCH_SECS:-60}"; KSM_SETTLE="${KSM_SETTLE:-90}"
SQUEEZE_PCT="${SQUEEZE_PCT:-55}"
STRESS_IMG="${STRESS_IMG:-registry.access.redhat.com/ubi9/ubi:latest}"
NS=vmetal-bench
ZDEV=/dev/zram0; ZSYS=/sys/block/zram0

die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
w()   { echo "$2" | sudo tee "$1" >/dev/null; }

command -v oc >/dev/null || die "oc not found"
[[ -b "$ZDEV" ]] || die "no $ZDEV (host has no zram swap)"
kubeconfig="$ROOT/clusters/$CLUSTER/auth/kubeconfig"
[[ -f "$kubeconfig" ]] || die "no kubeconfig for '$CLUSTER'"
export KUBECONFIG="$kubeconfig"
PODS="${BENCH_PODS:-0}"
for _ in $(seq 1 30); do
  [[ "$PODS" -gt 0 ]] && break
  PODS=$(oc get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
  [[ "$PODS" -gt 0 ]] || sleep 10
done
[[ "$PODS" -gt 0 ]] || die "no Ready nodes after waiting"
ZSIZE="$(cat "$ZSYS/disksize")"

scopes() { ls -d /sys/fs/cgroup/machine.slice/*qemu*node*.scope 2>/dev/null; }

set_ksm() {  # on|off (off = unmerge and wait, since run=0 leaves pages merged)
  if [[ "$1" == on ]]; then
    # scan aggressively so dedup converges in seconds, not minutes
    w /sys/kernel/mm/ksm/pages_to_scan 20000
    w /sys/kernel/mm/ksm/sleep_millisecs 5
    w /sys/kernel/mm/ksm/run 1
  else
    w /sys/kernel/mm/ksm/run 2
    for _ in $(seq 1 120); do [[ "$(cat /sys/kernel/mm/ksm/pages_sharing)" -lt 2000 ]] && break; sleep 2; done
    w /sys/kernel/mm/ksm/run 0
  fi
}

ksm_converge() {  # wait until pages_sharing stops growing (dedup converged), max ~12min
  local prev=-1 cur stable=0
  for _ in $(seq 1 144); do
    cur=$(cat /sys/kernel/mm/ksm/pages_sharing)
    if [[ "$prev" -ge 0 ]] && [[ $(( cur>prev ? cur-prev : prev-cur )) -lt 2000 ]]; then
      stable=$((stable + 1)); [[ "$stable" -ge 3 ]] && break
    else stable=0; fi
    prev=$cur; sleep 5
  done
  # Dial back to a gentle scan rate so KSM is not burning CPU/membw during the
  # perf measurement (it stays on, merged pages persist, just scans lightly).
  w /sys/kernel/mm/ksm/pages_to_scan 100
  w /sys/kernel/mm/ksm/sleep_millisecs 20
  log "KSM converged: $(( $(cat /sys/kernel/mm/ksm/pages_sharing) * 4 / 1024 ))MiB merged (scan dialed down)"
}

zram_converge() {  # wait until the squeeze finishes evicting cold pages to zram
  local prev=-1 cur stable=0
  for _ in $(seq 1 72); do   # up to ~6min
    cur=$(free -m | awk '/Swap/{print $3}')
    if [[ "$prev" -ge 0 ]] && [[ $(( cur>prev ? cur-prev : prev-cur )) -lt 100 ]]; then
      stable=$((stable + 1)); [[ "$stable" -ge 3 ]] && break
    else stable=0; fi
    prev=$cur; sleep 5
  done
  log "zram converged: $(free -m | awk '/Swap/{print $3}')MiB compressed in"
}

set_zram_algo() {  # reset zram0 with compression algorithm $1 (drains swap first)
  sudo swapoff "$ZDEV" 2>/dev/null || true
  if grep -q zram0 /proc/swaps; then
    log "WARN: could not drain zram (host full) - keeping current algo for [$1]"
    return 0
  fi
  w "$ZSYS/reset" 1
  w "$ZSYS/comp_algorithm" "$1"
  w "$ZSYS/disksize" "$ZSIZE"
  sudo mkswap "$ZDEV" >/dev/null 2>&1
  sudo swapon "$ZDEV" -p 100
}

# Global swappiness is forced to 0 for the run so nothing swaps "for the sake of
# it" (this host defaults to 150 = very eager). Pages only reach zram when the
# cgroup squeeze (memory.high) deliberately evicts them, so baseline/ksm stay in
# RAM (no swap) and only the zram states exercise compression.
ORIG_SWAPPINESS="$(cat /proc/sys/vm/swappiness)"
restore_host() {
  w /proc/sys/vm/swappiness "$ORIG_SWAPPINESS"
  w /sys/kernel/mm/ksm/pages_to_scan 100
  w /sys/kernel/mm/ksm/sleep_millisecs 20
}
trap restore_host EXIT
w /proc/sys/vm/swappiness 0

set_squeeze() {  # on|off : memory.high on each VM scope
  for s in $(scopes); do
    [[ -f "$s/memory.high" ]] || continue
    if [[ "$1" == on ]]; then
      local mx; mx=$(cat "$s/memory.max" 2>/dev/null)
      [[ "$mx" == max || -z "$mx" ]] && mx=$(( 16*1024*1024*1024 ))
      w "$s/memory.high" "$(( mx * SQUEEZE_PCT / 100 ))"
    else w "$s/memory.high" max; fi
  done
}

mem_row() {  # host_used_MiB ksm_saved_MiB zram_data_MiB zram_compr_MiB ratio swap_used_MiB
  local used ksm orig compr rest zdata zcompr swu ratio
  used=$(free -m | awk '/Mem/{print $3}')
  ksm=$(( $(cat /sys/kernel/mm/ksm/pages_sharing 2>/dev/null||echo 0) * 4 / 1024 ))
  read -r orig compr rest < "$ZSYS/mm_stat"
  zdata=$(( orig / 1024 / 1024 )); zcompr=$(( compr / 1024 / 1024 ))
  swu=$(free -m | awk '/Swap/{print $3}')
  ratio="n/a"; [[ "$zcompr" -gt 0 ]] && ratio=$(awk "BEGIN{printf \"%.1fx\", $zdata/$zcompr}")
  echo "$used $ksm $zdata $zcompr $ratio $swu"
}

run_bench() {  # echo summed cpu bogo-ops/s across pods
  oc create ns "$NS" >/dev/null 2>&1 || true
  oc -n "$NS" delete job stress >/dev/null 2>&1 || true
  cat <<YAML | oc -n "$NS" apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata: { name: stress }
spec:
  parallelism: $PODS
  completions: $PODS
  completionMode: Indexed
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: s
        image: $STRESS_IMG
        command: ["bash","-lc"]
        args: ["openssl speed -multi 4 -seconds ${SECS} -bytes 1024 sha256 2>&1"]
        resources: { requests: { cpu: "500m", memory: "256Mi" } }
YAML
  oc -n "$NS" wait --for=condition=complete job/stress --timeout="$(( SECS + 240 ))s" >/dev/null 2>&1 || true
  # openssl summary row: "sha256  <throughput>k" (1000 bytes/s); sum across pods.
  oc -n "$NS" logs -l job-name=stress --tail=-1 2>/dev/null \
    | awk '/^sha256[ \t]/{v=$2; sub("k","",v); s+=v} END{printf "%.0f", s+0}'
  oc -n "$NS" delete job stress >/dev/null 2>&1 || true
}

ALGOS="${BENCH_ALGOS:-zstd lz4 lzo}"
ORDER=(baseline ksm); declare -A SPEC RES
SPEC[baseline]="off:-:off"; SPEC[ksm]="on:-:off"
for a in $ALGOS; do
  ORDER+=("zram-$a" "ksm+zram-$a")
  SPEC["zram-$a"]="off:$a:on"; SPEC["ksm+zram-$a"]="on:$a:on"
done

OUT="$ROOT/build/bench-results.csv"; mkdir -p "$ROOT/build"
write_csv() {  # write all states recorded so far (survives a late failure)
  {
    echo "state,host_used_mib,ksm_saved_mib,zram_data_mib,zram_compr_mib,swap_used_mib,perf_ops_s"
    for l in "${ORDER[@]}"; do
      [[ -n "${RES[$l]:-}" ]] || continue
      IFS='|' read -r u k zd zc r sw p <<<"${RES[$l]}"
      echo "$l,$u,$k,$zd,$zc,$sw,$p"
    done
  } > "$OUT"
}

for label in "${ORDER[@]}"; do
  IFS=: read -r k a sq <<<"${SPEC[$label]}"
  set_squeeze off                       # lift any prior squeeze first
  set_ksm "$k"
  sudo swapoff "$ZDEV" 2>/dev/null || true   # drain + leave OFF: definitive no-swap
  # zram states re-enable the device with the chosen algorithm (a clean reset);
  # baseline/ksm leave swap OFF, so no swap is possible regardless of swappiness.
  [[ "$a" != "-" ]] && set_zram_algo "$a"
  set_squeeze "$sq"
  # Let each active optimization reach steady state BEFORE the perf run, so perf
  # reflects the settled state (not active dedup/compression churn).
  if [[ "$k" == off && "$sq" == off ]]; then
    log "[$label] settling (${KSM_SETTLE}s)"; sleep "$KSM_SETTLE"
  fi
  [[ "$k" == on ]]  && { log "[$label] KSM scanning to convergence"; ksm_converge; }
  [[ "$sq" == on ]] && { log "[$label] zram compressing to convergence"; zram_converge; }
  log "[$label] running stress-ng on $PODS pod(s)"
  perf=$(run_bench)
  read -r used ksm zd zc ratio swu < <(mem_row)
  RES[$label]="$used|$ksm|$zd|$zc|$ratio|$swu|$perf"
  log "[$label] used=${used}MiB ksm=${ksm}MiB zram=${zd}->${zc}MiB($ratio) swap=${swu}MiB perf=${perf}"
  write_csv   # persist after every state
done

set_squeeze off; set_zram_algo zstd >/dev/null 2>&1 || true   # restore host default
oc delete ns "$NS" >/dev/null 2>&1 || true

echo
printf "%-16s %10s %10s %10s %10s %7s %9s %12s\n" state used_MiB ksm_MiB zram_data zram_compr ratio swap_MiB perf_ops_s
for label in "${ORDER[@]}"; do
  [[ -n "${RES[$label]:-}" ]] || continue
  IFS='|' read -r u k zd zc r sw p <<<"${RES[$label]}"
  printf "%-16s %10s %10s %10s %10s %7s %9s %12s\n" "$label" "$u" "$k" "$zd" "$zc" "$r" "$sw" "$p"
done

write_csv
log "wrote $OUT  (plot: $ROOT/.venv/bin/python scripts/plot-bench.py)"
