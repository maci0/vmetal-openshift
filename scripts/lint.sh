#!/usr/bin/env bash
# Offline checks: no libvirt, no root. Safe to run in CI.
#   * ansible syntax-check (all playbooks)
#   * yamllint (if available)
#   * shellcheck (if available)
#   * offline template render + XML validation
#   * render install/agent configs + YAML parse
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Prefer the project venv if present (absolute paths, we cd around).
if [[ -x "$ROOT/.venv/bin/ansible-playbook" ]]; then
  AP="$ROOT/.venv/bin/ansible-playbook"
  PY="$ROOT/.venv/bin/python"
else
  AP="ansible-playbook"
  PY="python3"
fi
if [[ -x "$ROOT/.venv/bin/yamllint" ]]; then YAMLLINT="$ROOT/.venv/bin/yamllint"; else YAMLLINT="yamllint"; fi
if [[ -x "$ROOT/.venv/bin/ansible-lint" ]]; then ANSIBLELINT="$ROOT/.venv/bin/ansible-lint"; else ANSIBLELINT="ansible-lint"; fi

pass() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
skip() { printf '\033[1;33mSKIP\033[0m %s\n' "$*"; }

echo "== ansible syntax-check =="
( cd ansible && "$AP" --syntax-check \
    setup.yml cleanup.yml dump-topology.yml generate-configs.yml \
    bmc.yml sushy.yml host-dns.yml workers.yml operators.yml haproxy.yml nfs.yml metallb-bgp.yml adopt.yml optimize.yml >/dev/null )
pass "playbooks parse"

echo "== yamllint =="
if [[ -x "$YAMLLINT" ]] || command -v "$YAMLLINT" >/dev/null 2>&1; then
  "$YAMLLINT" -c "$ROOT/.yamllint" ansible/
  pass "yaml clean"
else
  skip "yamllint not installed"
fi

echo "== ansible-lint =="
if [[ -x "$ANSIBLELINT" ]] || command -v "$ANSIBLELINT" >/dev/null 2>&1; then
  ( cd ansible && "$ANSIBLELINT" -q )
  pass "ansible-lint (production profile)"
else
  skip "ansible-lint not installed"
fi

echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
  # -S warning: skip info/style notes (e.g. SC2015 on intentional `... || true`),
  # which older shellcheck versions emit and would fail CI. Real bugs are >= warning.
  shellcheck -S warning scripts/*.sh
  pass "shell clean"
else
  skip "shellcheck not installed"
fi

echo "== render + xmllint =="
if command -v xmllint >/dev/null 2>&1; then
  "$PY" tests/render_check.py
else
  skip "xmllint not installed"
fi

echo "== render install/agent configs =="
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT   # clean up even on early (set -e) exit
( cd ansible && "$AP" generate-configs.yml -e out_dir="$TMP" >/dev/null )
( cd ansible && "$AP" generate-configs.yml -e out_dir="$TMP" \
    -e '{"clusters":[{"name":"ipichk","control_plane":3,"workers":0,"install_mode":"ipi"}]}' >/dev/null )
( cd ansible && "$AP" generate-configs.yml -e out_dir="$TMP" \
    -e '{"clusters":[{"name":"upichk","control_plane":1,"workers":0,"install_mode":"upi"}]}' >/dev/null )
( cd ansible && "$AP" generate-configs.yml -e out_dir="$TMP" \
    -e '{"clusters":[{"name":"upimn","control_plane":3,"workers":2,"install_mode":"upi","boot_via":"pxe"}]}' >/dev/null )
( cd ansible && "$AP" generate-configs.yml -e out_dir="$TMP" \
    -e '{"clusters":[{"name":"discchk","control_plane":1,"workers":0,"disconnected":true}]}' >/dev/null )
"$PY" tests/parse_configs.py "$TMP"
pass "install/agent/ipi/upi configs parse"
rm -rf "$TMP"

echo "== examples drift =="
"$ROOT/scripts/check-examples.sh"
pass "docs/examples.md in sync"

echo
pass "lint complete"
