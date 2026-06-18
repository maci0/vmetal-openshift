#!/usr/bin/env bash
# Export a Markdown doc (with mermaid diagrams) to PDF.
# Renders mermaid blocks to PNG (mmdc), inlines them, then markdown -> HTML
# (pandoc) -> PDF (headless chromium).
#
#   docs/export-pdf.sh                         # docs/architecture.md -> docs/architecture.pdf
#   docs/export-pdf.sh README.md out.pdf
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-$ROOT/docs/architecture.md}"
OUT="${2:-${SRC%.md}.pdf}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1 ($2)" >&2; exit 1; }; }
need pandoc "dnf/apt install pandoc"
MMDC="$(command -v mmdc || echo "npx -y @mermaid-js/mermaid-cli")"
CHROME="$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)"
[[ -n "$CHROME" ]] || { echo "missing: chromium/chrome" >&2; exit 1; }
[[ -f "$SRC" ]] || { echo "no such file: $SRC" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# 1. Render mermaid blocks to PNG and rewrite them as image links.
MMDC="$MMDC" python3 - "$SRC" "$WORK" <<'PY'
import sys, re, os, subprocess, shlex
src, work = sys.argv[1], sys.argv[2]
mmdc = shlex.split(os.environ["MMDC"])
text = open(src).read()
n = 0
def repl(m):
    global n
    mmd = os.path.join(work, f"d{n}.mmd")
    png = os.path.join(work, f"d{n}.png")
    open(mmd, "w").write(m.group(1))
    subprocess.run(mmdc + ["-i", mmd, "-o", png, "-b", "white", "-w", "1600"], check=True)
    n += 1
    return f"![]({png})"
text = re.sub(r"```mermaid\n(.*?)```", repl, text, flags=re.S)
open(os.path.join(work, "patched.md"), "w").write(text)
print(f"rendered {n} diagram(s)")
PY

# 2. Markdown -> standalone HTML (images inlined).
cat >"$WORK/style.css" <<'CSS'
body{font-family:system-ui,"Segoe UI",Helvetica,Arial,sans-serif;max-width:46rem;
  margin:2rem auto;line-height:1.55;color:#1f2937}
h1,h2,h3{color:#111827;border-bottom:1px solid #e5e7eb;padding-bottom:.2em}
code{background:#f3f4f6;padding:.1em .35em;border-radius:4px;font-size:.9em}
pre{background:#f8fafc;padding:1rem;border-radius:8px;overflow:auto;border:1px solid #e5e7eb}
pre code{background:none;padding:0}
table{border-collapse:collapse;width:100%;margin:1em 0}
th,td{border:1px solid #d1d5db;padding:.4rem .6rem;text-align:left}
th{background:#f3f4f6}
img{max-width:100%;display:block;margin:1.2em auto}
blockquote{border-left:4px solid #f59e0b;margin:1em 0;padding:.2em 1em;background:#fffbeb;color:#92400e}
CSS

# --embed-resources is newer pandoc; fall back to --self-contained.
EMBED="--embed-resources"
pandoc --help 2>/dev/null | grep -q -- '--embed-resources' || EMBED="--self-contained"
pandoc "$WORK/patched.md" -o "$WORK/doc.html" --standalone $EMBED \
  --css "$WORK/style.css" --metadata title="$(basename "${SRC%.md}")"

# 3. HTML -> PDF (headless chromium).
"$CHROME" --headless --no-sandbox --disable-gpu --no-pdf-header-footer \
  --print-to-pdf="$OUT" "file://$WORK/doc.html" >/dev/null 2>&1 \
  || "$CHROME" --headless=new --no-sandbox --disable-gpu \
       --print-to-pdf="$OUT" "file://$WORK/doc.html" >/dev/null 2>&1

echo "Wrote $OUT"
