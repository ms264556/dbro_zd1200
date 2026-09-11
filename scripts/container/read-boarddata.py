#!/usr/bin/env python3
"""Read the ZD1200 board-data records (serial + MACs) back from the guest disk.

The board data is authoritative.  A ZD1200 lets the operator change the
appliance MAC in the web UI, and the firmware writes the new value into the
board-data record on the CF.  On every container start the entrypoint reads it
here and hands it to the macvtap, the QEMU NIC and the DHCP sniffer, so a MAC
changed inside the guest is honoured on the next start.

Reads the `rks_boarddata` record (falling back to `ar531x_boarddata`) from the
raw synthetic CF disk.  Offsets match
write-boarddata.py.

Prints source-able KEY=VALUE lines: SERIAL, MAC, MAC2.
"""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path

SECTOR = 512
REGION2_START = 3920881          # CONFIG_V54_ZD_PLATFORM == 1 (ZD1200)
RKS_BD_OFFSET = 0x8000           # rks_boarddata sits RKS_BD_OFFSET into region2
RKS_BD_MAGIC = 0x52434B53        # "SKCR"
AR531X_BD_MAGIC = 0x35333131     # "1135"

RKS_SERIAL = 0x08
RKS_MAC1 = 0x58
RKS_MAC2 = 0x5E
AR_MAC1 = 0x66
AR_MAC2 = 0x6C


def read_sector(disk: Path, sector: int) -> bytes:
    with disk.open("rb") as fh:
        fh.seek(sector * SECTOR)
        return fh.read(SECTOR)


def mac_at(buf: bytes, offset: int):
    mac = buf[offset:offset + 6]
    if len(mac) != 6 or mac == b"\x00" * 6 or mac == b"\xff" * 6:
        return None
    return ":".join(f"{b:02x}" for b in mac)


def read_board_data(disk: Path) -> dict:
    rks = read_sector(disk, REGION2_START + RKS_BD_OFFSET // SECTOR)
    out = {}
    if len(rks) == SECTOR and struct.unpack_from("<I", rks, 0)[0] == RKS_BD_MAGIC:
        serial = rks[RKS_SERIAL:RKS_SERIAL + 16].split(b"\x00")[0].decode("ascii", "replace")
        if serial:
            out["SERIAL"] = serial
        if (mac := mac_at(rks, RKS_MAC1)):
            out["MAC"] = mac
        if (mac := mac_at(rks, RKS_MAC2)):
            out["MAC2"] = mac
    if "MAC" not in out:
        ar = read_sector(disk, REGION2_START)
        if len(ar) == SECTOR and struct.unpack_from("<I", ar, 0)[0] == AR531X_BD_MAGIC:
            if (mac := mac_at(ar, AR_MAC1)):
                out["MAC"] = mac
            if (mac := mac_at(ar, AR_MAC2)):
                out["MAC2"] = mac
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("disk", type=Path, help="guest disk image (raw CF)")
    args = ap.parse_args()
    if not args.disk.exists():
        sys.exit(f"read-boarddata: disk not found: {args.disk}")
    data = read_board_data(args.disk)
    if "MAC" not in data:
        sys.exit("read-boarddata: no valid board-data record with a MAC found")
    for key in ("SERIAL", "MAC", "MAC2"):
        if key in data:
            print(f"{key}={data[key]}")


if __name__ == "__main__":
    main()
