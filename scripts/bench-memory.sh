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
# Env: BENCH_PODS (=node count), BENCH_VM_BYTES (512M), BENCH_SECS (60),
#      KSM_SETTLE (90), SQUEEZE_PCT (55), BENCH_ALGOS ("zstd lz4 lzo"), STRESS_IMG.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${1:-${CLUSTER:-cluster0}}"
SECS="${BENCH_SECS:-60}"; VMB="${BENCH_VM_BYTES:-512M}"; KSM_SETTLE="${KSM_SETTLE:-90}"
SQUEEZE_PCT="${SQUEEZE_PCT:-55}"
STRESS_IMG="${STRESS_IMG:-docker.io/colinianking/stress-ng:latest}"
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
PODS="${BENCH_PODS:-$(oc get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)}"
[[ "$PODS" -gt 0 ]] || die "no Ready nodes"
ZSIZE="$(cat "$ZSYS/disksize")"

scopes() { ls -d /sys/fs/cgroup/machine.slice/*qemu*node*.scope 2>/dev/null; }

set_ksm() {  # on|off (off = unmerge and wait, since run=0 leaves pages merged)
  if [[ "$1" == on ]]; then w /sys/kernel/mm/ksm/run 1; w /sys/kernel/mm/ksm/pages_to_scan 2000
  else
    w /sys/kernel/mm/ksm/run 2
    for _ in $(seq 1 90); do [[ "$(cat /sys/kernel/mm/ksm/pages_sharing)" -lt 2000 ]] && break; sleep 2; done
    w /sys/kernel/mm/ksm/run 0
  fi
}

set_zram_algo() {  # reset zram0 with compression algorithm $1 (drains swap first)
  sudo swapoff "$ZDEV" 2>/dev/null || true
  w "$ZSYS/reset" 1
  w "$ZSYS/comp_algorithm" "$1"
  w "$ZSYS/disksize" "$ZSIZE"
  sudo mkswap "$ZDEV" >/dev/null 2>&1
  sudo swapon "$ZDEV" -p 100
}

drain_swap() { sudo swapoff "$ZDEV" 2>/dev/null && sudo swapon "$ZDEV" -p 100; }

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
        args: ["--cpu","2","--vm","1","--vm-bytes","$VMB","--timeout","${SECS}s","--metrics-brief"]
        resources: { requests: { cpu: "500m", memory: "256Mi" } }
YAML
  oc -n "$NS" wait --for=condition=complete job/stress --timeout="$(( SECS + 240 ))s" >/dev/null 2>&1 || true
  oc -n "$NS" logs -l job-name=stress --tail=-1 2>/dev/null \
    | awk '/metrc/ && / cpu /{print $(NF-1)}' | awk '{s+=$1} END{printf "%.0f", s+0}'
  oc -n "$NS" delete job stress >/dev/null 2>&1 || true
}

ALGOS="${BENCH_ALGOS:-zstd lz4 lzo}"
ORDER=(baseline ksm); declare -A SPEC RES
SPEC[baseline]="off:-:off"; SPEC[ksm]="on:-:off"
for a in $ALGOS; do
  ORDER+=("zram-$a" "ksm+zram-$a")
  SPEC["zram-$a"]="off:$a:on"; SPEC["ksm+zram-$a"]="on:$a:on"
done

for label in "${ORDER[@]}"; do
  IFS=: read -r k a sq <<<"${SPEC[$label]}"
  set_squeeze off                       # lift any prior squeeze first
  [[ "$a" != "-" ]] && set_zram_algo "$a"
  set_ksm "$k"
  [[ "$sq" == off ]] && drain_swap      # baseline/ksm: clear swap -> honest no-swap
  set_squeeze "$sq"
  log "[$label] settling (${KSM_SETTLE}s)"; sleep "$KSM_SETTLE"
  log "[$label] running stress-ng on $PODS pod(s)"
  perf=$(run_bench)
  read -r used ksm zd zc ratio swu < <(mem_row)
  RES[$label]="$used|$ksm|$zd|$zc|$ratio|$swu|$perf"
  log "[$label] used=${used}MiB ksm=${ksm}MiB zram=${zd}->${zc}MiB($ratio) swap=${swu}MiB perf=${perf}"
done

set_squeeze off; set_zram_algo zstd >/dev/null 2>&1 || true   # restore host default
oc delete ns "$NS" >/dev/null 2>&1 || true

echo
printf "%-16s %10s %10s %10s %10s %7s %9s %12s\n" state used_MiB ksm_MiB zram_data zram_compr ratio swap_MiB perf_ops_s
for label in "${ORDER[@]}"; do
  IFS='|' read -r u k zd zc r sw p <<<"${RES[$label]}"
  printf "%-16s %10s %10s %10s %10s %7s %9s %12s\n" "$label" "$u" "$k" "$zd" "$zc" "$r" "$sw" "$p"
done

out="$ROOT/build/bench-results.csv"; mkdir -p "$ROOT/build"
{
  echo "state,host_used_mib,ksm_saved_mib,zram_data_mib,zram_compr_mib,swap_used_mib,perf_ops_s"
  for label in "${ORDER[@]}"; do
    IFS='|' read -r u k zd zc r sw p <<<"${RES[$label]}"
    echo "$label,$u,$k,$zd,$zc,$sw,$p"
  done
} > "$out"
log "wrote $out"
