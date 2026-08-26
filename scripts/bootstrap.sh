#!/usr/bin/env bash
# Bootstrap the host: Python venv + deps, Ansible collection, openshift-install,
# and a self-signed TLS cert for the sushy Redfish emulator.
# Idempotent: skips anything already present. Re-run with FORCE=1 to refresh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

# --- config (override via env) ---
ARCH="${ARCH:-x86_64}"
OCP_CHANNEL="${OCP_CHANNEL:-stable}"      # stable | latest | fast | candidate
OCP_VERSION="${OCP_VERSION:-}"            # e.g. 4.16.7; empty = newest in channel
BUILD_DIR="$SCRIPT_DIR/build"                # downloaded/generated artifacts
CERTS_DIR="$SCRIPT_DIR/certs"                # local TLS material
INSTALL_DIR="$BUILD_DIR/openshift-install"   # self-contained: never touches the system
MIRROR="https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp"
RELEASE_PATH="${OCP_VERSION:-$OCP_CHANNEL}"
TARBALL="$BUILD_DIR/openshift-install-linux.tar.gz"
mkdir -p "$BUILD_DIR" "$CERTS_DIR"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }

# --- 1. Python venv + deps ---
if [[ ! -d .venv || -n "${FORCE:-}" ]]; then
  log "Creating Python venv (.venv)"
  # Runtime deps to operate the lab: sushy-tools (BMC), ansible-core, the
  # community.libvirt requirements (libvirt-python + lxml), jinja2/pyyaml, and
  # kubernetes (kubernetes.core for Day-2 operators).
  deps=(sushy-tools ansible-core libvirt-python lxml pyyaml jinja2 kubernetes docker)
  # Dev/CI only, not needed to run the lab: yamllint + ansible-lint (make lint)
  # and matplotlib (regenerates docs/bench.png). Install with DEV=1.
  dev_deps=(yamllint ansible-lint matplotlib)
  [[ -n "${DEV:-}" ]] && deps+=("${dev_deps[@]}")
  command -v uv >/dev/null 2>&1 \
    || { warn "uv not found; install it: curl -LsSf https://astral.sh/uv/install.sh | sh"; exit 1; }
  uv venv
  uv pip install --python .venv/bin/python "${deps[@]}"
  [[ -z "${DEV:-}" ]] && log "(dev tools skipped; DEV=1 make bootstrap adds yamllint/ansible-lint/matplotlib)"
else
  log "venv exists, skipping (FORCE=1 to recreate)"
fi

# --- 2. Ansible collection ---
log "Installing community.libvirt collection"
./.venv/bin/ansible-galaxy collection install -r ansible/requirements.yml \
  ${FORCE:+--force}

# --- 3. openshift-install (self-contained; lives in ./build/openshift-install) ---
if [[ -x "$INSTALL_DIR/openshift-install" && -z "${FORCE:-}" ]]; then
  log "openshift-install present ($("$INSTALL_DIR/openshift-install" version | head -1))"
else
  if [[ ! -f "$TARBALL" || -n "${FORCE:-}" ]]; then
    log "Downloading openshift-install ($RELEASE_PATH, $ARCH)"
    curl -fL --retry 3 -o "$TARBALL" "${MIRROR}/${RELEASE_PATH}/openshift-install-linux.tar.gz"
  else
    log "$TARBALL present, skipping download"
  fi
  log "Extracting openshift-install into $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  tar -xzf "$TARBALL" -C "$INSTALL_DIR" openshift-install
  chmod 0755 "$INSTALL_DIR/openshift-install"
fi

# matching oc client (the system oc may be too old; `oc adm node-image` needs 4.17+)
if [[ -x "$INSTALL_DIR/oc" && -z "${FORCE:-}" ]]; then
  log "oc present ($("$INSTALL_DIR/oc" version --client 2>/dev/null | head -1))"
