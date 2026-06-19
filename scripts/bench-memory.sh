#!/usr/bin/env bash
# Validate the memory-optimization stack: run an identical stress-ng workload on
# the cluster under four host settings and compare memory use AND performance.
#   baseline       no KSM, no zswap
#   ksm            KSM only
#   zswap          zswap + per-VM cgroup squeeze (memory.high) only
#   ksm+zswap      everything
#
#   scripts/bench-memory.sh [cluster]
# Env: BENCH_PODS (default = node count), BENCH_VM_BYTES (1G), BENCH_SECS (60),
#      KSM_SETTLE (90), SQUEEZE_PCT (60), STRESS_IMG.
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
  if [[ "$1" == on ]]; then w /sys/kernel/mm/ksm/run 1; w /sys/kernel/mm/ksm/pages_to_scan 2000
  else w /sys/kernel/mm/ksm/run 2; sleep 3; w /sys/kernel/mm/ksm/run 0; fi
}
set_zswap() { [[ -f /sys/module/zswap/parameters/enabled ]] && w /sys/module/zswap/parameters/enabled "$1" || true; }
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
  # sum cpu bogo-ops/s (real time) across pods
  oc -n "$NS" logs -l job-name=stress --tail=-1 2>/dev/null \
    | awk '/cpu/ && /bogo ops\/s/ {next} /[[:space:]]cpu[[:space:]]/{for(i=1;i<=NF;i++)if($i=="cpu"){print $(i+4)}}' \
    | awk '{s+=$1} END{printf "%.0f", s+0}'
  oc -n "$NS" delete job stress >/dev/null 2>&1 || true
}

declare -A RES
for state in baseline ksm zswap ksm+zswap; do
  case "$state" in
    baseline)  set_ksm off; set_zswap N; set_squeeze off ;;
    ksm)       set_ksm on;  set_zswap N; set_squeeze off ;;
    zswap)     set_ksm off; set_zswap Y; set_squeeze on ;;
    ksm+zswap) set_ksm on;  set_zswap Y; set_squeeze on ;;
  esac
  log "[$state] settling (${KSM_SETTLE}s)"; sleep "$KSM_SETTLE"
  log "[$state] running stress-ng on $PODS pod(s)"
  perf=$(run_bench)
  read -r used ksm stored compr ratio < <(mem_row)
  RES[$state]="$used|$ksm|$stored|$compr|$ratio|$perf"
  log "[$state] host_used=${used}MiB ksm_saved=${ksm}MiB zswap=${stored}->${compr}MiB($ratio) perf=${perf} bogo-ops/s"
done

oc delete ns "$NS" >/dev/null 2>&1 || true
echo
printf "%-12s %12s %12s %14s %14s %8s %14s\n" state host_used_MiB ksm_saved_MiB zswap_stored_MiB zswap_compr_MiB ratio perf_ops_s
for state in baseline ksm zswap ksm+zswap; do
  IFS='|' read -r u k st co r p <<<"${RES[$state]}"
  printf "%-12s %12s %12s %14s %14s %8s %14s\n" "$state" "$u" "$k" "$st" "$co" "$r" "$p"
done

out="$ROOT/build/bench-results.csv"
mkdir -p "$ROOT/build"
{
  echo "state,host_used_mib,ksm_saved_mib,zswap_stored_mib,zswap_compr_mib,perf_ops_s"
  for state in baseline ksm zswap ksm+zswap; do
    IFS='|' read -r u k st co r p <<<"${RES[$state]}"
    echo "$state,$u,$k,$st,$co,$p"
  done
} > "$out"
log "wrote $out  (plot: $ROOT/.venv/bin/python scripts/plot-bench.py)"
