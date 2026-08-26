#!/usr/bin/env bash
# Offline checks: no libvirt, no root. Safe to run in CI.
#   * ansible syntax-check (all playbooks)
#   * yamllint (if available)
#   * shellcheck (if available)
#   * ruff + black + mypy over tools/ and tests/ (if uv is installed)
#   * offline template render + XML validation
#   * render install/agent configs + YAML parse
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

# Absolute paths: the checks below cd around.
resolve_ansible
if [[ -x "$ROOT/.venv/bin/yamllint" ]]; then YAMLLINT="$ROOT/.venv/bin/yamllint"; else YAMLLINT="yamllint"; fi
if [[ -x "$ROOT/.venv/bin/ansible-lint" ]]; then ANSIBLELINT="$ROOT/.venv/bin/ansible-lint"; else ANSIBLELINT="ansible-lint"; fi

pass() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
skip() { printf '\033[1;33mSKIP\033[0m %s\n' "$*"; }

echo "== ansible syntax-check =="
# Auto-discover playbooks so new ones cannot silently skip CI.
mapfile -t PLAYBOOKS < <(cd ansible && compgen -G 'lifecycle/*.yml' && compgen -G 'day2/*.yml' && compgen -G 'appliances/*.yml' | sort -u)
[[ "${#PLAYBOOKS[@]}" -gt 0 ]] || { echo "no playbooks found under ansible/" >&2; exit 1; }
( cd ansible && "$AP" --syntax-check "${PLAYBOOKS[@]}" >/dev/null )
pass "playbooks parse (${#PLAYBOOKS[@]})"

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
  shellcheck -S warning scripts/*.sh scripts/*/*.sh
  pass "shell clean"
else
  skip "shellcheck not installed"
fi

echo "== python (ruff / black / mypy) =="
if command -v uv >/dev/null 2>&1; then
  # uvx, not the venv: these are dev gates, not runtime deps of the lab.
  uvx ruff check tools tests
  uvx black --check --quiet tools tests
  uvx --with pyyaml --with jinja2 --with types-PyYAML mypy
  pass "python clean"
else
  skip "uv not installed (https://astral.sh/uv); ruff/black/mypy not run"
fi

echo "== render + xmllint =="
if command -v xmllint >/dev/null 2>&1; then
  "$PY" tests/render_check.py
else
  skip "xmllint not installed"
fi

echo "== render install/agent configs =="
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT   # clean up even on early (set -e) exit
( cd ansible && "$AP" lifecycle/generate-configs.yml -e out_dir="$TMP" >/dev/null )
( cd ansible && "$AP" lifecycle/generate-configs.yml -e out_dir="$TMP" \
    -e '{"clusters":[{"name":"ipichk","control_plane":3,"workers":0,"install_mode":"ipi"}]}' >/dev/null )
( cd ansible && "$AP" lifecycle/generate-configs.yml -e out_dir="$TMP" \
    -e '{"clusters":[{"name":"upichk","control_plane":1,"workers":0,"install_mode":"upi"}]}' >/dev/null )
( cd ansible && "$AP" lifecycle/generate-configs.yml -e out_dir="$TMP" \
    -e '{"clusters":[{"name":"upimn","control_plane":3,"workers":2,"install_mode":"upi","boot_via":"pxe"}]}' >/dev/null )
( cd ansible && "$AP" lifecycle/generate-configs.yml -e out_dir="$TMP" \
    -e '{"clusters":[{"name":"discchk","control_plane":1,"workers":0,"disconnected":true}]}' >/dev/null )
"$PY" tests/parse_configs.py "$TMP"
pass "install/agent/ipi/upi configs parse"
rm -rf "$TMP"

echo "== examples drift =="
"$ROOT/scripts/check-examples.sh"
pass "docs/examples.md in sync"

echo
pass "lint complete"
