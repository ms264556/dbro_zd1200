#!/usr/bin/env python3
"""Encrypt a gzip-TAR payload into the Ruckus TAC container.

The inverse of ``tac-decrypt.py``: a ZoneDirector Web-UI configuration backup
and a firmware upgrade file are both TAC-encrypted gzip-TAR archives, and a
backup whose metadata has been rewritten (``unlock-backup.py``) must be put back
into that container for the guest's vendor ``verify-backup`` to accept it.

Usage:
    tac-encrypt.py <input .tgz> <output .bak>
"""

from __future__ import annotations

import argparse
import os
import struct
import tempfile
from io import BytesIO
from pathlib import Path
from typing import BinaryIO


# Explicit little-endian byte order, matching tac-decrypt.py and the vendor's
# native ``Q`` processing on Linux x86-64 and ARM64.
_WORD = struct.Struct("<Q")
_INITIAL_XOR, _XOR_FLIP = struct.unpack(
    "<QQ",
    b")\x1aB\x05\xbd,\xd6\xf25\xad\xb8\xe0?T\xc58"
)


def encrypt_bytes(payload: bytes) -> bytes:
    """Encrypt a complete TAC payload.  Backups are small, so this is not streamed."""
    xor_value = _INITIAL_XOR
    output_value = 0
    output = bytearray()
    full = len(payload) - (len(payload) % 8)
    for offset in range(0, full, 8):
        current, = _WORD.unpack_from(payload, offset)
        output_value ^= xor_value ^ current
        xor_value ^= _XOR_FLIP
        output += _WORD.pack(output_value)

    # TAC word-aligns its payload: the final partial word is padded with a byte
    # whose low nibble is the pad count, which the decryptor uses to truncate.
    tail = payload[full:]
    padding = 8 - len(tail)
    pad_byte = padding | (padding << 4)
    current, = _WORD.unpack(tail + bytes([pad_byte]) * padding)
    output_value ^= xor_value ^ current
    output += _WORD.pack(output_value)
    return bytes(output)


def encrypt_stream(source: BinaryIO, destination: BinaryIO) -> int:
    """Encrypt a stream, returning the number of output bytes written."""
    payload = source.read()
    encrypted = encrypt_bytes(payload)
    destination.write(encrypted)
    return len(encrypted)


def encrypt_file(source_path: Path, destination_path: Path) -> int:
    """Encrypt to a sibling temporary file, replacing destination on success."""
    if source_path.resolve() == destination_path.resolve():
        raise ValueError("source and destination must be different files")
    destination_path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination_path.name}.", suffix=".tmp", dir=destination_path.parent
    )
    try:
        with source_path.open("rb") as source, os.fdopen(descriptor, "wb") as destination:
            written = encrypt_stream(source, destination)
            destination.flush()
            os.fsync(destination.fileno())
        os.replace(temporary_name, destination_path)
        return written
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="decrypted gzip-TAR input")
    parser.add_argument("destination", type=Path, help="encrypted Ruckus TAC-format output")
    args = parser.parse_args()
    written = encrypt_file(args.source, args.destination)
    print(f"encrypted {args.source} -> {args.destination} ({written} bytes)")


if __name__ == "__main__":
    main()
