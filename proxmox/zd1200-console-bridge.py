#!/usr/bin/env python3
"""Show the ZD1200 guest's serial console on the container's Proxmox console tty.

The Proxmox "Console" tab for an LXC container runs

    lxc-console -n <vmid>                  (PVE cmode=tty, no -t given)

which attaches to the container's first tty that no other console client already
holds -- /dev/tty1, unless something else claimed it first.  This program runs
with its stdin/stdout on that tty (zd1200-console-tty.service, StandardInput=tty
+ TTYPath=/dev/tty1), so what it writes is what the Console tab shows, and what
the user types is what it reads.

QEMU forwards the guest's ttyS0 -- the console the stock /etc/inittab runs
`/bin/login.sh` on -- to a unix socket, and also appends every byte to the
console log that the entrypoint's READY probe and the health checks read (see
launch-vm.sh).  QEMU's socket chardev serves exactly ONE client: against this
QEMU (10.0.13) a second connection is accepted by the kernel but never answered,
and there is no max_connections property to raise.  So this program is the
socket's single client, and is itself a small server on the public console
socket.  That keeps the documented

    attach-console.py  (default /tmp/zd1200-console.sock)

working beside the web console instead of silently dead: guest output is copied
to the tty and to every attached client, and input from the tty or any client is
forwarded to the guest -- the same shared-console model dtach gives the web tab.

Two behaviours are deliberate:

* The tty is written NON-BLOCKINGLY and bytes are dropped when the pty buffer is
  full.  That buffer is drained only while a console client is attached, so a
  blocking write would stall the entire guest console feed whenever nobody has
  the tab open (measured: an unattached tty blocks after its buffer fills).
  Nothing diagnostic is lost -- the console log remains the complete record,
  written by QEMU itself, not by this bridge.

* The QEMU connection is retried forever, because a guest reboot makes
  launch-vm.sh relaunch QEMU, which recreates the socket.

The tty is put in raw mode so keystrokes reach the guest unchanged and the
container's line discipline does not echo them or translate the guest's CR/LF.

Environment (from /etc/zd1200.conf):
    ZD_CONSOLE_QEMU_SOCK   the socket QEMU's console chardev binds (private)
    ZD_CONSOLE_SOCK        the socket this bridge serves to attach-console.py
"""
import errno
import fcntl
import os
import selectors
import signal
import socket
import sys
import termios
import time
import tty

TTY_IN = 0
TTY_OUT = 1
# No default: main() refuses to run without an explicit private path, so a
# missing /etc/zd1200.conf key cannot make the bridge hijack the public socket
# that QEMU itself would then be bound to.
QEMU_SOCK = os.environ.get("ZD_CONSOLE_QEMU_SOCK", "")
PUBLIC_SOCK = os.environ.get("ZD_CONSOLE_SOCK") or "/tmp/zd1200-console.sock"
# How long to wait between attempts to reach QEMU while it is not running.
RETRY_SECONDS = 1.0
# How often to verify that the public socket is still on disk.  A /tmp cleaner
# (systemd-tmpfiles removes files older than ten days) or a stray unlink would
# otherwise leave the bridge listening on a path nothing can reach.
LISTENER_CHECK_SECONDS = 5.0
# Never let a wedged guest grow the buffer of input we owe it without bound.
MAX_PENDING_INPUT = 65536
# Per-client output held while a client is not reading.  attach-console.py is a
# human terminal that may fall behind during a boot burst; unlike the tty (which
# must drop when nobody is attached), a client can be buffered.  Past this the
# oldest output is dropped -- the console log stays the complete record.
MAX_PENDING_CLIENT = 262144

_selector = selectors.DefaultSelector()
_qemu = None
_qemu_pending = bytearray()
_clients = {}  # socket -> bytearray of output waiting to be written
_listener = None
_listener_id = None  # (st_dev, st_ino) of the bound socket, to detect unlinking
_tty_saved = None
_input_dropped_notice = False


def tty_write(data: bytes) -> None:
    """Best-effort write to the Proxmox console tty, dropping what will not fit.

    A short write drops the tail of the chunk (the buffer is full and only a
    client attaching drains it); that is deliberate, see the module docstring.
    """
    try:
        os.write(TTY_OUT, data)
    except OSError as exc:
        if exc.errno not in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EIO):
            raise


def tty_note(text: str) -> None:
    """Print a bridge notice (never guest output) on the console tty."""
    tty_write(b"\r\n" + text.encode("utf-8", "replace") + b"\r\n")


