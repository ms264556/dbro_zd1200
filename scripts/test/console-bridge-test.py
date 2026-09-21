#!/usr/bin/env python3
"""Exercise scripts/container/proxmox/zd1200-console-bridge.py without a container.

The bridge is what puts the ZD1200 guest's serial console on the Proxmox Console
tab.  It fakes QEMU's console socket and runs the bridge with its stdio on a pty
that plays the container's /dev/tty1, then checks the behaviour the container
depends on:

  1. guest output reaches the tty
  2. tty input reaches the guest
  3. a public client (attach-console.py) sees guest output
  4. a public client's input reaches the guest
  5. a full pty buffer does not stall the bridge (bytes are dropped, not blocked)
  6. the public socket is private (0600)
  7. a vanished public socket is rebound

Run from the repository root:

    python3 scripts/test/console-bridge-test.py
"""
import os
import pty
import select
import socket
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BRIDGE = os.path.join(REPO, "scripts", "container", "proxmox", "zd1200-console-bridge.py")
TMP = "/tmp/zd1200-console-bridge-test"
QEMU = os.path.join(TMP, "qemu.sock")
PUBLIC = os.path.join(TMP, "public.sock")
STDERR = os.path.join(TMP, "bridge.err")
# Must exceed the bridge's LISTENER_CHECK_SECONDS so the rebind check runs.
REBIND_WAIT = 7.0


def read_fd(fd, timeout=2.0, want=None, limit=1 << 20):
    raw = fd.fileno() if hasattr(fd, "fileno") else fd
    out = b""
    end = time.time() + timeout
    while time.time() < end and len(out) < limit:
        r, _, _ = select.select([raw], [], [], 0.1)
        if r:
            try:
                data = os.read(raw, 65536)
            except OSError:
                break
            if not data:
                break
            out += data
            if want and want in out:
                break
    return out


def send_all(sock, data):
    view = memoryview(data)
    while view:
        try:
            sent = sock.send(view)
        except BlockingIOError:
            select.select([], [sock], [], 2.0)
            continue
        view = view[sent:]


class Test:
    def __init__(self):
        self.failures = []
        self.guest = None
        self.master = None
        self.proc = None
        self.qsrv = None

    def check(self, name, ok, detail=""):
        print(f"{'PASS' if ok else 'FAIL'}: {name}{(' -- ' + detail) if detail else ''}")
        if not ok:
            self.failures.append(name)

    def run(self):
        os.makedirs(TMP, exist_ok=True)
        for path in (QEMU, PUBLIC, STDERR):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass

        self.qsrv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.qsrv.bind(QEMU)
        self.qsrv.listen(1)
        self.qsrv.settimeout(5)

        self.master, slave = pty.openpty()
        env = dict(os.environ, ZD_CONSOLE_QEMU_SOCK=QEMU, ZD_CONSOLE_SOCK=PUBLIC)
        with open(STDERR, "wb") as errfh:
            self.proc = subprocess.Popen(
                [sys.executable, BRIDGE], stdin=slave, stdout=slave, stderr=errfh,
                env=env, close_fds=True)
        os.close(slave)

        self.guest, _ = self.qsrv.accept()
        self.guest.setblocking(False)
        time.sleep(0.2)
        self.guest.sendall(b"GUEST-HELLO\r\n")
        seen = read_fd(self.master, 3.0, want=b"GUEST-HELLO")
        self.check("1. guest output -> tty", b"GUEST-HELLO" in seen, repr(seen[:160]))

        os.write(self.master, b"typed-on-tty\r")
        self.check("2. tty input -> guest",
                   b"typed-on-tty\r" in read_fd(self.guest, 3.0, want=b"typed-on-tty\r"))

        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.connect(PUBLIC)
        client.setblocking(False)
        self.guest.sendall(b"GUEST-AFTER-CLIENT\r\n")
        self.check("3. guest output -> public client",
                   b"GUEST-AFTER-CLIENT" in read_fd(client, 3.0))
        client.sendall(b"typed-on-client\r")
        self.check("4. public client input -> guest",
                   b"typed-on-client\r" in read_fd(self.guest, 3.0, want=b"typed-on-client\r"))

        # Fill the pty while nobody reads the tty: the bridge must keep running.
        send_all(self.guest, b"X" * (512 * 1024))
        time.sleep(1.0)
        self.guest.sendall(b"AFTER-FILL\r\n")
        time.sleep(0.5)
        self.check("5a. bridge alive after filling the pty", self.proc.poll() is None)
        self.check("5b. public client fed while the tty is full",
                   b"AFTER-FILL" in read_fd(client, 3.0, want=b"AFTER-FILL"))
        read_fd(self.master, 0.5, limit=1 << 22)
        self.guest.sendall(b"LIVE-AFTER-DRAIN\r\n")
        self.check("5c. live output after the pty drains",
                   b"LIVE-AFTER-DRAIN" in read_fd(self.master, 3.0, want=b"LIVE-AFTER-DRAIN"))

        self.check("6. public socket mode is 0600",
                   (os.stat(PUBLIC).st_mode & 0o777) == 0o600,
                   oct(os.stat(PUBLIC).st_mode & 0o777))

        os.unlink(PUBLIC)
        time.sleep(REBIND_WAIT)
        self.check("7a. public socket rebound after unlink", os.path.exists(PUBLIC))
        rebound = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connected = True
        try:
            rebound.connect(PUBLIC)
            rebound.setblocking(False)
        except OSError as exc:
            connected = False
            print("    connect failed:", exc)
        self.check("7b. new client connects after rebind", connected)
        if connected:
            self.guest.sendall(b"AFTER-REBIND\r\n")
            self.check("7c. rebind still relays guest output",
                       b"AFTER-REBIND" in read_fd(rebound, 3.0, want=b"AFTER-REBIND"))
            rebound.close()
        client.close()

        # 8. without the private path configured the bridge must refuse to run
        # (and so must not claim the public socket that QEMU may be bound to).
        env = dict(os.environ)
        env.pop("ZD_CONSOLE_QEMU_SOCK", None)
        env["ZD_CONSOLE_SOCK"] = os.path.join(TMP, "never.sock")
        result = subprocess.run([sys.executable, BRIDGE], env=env,
                                capture_output=True, timeout=15)
        self.check("8. refuses to run without ZD_CONSOLE_QEMU_SOCK",
                   result.returncode == 0 and b"not set" in result.stderr,
                   f"rc={result.returncode}")

    def cleanup(self):
        if self.proc is not None and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        if self.guest is not None:
            self.guest.close()
        if self.master is not None:
            try:
                os.close(self.master)
            except OSError:
                pass
        if self.qsrv is not None:
            self.qsrv.close()


def main():
    test = Test()
    try:
        test.run()
    except Exception:  # noqa: BLE001 - report, never mask
        import traceback
        traceback.print_exc()
        test.failures.append("unexpected exception")
    finally:
        test.cleanup()
        try:
            with open(STDERR, "rb") as handle:
                stderr = handle.read().decode("utf-8", "replace")
            if stderr:
                print("---- bridge stderr ----")
                print(stderr[:2000])
        except OSError:
            pass
    if test.failures:
        print(f"FAILURES: {test.failures}")
        return 1
    print("ALL PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
