#!/usr/bin/env python3
"""Allocate compressible-but-unique anonymous memory, then idle.

Each 4 KiB page gets the same low-entropy body (a zero run plus an incompressible
tail) but a unique 8-byte header. So:

  * every page differs  -> KSM finds no identical pages to merge (dedup gets ~0)
  * the body is low-entropy -> zram compresses each page well

This is the workload where compression beats deduplication: guests whose memory
is similar in shape but not byte-identical (logs, sparse heaps, partially-zeroed
buffers). It is the mirror image of the identical-RHCOS case, where KSM wins.

The pages are touched once and then left cold, so a cgroup memory.high squeeze can
evict them to zram. The process holds the mapping and sleeps until killed.

    memfill.py --mib 2048 [--comp-frac 0.66] [--seconds 0]
    memfill.py --self-check

`--comp-frac` is the fraction of each page that is a zero run (the rest is random,
incompressible): it sets the rough compression ceiling (0.66 -> about 3x).
"""

import argparse
import ctypes
import mmap
import os
import sys
import time
import zlib

PAGE = 4096
MADV_MERGEABLE = 12  # from <linux/mman.h>; tells KSM this region is a merge candidate


def build_template(comp_frac: float) -> bytes:
    """One page body shared by every page: a zero run then an incompressible tail."""
    zlen = max(8, min(PAGE - 8, int(PAGE * comp_frac)))
    return bytes(zlen) + os.urandom(PAGE - zlen)


def madvise_mergeable(mm: mmap.mmap, length: int) -> None:
    """Mark the mapping MADV_MERGEABLE so KSM will actually scan it (else it ignores us)."""
    addr = ctypes.addressof(ctypes.c_char.from_buffer(mm))
    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    rc = libc.madvise(ctypes.c_void_p(addr), ctypes.c_size_t(length), MADV_MERGEABLE)
    if rc != 0:
        err = ctypes.get_errno()
        print(f"warning: madvise(MERGEABLE) failed: {os.strerror(err)}", file=sys.stderr)


def fill(mm: mmap.mmap, npages: int, template: bytes) -> None:
    for p in range(npages):
        base = p * PAGE
        mm[base : base + PAGE] = template  # fast memcpy of the shared body
        mm[base : base + 8] = p.to_bytes(8, "little")  # unique header -> KSM cannot merge


def run(mib: int, comp_frac: float, seconds: int) -> None:
    length = mib * 1024 * 1024
    npages = length // PAGE
    mm = mmap.mmap(-1, length, prot=mmap.PROT_READ | mmap.PROT_WRITE)
    madvise_mergeable(mm, length)
    fill(mm, npages, build_template(comp_frac))
    print(f"memfill: {mib} MiB resident ({npages} unique pages), idling", flush=True)
    if seconds <= 0:
        while True:
            time.sleep(3600)
    else:
        time.sleep(seconds)


def self_check() -> None:
    n = 256
    template = build_template(0.66)
    pages = []
    for p in range(n):
        page = bytearray(template)
        page[0:8] = p.to_bytes(8, "little")
        pages.append(bytes(page))
    assert len(set(pages)) == n, "pages are not unique; KSM would merge them (bad test)"
    # zram compresses each page independently, so measure per-page (not concatenated,
    # which would hide the per-page floor behind cross-page redundancy).
    raw = sum(len(p) for p in pages)
    comp = sum(len(zlib.compress(p, 6)) for p in pages)
    ratio = raw / max(1, comp)
    assert 2.0 < ratio < 20.0, f"per-page ratio {ratio:.1f}x outside the demo's intended range"
    print(f"self-check OK: {n} unique pages, ~{ratio:.1f}x per-page compressible (zlib proxy)")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--mib", type=int, default=2048)
    ap.add_argument("--comp-frac", type=float, default=0.66)
    ap.add_argument("--seconds", type=int, default=0, help="0 = idle until killed")
    ap.add_argument("--self-check", action="store_true")
    args = ap.parse_args()
    if args.self_check:
        self_check()
        return
    if args.mib <= 0:
        ap.error("--mib must be positive")
    if not (0.0 < args.comp_frac < 1.0):
        ap.error("--comp-frac must be between 0 and 1 (exclusive)")
    run(args.mib, args.comp_frac, args.seconds)


if __name__ == "__main__":
    main()
