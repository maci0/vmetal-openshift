# shellcheck shell=bash
# Shared helpers for scripts/*. Source from a script that already set ROOT and
# uses `set -euo pipefail`. Safe to source multiple times.
#
#   ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
#   # shellcheck source=scripts/lib.sh
#   source "$ROOT/scripts/lib.sh"

[[ -n "${_VMETAL_LIB_SH:-}" ]] && return 0
_VMETAL_LIB_SH=1

die() { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

# CLUSTER names become paths, domain labels, and libvirt names.
require_cluster_name() {
  local c="${1:-}"
  [[ "$c" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "invalid CLUSTER name '$c' (use alnum/underscore/hyphen)"
}

# Prefer the project venv, then PATH.
resolve_ansible() {
  if [[ -x "${ROOT}/.venv/bin/ansible-playbook" ]]; then
    AP="${ROOT}/.venv/bin/ansible-playbook"
  else
    command -v ansible-playbook >/dev/null 2>&1 || die "ansible-playbook not found, run scripts/bootstrap.sh"
    AP="ansible-playbook"
  fi
  if [[ -x "${ROOT}/.venv/bin/python" ]]; then
    PY="${ROOT}/.venv/bin/python"
  else
    PY="python3"
  fi
}

# Prefer the bootstrapped client, then a versioned fallback, then PATH.
resolve_oc() {
  OC="${ROOT}/build/openshift-install/oc"
  [[ -x "$OC" ]] || OC="${ROOT}/build/oc422/oc"
  [[ -x "$OC" ]] || OC="$(command -v oc || true)"
  [[ -n "${OC:-}" && -x "$OC" ]] || die "oc not found (run scripts/bootstrap.sh, or put oc on PATH)"
}

resolve_openshift_install() {
  OI="${ROOT}/build/openshift-install/openshift-install"
  [[ -x "$OI" ]] || OI="$(command -v openshift-install || true)"
  [[ -n "${OI:-}" && -x "$OI" ]] || die "openshift-install not found; run scripts/bootstrap.sh"
}

# libvirt become flags used by ansible (skip sudo when already in the group).
# Sets BECOME for the caller.
libvirt_become_args() {
  if [[ "$(id -u)" == 0 ]] || id -nG | grep -qw libvirt; then
    # shellcheck disable=SC2034  # BECOME is for the caller
    BECOME=(-e use_become=false)
  else
    # shellcheck disable=SC2034
    BECOME=()
  fi
}

# virsh against qemu:///system, with sudo when the user is not in libvirt.
# Sets VIRSH for the caller.
resolve_virsh() {
  local uri="${LIBVIRT_URI:-qemu:///system}"
  if [[ "$(id -u)" == 0 ]] || id -nG | grep -qw libvirt; then
    # shellcheck disable=SC2034  # VIRSH is for the caller
    VIRSH=(virsh -c "$uri")
  else
    # shellcheck disable=SC2034
    VIRSH=(sudo virsh -c "$uri")
  fi
}

# Dump topology JSON to a temp file; caller must rm. Prints path on stdout.
dump_topology() {
  local topo
  topo="$(mktemp)"
  # shellcheck disable=SC2064
  ( cd "${ROOT}/ansible" && "$AP" lifecycle/dump-topology.yml -e out="$topo" ) >/dev/null \
    || { rm -f "$topo"; die "dump-topology failed"; }
  printf '%s\n' "$topo"
}

# Clear installer state that is safe to regenerate. Never deletes auth/ (live
# kubeconfig / kubeadmin password). Use FORCE_AUTH_WIPE=1 only when intentional.
clear_install_artifacts() {
  local dir="${1:?cluster dir}"
  [[ -d "$dir" ]] || return 0
  log "Clearing previous build artifacts in $dir (keeping auth/)"
  rm -rf "$dir/openshift"
  rm -f "$dir"/*.ign \
        "$dir"/agent.*.iso \
        "$dir/.openshift_install_state.json" \
        "$dir/.openshift_install.log"
  if [[ "${FORCE_AUTH_WIPE:-}" == "1" ]]; then
    log "FORCE_AUTH_WIPE=1: removing $dir/auth"
    rm -rf "$dir/auth"
  fi
}

# Start a short-lived HTTP server for ISO/PXE artifacts. Binds to 127.0.0.1 for
# Redfish/virtual-media; pass bind=0.0.0.0 or a gateway IP for PXE guests.
# Sets http_pid; caller should trap kill.
start_http_server() {
  local port="${1:?port}"
  local dir="${2:?dir}"
  local bind="${3:-127.0.0.1}"
  local probe="${4:-}"
  "$PY" -m http.server "$port" --bind "$bind" --directory "$dir" \
    >/tmp/vmetal-iso-http.log 2>&1 &
  http_pid=$!
  # Give the process a moment; die if it exited (bind failure / bad dir).
  sleep 0.3
  kill -0 "$http_pid" 2>/dev/null \
    || die "HTTP server failed to start on ${bind}:${port} (see /tmp/vmetal-iso-http.log)"
  if [[ -n "$probe" ]]; then
    local url="http://127.0.0.1:${port}/${probe}"
    # When bound to a non-loopback address, still probe via that address if needed.
    if [[ "$bind" != "127.0.0.1" && "$bind" != "0.0.0.0" && "$bind" != "::" ]]; then
      url="http://${bind}:${port}/${probe}"
    fi
    local _
    for _ in $(seq 1 10); do
      curl -fsS --max-time 3 -o /dev/null "$url" && return 0
      kill -0 "$http_pid" 2>/dev/null || die "HTTP server died (see /tmp/vmetal-iso-http.log)"
      sleep 1
    done
    die "HTTP server not serving ${probe} on ${bind}:${port} (port in use? see /tmp/vmetal-iso-http.log)"
  fi
}