else
  OC_TARBALL="$BUILD_DIR/openshift-client-linux.tar.gz"
  log "Downloading oc client ($RELEASE_PATH, $ARCH)"
  curl -fL --retry 3 -o "$OC_TARBALL" "${MIRROR}/${RELEASE_PATH}/openshift-client-linux.tar.gz"
  tar -xzf "$OC_TARBALL" -C "$INSTALL_DIR" oc
  chmod 0755 "$INSTALL_DIR/oc"
fi

# coreos-installer (embeds ignition into the RHCOS live ISO for UPI installs).
# A single static binary, kept in build/ alongside the other self-contained tools.
if [[ -x "$BUILD_DIR/coreos-installer" && -z "${FORCE:-}" ]]; then
  log "coreos-installer present"
else
  log "Downloading coreos-installer ($ARCH)"
  curl -fL --retry 3 -o "$BUILD_DIR/coreos-installer" \
    "https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/coreos-installer/latest/coreos-installer"
  chmod 0755 "$BUILD_DIR/coreos-installer"
fi

# oc-mirror (v2): mirrors operator catalogs for fully air-gapped Day-2 operators
# (make mirror-operators). Optional; only needed for a true air gap.
if [[ -x "$INSTALL_DIR/oc-mirror" && -z "${FORCE:-}" ]]; then
  log "oc-mirror present"
else
  OCM_TARBALL="$BUILD_DIR/oc-mirror.tar.gz"
  log "Downloading oc-mirror ($RELEASE_PATH, $ARCH)"
  if curl -fL --retry 3 -o "$OCM_TARBALL" "${MIRROR}/${RELEASE_PATH}/oc-mirror.tar.gz"; then
    tar -xzf "$OCM_TARBALL" -C "$INSTALL_DIR" oc-mirror && chmod 0755 "$INSTALL_DIR/oc-mirror"
  else
    warn "oc-mirror download failed (only needed for air-gapped operators; make mirror-operators)"
  fi
fi

# --- 4. TLS cert for sushy-emulator ---
if [[ ! -f "$CERTS_DIR/localhost-cert.pem" || ! -f "$CERTS_DIR/localhost-key.pem" || -n "${FORCE:-}" ]]; then
  log "Generating self-signed TLS cert in $CERTS_DIR"
  openssl req -x509 -newkey rsa:4096 -nodes -days 365 \
    -keyout "$CERTS_DIR/localhost-key.pem" -out "$CERTS_DIR/localhost-cert.pem" -subj "/CN=localhost"
else
  log "TLS cert exists, skipping"
fi

# --- 5. pull-secret check ---
if [[ ! -s pull-secret.json ]]; then
  warn "pull-secret.json missing, download from https://console.redhat.com/openshift/install/pull-secret"
fi

# --- 6. modular libvirt sockets (offer to enable; make up fails without them) ---
if systemctl cat virtqemud.socket >/dev/null 2>&1; then
  off=""
  for d in virtqemud virtnetworkd virtstoraged; do
    systemctl is-active --quiet "$d.socket" 2>/dev/null || off="$off $d.socket"
  done
  if [[ -n "$off" ]]; then
    log "Modular libvirt sockets inactive:$off ('make up' needs them)"
    if [[ -t 0 ]]; then
      read -r -p "  Enable now? sudo systemctl enable --now$off [Y/n] " ans
      # shellcheck disable=SC2086
      [[ "$ans" == [nN]* ]] || { sudo systemctl enable --now $off && log "enabled:$off"; }
    else
      log "non-interactive; enable manually: sudo systemctl enable --now$off"
    fi
  fi
fi

log "Bootstrap complete."
echo
echo "Next:"
echo "  source .venv/bin/activate"
echo "  export PATH=\"$INSTALL_DIR:\$PATH\"   # use the self-contained installer"
echo "  cd ansible && ansible-playbook lifecycle/setup.yml   # -K if not in libvirt group"
