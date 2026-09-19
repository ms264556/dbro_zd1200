#!/usr/bin/env python3
"""Read the appliance board-data records (serial + MACs) back from a CF disk.

The board data is authoritative.  A ZD1200 lets the operator change the
appliance MAC in the web UI, and the firmware writes the new value into the
board-data record on the CF.  On every container start the entrypoint reads it
here and hands it to the macvtap, the QEMU NIC and the DHCP sniffer, so a MAC
changed inside the guest is honoured on the next start.

Two layouts are tried, newest first (both come from the shared v54bsp BSP in the
ZD1200 kernel tree, drivers/v54bsp/nar5520_bsp.c):

    REGION2_START 3920881   CONFIG_V54_ZD_PLATFORM == 1   (the ZD1200 layout)
    REGION2_START 3981601   CONFIG_V54_ZD_PLATFORM == 0   (the ZD3000 family)

Each carries `rks_boarddata` at +0x8000 (magic "SKCR") and `ar531x_boarddata` at
+0.  Only the ZD1200 layout is confirmed against a dump; the second is a
best-effort guess for a foreign card (a ZD3000/ZD1100 dump), so its serial is
only accepted when it really looks like one: all digits.  When neither record
yields a usable serial the caller falls back to a MAC-derived one.

Prints source-able KEY=VALUE lines: SERIAL, MAC, MAC2.
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

SECTOR = 512
# CONFIG_V54_ZD_PLATFORM values from drivers/v54bsp/nar5520_bsp.c.
REGION2_BASES = (
    3920881,   # platform 1 -- the ZD1200 (confirmed against a dump)
    3981601,   # platform 0 -- the ZD3000 family (best-effort guess)
)
RKS_BD_OFFSET = 0x8000           # rks_boarddata sits RKS_BD_OFFSET into region2
RKS_BD_MAGIC = 0x52434B53        # "SKCR"
AR531X_BD_MAGIC = 0x35333131     # "1135"

RKS_SERIAL = 0x08
RKS_SERIAL32 = 0x9C
RKS_MAC1 = 0x58
RKS_MAC2 = 0x5E
AR_MAC1 = 0x66
AR_MAC2 = 0x6C


def read_sector(disk: Path, sector: int, offset: int = 0) -> bytes:
    if sector < 0:
        return b""
    with disk.open("rb") as fh:
        fh.seek(offset + sector * SECTOR)
        return fh.read(SECTOR)


def mac_at(buf: bytes, offset: int):
    mac = buf[offset:offset + 6]
    if len(mac) != 6 or mac == b"\x00" * 6 or mac == b"\xff" * 6:
        return None
    return ":".join(f"{b:02x}" for b in mac)


def serial_field(buf: bytes, offset: int, size: int) -> str:
    return buf[offset:offset + size].split(b"\x00")[0].decode("ascii", "replace")


def valid_serial(text: str) -> bool:
    """A real serial is a plain number ("5" + 11 digits on a ZD1200)."""
    return 5 <= len(text) <= 20 and text.isdigit()


def rks_record(disk: Path, base: int, offset: int):
    """The usable (serial, mac1, mac2) of an rks_boarddata record, or None."""
    rks = read_sector(disk, base + RKS_BD_OFFSET // SECTOR, offset)
    if len(rks) != SECTOR or struct.unpack_from("<I", rks, 0)[0] != RKS_BD_MAGIC:
        return None
    serial = serial_field(rks, RKS_SERIAL, 16)
    if not valid_serial(serial):
        serial = serial_field(rks, RKS_SERIAL32, 32)
    if not valid_serial(serial):
        # A record whose serial is not a number is not a record we understand
        # (most likely the guessed base is wrong); do not trust its MACs either.
        return None
    return serial, mac_at(rks, RKS_MAC1), mac_at(rks, RKS_MAC2)


def ar_macs(disk: Path, base: int, offset: int):
    ar = read_sector(disk, base, offset)
    if len(ar) != SECTOR or struct.unpack_from("<I", ar, 0)[0] != AR531X_BD_MAGIC:
        return None, None
    return mac_at(ar, AR_MAC1), mac_at(ar, AR_MAC2)


def read_board_data(disk: Path, offset: int = 0) -> dict:
    out = {}
    for base in REGION2_BASES:
        record = rks_record(disk, base, offset)
        if record:
            serial, mac1, mac2 = record
            out["SERIAL"] = serial
            if mac1:
                out["MAC"] = mac1
            if mac2:
                out["MAC2"] = mac2
            return out
        mac1, mac2 = ar_macs(disk, base, offset)
        if mac1:
            out["MAC"] = mac1
        if mac2:
            out["MAC2"] = mac2
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("disk", type=Path, help="guest disk image (raw CF)")
    ap.add_argument("--offset-bytes", type=int, default=0,
                    help="skip this many bytes first (e.g. 512 for an ImageUSB dump)")
    ap.add_argument("--allow-empty", action="store_true",
                    help="exit 0 even when no board-data record with a MAC is found")
    args = ap.parse_args()
    if not args.disk.exists():
        sys.exit(f"read-boarddata: disk not found: {args.disk}")
    data = read_board_data(args.disk, offset=args.offset_bytes)
    if "MAC" not in data and not args.allow_empty:
        sys.exit("read-boarddata: no valid board-data record with a MAC found")
    for key in ("SERIAL", "MAC", "MAC2"):
        if key in data:
            print(f"{key}={data[key]}")


if __name__ == "__main__":
    main()
