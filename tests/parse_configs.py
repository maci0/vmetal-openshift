#!/usr/bin/env python3
"""Parse every rendered config YAML under a directory (multi-doc / BMH aware).

    parse_configs.py <dir>

Exits non-zero if any file fails to parse.
"""
import glob
import sys

import yaml

for f in glob.glob(sys.argv[1] + "/*/*.yaml"):
    with open(f) as fh:
        list(yaml.safe_load_all(fh))
