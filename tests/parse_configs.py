#!/usr/bin/env python3
"""Parse every rendered config YAML under a directory (multi-doc / BMH aware).

    parse_configs.py <dir>

Exits non-zero if any file fails to parse.
"""
import glob
import sys

import yaml

if len(sys.argv) < 2:
    sys.exit(f"usage: {sys.argv[0]} <dir>")

files = glob.glob(sys.argv[1] + "/*/*.yaml")
if not files:
    sys.exit(f"no rendered config YAML under {sys.argv[1]} (did the render produce nothing?)")
for f in files:
    with open(f, encoding="utf-8") as fh:
        list(yaml.safe_load_all(fh))
