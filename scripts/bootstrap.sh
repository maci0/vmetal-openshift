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
  # libvirt-python + lxml are required by the community.libvirt modules.
  deps=(sushy-tools ansible-core yamllint ansible-lint libvirt-python lxml)
  if command -v uv >/dev/null 2>&1; then
    uv venv
    uv pip install --python .venv/bin/python "${deps[@]}"
  else
    python3 -m venv .venv
    ./.venv/bin/pip install --upgrade pip
    ./.venv/bin/pip install "${deps[@]}"
  fi
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
    curl -fL --retry 3 -o "$TARBALL" "${MIRROR}/${RELEASE_PATH}/${TARBALL}"
  else
    log "$TARBALL present, skipping download"
  fi
  log "Extracting openshift-install into $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR"
  tar -xzf "$TARBALL" -C "$INSTALL_DIR" openshift-install
  chmod 0755 "$INSTALL_DIR/openshift-install"
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

log "Bootstrap complete."
echo
echo "Next:"
echo "  source .venv/bin/activate"
echo "  export PATH=\"$INSTALL_DIR:\$PATH\"   # use the self-contained installer"
echo "  cd ansible && ansible-playbook setup.yml   # -K if not in libvirt group"