def enter_raw() -> None:
    global _tty_saved
    try:
        _tty_saved = termios.tcgetattr(TTY_IN)
        tty.setraw(TTY_IN, termios.TCSANOW)
    except (termios.error, OSError):
        _tty_saved = None  # not a tty (a manual, redirected run): carry on
    # The output side MUST be non-blocking: the pty buffer is only drained
    # while a console client is attached, and a blocking write once it filled
    # would stall the whole guest-console feed (see the module docstring).
    for fd in (TTY_IN, TTY_OUT):
        try:
            flags = fcntl.fcntl(fd, fcntl.F_GETFL)
            fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)
        except OSError:
            pass


def restore_tty() -> None:
    if _tty_saved is not None:
        try:
            termios.tcsetattr(TTY_IN, termios.TCSANOW, _tty_saved)
        except (termios.error, OSError):
            pass


def connect_qemu():
    """One connection attempt to QEMU's console chardev; None when it is not up."""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(QEMU_SOCK)
    except OSError:
        sock.close()
        return None
    sock.setblocking(False)
    return sock


def open_listener(previous=None):
    """Bind the socket attach-console.py expects, replacing a stale one.

    Pass the current listener to replace it; existing client connections are
    separate descriptors and are unaffected.  Returns the socket, or None when
    the path cannot be served this attempt (the caller retries: a crash loop
    under Restart=always would put the traceback on the console tab instead).
    """
    global _listener, _listener_id
    if previous is not None:
        try:
            _selector.unregister(previous)
        except (KeyError, ValueError):
            pass
        previous.close()
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        try:
            os.unlink(PUBLIC_SOCK)
        except FileNotFoundError:
            pass
        sock.bind(PUBLIC_SOCK)
        os.chmod(PUBLIC_SOCK, 0o600)
        sock.listen(8)
        sock.setblocking(False)
        st = os.stat(PUBLIC_SOCK)
    except OSError as exc:
        sock.close()
        _listener, _listener_id = None, None
        tty_note(f"[zd1200] cannot serve {PUBLIC_SOCK}: {exc}; retrying")
        return None
    _listener, _listener_id = sock, (st.st_dev, st.st_ino)
    return sock


def listener_live() -> bool:
    """True while the bound socket still has a directory entry at its path."""
    if _listener is None or _listener_id is None:
        return False
    try:
        st = os.stat(PUBLIC_SOCK)
    except OSError:
        return False
    return (st.st_dev, st.st_ino) == _listener_id


def drop_qemu(reason: str) -> None:
    """Forget the current QEMU connection; it will be retried."""
    global _qemu
    if _qemu is None:
        return
    _selector.unregister(_qemu)
    _qemu.close()
    _qemu = None
    _qemu_pending.clear()
    tty_note(f"[zd1200] guest serial console {reason}; waiting for it to return")


def queue_input(data: bytes) -> None:
    """Forward console input to the guest, without ever blocking the bridge."""
    global _input_dropped_notice
    if _qemu is None:
        if not _input_dropped_notice:
            _input_dropped_notice = True
            tty_note("[zd1200] guest serial console is not up yet; input dropped")
        return
    _qemu_pending.extend(data)
    if len(_qemu_pending) > MAX_PENDING_INPUT:
        del _qemu_pending[: len(_qemu_pending) - MAX_PENDING_INPUT]
    _selector.modify(_qemu, selectors.EVENT_READ | selectors.EVENT_WRITE, "qemu")


def flush_input() -> None:
    if _qemu is None or not _qemu_pending:
        return
    try:
        sent = _qemu.send(bytes(_qemu_pending))
    except BlockingIOError:
        return
    except OSError:
        drop_qemu("disconnected")
        return
    del _qemu_pending[:sent]
    if not _qemu_pending:
        _selector.modify(_qemu, selectors.EVENT_READ, "qemu")


def broadcast_guest(data: bytes) -> None:
    """Guest -> tty (best effort) and every attached client (buffered)."""
    tty_write(data)
    for client in list(_clients):
        send_client(client, data)


def send_client(client: socket.socket, data: bytes) -> None:
    """Write to one public client, queueing what its socket will not take yet."""
    buf = _clients.get(client)
    if buf is None:
        return
    if buf:  # already behind: keep ordering, let the write event catch up
        buf.extend(data)
        _trim(buf)
        return
    try:
        sent = client.send(data)
    except (BlockingIOError, InterruptedError):
        sent = 0
    except OSError:
        forget_client(client)
        return
    if sent < len(data):
        buf.extend(data[sent:])
        _trim(buf)
        _selector.modify(client, selectors.EVENT_READ | selectors.EVENT_WRITE, "client")


