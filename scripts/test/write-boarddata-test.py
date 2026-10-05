#!/usr/bin/env python3
"""Unit test for the input checks of scripts/container/write-boarddata.py.

The writer stamps the guest's serial and MACs into the disk's board-data records.
A MAC or serial the guest cannot use must be refused before anything is written:
a multicast MAC is rejected by the guest's NIC driver, and a serial the reader
rejects makes the whole record be discarded on the next read.  Each refusal here
is checked against a sparse disk that must stay untouched, and an accepted value
is read back with read-boarddata.py so the checks are not vacuous.

Usage: ./scripts/test/write-boarddata-test.py
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WRITER = REPO / "container" / "write-boarddata.py"
READER = REPO / "container" / "read-boarddata.py"

SECTOR = 512
REGION2_START = 3920881          # the ZD1200 platform's board-data base (sector)
DISK_SECTORS = REGION2_START + 0x8000 // SECTOR + 64

failures = []


def check(name: str, ok: bool, detail: str = "") -> None:
    if ok:
        print(f"ok   {name}")
    else:
        print(f"FAIL {name} {detail}")
        failures.append(name)


def blank_disk(directory: Path, name: str) -> Path:
    path = directory / name
    with path.open("wb") as fh:
        fh.truncate(DISK_SECTORS * SECTOR)
    return path


def untouched(path: Path) -> bool:
    """A sparse file nothing was written to has no allocated blocks."""
    return os.stat(path).st_blocks == 0


def write(disk: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(WRITER), "--disk", str(disk), *args],
                          capture_output=True, text=True)


def read(disk: Path) -> dict:
    out = subprocess.run([sys.executable, str(READER), str(disk)],
                         capture_output=True, text=True).stdout
    return dict(line.split("=", 1) for line in out.splitlines() if "=" in line)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="zd-wbd.") as t:
        tmp = Path(t)

        # --- MACs that must be refused ----------------------------------------
        bad_macs = {
            "multicast": "01:00:5e:00:00:01",
            "broadcast": "ff:ff:ff:ff:ff:ff",
            "multicast low bit, uppercase": "03:AA:BB:CC:DD:EE",
            "too short": "00:0c:e6:12:00",
            "too long": "00:0c:e6:12:00:01:02",
            "no separators": "000ce6120001",
            "dash separated": "00-0c-e6-12-00-01",
            "0x prefix": "0x:0c:e6:12:00:01",
            "octet above ff": "00:0c:e6:12:00:1ff",
            "non-hex": "00:0c:e6:12:00:zz",
        }
        for label, mac in bad_macs.items():
            disk = blank_disk(tmp, "mac.img")
            r = write(disk, "--mac", mac)
            check(f"refuses a {label} MAC", r.returncode != 0 and "bad MAC" in r.stderr,
                  f"rc={r.returncode} {r.stderr.strip()!r}")
            check(f"writes nothing for a {label} MAC", untouched(disk))

        # --- serials that must be refused -------------------------------------
        bad_serials = {
            "too short": "1234",
            "16 digits (the field holds 15)": "1234567890123456",
            "letters": "12a45678",
            "empty": "",
            "unicode digits": "١٢٣٤٥٦",
        }
        for label, serial in bad_serials.items():
            disk = blank_disk(tmp, "serial.img")
            r = write(disk, "--serial", serial, "--mac", "02:11:22:33:44:56")
            check(f"refuses a serial that is {label}",
                  r.returncode != 0 and "bad serial" in r.stderr,
                  f"rc={r.returncode} {r.stderr.strip()!r}")
            check(f"writes nothing for a serial that is {label}", untouched(disk))

        # --- the disk must exist ----------------------------------------------
        r = write(tmp / "no-such.img", "--mac", "02:11:22:33:44:56")
        check("refuses a disk that does not exist",
              r.returncode != 0 and "not found" in r.stderr, r.stderr.strip())

        # --- an accepted MAC and serial round-trip ----------------------------
        disk = blank_disk(tmp, "good.img")
        r = write(disk, "--serial", "441408000009", "--mac", "02:11:22:33:44:56")
        check("accepts a unicast MAC and a 12-digit serial", r.returncode == 0, r.stderr.strip())
        got = read(disk)
        check("the serial reads back", got.get("SERIAL") == "441408000009", repr(got))
        check("MAC1 reads back", got.get("MAC1", got.get("MAC", "")).lower() == "02:11:22:33:44:56",
              repr(got))

        # An odd last octet is a valid MAC: the board data carries whatever the
        # appliance was given (MAC2 is MAC1 + 1 and carries over 0xff).
        disk = blank_disk(tmp, "odd.img")
        r = write(disk, "--serial", "441408000009", "--mac", "bc:24:11:aa:bb:ff")
        check("accepts an odd last octet, as Proxmox assigns", r.returncode == 0, r.stderr.strip())
        got = read(disk)
        check("an odd MAC1 reads back as given",
              got.get("MAC1", got.get("MAC", "")).lower() == "bc:24:11:aa:bb:ff", repr(got))

        # --mac-only keeps the serial and refuses a disk with no record to edit.
        r = write(disk, "--mac-only", "--mac", "02:99:88:77:66:54")
        got = read(disk)
        check("--mac-only rewrites the MAC and keeps the serial",
              r.returncode == 0 and got.get("SERIAL") == "441408000009"
              and got.get("MAC1", got.get("MAC", "")).lower() == "02:99:88:77:66:54",
              f"{r.stderr.strip()!r} {got!r}")
        disk = blank_disk(tmp, "empty.img")
        r = write(disk, "--mac-only", "--mac", "02:99:88:77:66:54")
        check("--mac-only refuses a disk with no board data and writes nothing",
              r.returncode != 0 and "refusing to write" in r.stderr and untouched(disk),
              f"rc={r.returncode} {r.stderr.strip()!r}")

    if failures:
        print(f"\n{len(failures)} failure(s): {', '.join(failures)}")
        return 1
    print("\nall write-boarddata tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
