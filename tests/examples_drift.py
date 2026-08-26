#!/usr/bin/env python3
"""Assert every concrete code block in docs/examples.md still appears verbatim in
freshly generated (and redacted) config output.

    examples_drift.py <examples.md> <corpus.txt>

Blocks that are illustrative (rendered XML, or containing a "..." elision) are
skipped. Exits non-zero on drift.
"""

import re
import sys

BARE_ELLIPSIS = re.compile(r"(?m)^\s*\.\.\.\s*$")
CODE_BLOCK = re.compile(r"```[A-Za-z0-9]*\n(.*?)```", re.S)


def contiguous(needle: str, hay: list[str]) -> bool:
    """True when needle's non-blank lines appear as a run in hay."""
    n = [ln.rstrip() for ln in needle.splitlines() if ln.strip() != ""]
    h = [ln for ln in hay if ln.strip() != ""]
    if not n:
        return True
    return any(h[i : i + len(n)] == n for i in range(len(h) - len(n) + 1))


def illustrative(block: str) -> bool:
    """True for doc blocks that are not meant to match generated output verbatim."""
    return (
        block.lstrip().startswith("<")  # rendered XML is reformatted in docs
        or "# ..." in block  # explicit elision comment
        or BARE_ELLIPSIS.search(block) is not None
    )


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(f"usage: {sys.argv[0]} <examples.md> <corpus.txt>")
    with open(sys.argv[1], encoding="utf-8") as fh:
        doc = fh.read()
    with open(sys.argv[2], encoding="utf-8") as fh:
        corpus_lines = [ln.rstrip() for ln in fh.read().splitlines()]

    checked = skipped = 0
    missing: list[str] = []
    for block in CODE_BLOCK.findall(doc):
        if illustrative(block):
            skipped += 1
            continue
        checked += 1
        if not contiguous(block, corpus_lines):
            missing.append(block.splitlines()[0] if block.strip() else "(empty)")

    print(f"checked {checked} block(s), skipped {skipped} illustrative")
    if missing:
        print("DRIFT: these doc blocks no longer match generated output:")
        for m in missing:
            print("  starts:", m)
        sys.exit(1)
    print("examples in sync with templates")


if __name__ == "__main__":
    main()
