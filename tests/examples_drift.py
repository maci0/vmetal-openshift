#!/usr/bin/env python3
"""Assert every concrete code block in docs/examples.md still appears verbatim in
freshly generated (and redacted) config output.

    examples_drift.py <examples.md> <corpus.txt>

Blocks that are illustrative (rendered XML, or containing a "..." elision) are
skipped. Exits non-zero on drift.
"""
import re
import sys


def contiguous(needle, hay):
    n = [ln.rstrip() for ln in needle.splitlines() if ln.strip() != ""]
    h = [ln for ln in hay if ln.strip() != ""]
    if not n:
        return True
    for i in range(len(h) - len(n) + 1):
        if h[i:i + len(n)] == n:
            return True
    return False


def illustrative(b):
    if b.lstrip().startswith("<"):           # rendered XML is reformatted in docs
        return True
    if "# ..." in b:                         # explicit elision comment
        return True
    if re.search(r"(?m)^\s*\.\.\.\s*$", b):  # a bare "..." line
        return True
    return False


def main():
    with open(sys.argv[1]) as fh:
        doc = fh.read()
    with open(sys.argv[2]) as fh:
        corpus_lines = [ln.rstrip() for ln in fh.read().splitlines()]

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


if __name__ == "__main__":
    main()
