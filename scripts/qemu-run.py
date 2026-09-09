#!/usr/bin/env python3
"""Run QEMU once and report why it exited, so the caller can tell a guest reboot
from a guest poweroff.

QEMU is started with -no-reboot and a QMP socket.  A guest reset (reboot) makes
QEMU emit SHUTDOWN with reason "guest-reset"; a guest poweroff emits
"guest-shutdown".  Those are mapped to exit codes:

    0   guest powered off  -> the caller should stop the container
    10  guest rebooted     -> the caller should relaunch QEMU
    n   anything else (QEMU error, host signal, unknown reason)

Usage: qemu-run.py [QEMU arguments...]
"""
import json
import os
import socket
import subprocess
import sys
import tempfile

REBOOT_EXIT = 10
SOCK_TIMEOUT = 120.0


def main() -> int:
    sock_path = os.path.join(tempfile.gettempdir(), f"zd1200-qmp.{os.getpid()}.sock")
    if os.path.exists(sock_path):
        os.unlink(sock_path)

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sock_path)
    srv.listen(1)
    srv.settimeout(SOCK_TIMEOUT)

    # server=off makes QEMU connect to our listening socket (client mode); the
    # default would make QEMU try to bind the path we already bound.
    cmd = ["qemu-system-i386", "-no-reboot",
           "-qmp", f"unix:{sock_path},server=off", *sys.argv[1:]]
    # close_fds=False: run-zd1200-qemu.sh opens the macvtap device on fd 3 and
    # passes it as -net tap,fd=3; Python's default would close it before exec.
    proc = subprocess.Popen(cmd, close_fds=False)

    reason = "unknown"
    try:
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            # QEMU never connected: it failed to start or exited immediately.
            proc.wait()
            return proc.returncode or 1
        with conn, conn.makefile("rw") as f:
            f.readline()  # QMP greeting
            f.write(json.dumps({"execute": "qmp_capabilities"}) + "\n")
            f.flush()
            f.readline()  # capabilities reply
            for line in f:
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                if msg.get("event") == "SHUTDOWN":
                    reason = msg.get("data", {}).get("reason", "unknown")
                    break
    finally:
        srv.close()
        try:
            os.unlink(sock_path)
        except FileNotFoundError:
            pass

    proc.wait()
    if reason == "guest-reset":
        return REBOOT_EXIT
    if reason == "guest-shutdown":
        return 0
    return proc.returncode or 1


if __name__ == "__main__":
    sys.exit(main())
