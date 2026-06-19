#!/usr/bin/env bash
# Drift check: regenerate sample configs and assert every concrete code block in
# docs/examples.md still appears verbatim in fresh output. Blocks that are
# illustrative (XML, or containing a "..." elision) are skipped.
# Offline, no libvirt, no root.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -x "$ROOT/.venv/bin/ansible-playbook" ]]; then
  AP="$ROOT/.venv/bin/ansible-playbook"; PY="$ROOT/.venv/bin/python"
else
  AP="ansible-playbook"; PY="python3"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Deterministic render regardless of host: always supply a (dummy) ssh key so the
# sshKey line is present, and rely on redaction. Pull secret may be absent on CI;
# its line is redacted too.
echo "ssh-ed25519 AAAAdummy check-examples" > "$TMP/id.pub"
gen() { ( cd ansible && "$AP" generate-configs.yml -e out_dir="$TMP/$1" \
          -e ssh_key_file="$TMP/id.pub" -e "$2" >/dev/null ); }
gen sno  '{"clusters":[{"name":"sno","node_count":1}]}'
gen prod '{"clusters":[{"name":"prod","node_count":3}]}'
gen ipi  '{"clusters":[{"name":"ipi0","node_count":3,"install_mode":"ipi","provisioning_network_mode":"Managed"}]}'

# Same redactions the doc uses, concatenated into one corpus.
corpus="$TMP/corpus.txt"
: >"$corpus"
for f in "$TMP"/*/*/*.yaml; do
  sed -E "s/^pullSecret:.*/pullSecret: 'REDACTED'/; s/^( *password:).*/\1 REDACTED/; s|^sshKey:.*|sshKey: 'ssh-ed25519 AAAA...'|" "$f" >>"$corpus"
  echo >>"$corpus"
done

"$PY" "$ROOT/tests/examples_drift.py" docs/examples.md "$corpus"
