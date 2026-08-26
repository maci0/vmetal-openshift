#!/usr/bin/env python3
"""Parse every rendered config YAML under a directory (multi-doc / BMH aware).

    parse_configs.py <dir>

Exits non-zero if any file fails to parse.
"""

import sys
from pathlib import Path

import yaml


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(f"usage: {sys.argv[0]} <dir>")
    root = Path(sys.argv[1])
    files = sorted(root.glob("*/*.yaml"))
    if not files:
        sys.exit(f"no rendered config YAML under {root} (did the render produce nothing?)")
    for f in files:
        with f.open(encoding="utf-8") as fh:
            list(yaml.safe_load_all(fh))


if __name__ == "__main__":
    main()
