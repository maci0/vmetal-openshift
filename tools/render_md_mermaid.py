#!/usr/bin/env python3
"""Render the ```mermaid``` blocks of a Markdown file to PNGs and rewrite them as
image links, writing patched.md into the work dir.

    render_md_mermaid.py <src.md> <work_dir>

The mermaid CLI command is taken from the MMDC environment variable.
"""

import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

MERMAID_BLOCK = re.compile(r"```mermaid\n(.*?)```", re.S)
RENDER_WIDTH = "1600"
RENDER_TIMEOUT_S = 120


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(f"usage: {sys.argv[0]} <src.md> <work_dir>")
    src, work = Path(sys.argv[1]), Path(sys.argv[2])
    mmdc_env = os.environ.get("MMDC")
    if not mmdc_env:
        sys.exit("MMDC env var must be set to the mermaid-cli command")
    mmdc = shlex.split(mmdc_env)

    rendered = 0

    def repl(m: re.Match[str]) -> str:
        nonlocal rendered
        mmd = work / f"d{rendered}.mmd"
        png = work / f"d{rendered}.png"
        mmd.write_text(m.group(1), encoding="utf-8")
        # mermaid-cli is a Node CLI: no in-process API to call instead.
        subprocess.run(
            [*mmdc, "-i", str(mmd), "-o", str(png), "-b", "white", "-w", RENDER_WIDTH],
            check=True,
            timeout=RENDER_TIMEOUT_S,
        )
        rendered += 1
        return f"![]({png})"

    text = MERMAID_BLOCK.sub(repl, src.read_text(encoding="utf-8"))
    (work / "patched.md").write_text(text, encoding="utf-8")
    print(f"rendered {rendered} diagram(s)")


if __name__ == "__main__":
    main()
