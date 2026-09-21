#!/usr/bin/env python3
"""Unit test for scripts/build/tac-encrypt.py and scripts/build/unlock-backup.py.

Checks that tac-encrypt is the exact inverse of tac-decrypt at every length
(including the word-aligned edge the TAC padding byte exists for), that
unlock-backup rewrites a foreign backup's metadata to PLATFORM=ar7161 with
APMODEL dropped while leaving the release and the rest of the archive alone, and
that its output stays TAC so the guest's verify-backup can still read it.

Usage: ./scripts/test/unlock-backup-test.py
"""

from __future__ import annotations

import gzip
import importlib.util
import os
import subprocess
import sys
import tarfile
from io import BytesIO
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BUILD = REPO / "scripts" / "build"

failures = []


def check(name: str, ok: bool, detail: str = "") -> None:
    if ok:
        print(f"ok   {name}")
    else:
        print(f"FAIL {name} {detail}")
        failures.append(name)


def load(name: str):
    path = BUILD / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


decrypt = load("tac-decrypt.py")
encrypt = load("tac-encrypt.py")


def tac_roundtrip(tmp: Path) -> None:
    # 0, a full word, another full word, and every partial-word tail.  The
    # word-aligned cases exercise the full padding block (pad byte 0x88).
    # decrypt_file is the interface that strips TAC padding; decrypt_bytes keeps
    # it, so the round trip must go through files.
    for length in (0, 1, 7, 8, 9, 15, 16, 17, 64, 1000):
        payload = bytes((i * 7 + 3) & 0xFF for i in range(length))
        encrypted_path = tmp / f"roundtrip-{length}.tac"
        decrypted_path = tmp / f"roundtrip-{length}.out"
        encrypted_path.write_bytes(encrypt.encrypt_bytes(payload))
        decrypt.decrypt_file(encrypted_path, decrypted_path)
        check(f"tac round-trip length {length}",
              decrypted_path.read_bytes() == payload,
              "decrypt(encrypt(x)) != x")


def make_backup(metadata: str) -> bytes:
    """A minimal TAC backup: metadata plus one configuration file."""
    buffer = BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.GNU_FORMAT) as tar:
        info = tarfile.TarInfo("metadata")
        body = metadata.encode()
        info.size = len(body)
        tar.addfile(info, BytesIO(body))
        info = tarfile.TarInfo("etc/airespider/system.xml")
        body = b"<mgmt-ip ip=\"10.0.0.9\"/>"
        info.size = len(body)
        tar.addfile(info, BytesIO(body))
    return encrypt.encrypt_bytes(gzip.compress(buffer.getvalue(), mtime=0))


def unlock_case(tmp: Path) -> None:
    source = tmp / "ruckus_db_zd3000.bak"
    output = tmp / "unlocked.bak"
    source.write_bytes(make_backup(
        "PURPOSE=backup\nVERSION=10.5.1.0\nBUILD=240\n"
        "PLATFORM=NAR5520\nAPMODEL=ZD3000\n"
    ))
    result = subprocess.run(
        [sys.executable, str(BUILD / "unlock-backup.py"), str(source), str(output)],
        capture_output=True, text=True,
    )
    check("unlock exits 0", result.returncode == 0, result.stderr.strip())
    if result.returncode != 0:
        return

    raw = output.read_bytes()
    check("unlock output is TAC", raw.startswith(b"\x36\x91\x4a"))
    payload = decrypt.decrypt_bytes(raw)
    with tarfile.open(fileobj=BytesIO(payload), mode="r:gz") as tar:
        metadata = tar.extractfile("metadata").read().decode()
        system = tar.extractfile("etc/airespider/system.xml")
        system_body = system.read() if system else b""

    check("PLATFORM rewritten to ar7161", "PLATFORM=ar7161" in metadata, metadata)
    check("APMODEL dropped", "APMODEL" not in metadata, metadata)
    check("VERSION untouched", "VERSION=10.5.1.0" in metadata, metadata)
    check("PURPOSE untouched", "PURPOSE=backup" in metadata, metadata)
    check("other members preserved", system_body.startswith(b"<mgmt-ip"), repr(system_body))

    # A decrypted gzip tar (the *.tgz an operator may hold) takes the same path.
    plain = tmp / "ruckus_db_zd3000.tgz"
    plain.write_bytes(payload)
    plain_out = tmp / "unlocked-from-tgz.bak"
    result = subprocess.run(
        [sys.executable, str(BUILD / "unlock-backup.py"), str(plain), str(plain_out)],
        capture_output=True, text=True,
    )
    check("unlock accepts a decrypted tgz",
          result.returncode == 0 and plain_out.read_bytes() == raw, result.stderr.strip())


def missing_metadata_case(tmp: Path) -> None:
    buffer = BytesIO()
    with tarfile.open(fileobj=buffer, mode="w", format=tarfile.GNU_FORMAT) as tar:
        info = tarfile.TarInfo("other.txt")
        info.size = 1
        tar.addfile(info, BytesIO(b"x"))
    source = tmp / "no-metadata.bak"
    source.write_bytes(encrypt.encrypt_bytes(gzip.compress(buffer.getvalue(), mtime=0)))
    result = subprocess.run(
        [sys.executable, str(BUILD / "unlock-backup.py"), str(source), str(tmp / "out.bak")],
        capture_output=True, text=True,
    )
    check("a backup without metadata is refused",
          result.returncode != 0 and "no metadata" in result.stderr, result.stderr.strip())


def main() -> int:
    import tempfile
    with tempfile.TemporaryDirectory() as directory:
        tmp = Path(directory)
        tac_roundtrip(tmp)
        unlock_case(tmp)
        missing_metadata_case(tmp)
    if failures:
        print(f"\n{len(failures)} failure(s): {', '.join(failures)}")
        return 1
    print("\nall unlock-backup checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
