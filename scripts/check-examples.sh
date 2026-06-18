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

gen() { ( cd ansible && "$AP" generate-configs.yml -e out_dir="$TMP/$1" -e "$2" >/dev/null ); }
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

"$PY" - docs/examples.md "$corpus" <<'PY'
import sys, re
doc = open(sys.argv[1]).read()
corpus_lines = [l.rstrip() for l in open(sys.argv[2]).read().splitlines()]

def contiguous(needle, hay):
    n = [l.rstrip() for l in needle.splitlines() if l.strip() != ""]
    h = [l for l in hay if l.strip() != ""]
    if not n:
        return True
    for i in range(len(h) - len(n) + 1):
        if h[i:i + len(n)] == n:
            return True
    return False

def illustrative(b):
    if b.lstrip().startswith("<"):          # rendered XML is reformatted in docs
        return True
    if "# ..." in b:                        # explicit elision comment
        return True
    if re.search(r"(?m)^\s*\.\.\.\s*$", b):  # a bare "..." line
        return True
    return False

blocks = re.findall(r"```[a-z]*\n(.*?)```", doc, re.S)
checked = skipped = 0
missing = []
for b in blocks:
    if illustrative(b):
        skipped += 1
        continue
    checked += 1
    if not contiguous(b, corpus_lines):
        missing.append(b.splitlines()[0] if b.strip() else "(empty)")

print(f"checked {checked} block(s), skipped {skipped} illustrative")
if missing:
    print("DRIFT: these doc blocks no longer match generated output:")
    for m in missing:
        print("  starts:", m)
    sys.exit(1)
print("examples in sync with templates")
PY
