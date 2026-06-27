#!/usr/bin/env bash
# Render docs/diagrams/*.mmd to light + dark SVGs for the doc <picture> embeds.
# Run after editing any .mmd source. Needs mmdc (mermaid-cli) or npx.
#   make diagrams   (or: tools/render-diagrams.sh)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
MMDC="$(command -v mmdc || echo 'npx -y @mermaid-js/mermaid-cli')"
n=0
for m in docs/diagrams/*.mmd; do
  base="${m%.mmd}"
  $MMDC -i "$m" -o "${base}.svg"      -c tools/mermaid-light.json -b transparent >/dev/null 2>&1
  $MMDC -i "$m" -o "${base}-dark.svg" -c tools/mermaid-dark.json  -b transparent >/dev/null 2>&1
  n=$((n+1))
done
echo "rendered $n diagram(s) (light + dark SVG)"
