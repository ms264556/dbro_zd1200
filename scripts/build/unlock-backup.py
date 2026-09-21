#!/usr/bin/env python3
"""Rewrite a ZoneDirector configuration backup so it restores on any model.

Ruckus only allows a backup to move from a smaller ZoneDirector to a larger one,
so a ZD3000 (or ZD5000) backup will not restore onto a ZD1100/ZD1200.  The
vendor decides this from the backup's ``metadata``: it reads ``PLATFORM`` and
``APMODEL``.  Rewriting ``PLATFORM`` to the ZD1100/ZD1200 value ``ar7161`` and
dropping ``APMODEL`` makes the backup acceptable on any ZoneDirector, which is
what lets a dead ZD3000's configuration be revived on a ZD1200 appliance.

The release is left alone: the backup must still match the firmware it is
restored onto, and the guest's vendor ``verify-backup`` re-checks that.

Input may be a TAC-encrypted ``ruckus_db_*.bak`` (as downloaded from the Web UI)
or an already-decrypted ``*.tgz``.  Output is always TAC-encrypted, so the
guest's normal ``verify-backup`` path handles it.

Usage:
    unlock-backup.py <ruckus_db_*.bak|*.tgz> <output .bak>
"""

from __future__ import annotations

import argparse
import gzip
import importlib.util
import os
import sys
import tarfile
import tempfile
from io import BytesIO
from pathlib import Path


TARGET_PLATFORM = "ar7161"
METADATA_MEMBER = "metadata"


def _load_tac(name: str):
    path = Path(__file__).with_name(name)
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def decode(source: bytes) -> bytes:
    """Return the gzip-TAR payload, decrypting a TAC container if needed."""
    if source[:2] == b"\x1f\x8b":
        return source
    return _load_tac("tac-decrypt.py").decrypt_bytes(source)


def patch_metadata(data: bytes) -> bytes:
    """Set PLATFORM=ar7161 and remove APMODEL, preserving every other line."""
    lines: list[str] = []
    seen_platform = False
    for raw in data.decode("utf-8", "surrogateescape").splitlines():
        if raw.startswith("PLATFORM="):
            lines.append(f"PLATFORM={TARGET_PLATFORM}")
            seen_platform = True
        elif raw.startswith("APMODEL"):
            continue
        else:
            lines.append(raw)
    if not seen_platform:
        lines.append(f"PLATFORM={TARGET_PLATFORM}")
    return ("\n".join(lines) + "\n").encode("utf-8", "surrogateescape")


def rewrite(payload: bytes) -> bytes:
    """Rebuild the gzip-TAR with a platform-unlocked metadata member."""
    with tarfile.open(fileobj=BytesIO(payload), mode="r:gz") as source:
        members = source.getmembers()
        if not any(member.name == METADATA_MEMBER for member in members):
            raise ValueError(f"the backup has no {METADATA_MEMBER} member")

        tar_buffer = BytesIO()
        with tarfile.open(fileobj=tar_buffer, mode="w", format=tarfile.GNU_FORMAT) as destination:
            for member in members:
                if member.name == METADATA_MEMBER:
                    body = source.extractfile(member)
                    if body is None:
                        raise ValueError(f"the backup's {METADATA_MEMBER} is not a file")
                    rewritten = patch_metadata(body.read())
                    member.size = len(rewritten)
                    destination.addfile(member, BytesIO(rewritten))
                elif member.isfile():
                    destination.addfile(member, source.extractfile(member))
                else:
                    destination.addfile(member)

    # mtime=0 keeps the output byte-for-byte reproducible, so a rebuilt disk is
    # not seen as having a changed backup.
    return gzip.compress(tar_buffer.getvalue(), mtime=0)


def unlock(source_path: Path, destination_path: Path) -> None:
    payload = rewrite(decode(source_path.read_bytes()))
    encrypted = _load_tac("tac-encrypt.py").encrypt_bytes(payload)
    destination_path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination_path.name}.", suffix=".tmp", dir=destination_path.parent
    )
    try:
        with os.fdopen(descriptor, "wb") as destination:
            destination.write(encrypted)
            destination.flush()
            os.fsync(destination.fileno())
        os.replace(temporary_name, destination_path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="ZD configuration backup (.bak or decrypted .tgz)")
    parser.add_argument("destination", type=Path, help="platform-unlocked TAC-format output")
    args = parser.parse_args()
    try:
        unlock(args.source, args.destination)
    except (OSError, ValueError, tarfile.TarError) as error:
        sys.exit(f"unlock-backup: {error}")
    print(f"unlocked {args.source.name} for any ZoneDirector -> {args.destination} "
          f"(PLATFORM={TARGET_PLATFORM}, APMODEL dropped)")


if __name__ == "__main__":
    main()
