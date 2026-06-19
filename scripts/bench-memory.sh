#!/usr/bin/env bash
# Validate the memory-optimization stack: run an identical stress-ng workload on
# the cluster under four host settings and compare memory use AND performance.
#   baseline       no KSM, no zswap
#   ksm            KSM only
#   zswap          zswap + per-VM cgroup squeeze (memory.high) only
#   ksm+zswap      everything
#
# The zswap states are swept across compression algorithms (BENCH_COMPRESSORS,
# default "zstd lz4 lzo", filtered to what the kernel accepts).
#
# Note: turning KSM off (run=0) only stops scanning, already-merged pages stay
# merged, so for a clean baseline we run=2 (unmerge) and wait for pages_sharing to
# drain. A full VM reboot would also reset it, but that costs a reboot per state.
#
#   scripts/bench-memory.sh [cluster]
# Env: BENCH_PODS (default = node count), BENCH_VM_BYTES (1G), BENCH_SECS (60),
#      KSM_SETTLE (90), SQUEEZE_PCT (60), BENCH_COMPRESSORS, STRESS_IMG.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="${1:-${CLUSTER:-cluster0}}"
SECS="${BENCH_SECS:-60}"; VMB="${BENCH_VM_BYTES:-1G}"; KSM_SETTLE="${KSM_SETTLE:-90}"
SQUEEZE_PCT="${SQUEEZE_PCT:-60}"
STRESS_IMG="${STRESS_IMG:-docker.io/colinianking/stress-ng:latest}"
NS=vmetal-bench

die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
w()   { echo "$2" | sudo tee "$1" >/dev/null; }

command -v oc >/dev/null || die "oc not found"
kubeconfig="$ROOT/clusters/$CLUSTER/auth/kubeconfig"
[[ -f "$kubeconfig" ]] || die "no kubeconfig for '$CLUSTER'"
export KUBECONFIG="$kubeconfig"
PODS="${BENCH_PODS:-$(oc get nodes --no-headers 2>/dev/null | grep -c Ready)}"
[[ "$PODS" -gt 0 ]] || die "no Ready nodes"

scopes() { ls -d /sys/fs/cgroup/machine.slice/machine-qemu*-node*.scope \
                  /sys/fs/cgroup/machine.slice/machine-qemu*-day2-worker*.scope 2>/dev/null; }

set_ksm() {  # $1 = on|off
  if [[ "$1" == on ]]; then
    w /sys/kernel/mm/ksm/run 1; w /sys/kernel/mm/ksm/pages_to_scan 2000
  else
    # run=0 only STOPS scanning, merged pages stay merged. run=2 unmerges them;
    # wait until they are actually split so the baseline is truly un-deduped.
    w /sys/kernel/mm/ksm/run 2
    for _ in $(seq 1 90); do
      [[ "$(cat /sys/kernel/mm/ksm/pages_sharing)" -lt 2000 ]] && break
      sleep 2
    done
    w /sys/kernel/mm/ksm/run 0
  fi
}
set_zswap() {  # $1 = Y|N ; $2 = compressor (when Y)
  [[ -f /sys/module/zswap/parameters/enabled ]] || return 0
  if [[ "$1" == Y ]]; then
    w /sys/module/zswap/parameters/enabled N            # change compressor while off
    w /sys/module/zswap/parameters/compressor "$2"
    w /sys/module/zswap/parameters/enabled Y
  else
    w /sys/module/zswap/parameters/enabled N
  fi
}
set_squeeze() {  # $1 = on|off : memory.high on each VM scope
  for s in $(scopes); do
    [[ -f "$s/memory.high" ]] || continue
    if [[ "$1" == on ]]; then
      # cap uncompressed RAM at SQUEEZE_PCT% of the VM's allocated memory
      local mx; mx=$(cat "$s/memory.max" 2>/dev/null)
      [[ "$mx" == max || -z "$mx" ]] && mx=$(( 32*1024*1024*1024 ))
      w "$s/memory.high" "$(( mx * SQUEEZE_PCT / 100 ))"
      [[ -f "$s/memory.zswap.max" ]] && w "$s/memory.zswap.max" max || true
    else w "$s/memory.high" max; fi
  done
}

