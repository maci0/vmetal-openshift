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

src, work = sys.argv[1], sys.argv[2]
mmdc = shlex.split(os.environ["MMDC"])
with open(src) as fh:
    text = fh.read()

n = 0


def repl(m):
    global n
    mmd = os.path.join(work, f"d{n}.mmd")
    png = os.path.join(work, f"d{n}.png")
    with open(mmd, "w") as fh:
        fh.write(m.group(1))
    subprocess.run(mmdc + ["-i", mmd, "-o", png, "-b", "white", "-w", "1600"], check=True)
    n += 1
    return f"![]({png})"


text = re.sub(r"```mermaid\n(.*?)```", repl, text, flags=re.S)
with open(os.path.join(work, "patched.md"), "w") as fh:
    fh.write(text)
print(f"rendered {n} diagram(s)")
