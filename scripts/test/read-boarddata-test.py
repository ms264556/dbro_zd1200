#!/usr/bin/env python3
"""Unit test for scripts/container/read-boarddata.py.

Builds sparse disk images carrying board-data records at the two
CONFIG_V54_ZD_PLATFORM bases and checks the reader picks the right one, rejects
a guessed location whose serial is not a number, and falls back to MAC-only.

Usage: ./scripts/test/read-boarddata-test.py
"""

from __future__ import annotations

import struct
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
READER = REPO / "container" / "read-boarddata.py"

SECTOR = 512
RKS_BD_MAGIC = 0x52434B53
AR531X_BD_MAGIC = 0x35333131
BASES = (3920881, 3981601)

failures = []


def check(name: str, ok: bool, detail: str = "") -> None:
    if ok:
        print(f"ok   {name}")
    else:
        print(f"FAIL {name} {detail}")
        failures.append(name)


def rks_sector(serial: bytes, mac1: bytes, mac2: bytes) -> bytes:
    buf = bytearray(SECTOR)
    struct.pack_into("<IHH", buf, 0, RKS_BD_MAGIC, 0, 4)
    buf[0x08:0x08 + len(serial)] = serial
    buf[0x58:0x5E] = mac1
    buf[0x5E:0x64] = mac2
    return bytes(buf)


def ar_sector(mac1: bytes, mac2: bytes) -> bytes:
    buf = bytearray(SECTOR)
    struct.pack_into("<I", buf, 0, AR531X_BD_MAGIC)
    buf[0x66:0x6C] = mac1
    buf[0x6C:0x72] = mac2
    return bytes(buf)


def put(path: Path, base: int, payload: bytes, at: int = 0, header: int = 0) -> None:
    with path.open("r+b") as fh:
        fh.seek(header + base * SECTOR + at)
        fh.write(payload)


def image(tmp: Path, name: str, header: int = 0) -> Path:
    p = tmp / name
    with p.open("wb") as fh:
        fh.truncate(header + (max(BASES) + 0x8000 // SECTOR + 4) * SECTOR)
    return p


def run(p: Path, *extra: str):
    return subprocess.run([sys.executable, str(READER), str(p), *extra],
                          capture_output=True, text=True)


def main() -> int:
    mac1 = bytes.fromhex("f0b052000000")
    mac2 = bytes.fromhex("f0b052000001")
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)

        # platform 1 (ZD1200): read normally.
        p = image(tmp, "p1.img")
        put(p, BASES[0], rks_sector(b"441408000009", mac1, mac2), at=0x8000)
        r = run(p)
        check("platform 1 serial+macs", r.stdout.splitlines() ==
              ["SERIAL=441408000009", "MAC=f0:b0:52:00:00:00", "MAC2=f0:b0:52:00:00:01"],
              repr(r.stdout))

        # platform 0 (ZD3000 guess): the serial is a number, so accept it.
        p = image(tmp, "p0.img")
        put(p, BASES[1], rks_sector(b"398160100001", mac1, mac2), at=0x8000)
        r = run(p)
        check("platform 0 guess accepted when numeric",
              "SERIAL=398160100001" in r.stdout, repr(r.stdout))

        # platform 1 wins when both are present.
        p = image(tmp, "both.img")
        put(p, BASES[0], rks_sector(b"441408000009", mac1, mac2), at=0x8000)
        put(p, BASES[1], rks_sector(b"398160100001", mac1, mac2), at=0x8000)
        r = run(p)
        check("platform 1 preferred", "SERIAL=441408000009" in r.stdout, repr(r.stdout))

        # platform 0 with a non-numeric serial: reject it, produce nothing.
        p = image(tmp, "p0bad.img")
        put(p, BASES[1], rks_sector(b"NOT-A-NUMBER", mac1, mac2), at=0x8000)
        r = run(p, "--allow-empty")
        check("non-numeric guessed serial rejected", r.stdout.strip() == "", repr(r.stdout))

        # platform 0 is ignored when it is not numeric but platform 1 is fine.
        p = image(tmp, "p0bad-p1good.img")
        put(p, BASES[0], rks_sector(b"441408000009", mac1, mac2), at=0x8000)
        put(p, BASES[1], rks_sector(b"NOT-A-NUMBER", mac1, mac2), at=0x8000)
        r = run(p)
        check("falls through to platform 1", "SERIAL=441408000009" in r.stdout, repr(r.stdout))

        # No rks record, but an ar531x one: MACs yes, serial no.
        p = image(tmp, "ar.img")
        put(p, BASES[1], ar_sector(mac1, mac2))
        r = run(p)
        check("ar531x gives macs and no serial",
              r.stdout.splitlines() == ["MAC=f0:b0:52:00:00:00", "MAC2=f0:b0:52:00:00:01"],
              repr(r.stdout))

        # ImageUSB header offset is honoured.
        p = image(tmp, "hdr.img", header=512)
        put(p, BASES[0], rks_sector(b"441408000009", mac1, mac2), at=0x8000, header=512)
        r = run(p, "--offset-bytes", "512")
        check("ImageUSB 512-byte header", "SERIAL=441408000009" in r.stdout, repr(r.stdout))

        # Empty disk: --allow-empty is silent and exits 0.
        p = image(tmp, "empty.img")
        r = run(p, "--allow-empty")
        check("empty disk silent with --allow-empty",
              r.returncode == 0 and r.stdout.strip() == "", repr(r.stdout))

        # A real ZD1200-sized disk ends before the platform-0 base: reading past
        # EOF must be harmless and platform 1 must still be found.
        p = tmp / "small.img"
        with p.open("wb") as fh:
            fh.truncate((BASES[0] + 0x8000 // SECTOR + 4) * SECTOR)
        put(p, BASES[0], rks_sector(b"441408000009", mac1, mac2), at=0x8000)
        r = run(p)
        check("platform-0 base past EOF is harmless",
              "SERIAL=441408000009" in r.stdout, repr(r.stderr or r.stdout))

    if failures:
        print(f"\n{len(failures)} failure(s): {', '.join(failures)}")
        return 1
    print("\nall read-boarddata tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
