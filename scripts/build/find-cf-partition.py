#!/usr/bin/env python3
"""Find partitions in a raw ZD1200-family card dump.

Scans for the vendor partition table -- an MBR-style sector ending in 0x55AA
whose entries describe the appliance layout.  Works for both the ZD1200 layout
and foreign ones (e.g. a ZD1100 card) without assuming a particular disk size.

By default it prints "START COUNT" (in 512-byte sectors) for the /writable
partition (the last Linux-type entry), validated by the reiserfs superblock
magic at its 64 KiB mark.

With --roots it prints the root filesystems instead: the two ext2 Linux-type
entries other than /writable, in table order.  The vendor's card layout is
/boot, root A, root B, /writable, so those are the dump's own rootfs images
(the /boot entry holds GRUB and the kernel, not a rootfs).

Usage: find-cf-partition.py [--roots] <dump> [header_offset_bytes]
"""

from __future__ import annotations

import mmap
import struct
import sys

SECTOR = 512
REISER_MAGIC_OFFSET = 0x10000 + 0x34   # superblock + magic field
EXT2_MAGIC_OFFSET = 1024 + 0x38        # superblock (1024) + s_magic field
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


def linux_entries(ents, sectors):
    return [(t, s, c) for t, s, c in ents
            if t in LINUX_TYPES and 0 < s < sectors and 0 < c < sectors]


def magic_ok(mm: mmap.mmap, total: int, start: int, offset: int,
             magic_offset: int, magic: bytes) -> bool:
    at = start * SECTOR + offset + magic_offset
    return 0 <= at < total - len(magic) and mm[at:at + len(magic)] == magic


def main() -> int:
    args = sys.argv[1:]
    want_roots = False
    if args and args[0] == "--roots":
        want_roots = True
        args = args[1:]
    if not args:
        sys.exit(__doc__.splitlines()[0] + " -- usage: find-cf-partition.py [--roots] <dump> [offset]")
    path = args[0]
    offset = int(args[1]) if len(args) > 1 else 0

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
                if ents and len(linux_entries(ents, sectors)) >= 3:
                    if want_roots:
                        # The roots are the last two ext2 filesystems that are
                        # not /writable.  The /boot entry is ext2 on the ZD1200
                        # but holds no rootfs, so it must not be mistaken for
                        # one; /writable is excluded by identity (the last
                        # Linux entry), not by position, so the /boot entry --
                        # which precedes it -- is not a candidate either.
                        lents = linux_entries(ents, sectors)
                        writable = (lents[-1][1], lents[-1][2]) if lents else None
                        roots = [(s, c) for _, s, c in lents
                                 if (s, c) != writable
                                 and magic_ok(mm, total, s, offset,
                                              EXT2_MAGIC_OFFSET, b"\x53\xef")][-2:]
                        if roots:
                            candidates.append((True, roots))
                    else:
                        # /writable is the last Linux entry; validate reiserfs.
                        for t, s, c in reversed(ents):
                            if t not in LINUX_TYPES or not (0 < s < sectors and 0 < c < sectors):
                                continue
                            ok = magic_ok(mm, total, s, offset,
                                          REISER_MAGIC_OFFSET, b"ReIsEr2Fs")
                            candidates.append((ok, (s, c)))
                            break
            pos = i + 1
        mm.close()

    if not candidates:
        sys.exit("find-cf-partition: no vendor partition table found")
    candidates.sort(key=lambda t: not t[0])       # prefer a validated hit
    selected = candidates[0][1]
    if want_roots:
        sys.stdout.write("".join(f"{s} {c}\n" for s, c in selected))
    else:
        print(f"{selected[0]} {selected[1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
