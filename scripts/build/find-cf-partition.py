#!/usr/bin/env python3
"""Find the CompactFlash data partition in a raw dump.

Scans for the vendor partition table -- an MBR-style sector ending in 0x55AA
whose entries describe the appliance layout -- and prints "START COUNT" (in
512-byte sectors) for the /writable partition (the Linux-type entry),
validated by the reiserfs superblock magic at its 64 KiB mark.  Works for both
the ZD1200 layout and foreign ones (e.g. a ZD1100 card) without assuming a
particular disk size.

Usage: find-cf-partition.py <dump> [header_offset_bytes]
"""

from __future__ import annotations

import mmap
import struct
import sys

SECTOR = 512
REISER_MAGIC_OFFSET = 0x10000 + 0x34   # superblock + magic field
LINUX_TYPES = (0x83, 0x82, 0x05, 0x0B)


def entries_at(mm: mmap.mmap, sector_start: int, total: int):
    ent = sector_start + 0x1BE
    if ent + 64 > total:
        return None
    out = []
    for k in range(4):
        e = ent + k * 16
        out.append((mm[e + 4],
                    struct.unpack_from("<I", mm, e + 8)[0],
                    struct.unpack_from("<I", mm, e + 12)[0]))
    return out


def main() -> int:
    if len(sys.argv) < 2:
        sys.exit(__doc__.splitlines()[0] + " -- usage: find-cf-partition.py <dump> [offset]")
    path = sys.argv[1]
    offset = int(sys.argv[2]) if len(sys.argv) > 2 else 0

    with open(path, "rb") as fh:
        mm = mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ)
        total = len(mm)
        sectors = total // SECTOR
        candidates = []
        pos = 0x1FE
        while True:
            i = mm.find(b"\x55\xaa", pos)
            if i < 0:
                break
            start = i - 0x1FE
            if start >= 0:
                ents = entries_at(mm, start, total)
                if ents:
                    good = sum(1 for t, s, c in ents
                               if t in LINUX_TYPES and 0 < s < sectors and 0 < c < sectors)
                    if good >= 3:
                        # /writable is the last Linux entry; validate reiserfs.
                        for t, s, c in reversed(ents):
                            if t not in LINUX_TYPES or not (0 < s < sectors and 0 < c < sectors):
                                continue
                            magic = s * SECTOR + offset + REISER_MAGIC_OFFSET
                            ok = (0 <= magic < total - 9
                                  and mm[magic:magic + 9] == b"ReIsEr2Fs")
                            candidates.append((ok, s, c))
                            break
            pos = i + 1
        mm.close()

    if not candidates:
        sys.exit("find-cf-partition: no vendor partition table found")
    candidates.sort(key=lambda t: not t[0])       # prefer a reiserfs-validated hit
    _, start, count = candidates[0]
    print(f"{start} {count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
