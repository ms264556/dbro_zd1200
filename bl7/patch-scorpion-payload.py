#!/usr/bin/env python3
"""Apply the ap-11n-scorpion (R600) mesh repair to a staged firmware tree.

Ported from dbro/zd1200's build_zd1200_bundle.py.  ZoneDirector 10.5.1.0.276
introduced a mesh receive-path bug in the shared ``ap-11n-scorpion`` AP image
(R600 and the other models that resolve to the same vendor BL7 file).  This
converts that image from signed FSI to unsigned UI, patches ``wlan.ko`` with the
catalog rules, re-squashes the rootfs, rebuilds the BL7, and rewrites every
shared model's control file with the new image size.

The vendor layout aliases one real image from many model directories: for
example ``firmwares/r600/10.5.1.0.282/rcks_fw.bl7`` and ``rcks_fw.bl7.bkup`` are
symlinks to ``firmwares/ap-patch/patch000/ap-11n-scorpion/.../rcks_fw.bl7.main``.
Resolving the links deduplicates the patching work; the aliases drive which
``*_cntrl.rcks`` files need their two size fields updated.

Usage:
    patch-scorpion-payload.py STAGE_DIR \\
        --unsquashfs /opt/zd1200/ruckus-squashfs/unsquashfs \\
        --mksquashfs /opt/zd1200/ruckus-squashfs/mksquashfs

STAGE_DIR is the directory that contains ``firmwares/``.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

from patch_r600_bl7 import patch_image  # noqa: E402
from ruckus_bl7 import HEADER_SIZE, MAGIC  # noqa: E402

SCORPION_IMAGE_NAMES = frozenset({"rcks_fw.bl7", "rcks_fw.bl7.bkup"})
# The receive-path regression was introduced by 10.5.1.0.276 ("Resolved a VLAN
# packet forwarding issue", ER-12565, 2024-03-26) and is still present in
# 10.5.1.0.282.  Earlier 10.5.1 builds, and every other family, ship a
# different payload that must not be rewritten -- and whose wlan.ko does not
# carry the buggy instruction the patch targets.  Gate on the build number, not
# just the 10.5.1 prefix.
MESH_REPAIR_FAMILY = ("10", "5", "1")
MESH_REPAIR_MIN_BUILD = 276


def mesh_repair_needed(version: str) -> bool:
    """True when `version` is a 10.5.1 build at or after the regression."""
    parts = version.split(".")
    if len(parts) < 4 or tuple(parts[:3]) != MESH_REPAIR_FAMILY:
        return False
    try:
        build = int(parts[-1])
    except ValueError:
        return False
    return build >= MESH_REPAIR_MIN_BUILD


def bl7_version(path: Path) -> str:
    data = path.read_bytes()[: HEADER_SIZE]
    if len(data) < HEADER_SIZE or data[:4] != MAGIC:
        raise ValueError(f"not a Ruckus BL7 image: {path}")
    return data[0x2C:0x3C].split(b"\0", 1)[0].decode("ascii", "replace")


def scorpion_payload_paths(source_dir: Path) -> tuple[list[Path], set[str]]:
    """Return the real shared image path(s) and the model aliases that use them."""
    firmware_root = source_dir / "firmwares"
    r600_paths = sorted(
        path
        for path in (firmware_root / "r600").glob("*/*")
        if path.name in SCORPION_IMAGE_NAMES and path.is_file()
    )
    if not r600_paths:
        raise ValueError("vendor payload contains no R600 ap-11n-scorpion BL7 image")
    targets = {path.resolve() for path in r600_paths}
    aliases = {"r600"}
    for path in firmware_root.glob("*/*/*"):
        if path.name in SCORPION_IMAGE_NAMES and path.is_file() and path.resolve() in targets:
            aliases.add(path.relative_to(firmware_root).parts[0].lower())
    return sorted(targets), aliases


def update_control_files(source_dir: Path, models: set[str], image_size: int) -> list[str]:
    """Rewrite the two image-size fields in every aliased model's control file."""
    controls = sorted(
        {
            path.resolve()
            for model in models
            for path in (source_dir / "firmwares" / model).glob("*/*_cntrl.rcks")
            if path.is_file()
        }
    )
    if not controls:
        raise ValueError("vendor payload contains no ap-11n-scorpion control file")
    messages = []
    for control in controls:
        contents = control.read_text(encoding="ascii")
        updated, count = re.subn(r"(?m)^\d+$", str(image_size), contents)
        if count != 2:
            raise ValueError(
                f"expected two image-size fields in {control}, found {count}"
            )
        control.write_text(updated, encoding="ascii")
        messages.append(f"updated control sizes in {control} to {image_size}")
    return messages


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_dir", type=Path, help="directory containing firmwares/")
    parser.add_argument("--unsquashfs", type=Path, required=True)
    parser.add_argument("--mksquashfs", type=Path, required=True)
    args = parser.parse_args()

    for tool in (args.unsquashfs, args.mksquashfs):
        if not tool.is_file():
            parser.error(f"squashfs tool not found: {tool}")

    targets, aliases = scorpion_payload_paths(args.source_dir)
    version = bl7_version(targets[0])
    if not mesh_repair_needed(version):
        print(
            f"ap-11n-scorpion payload {version} is not a 10.5.1 build >= "
            f"{MESH_REPAIR_MIN_BUILD}; mesh repair skipped"
        )
        return 0

    messages = [f"ap-11n-scorpion payload {version}; models: {', '.join(sorted(aliases))}"]
    for path in targets:
        temporary = path.with_suffix(path.suffix + ".patched")
        messages.append(f"patching {path}")
        messages.extend(
            patch_image(
                path,
                temporary,
                unsquashfs=args.unsquashfs,
                mksquashfs=args.mksquashfs,
            )
        )
        temporary.replace(path)
    messages.extend(update_control_files(args.source_dir, aliases, targets[0].stat().st_size))
    for message in messages:
        print(message)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
