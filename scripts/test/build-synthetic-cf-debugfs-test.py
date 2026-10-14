#!/usr/bin/env python3
"""Unit test for how scripts/container/build-synthetic-cf.py puts a kernel into a root.

The disk builder gives each root partition a /bzImage with debugfs.  A firmware's
rootfs has none, so the patched kernel is written.  A ZD1200 card dump's rootfs
already carries its own /bzImage, and that is the kernel its modules match: the
kernel from the dump's /boot is a different build on some cards, and booting it
against the rootfs's modules fails (unknown symbols in igb2.ko/af.ko, no ethernet
devices, a kernel oops).  So an existing /bzImage must be left alone, for
prepare-vm-disks.sh to patch in place.

History this pins: debugfs `write` refuses to replace a file ("Ext2 file already
exists") yet exits 0, so while its output was discarded the dump's own kernel
stayed by accident and installs worked.  Once the builder checked debugfs's
output, every card-dump install failed; replacing the kernel instead fixed that
and broke the boot.  Leaving it is the only combination that works.

The real functions are lifted out of build-synthetic-cf.py (which runs a whole disk
build when imported) and run against small ext2 images.

Usage: ./scripts/test/build-synthetic-cf-debugfs-test.py
"""

from __future__ import annotations

import ast
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

CONTAINER = Path(__file__).resolve().parent.parent / "container"

for tool in ("mke2fs", "debugfs"):
    if not shutil.which(tool):
        print(f"skipped: {tool} not found (e2fsprogs is required)")
        raise SystemExit(0)

failures = []


def check(name: str, ok: bool, detail: str = "") -> None:
    if ok:
        print(f"ok   {name}")
    else:
        print(f"FAIL {name} {detail}")
        failures.append(name)


def load_functions():
    source = (CONTAINER / "build-synthetic-cf.py").read_text()
    wanted = ("debugfs_write", "place_root_kernel")
    nodes = [n for n in ast.parse(source).body
             if isinstance(n, ast.FunctionDef) and n.name in wanted]
    missing = set(wanted) - {n.name for n in nodes}
    if missing:
        raise SystemExit(f"FAIL: build-synthetic-cf.py no longer defines {sorted(missing)}")
    spec = importlib.util.spec_from_file_location("zd_build_bootfs", CONTAINER / "build-bootfs.py")
    bootfs = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bootfs)
    namespace = {"bootfs": lambda: bootfs, "tempfile": tempfile, "Path": Path}
    for node in nodes:
        exec(compile(ast.get_source_segment(source, node), node.name, "exec"), namespace)
    return namespace["debugfs_write"], namespace["place_root_kernel"]


def load_patch_scorpion(runtime: Path):
    """Lift patch_scorpion() out of the builder with its globals stubbed.

    Returns (function, namespace), so a test can point `runtime` at a fixture
    and swap in a recording subprocess.run.
    """
    source = (CONTAINER / "build-synthetic-cf.py").read_text()
    node = next((n for n in ast.parse(source).body
                 if isinstance(n, ast.FunctionDef) and n.name == "patch_scorpion"), None)
    if node is None:
        raise SystemExit("FAIL: build-synthetic-cf.py no longer defines patch_scorpion")
    namespace = {"os": os, "sys": sys, "subprocess": subprocess, "Path": Path,
                 "runtime": runtime}
    exec(compile(ast.get_source_segment(source, node), node.name, "exec"), namespace)
    return namespace["patch_scorpion"], namespace


def make_image(path: Path, files: dict) -> None:
    stage = path.parent / (path.name + ".stage")
    stage.mkdir()
    for name, data in files.items():
        (stage / name).write_bytes(data)
    subprocess.run(["mke2fs", "-q", "-t", "ext2", "-F", "-d", str(stage), str(path), "8M"],
                   check=True)


def cat(image: Path, name: str) -> bytes:
    return subprocess.run(["debugfs", "-R", f"cat {name}", str(image)],
                          capture_output=True).stdout


