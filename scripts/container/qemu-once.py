#!/usr/bin/env python3
"""Run QEMU once and report why it exited, so the caller can tell a guest reboot
from a guest poweroff.

QEMU is started with -no-reboot and a QMP socket.  A guest reset (reboot) makes
QEMU emit SHUTDOWN with reason "guest-reset"; a guest poweroff emits
"guest-shutdown".  Those are mapped to exit codes:

    0   guest powered off  -> the caller should stop the container
    10  guest rebooted     -> the caller should relaunch QEMU
    n   anything else (QEMU error, host signal, unknown reason)

Usage: qemu-once.py [QEMU arguments...]
"""
import json
import os
import socket
import subprocess
import sys
import tempfile

REBOOT_EXIT = 10
SOCK_TIMEOUT = 120.0
# How long to wait for a QEMU that closed its QMP socket to be reaped, so the
# pid file can be removed with it.
REAP_TIMEOUT = 30.0


def publish_pid(path: str, pid: int) -> None:
    """Record the emulator's pid in PATH for the entrypoint's CPU supervisor.

    QEMU is a grandchild of the entrypoint (launch-vm.sh -> this script ->
    qemu-system-i386), and /proc/<pid>/stat's utime+stime count a process's own
    CPU time only, so the supervisor has to sample QEMU itself rather than the
    launcher.  A temp file plus rename, so a reader never sees a partial pid.
    """
    if not path:
        return
    tmp = f"{path}.{os.getpid()}"
    try:
        with open(tmp, "w") as f:
            f.write(f"{pid}\n")
        os.replace(tmp, path)
    except OSError as exc:
        print(f"warning: cannot write {path}: {exc}", file=sys.stderr)


def unpublish_pid(path: str, pid: int) -> None:
    """Remove PATH once this QEMU has exited.

    Only while it still names this QEMU: a relaunch after a guest reset writes a
    new pid there, and the previous launch exiting must not remove that file.
    """
    if not path:
        return
    try:
        with open(path) as f:
            if f.read().strip() != str(pid):
                return
        os.unlink(path)
    except OSError:
        pass


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
    # close_fds=False: launch-vm.sh opens the macvtap device on fd 3 and
    # passes it as -net tap,fd=3; Python's default would close it before exec.
    proc = subprocess.Popen(cmd, close_fds=False)
    # The entrypoint's CPU supervisor samples and stops the pid in this file.
    # Written on every launch -- launch-vm.sh relaunches QEMU after each guest
    # reset -- and removed when this QEMU exits, so it never names a dead one.
    pid_file = os.environ.get("ZD_QEMU_PID_FILE", "")
    publish_pid(pid_file, proc.pid)

    reason = "unknown"
    try:
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            # QEMU never connected: it failed to start or exited immediately.
            proc.wait()
            unpublish_pid(pid_file, proc.pid)
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
    except ConnectionError:
        # QEMU died while this process was talking to it -- a kill racing the
        # handshake above gives BrokenPipeError here -- which is a QEMU outcome,
        # not a failure of this script.  It must still reap QEMU and drop the
        # pid file: the wait is bounded because the socket closes a moment
        # before the process is reapable, and a QEMU that somehow kept running
        # must not hang this script (its pid file then stays, correctly naming
        # a live emulator).
        try:
            proc.wait(timeout=REAP_TIMEOUT)
        except subprocess.TimeoutExpired:
            return 1
        unpublish_pid(pid_file, proc.pid)
        return proc.returncode or 1
    finally:
        srv.close()
        try:
            os.unlink(sock_path)
        except FileNotFoundError:
            pass

    proc.wait()
    unpublish_pid(pid_file, proc.pid)
    if reason == "guest-reset":
        return REBOOT_EXIT
    if reason == "guest-shutdown":
        return 0
    return proc.returncode or 1


if __name__ == "__main__":
    sys.exit(main())