mem_row() {  # echo: host_used_MiB ksm_saved_MiB zswap_stored_MiB zswap_compr_MiB ratio
  local used ksm zs_pages zs_bytes
  used=$(free -m | awk '/Mem/{print $3}')
  ksm=$(( $(cat /sys/kernel/mm/ksm/pages_sharing 2>/dev/null||echo 0) * 4 / 1024 ))
  zs_pages=$(sudo cat /sys/kernel/debug/zswap/stored_pages 2>/dev/null || echo 0)
  zs_bytes=$(sudo cat /sys/kernel/debug/zswap/pool_total_size 2>/dev/null || echo 0)
  local stored=$(( zs_pages * 4 / 1024 )) compr=$(( zs_bytes / 1024 / 1024 ))
  local ratio="n/a"; [[ "$compr" -gt 0 ]] && ratio=$(awk "BEGIN{printf \"%.1fx\", $stored/$compr}")
  echo "$used $ksm $stored $compr $ratio"
}

run_bench() {  # echo aggregate bogo-ops/s across pods
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
  # sum cpu bogo-ops/s (real time) across pods. stress-ng metrics row:
  #   stress-ng: metrc: [N] cpu <ops> <real> <usr> <sys> <bogo/s-real> <bogo/s-usrsys>
  # bogo-ops/s (real time) is the second-to-last field.
  oc -n "$NS" logs -l job-name=stress --tail=-1 2>/dev/null \
    | awk '/metrc/ && / cpu /{print $(NF-1)}' \
    | awk '{s+=$1} END{printf "%.0f", s+0}'
  oc -n "$NS" delete job stress >/dev/null 2>&1 || true
}

# Which zswap compressors to sweep (filter to those the kernel actually accepts).
avail=""
if [[ -f /sys/module/zswap/parameters/compressor ]]; then
  orig="$(cat /sys/module/zswap/parameters/compressor)"
  for c in ${BENCH_COMPRESSORS:-zstd lz4 lzo}; do
    if echo "$c" | sudo tee /sys/module/zswap/parameters/compressor >/dev/null 2>&1 \
       && [[ "$(cat /sys/module/zswap/parameters/compressor)" == "$c" ]]; then avail="$avail $c"; fi
  done
  echo "$orig" | sudo tee /sys/module/zswap/parameters/compressor >/dev/null 2>&1 || true
fi
avail="${avail# }"; [[ -n "$avail" ]] || avail="zstd"
log "zswap compressors to test: $avail"

# state spec: ksm:zswap:compressor:squeeze
ORDER=(baseline ksm)
declare -A SPEC RES
SPEC[baseline]="off:N:-:off"; SPEC[ksm]="on:N:-:off"
for c in $avail; do
  ORDER+=("zswap-$c" "ksm+zswap-$c")
  SPEC["zswap-$c"]="off:Y:$c:on"
  SPEC["ksm+zswap-$c"]="on:Y:$c:on"
done

for label in "${ORDER[@]}"; do
  IFS=: read -r k z c sq <<<"${SPEC[$label]}"
  set_ksm "$k"; set_zswap "$z" "$c"; set_squeeze "$sq"
  log "[$label] settling (${KSM_SETTLE}s)"; sleep "$KSM_SETTLE"
  log "[$label] running stress-ng on $PODS pod(s)"
  perf=$(run_bench)
  read -r used ksm stored compr ratio < <(mem_row)
  RES[$label]="$used|$ksm|$stored|$compr|$ratio|$perf"
  log "[$label] host_used=${used}MiB ksm_saved=${ksm}MiB zswap=${stored}->${compr}MiB($ratio) perf=${perf} bogo-ops/s"
done

oc delete ns "$NS" >/dev/null 2>&1 || true
echo
printf "%-16s %12s %12s %14s %14s %8s %14s\n" state host_used_MiB ksm_saved_MiB zswap_stored_MiB zswap_compr_MiB ratio perf_ops_s
for label in "${ORDER[@]}"; do
  IFS='|' read -r u k st co r p <<<"${RES[$label]}"
  printf "%-16s %12s %12s %14s %14s %8s %14s\n" "$label" "$u" "$k" "$st" "$co" "$r" "$p"
done

out="$ROOT/build/bench-results.csv"
mkdir -p "$ROOT/build"
{
  echo "state,host_used_mib,ksm_saved_mib,zswap_stored_mib,zswap_compr_mib,perf_ops_s"
  for label in "${ORDER[@]}"; do
    IFS='|' read -r u k st co r p <<<"${RES[$label]}"
    echo "$label,$u,$k,$st,$co,$p"
  done
} > "$out"
log "wrote $out  (plot: $ROOT/.venv/bin/python scripts/plot-bench.py)"