def main() -> int:
    debugfs_write, place_root_kernel = load_functions()
    with tempfile.TemporaryDirectory(prefix="zd-dbgfs.") as t:
        tmp = Path(t)
        patched = tmp / "bzImage.patched"
        patched.write_bytes(b"PATCHED-KERNEL\n" * 4000)
        vendor = b"VENDOR-KERNEL\n" * 5000

        # A firmware-style rootfs: no /bzImage yet.
        fresh = tmp / "fresh.img"
        make_image(fresh, {"hello": b"x\n"})
        wrote = place_root_kernel(fresh, patched)
        check("a rootfs with no /bzImage gets the patched kernel", wrote is True)
        check("...and its content is the patched kernel",
              cat(fresh, "/bzImage") == patched.read_bytes())

        # A card-dump-style rootfs: it already carries its own, different kernel.
        dump = tmp / "dump.img"
        make_image(dump, {"bzImage": vendor, "hello": b"x\n"})
        try:
            wrote = place_root_kernel(dump, patched)
            raised = None
        except SystemExit as exc:
            wrote, raised = None, exc
        check("a card-dump rootfs's own /bzImage does not make the build fail",
              raised is None, f"raised: {raised}")
        check("...the dump's own kernel is left in place, not replaced",
              wrote is False and cat(dump, "/bzImage") == vendor)
        check("...and the rest of that filesystem is untouched",
              cat(dump, "/hello") == b"x\n")

        # debugfs_write itself stays strict: a swallowed overwrite refusal is how
        # this went wrong before.
        try:
            debugfs_write(dump, [(patched, "/bzImage")])
            refused = False
        except SystemExit:
            refused = True
        check("debugfs_write still fails rather than silently skipping an existing file", refused)
        check("...and leaves the existing file as it was", cat(dump, "/bzImage") == vendor)

        # A real error still fails: the destination directory does not exist.
        try:
            debugfs_write(fresh, [(patched, "/no-such-dir/bzImage")])
            failed = False
        except SystemExit:
            failed = True
        check("a write that cannot succeed still fails", failed)

        # The ap-11n-scorpion (R600) mesh repair is opt-in, because the repaired
        # image bootlooped APs.  patch_scorpion() must reach the vendored helper
        # only for an explicit ZD_R600_REPAIR=1; anything else (unset, "0", a typo)
        # has to deliver the vendor AP image untouched.
        runtime_fix = tmp / "runtime"
        (runtime_fix / "packages" / "mesh-patch").mkdir(parents=True)
        (runtime_fix / "packages" / "mesh-patch" / "patch-scorpion-payload.py") \
            .write_text("# stub helper\n")
        (runtime_fix / "ruckus-squashfs").mkdir()
        for tool in ("unsquashfs", "mksquashfs"):
            (runtime_fix / "ruckus-squashfs" / tool).write_text("#!/bin/sh\n")

        r600_stage = tmp / "stage"
        (r600_stage / "firmwares" / "r600" / "10.5.1.0.282").mkdir(parents=True)

        class RecordRun:
            def __init__(self):
                self.calls = []

            def run(self, argv, **kwargs):
                self.calls.append(list(argv))

        def run_gate(value):
            patch_scorpion, namespace = load_patch_scorpion(runtime_fix)
            if value is None:
                os.environ.pop("ZD_R600_REPAIR", None)
            else:
                os.environ["ZD_R600_REPAIR"] = value
            recorder = RecordRun()
            namespace["subprocess"] = recorder
            patch_scorpion(r600_stage)
            return recorder.calls

        calls = run_gate(None)
        check("an unset ZD_R600_REPAIR leaves the vendor AP image alone",
              calls == [], f"calls: {calls}")
        calls = run_gate("0")
        check("ZD_R600_REPAIR=0 leaves the vendor AP image alone",
              calls == [], f"calls: {calls}")
        calls = run_gate("1")
        check("ZD_R600_REPAIR=1 runs the mesh-patch helper",
              len(calls) == 1 and calls[0][1].endswith("patch-scorpion-payload.py"),
              f"calls: {calls}")

        # With the repair enabled, the two non-applications are still quiet and
        # loud respectively: no r600/ directory means nothing to do even without
        # the tools; a missing tool must abort rather than skip silently.
        no_r600_stage = tmp / "no-r600-stage"
        (no_r600_stage / "firmwares").mkdir(parents=True)
        patch_scorpion, namespace = load_patch_scorpion(tmp / "no-tools-runtime")
        os.environ["ZD_R600_REPAIR"] = "1"
        try:
            patch_scorpion(no_r600_stage)
            skipped_quietly = True
        except BaseException:
            skipped_quietly = False
        check("with the repair on, a payload with no r600/ directory is skipped",
              skipped_quietly)
        try:
            patch_scorpion(r600_stage)
            raised = None
        except SystemExit as exc:
            raised = exc
        check("with the repair on, missing squashfs tooling fails loudly",
              raised is not None, f"raised: {raised}")
        os.environ.pop("ZD_R600_REPAIR", None)

    if failures:
        print(f"\n{len(failures)} failure(s): {', '.join(failures)}")
        return 1
    print("\nall build-synthetic-cf kernel-placement tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