def _trim(buf: bytearray) -> None:
    if len(buf) > MAX_PENDING_CLIENT:
        del buf[: len(buf) - MAX_PENDING_CLIENT]


def flush_client(client: socket.socket) -> None:
    buf = _clients.get(client)
    if not buf:
        return
    try:
        sent = client.send(bytes(buf))
    except (BlockingIOError, InterruptedError):
        return
    except OSError:
        forget_client(client)
        return
    del buf[:sent]
    if not buf:
        _selector.modify(client, selectors.EVENT_READ, "client")


def forget_client(client: socket.socket) -> None:
    if _clients.pop(client, None) is None:
        return
    try:
        _selector.unregister(client)
    except (KeyError, ValueError):
        pass
    client.close()


def read_guest() -> None:
    assert _qemu is not None
    try:
        data = _qemu.recv(4096)
    except BlockingIOError:
        return
    except OSError:
        drop_qemu("disconnected")
        return
    if not data:
        drop_qemu("disconnected")
        return
    broadcast_guest(data)


def read_tty() -> None:
    try:
        data = os.read(TTY_IN, 4096)
    except BlockingIOError:
        return
    except OSError:
        data = b""
    if not data:
        # The tty hung up (the container is stopping): let systemd reap us.
        raise SystemExit(0)
    queue_input(data)


def read_client(client: socket.socket) -> None:
    try:
        data = client.recv(4096)
    except BlockingIOError:
        return
    except OSError:
        forget_client(client)
        return
    if not data:
        forget_client(client)
        return
    queue_input(data)


def main() -> int:
    global _qemu
    # Both of these are static configuration errors, not transient ones; exit
    # cleanly (the unit restarts us, but the guard means we never unlink the
    # socket QEMU itself is bound to).
    if not QEMU_SOCK:
        print("ZD_CONSOLE_QEMU_SOCK is not set: QEMU is not using a private "
              "console socket, so there is nothing to bridge to", file=sys.stderr)
        return 0
    if os.path.abspath(QEMU_SOCK) == os.path.abspath(PUBLIC_SOCK):
        print("ZD_CONSOLE_QEMU_SOCK and ZD_CONSOLE_SOCK must be different paths",
              file=sys.stderr)
        return 0

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    # TTYVHangup=yes makes systemd hang the tty up on stop; without this the
    # signal would kill us and skip the finally block below.
    signal.signal(signal.SIGHUP, lambda *_: sys.exit(0))
    enter_raw()
    try:
        _selector.register(TTY_IN, selectors.EVENT_READ, "tty")
        if open_listener() is not None:
            _selector.register(_listener, selectors.EVENT_READ, "listen")
        tty_note("[zd1200] waiting for the guest's serial console...")

        next_retry = 0.0
        next_listener_check = 0.0
        while True:
            now = time.monotonic()
            if _qemu is None and now >= next_retry:
                _qemu = connect_qemu()
                if _qemu is not None:
                    _selector.register(_qemu, selectors.EVENT_READ, "qemu")
                    tty_note("[zd1200] guest serial console attached")
                else:
                    next_retry = now + RETRY_SECONDS
            if now >= next_listener_check:
                if not listener_live():
                    if open_listener(_listener) is not None:
                        _selector.register(_listener, selectors.EVENT_READ, "listen")
                next_listener_check = now + LISTENER_CHECK_SECONDS
            for key, mask in _selector.select(1.0 if _qemu is None else LISTENER_CHECK_SECONDS):
                kind = key.data
                if kind == "qemu":
                    if mask & selectors.EVENT_WRITE:
                        flush_input()
                    if mask & selectors.EVENT_READ:
                        read_guest()
                elif kind == "tty":
                    read_tty()
                elif kind == "listen":
                    try:
                        client, _ = _listener.accept()
                    except OSError:
                        continue
                    client.setblocking(False)
                    _clients[client] = bytearray()
                    _selector.register(client, selectors.EVENT_READ, "client")
                else:
                    if mask & selectors.EVENT_WRITE:
                        flush_client(key.fileobj)
                    if mask & selectors.EVENT_READ:
                        read_client(key.fileobj)
    finally:
        restore_tty()
        # Remove the public socket only if it is still the one we bound; a
        # rebind may have replaced it.
        if listener_live():
            try:
                os.unlink(PUBLIC_SOCK)
            except OSError:
                pass
        if _listener is not None:
            try:
                _listener.close()
            except OSError:
                pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
