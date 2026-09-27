#!/usr/bin/env bash
# NOTE: This is the container's ENTRYPOINT. It is run by Docker Compose as the
# zd1200 container command — do NOT run it directly on the host as a standalone
# flow. The supported way to run this project is `sudo ./install-zd1200-docker.sh`
# (= docker compose up -d --build). See README.md.
set -euo pipefail

# Exit status prepare-vm-disks.sh returns when the saved GRUB entry is a rescue
# entry (it has already printed how to rebuild the machinery).  This entrypoint
# stops the container cleanly rather than letting Compose restart it.
RET_RESCUE_ACTIVE=4

work_dir="$(cd "$(dirname "$0")" && pwd)"
log_file="${LOG_FILE:-/tmp/zd1200-console.log}"
control_sock="${ZD_CONTROL_SOCK:-/tmp/zd1200-control.sock}"
qemu_pid=""
started_at=$SECONDS
high_cpu_samples=0
ready=0
http_status=""
http_port="${HTTP_PORT:-38080}"
https_port="${HTTPS_PORT-38443}"
network_mode="${NETWORK_MODE:-user}"
# The guest is the authority on its own address: it asked the LAN's DHCP server
# for the lease, so it is asked on the control channel
# (scripts/container/zd1200-guest-address, which every flow's runtime layout
# carries at "$work_dir/zd1200-guest-address").  A configured GUEST_IP is only
# the fallback for when the helper is absent or the guest does not answer.
# GUEST_IP is NOT evidence that the guest is at that address: the Docker flavour
# always sets one (docker/docker-compose.yml, default 192.168.50.10), and
# printing it while the guest leased elsewhere sends an operator to an address
# the guest never had.  There is deliberately no guessed default here, either:
# probing an address that may not be the guest's makes a healthy guest look dead,
# and then the readiness deadline restarts it.  The address is a display concern
# only -- see refreshed_guest_ip() below.
guest_ip="${GUEST_IP:-}"
# 1 once the helper has answered: see refreshed_guest_ip and the display retry.
address_answered=0
address_helper="${ZD_ADDRESS_HELPER:-$work_dir/zd1200-guest-address}"
state_dir="${STATE_DIR:-$work_dir}"
# Where the vendor artifacts (rootfs.ext2, bzImage, menu.lst, …) live.  The
# Docker flow mounts them read-only from the host's image/; the LXC flow symlinks
# that path to the state dir.  Derived from this script's own directory rather
# than the current working directory: the two are the same under Docker's
# WORKDIR (/opt/zd1200), but a caller that starts the entrypoint from elsewhere
# would otherwise look for image/ in the wrong place.  Set IMAGE_DIR to override.
image_dir="${IMAGE_DIR:-$work_dir/image}"
synthetic_disk="${SYNTHETIC_DISK:-$state_dir/synthetic-cf.img}"
vm_snapshot="${VM_SNAPSHOT:-0}"
# Consecutive >95% CPU samples (5s each) before the supervisor stops QEMU.
# The 2.6.32 guest can legitimately spin during TCG boot/keygen phases, which
# false-triggers this watchdog; set 0/off/none to disable it.
cpu_guard="${ZD_CPU_GUARD:-4}"
# ACCEL is the same knob launch-vm.sh reads, and this script previously did not
# consult it at all: the probe below always won, so neither flow could choose the
# accelerator.  `auto` (the default, and what every flow here wants) keeps that
# probe; `kvm`/`tcg` name it explicitly, for a host whose /dev/kvm is readable
# but whose guest must run emulated anyway.
case "${ACCEL:-auto}" in
    kvm) vm_accel=kvm ;;
    tcg) vm_accel=tcg ;;
    auto|"")
        if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
            vm_accel=kvm
        else
            vm_accel=tcg
        fi
        ;;
    *)
        echo "ACCEL must be auto, kvm, or tcg (got '$ACCEL')." >&2
        exit 2
        ;;
esac

# The container's own LAN address is maintenance-only: the patch pipeline is
# local, and the healthcheck/watchdog/address helpers use the guest's serial
# control channel rather than IP.  With ZD_CT_ADDRESS_FOLLOW_QEMU=1 the
# entrypoint hands the address back just before QEMU starts and takes a fresh
# lease again when QEMU exits, so the appliance is the only thing on the LAN
# while it runs (and the Proxmox Summary shows only the guest).  See
# scripts/container/proxmox/zd1200-ct-address; a no-op in the Docker flow, which
# sets neither the flag nor the helper.
ct_address_helper="${ZD_CT_ADDRESS_HELPER:-/usr/local/sbin/zd1200-ct-address}"
# The guest shares the container's uplink MAC, so default to releasing the
# container's own address while the guest runs.  The bootstrap writes
# ZD_CT_ADDRESS_FOLLOW_QEMU explicitly, but a conf that predates (or has lost)
# the key must not silently hold an address under the shared MAC.
follow_qemu_address="${ZD_CT_ADDRESS_FOLLOW_QEMU:-1}"
ct_address() {
    [ "$follow_qemu_address" = 1 ] || return 0
    [ "$network_mode" = bridge ] || return 0
    [ -x "$ct_address_helper" ] || return 0
    "$ct_address_helper" "$1" >&2 || true
}

cleanup() {
    # $1 = 1 for a signal (docker stop/down): try an orderly guest shutdown
    # first so the guest unmounts and flushes /writable.  0 (normal exit) just
    # tears QEMU down.
    local graceful="${1:-0}"
    trap - EXIT INT TERM
    # The guest watchdog probes the guest, so it must not outlive QEMU: a probe
    # that fails after the emulator is gone would ask a dead control channel for
    # a reboot.  Killing it here also keeps a stop from racing it.
    if [[ "${watchdog_pid:-}" =~ ^[0-9]+$ ]] && (( watchdog_pid > 1 )); then
        kill "$watchdog_pid" 2>/dev/null || true
        wait "$watchdog_pid" 2>/dev/null || true
        watchdog_pid=""
    fi
    if [[ "$qemu_pid" =~ ^[0-9]+$ ]] && (( qemu_pid > 1 )); then
        if [ "$graceful" = 1 ] && [ "${ZD_CONTAINER_CONTROL:-1}" != "0" ] \
           && kill -0 "$qemu_pid" 2>/dev/null; then
            echo "Requesting an orderly guest shutdown (unmounts /writable)..."
            # launch-vm.sh sees this and exits after the guest's reboot-reset
            # instead of relaunching QEMU.
            : > "$state_dir/.stop-after-reset" 2>/dev/null || true
            # The guest's control hook starts late in init (its init script is
            # near the end), so a stop requested in the first seconds after a
            # boot can arrive before anything is listening on ttyS1 and be lost.
            # Send once, then resend every 5s until QEMU exits: a healthy guest
            # reboots on the first command (seconds), and a guest that is still
            # booting gets it on a later one instead of making the container wait
            # out the whole grace period.
            send_guest_reboot() {
                [ -S "$control_sock" ] || return 0
                python3 - "$control_sock" <<'PY' 2>/dev/null || true
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(sys.argv[1])
s.sendall(b"reboot\n")
s.close()
PY
            }
            send_guest_reboot
            ticks=0
            # The guest's reboot path flushes the data partition; allow the same
            # grace the appliance itself needs after an unclean stop.
            for _ in $(seq 1 "${ZD_STOP_TIMEOUT:-240}"); do
                kill -0 "$qemu_pid" 2>/dev/null || break
                ticks=$((ticks + 1))
                if [ $((ticks % 10)) -eq 0 ]; then send_guest_reboot; fi
                sleep 0.5
            done
            if kill -0 "$qemu_pid" 2>/dev/null; then
                echo "Guest did not shut down in time; stopping QEMU." >&2
            else
                echo "Guest shut down cleanly."
            fi
        fi
        kill -CONT -- "-$qemu_pid" 2>/dev/null || true
        kill -TERM -- "-$qemu_pid" 2>/dev/null || true
        for _ in {1..20}; do
            kill -0 "$qemu_pid" 2>/dev/null || break
            sleep 0.1
        done
        kill -KILL -- "-$qemu_pid" 2>/dev/null || true
        wait "$qemu_pid" 2>/dev/null || true
    fi
    # The guest's macvtap lives in the host's network namespace (this container
    # runs with network_mode: host), so nothing else removes it when the
    # container goes away.  Take it down with the guest: otherwise every
    # `docker rm -f` leaves a stray interface carrying the dead guest's MAC,
    # and a later install inherits it.  launch-vm.sh recreates what it needs.
    if [ "$network_mode" = macvtap ]; then
        macvtap_if="${ZD_MACVTAP_IF:-mvt0}"
        if [ -e "/sys/class/net/$macvtap_if" ]; then
            ip link del "$macvtap_if" 2>/dev/null || true
        fi
    fi
    # The guest is down (or going down).  A guest-initiated poweroff stops the
    # container too (see the qemu_rc branch at the end); every other exit puts the
    # container's own address back for maintenance.
    if [ "${stop_container:-0}" = 1 ]; then
        echo "Shutting the container down with the appliance."
        systemctl --no-block poweroff 2>/dev/null || true
        return 0
    fi
    ct_address up
}
trap 'cleanup 1' INT TERM
trap 'cleanup 0' EXIT

cd "$work_dir" || exit 1
mkdir -p "$state_dir"
# A stale orderly-stop marker from a previous run must not suppress a reboot.
rm -f "$state_dir/.stop-after-reset" 2>/dev/null || true

# Maintenance work below may want the network, and a previous run that crashed
# hard could have left the address down: make sure it is up before starting.
ct_address up

if [ ! -f "$image_dir/bzImage" ]; then
    echo "Missing $image_dir/bzImage" >&2
    exit 1
fi
# The lab boots the statically patched kernel (patch-kernel.py applies the
# QEMU hardware accommodations; no gdb attach is needed).  image/ is mounted
# read-only in the container, so the patched kernel lands in the writable
# state dir and is passed via KERNEL=.
patched_kernel="${PATCHED_KERNEL:-$state_dir/bzImage.patched}"
if [ ! -f "$patched_kernel" ] || [ ! -s "$patched_kernel" ]; then
    echo "Building patched kernel $patched_kernel ..."
    python3 "$work_dir/patch-kernel.py" \
        --in "$image_dir/bzImage" \
        --out "$patched_kernel"
fi
# The serial number and MACs live in the board-data records on the CF image
# (read by the kernel's v54bsp driver; NOT patched into the kernel).  This block
# only computes the identity to WRITE when the synthetic base is first built
# (see prepare-vm-disks.sh below); on every start the board data is read
# back afterwards and takes precedence.
# By default the identity is derived from ZD_CONTAINER_MAC, a unique
# locally-administered MAC generated into .env by install-zd1200-docker.sh
# (scripts/container/boarddata-from-mac.sh: MAC1 = ZD_CONTAINER_MAC, serial hashed
# from MAC1); MAC2 = MAC1 + 1.  Set ZD_BOARDDATA_FROM_MAC=0 to pin the fixed
# ZD_SERIAL/ZD_MAC1 instead.
if { [ "${NETWORK_MODE:-user}" = macvtap ] || [ "${NETWORK_MODE:-user}" = bridge ]; } \
   && [ "${ZD_BOARDDATA_FROM_MAC:-1}" != "0" ]; then
    eval "$("$work_dir/boarddata-from-mac.sh")"
    zd_serial="$SERIAL"
    zd_mac1="$MAC"
    zd_mac2="$MAC2"
else
    zd_serial="${ZD_SERIAL:-123456000789}"
    zd_mac1="${ZD_MAC1:-00:0c:e6:12:00:01}"
    zd_mac2="${ZD_MAC2:-}"
fi
# A CF-dump image carries the appliance's own board serial (extracted by
# prepare-vendor-image.sh); reuse it.  The MAC still comes from
# ZD_CONTAINER_MAC so a clone does not collide on the LAN.
if [ -f "$image_dir/dump-boarddata" ]; then
    dump_serial="$(sed -n 's/^SERIAL=//p' "$image_dir/dump-boarddata" | head -n1)"
    if [ -n "$dump_serial" ]; then
        echo "board data: using the CF-dump serial $dump_serial"
        zd_serial="$dump_serial"
    fi
fi
# Build the flat synthetic disk if missing, write the board data, and run the
# kernel + rootfs customisations on whichever root partitions still need them
# (see prepare-vm-disks.sh).  It is the ONLY place that builds or patches the disk.
STATE_DIR="$state_dir" \
SYNTHETIC_DISK="$synthetic_disk" \
WORK="$state_dir/.rootfs-patch-work" \
ZD_SERIAL="$zd_serial" \
ZD_MAC1="$zd_mac1" \
ZD_MODEL="${ZD_MODEL:-ZD1200}" \
ZD_CUSTOMER="${ZD_CUSTOMER:-ruckus}" \
ZD_SIGN_CERT_DIR="${ZD_SIGN_CERT_DIR:-/opt/zd1200/signing-cert}" \
"$work_dir/prepare-vm-disks.sh" || prepare_rc=$?
prepare_rc="${prepare_rc:-0}"
if [ "$prepare_rc" -eq "$RET_RESCUE_ACTIVE" ]; then
    echo "The saved GRUB entry is a rescue entry; stopping the container." >&2
    if [ "${ZD_POWEROFF_CONTAINER:-0}" = 1 ]; then stop_container=1; fi
    exit 0
fi
if [ "$prepare_rc" -ne 0 ]; then
    exit "$prepare_rc"
fi

: > "$log_file"

# The board data is authoritative: a ZD1200 can change its MAC in the web UI and
# the firmware writes it back into the board-data record.  Read it back now and
# use it for the macvtap, the QEMU NIC and the DHCP sniffer, so a MAC changed
# inside the guest is honoured on the next start.  Only a freshly built base disk
# gets the identity derived above written into it (prepare-vm-disks.sh).
if [ -f "$work_dir/read-boarddata.py" ]; then
    if boarddata="$(python3 "$work_dir/read-boarddata.py" "$synthetic_disk" 2>>"$log_file")"; then
        eval "$boarddata"
        zd_serial="${SERIAL:-$zd_serial}"
        zd_mac1="${MAC:-$zd_mac1}"
        zd_mac2="${MAC2:-$zd_mac2}"
        echo "board data: serial=$zd_serial MAC1=$zd_mac1 MAC2=$zd_mac2" >>"$log_file"
    else
        echo "warning: no board data read from $synthetic_disk; using the derived identity" >>"$log_file"
    fi
fi

# macvlan: obtain the container's LAN IP from the DHCP server.  The macvlan
# network carries no useful Docker-assigned address (Docker only pools a
# vestigial subnet; udhcpc's deconfig flushes it), so udhcpc keeps retrying
# in the background until the LAN grants a lease - which also gives mDNS
# multicast a real L2 path.
#
# The lease sniffer below matters in bridge mode too: the LXC guest is a normal
# bridge port with its own MAC and still takes its address from the LAN's DHCP
# server, so the same broadcast-reply observation is how the container learns
# the guest's dynamic address.
if [ "${NETWORK_MODE:-user}" = macvtap ] || [ "${NETWORK_MODE:-user}" = bridge ]; then
    # In host-netns mode eth0 is the host's own interface and already carries
    # the host's IP; running udhcpc on it would try to re-lease and could
    # disturb the host's connectivity.  Skip it unless explicitly asked.
    if [ "${NETWORK_MODE:-user}" = macvtap ] && [ "${ZD_HOST_NET:-0}" != "1" ]; then
        udhcpc -i eth0 -b -q -p /var/run/udhcpc.pid >>"$log_file" 2>&1 || true
    fi
fi
# Interactive serial console (see launch-vm.sh): the chardev logfile must be
# the SAME file the READY detect + healthcheck grep, and the socket path is where
# you attach to the guest's /dev/console login (set ZD_CONSOLE=0 to disable).
# Everything that wanted the container's own address is finished; release it for
# as long as QEMU runs.
ct_address down
# The emulator is a grandchild of this shell: launch-vm.sh (=$qemu_pid) runs
# qemu-once.py, which runs qemu-system-i386.  /proc/<pid>/stat's utime+stime are
# a process's own CPU time and exclude its children, so sampling $qemu_pid reads
# ~0% however hard QEMU works.  The ZD_CPU_GUARD supervisor therefore samples the
# pid qemu-once.py publishes here: rewritten on every launch (launch-vm.sh
# relaunches QEMU after each guest reset) and removed when that QEMU exits.
qemu_pid_file="${ZD_QEMU_PID_FILE:-$state_dir/qemu.pid}"
read_emulator_pid() {
    # Print the published emulator pid, or nothing when it cannot be trusted:
    # no file, unparsable content, a pid that is not running, or a pid the kernel
    # has since handed to another process.  qemu-once.py starts the emulator as
    # qemu-system-i386, so its cmdline is what identifies it; without that check
    # a recycled pid would be sampled as if it were QEMU.
    local pid=""
    [ -r "$qemu_pid_file" ] || return 1
    read -r pid < "$qemu_pid_file" || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    (( pid > 1 )) || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    case "$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" in
        *qemu-system-*) printf '%s' "$pid" ;;
        *) return 1 ;;
    esac
}
# A file left behind by a hard-killed container must not outlive it.
rm -f "$qemu_pid_file" 2>/dev/null || true
# ZD_CONTROL_SOCK is the one that looks redundant and is not.  launch-vm.sh
# creates the QEMU ttyS1 chardev at that path, and this script and the address
# helper connect to the same path.  Without the pass-through QEMU uses its
# built-in default while every client uses the per-instance path that
# install-zd1200-docker.sh writes into compose, so BOTH the guest address query
# and the orderly-stop reboot are lost silently -- measured on the Docker flow,
# whose console printed the static GUEST_IP and whose stop could not reboot the
# guest.  The single-instance default is unchanged, because both sides default
# to the same path.
setsid env KERNEL="$patched_kernel" \
    INITRD="" \
    DISK_IMAGE="$synthetic_disk" DISK_FORMAT=raw DISK_CACHE=writeback SNAPSHOT="$vm_snapshot" PACE_GUEST=0 \
    ACCEL="$vm_accel" \
    STATE_DIR="$state_dir" \
    ZD_QEMU_PID_FILE="$qemu_pid_file" \
    SYNTHETIC_DISK="$synthetic_disk" \
    WORK="$state_dir/.rootfs-patch-work" \
    ZD_SERIAL="$zd_serial" \
    ZD_MAC1="$zd_mac1" \
    ZD_MODEL="${ZD_MODEL:-ZD1200}" \
    ZD_CUSTOMER="${ZD_CUSTOMER:-ruckus}" \
    ZD_SIGN_CERT_DIR="${ZD_SIGN_CERT_DIR:-/opt/zd1200/signing-cert}" \
    HTTP_PORT="$http_port" \
    HTTPS_PORT="$https_port" \
    NETWORK_MODE="$network_mode" \
    EXTRA_HOSTFWD="$(printf '%s' "${EXTRA_HOSTFWD:-}")" \
    TAP_IF="${TAP_IF:-tap-zd}" \
    ZD_MAC1="$zd_mac1" \
    ZD_MAC2="$zd_mac2" \
    ZD_CONSOLE="${ZD_CONSOLE:-1}" \
    ZD_CONSOLE_LOG="$log_file" \
    ZD_CONSOLE_SOCK="${ZD_CONSOLE_SOCK:-/tmp/zd1200-console.sock}" \
    ZD_CONSOLE_QEMU_SOCK="${ZD_CONSOLE_QEMU_SOCK:-}" \
    ZD_CONTROL_SOCK="${control_sock:-/tmp/zd1200-control.sock}" \
    nice -n 10 ./launch-vm.sh \
    >>"$log_file" 2>&1 </dev/null &
qemu_pid=$!

sleep 3

# CPU_LIMIT is gone, and a setting left in an operator's /etc/zd1200.conf must
# not be ignored silently: say what happened, once, and act on none of it.
#
# It was a SIGSTOP/SIGCONT duty-cycle cap (scripts/container/limit-process-cpu.py
# stopped the target for 40ms out of every 100ms).  As written it throttled the
# launch-vm.sh wrapper, which owns none of QEMU's CPU -- measured: the wrapper
# accumulated 1 tick of its own over 3s while its child ran at ~100% of a core --
# so it protected nothing.  Re-pointed at the emulator itself it would stop the
# emulator, which under TCG freezes the emulated block device and wedges the
# vendor guest on "write_kflag: *** Write to CF card failed, device /dev/sda2 not
# ready ***" before it ever reaches READY.  The knob is either inert or harmful,
# so it is removed rather than re-pointed.  ZD_CPU_GUARD below is the CPU
# backstop for a KVM-accelerated guest (under TCG a busy emulator core is
# normal -- see the arming block), and it stops a genuinely saturated emulator
# rather than throttling a healthy one -- but it samples only after the guest has
# reached READY, so during startup the readiness deadline is the only bound.
if [ -n "${CPU_LIMIT:-}" ]; then
    echo "warning: CPU_LIMIT is set but no longer supported: nothing is capped, and ZD_CPU_GUARD is the CPU backstop. Remove CPU_LIMIT from /etc/zd1200.conf." >&2
fi
case "$cpu_guard" in
    0|off|none) cpu_guard="" ;;
esac
# Whether the trip is armed is a property of the guest's accelerator, not of the
# setting.  The metric is "the emulator held a full core", and the headroom that
# makes a full core abnormal is a property of the HOST: measured across this
# project's own matrix (three releases, both flows), this guest settles at ~4% of
# one core on the bare-metal PVE node and ~50-60% on the nested test host under
# KVM, and at 27-32% under TCG.  A TCG guest is nonetheless not armed: a TCG boot
# crosses 95% in its own right (profiling an arm from launch at this loop's own 5s
# cadence caught three consecutive samples at 141/160/125% -- above one core
# because of -smp 2, ~21s, pid 16984, and that arm's window, which opens at READY,
# saw none of it), the sampling window below opens when the guest's own web service
# answers, and TCG is the fallback path where stopping a healthy boot is the
# expensive failure.  That decision is unchanged; arming under TCG is unmeasured.
# Under TCG the loop still samples and records, it just never stops QEMU.
cpu_guard_armed=0
if [ -n "$cpu_guard" ]; then
    if ! [[ "$cpu_guard" =~ ^[0-9]+$ ]] || (( cpu_guard < 1 )); then
        echo "ZD_CPU_GUARD must be a positive integer, or 0/off/none to disable." >&2
        exit 2
    fi
    if [ "$vm_accel" = kvm ]; then
        cpu_guard_armed=1
        echo "High-CPU watchdog: stopping QEMU after ${cpu_guard} samples (${cpu_guard}x5s) above 95% CPU."
    else
        echo "High-CPU watchdog: not armed, because this guest runs under TCG: a TCG boot crosses 95% of one core on its own (measured 141/160/125% over three consecutive 5s samples), the sampling window opens when the guest's web service answers, and TCG is the fallback path where stopping a healthy boot is the expensive failure. Steady-state TCG CPU (27-32%) is not the reason. Samples are still recorded. See \"What the CPU guard is now for\" in docs/TROUBLESHOOTING.md." >&2
    fi
fi

echo "ZD1200 is starting; waiting for the web service..."
wait_seconds="${WEB_WAIT_SECONDS:-${WEB_WAIT_LOOPS:-180}}"
if ! [[ "$wait_seconds" =~ ^[0-9]+$ ]] || (( wait_seconds < 1 )); then
    echo "WEB_WAIT_SECONDS must be a positive integer." >&2
    exit 2
fi
echo "Startup runs at full speed and has a ${wait_seconds}s readiness deadline."
refreshed_guest_ip() {
    # Ask the guest (or read its cached answer).  It may lease after startup, and
    # it may renew onto a different address.
    #
    # The guest is asked even when GUEST_IP is set: in the Docker flow Compose
    # always sets one (docker/docker-compose.yml, default 192.168.50.10), so
    # treating it as an answer is what printed a URL for an address the guest
    # never had.  GUEST_IP is the fallback -- an operator pin, or the address as
    # configured when the helper is absent (an older image) or the guest does
    # not answer.  Failure here changes nothing about readiness: no new trap, no
    # abort, and the value is only printed.
    local answer=""
    if [ -x "$address_helper" ]; then
        answer="$("$address_helper" --ask 2>/dev/null || true)"
    fi
    if [ -n "$answer" ]; then
        guest_ip="$answer"
        # The helper answered: this is the guest's own address, not the
        # configured fallback.  The display-path retry below uses this to tell
        # "no answer yet" from "an answer that happens to equal GUEST_IP".
        address_answered=1
    else
        guest_ip="${GUEST_IP:-}"
        address_answered=0
    fi
}
if [ "$network_mode" = tap ] || [ "$network_mode" = macvtap ] || [ "$network_mode" = bridge ]; then
    # No lease means no address to probe yet; the loop waits for one.
    probe_base=""
else
    probe_base="https://127.0.0.1:$https_port"
fi
# A macvlan parent does not loop broadcasts back to its own port, so an
# macvtap guest (a sibling macvlan on the same parent) is NOT reachable from
# this container by its LAN IP: curling $guest_ip would always time out.  In
# macvtap mode detect readiness from the guest's serial console instead, which
# this entrypoint writes to $log_file.  Other modes keep the HTTP probe.
# The guest announces readiness itself, on the console the appliance prints to:
# "System go into READY status."  That is the authority in every mode -- it needs
# no address, and a container that cannot yet see a lease still knows the
# controller came up.  Downloading an address is a *display* concern (the URL) and
# must never gate readiness: doing so once made a healthy guest look dead and the
# readiness deadline restart it.
probe_method=console
ready_marker="System go into READY status."
deadline=$((SECONDS + wait_seconds))
next_notice=$((SECONDS + 30))
while (( SECONDS < deadline )); do
    if [ "$probe_method" = console ]; then
        # The guest's own announcement, written to $log_file by the console
        # chardev.  No address is involved, so no lease or DHCP state can make a
        # healthy controller look absent.
        if rg -qF "$ready_marker" "$log_file" 2>/dev/null; then
            # Best effort, for the printed URL only: ask the guest for its
            # address.  A failure here changes nothing about readiness.
            #
            # The console marker arrives BEFORE the guest's control hook is
            # listening: the appliance prints READY and only afterwards starts
            # its remaining init scripts, of which the hook is one.  A single
            # ask at the marker therefore finds nothing and the static GUEST_IP
            # is printed instead -- measured on the Docker flow on six releases
            # in a row, while the same ask answered correctly a minute later.
            # The stop path has always retried for exactly this reason (see
            # send_guest_reboot); this is the display-path equivalent, bounded
            # so it can never hold the container up, and only entered when there
            # is a helper to ask and an address still missing.
            refreshed_guest_ip
            # 90s, not a token few: the hook is not listening at the marker and
            # was measured answering about a minute later, so a short window
            # would only sometimes work.  A guest whose hook never starts leaves
            # the static fallback printed, exactly as before.
            ip_wait="${ZD_ADDRESS_WAIT:-90}"
            case "$ip_wait" in ""|*[!0-9]*) ip_wait=90 ;; esac
            ip_deadline=$((SECONDS + ip_wait))
            while [ "${address_answered:-0}" = 0 ] && [ -x "$address_helper" ] \
                  && (( SECONDS < ip_deadline )); do
                sleep 2
                refreshed_guest_ip
            done
            ready_ip="${guest_ip:-}"
            # `/` redirects into the release's own admin tree (9.x `/admin`,
            # 10.x `/admin10`), so this printed URL works on every release.
            ready_url="https://$ready_ip/"
            ready_kind="web service"
            echo "ZD1200 $ready_kind is ready (guest console reported: '$ready_marker')."
            if [ -n "$ready_ip" ]; then
                echo "HTTPS: $ready_url"
            else
                echo "The guest has not reported an address yet; it takes one from your"
                echo "LAN's DHCP server. Check later with:"
                echo "  $address_helper"
            fi
            if [ "$vm_accel" = kvm ]; then
                echo "Hardware acceleration: KVM"
            fi
            echo "Press Ctrl-C to stop the virtual ZoneDirector."
            ready=1
            break
        fi
    else
        http_status="$(curl -ksS --max-time 3 -o /tmp/zd1200-login.html \
            -w '%{http_code}' \
            "$probe_base/admin10/login.jsp" \
            2>/dev/null || true)"
        if { [ "$http_status" = 302 ] && rg -q 'wizard\.jsp' /tmp/zd1200-login.html; } \
            || { [ "$http_status" = 200 ] \
                && [ "$(wc -c < /tmp/zd1200-login.html)" -gt 1000 ] \
                && ! rg -q '~(SystemName|Username|GP_Login)~' /tmp/zd1200-login.html; }; then
            if [ "$http_status" = 302 ] || rg -q 'form-wizard|Setup Wizard' /tmp/zd1200-login.html; then
                # Seeing HTML is insufficient: the stock factory session has an
                # empty CID, while its AJAX modules still enforce a CSRF match.
                # Confirm that our factory-only compatibility patch reaches the
                # backend before inviting the user to complete the wizard.
                cookie_jar="/tmp/zd1200-web-cookie.$qemu_pid"
                factory_reply="/tmp/zd1200-factory-probe.$qemu_pid.xml"
                curl -ksS --max-time 5 -c "$cookie_jar" -b "$cookie_jar" \
                    -o /dev/null "$probe_base/admin10/wizard.jsp" 2>/dev/null || true
                curl -ksS --max-time 8 -c "$cookie_jar" -b "$cookie_jar" \
                    -H 'X-Requested-With: XMLHttpRequest' \
                    -H 'X-Rico-Version: 1.1.2' -H 'X-CSRF-Token;' \
                    -H 'Content-Type: text/xml' \
                    --data-binary '<ajax-request action="getconf" comp="system" updater="readiness-probe"/>' \
                    -o "$factory_reply" "$probe_base/admin10/_conf.jsp" 2>/dev/null || true
                if ! rg -q '<ajax-response>.*<system>' "$factory_reply" 2>/dev/null; then
                    rm -f "$cookie_jar" "$factory_reply"
                    sleep 1
                    continue
                fi
                rm -f "$cookie_jar" "$factory_reply"
                ready_url="$probe_base/admin10/wizard.jsp"
                ready_kind="factory setup wizard"
            else
                ready_url="$probe_base/admin10/login.jsp"
                ready_kind="login page"
            fi
            echo "ZD1200 $ready_kind is ready:"
            if [ "$network_mode" = tap ] || [ "$network_mode" = macvtap ] || [ "$network_mode" = bridge ]; then
                [ -n "$guest_ip" ] && echo "HTTPS: $ready_url"
            else
                echo "HTTP:  http://127.0.0.1:$http_port/"
                echo "HTTPS: $ready_url"
            fi
            if [ "$vm_accel" = kvm ]; then
                echo "Hardware acceleration: KVM"
            fi
            echo "Press Ctrl-C to stop the virtual ZoneDirector."
            ready=1
            break
        fi
    fi
    if ! kill -0 "$qemu_pid" 2>/dev/null; then
        echo "QEMU exited before the web service became ready." >&2
        tail -160 "$log_file" >&2
        exit 1
    fi
    if (( SECONDS >= next_notice )); then
        echo "Still initializing ($((SECONDS - started_at))s elapsed since launch)..."
        next_notice=$((next_notice + 30))
    fi
    sleep 1
done

if (( ready == 0 )); then
    echo "Timed out waiting for the web service." >&2
    tail -160 "$log_file" >&2
    exit 1
fi

# Keep supervising the VM instead of blocking in wait(1).  The old claim here --
# that the embedded kernel "should idle with HLT", so full-core use means a spin
# loop -- is false: measured across this project's matrix, this guest settles at
# ~4% of one core on the bare-metal PVE node and ~50-60% on the nested test host
# under KVM, and at 27-32% under TCG.  (The ~101% for ~410s once attributed to
# TCG here was the vendor's boot-time rootfs integrity check burning system time,
# now skipped by 40-skip-integrity.sh, not a property of the accelerator.)  So the
# >=95% metric is a KVM-only backstop: there a guest near 50% has room to be
# abnormal in, while a healthy TCG boot crosses 95% of its own accord during boot,
# so arming a trip there can only cost a boot.  It is armed only when
# $cpu_guard_armed is 1.
#
# The pid sampled is the emulator's, re-read from $qemu_pid_file on every
# sample: $qemu_pid is the launch-vm.sh wrapper, whose own utime+stime stay at
# ~0% however hard QEMU works, and a guest reset gives the emulator a new pid.
# When no live emulator pid can be read the guard falls back to the wrapper (and
# says so): it cannot fire there, so never let that fallback be silent.
#
# Accounting for the backstop's own necessity, kept whether or not the trip is
# armed: we do not yet know whether it has ever been needed, so that question has
# to be answerable from the archived console log alone.  A launch therefore
# writes greppable "High-CPU watchdog record:" lines describing the emulator it
# sampled -- at a relaunch, before a trip's exit, once the loop has ended, every
# $guard_record_every samples while it is still running, and from the stop
# handler below.  Every line for an emulator_pid is that launch's counters as
# they stood when it was written, so the last one for that pid is the
# authoritative snapshot; an earlier one is a partial answer, never a different
# launch's.
clock_ticks="$(getconf CLK_TCK)"
process_ticks() {
    awk '{print $14 + $15}' "/proc/$1/stat" 2>/dev/null || echo 0
}
guard_peak_cpu=-1        # highest single-sample CPU seen, -1 = no sample yet
guard_samples=0          # samples taken from the emulator of this launch
guard_samples_high=0     # of those, samples at or above 95% CPU
guard_longest_run=0      # longest consecutive run at or above 95%, in samples
guard_would_trip=0       # continuous runs that reached the trip threshold
guard_trips=0            # times QEMU was actually stopped
# How often a running launch records itself: 60 samples is ~5 minutes at the
# loop's fixed 5s cadence, and it is also the bound on how much of a launch an
# abrupt stop can lose.  Not an operator knob -- nothing in the docs offers one.
guard_record_every=60
cpu_guard_record() {
    # $1 = the emulator pid this line accounts for.  Samples are 5s apart by
    # construction, so the longest run is also given in seconds, the way the trip
    # message below counts them.
    (( guard_samples > 0 )) || return 0
    local peak="none"
    (( guard_peak_cpu >= 0 )) && peak="${guard_peak_cpu}%"
    local armed="no"
    [ "$cpu_guard_armed" = 1 ] && armed="$cpu_guard"
    # With the guard disabled there is no threshold, so report the count as
    # inapplicable rather than as a misleading zero.
    local would="n/a"
    [ -n "$cpu_guard" ] && would="$guard_would_trip"
    echo "High-CPU watchdog record: accel=$vm_accel armed=$armed emulator_pid=$1 samples=$guard_samples peak=$peak longest_run=$guard_longest_run samples ($((guard_longest_run * 5))s) samples_above_95=$guard_samples_high would_have_tripped=$would trips=$guard_trips"
}
cpu_guard_reset() {
    guard_peak_cpu=-1
    guard_samples=0
    guard_samples_high=0
    guard_longest_run=0
    guard_would_trip=0
}
cpu_guard_record_current() {
    # $1 = the emulator pid to name in the line, as cpu_guard_record() takes it.
    # The mid-launch record runs from places the loop's own emission points do
    # not reach (a timer, a signal handler), so it repeats their condition here:
    # a line names an emulator, and the wrapper fallback owns none of QEMU's CPU,
    # so recording it would put a false emulator_pid on the line.  The fallback
    # therefore stays unrecorded, exactly as it is after the loop.
    [ "$sampled_emulator" = 1 ] || return 0
    cpu_guard_record "$1"
}
sample_pid=""
sampled_emulator=0
previous_ticks=0
previous_sample=$SECONDS
# The periodic line in the loop bounds what a stop loses to ~5 minutes; recording
# from the signal handler closes it for the ordinary stop.  The TERM trap set
# near the top of the script only runs cleanup(), which cannot record: it is
# defined long before these counters exist, so it is re-issued here rather than
# chained into a handler that has no guard state to read.  Measured: bash runs
# this handler as soon as the signal is delivered -- it interrupts the loop's
# sleep 5 and the loop then resumes -- so the line is written before cleanup()'s
# long wait, which is exactly where the runtime's SIGKILL lands.  The handler
# still ends with the same cleanup call the original trap made, and cleanup()
# ignores the signal while it runs (its first line clears EXIT/INT/TERM), so no
# exit status can change.  The record is failure-tolerant because set -e does
# apply inside a trap action -- measured, a command that fails there ends the
# whole shell -- and the status of a stop must not depend on a log line.  A TERM
# after the loop repeats the final line for the same pid, which the "last line
# for a pid wins" rule already covers.
trap 'cpu_guard_record_current "$sample_pid" || true; cleanup 1' INT TERM

# --- the container-side guest watchdog --------------------------------------
# The CPU guard below notices a guest that is pinning a core, and only on a KVM
# host: under TCG a busy emulator core is normal, so it deliberately never arms.
# That leaves the Docker flow with nothing that notices a guest which has gone
# quiet while QEMU still runs -- its HEALTHCHECK greps the console log for a
# READY line that stays in the file forever once boot succeeded, so it cannot
# fail after boot, and the LXC flow's systemd unit (zd1200-watchdog.service) has
# no Docker equivalent because there is no systemd here.  This runs that same
# watchdog as a supervised child instead: it probes the guest over the control
# channel and, after a run of failures, asks QEMU to reboot it.
#
# Where the guest's L2 presence lives differs from LXC: there is no br-zd here,
# the guest is a macvtap neighbour of the host's uplink, so the watchdog is told
# to look in that interface's neighbour table (ZD_WATCHDOG_LINK_KIND=iface).
# ZD_GUEST_WATCHDOG=0 disables it, as it does in the LXC flow.
watchdog_pid=""
# ZD_GUEST_WATCHDOG_CHILD=0 means this flow already supervises the watchdog
# itself: the LXC flow runs it as zd1200-watchdog.service, and a second copy
# here would probe the guest with the wrong flow's L2 lookup (this block's
# iface/eth0 macvtap shape instead of the bridge/br-zd one), share
# $STATE_FILE with the real one, and duplicate the recovery.  An explicit key
# rather than a test for /run/systemd/system, so the Docker flow cannot change
# behaviour by gaining a systemd it did not have.
if [ "${ZD_GUEST_WATCHDOG_CHILD:-1}" = "0" ]; then
    echo "Guest watchdog: not started here; this flow supervises it (ZD_GUEST_WATCHDOG_CHILD=0)."
elif [ "${ZD_GUEST_WATCHDOG:-1}" != "0" ] && [ -x "$work_dir/zd1200-guest-watchdog" ]; then
    setsid env \
        ZD_GUEST_WATCHDOG_INTERVAL="${ZD_GUEST_WATCHDOG_INTERVAL:-60}" \
        ZD_GUEST_WATCHDOG_FAILURES="${ZD_GUEST_WATCHDOG_FAILURES:-5}" \
        ZD_GUEST_WATCHDOG_COOLDOWN="${ZD_GUEST_WATCHDOG_COOLDOWN:-900}" \
        ZD_WATCHDOG_LINK_KIND="${ZD_WATCHDOG_LINK_KIND:-iface}" \
        ZD_WATCHDOG_GUEST_LINK="${ZD_WATCHDOG_GUEST_LINK:-eth0}" \
        ZD_MAC1="$zd_mac1" \
        ZD_CONTROL_SOCK="$control_sock" \
        STATE_DIR="$state_dir" \
        ZD_WATCHDOG_LOG="$log_file" \
        ZD_HEALTHCHECK_HELPER="${ZD_HEALTHCHECK_HELPER:-$work_dir/zd1200-guest-healthcheck}" \
        ZD_ADDRESS_HELPER="${ZD_ADDRESS_HELPER:-$address_helper}" \
        "$work_dir/zd1200-guest-watchdog" &
    # No redirect on that last line, deliberately: the watchdog writes its own
    # copy into $log_file (the correlated boot record, which the launcher
    # transcript and the board-data line are already part of), and piping its
    # stdout there as well -- which this used to do -- put every line in the
    # guest's record twice.  Its stdout stays on this process's, i.e. docker logs.
    watchdog_pid=$!
    echo "Guest watchdog: probing ${ZD_GUEST_WATCHDOG_INTERVAL:-60}s, ${ZD_GUEST_WATCHDOG_FAILURES:-5} failures before a reboot (pid $watchdog_pid)."
else
    if [ "${ZD_GUEST_WATCHDOG:-1}" = "0" ]; then
        echo "Guest watchdog: disabled by ZD_GUEST_WATCHDOG=0."
    else
        echo "Guest watchdog: not available ($work_dir/zd1200-guest-watchdog missing)." >&2
    fi
fi

while kill -0 "$qemu_pid" 2>/dev/null; do
    sleep 5
    current_sample=$SECONDS
    target_pid="$(read_emulator_pid || true)"
    if [ -n "$target_pid" ]; then
        target_is_emulator=1
    else
        target_pid="$qemu_pid"
        target_is_emulator=0
    fi
    if [ "$target_pid" != "$sample_pid" ]; then
        # A different process than the last sample: the pid file has just been
        # written, a guest reset relaunched QEMU, or the emulator pid cannot be
        # read.  The old tick count belongs to the old process, so start a fresh
        # sample rather than subtracting across two of them.  Account for the
        # launch that just ended first -- its record is complete, and a new pid
        # must not add to it -- and always start the counters over, including
        # when that was only the wrapper fallback.
        if [ "$sampled_emulator" = 1 ]; then
            cpu_guard_record "$sample_pid"
        fi
        cpu_guard_reset
        if [ "$target_is_emulator" = 0 ]; then
            echo "High-CPU watchdog warning: no live emulator pid in $qemu_pid_file; falling back to the launch-vm.sh wrapper pid $qemu_pid, whose own CPU time excludes QEMU's -- the watchdog cannot fire while that is the sample." >&2
        elif [ "$sampled_emulator" = 0 ]; then
            echo "High-CPU watchdog: sampling the emulator pid $target_pid from $qemu_pid_file." >&2
        else
            echo "High-CPU watchdog: emulator pid changed to $target_pid; starting a fresh sample." >&2
        fi
        sample_pid="$target_pid"
        sampled_emulator="$target_is_emulator"
        previous_ticks="$(process_ticks "$sample_pid")"
        previous_sample="$current_sample"
        high_cpu_samples=0
        continue
    fi
    current_ticks="$(process_ticks "$sample_pid")"
    sample_seconds=$((current_sample - previous_sample))
    (( sample_seconds > 0 )) || sample_seconds=1
    cpu=$(( (current_ticks - previous_ticks) * 100 / clock_ticks / sample_seconds ))
    previous_ticks="$current_ticks"
    previous_sample="$current_sample"
    if (( cpu >= 95 )); then
        high_cpu_samples=$((high_cpu_samples + 1))
        guard_samples_high=$((guard_samples_high + 1))
        (( high_cpu_samples > guard_longest_run )) && guard_longest_run="$high_cpu_samples"
        # The threshold is what a trip fires on; count it once per continuous
        # run so "would have fired" stays comparable to "did fire".
        if [ -n "$cpu_guard" ] && (( high_cpu_samples == cpu_guard )); then
            guard_would_trip=$((guard_would_trip + 1))
        fi
    else
        high_cpu_samples=0
    fi
    guard_samples=$((guard_samples + 1))
    (( cpu > guard_peak_cpu )) && guard_peak_cpu="$cpu"
    # Record the launch while it is still running, not only when it ends.  On a
    # normal container stop the outer SIGTERM is followed by SIGKILL once the
    # runtime's stop timeout expires, and cleanup() can be inside its graceful
    # shutdown wait for ZD_STOP_TIMEOUT (240s by default) when that lands, so the
    # record after the loop is routinely lost -- and under TCG, where nothing
    # trips, this line is the only evidence the guard would have fired at all.
    # It reports the counters exactly as they stand: no reset, no double count.
    if (( guard_samples % guard_record_every == 0 )); then
        cpu_guard_record_current "$sample_pid"
    fi
    if [ "$cpu_guard_armed" = 1 ] && (( high_cpu_samples >= cpu_guard )); then
        echo "QEMU stayed above 95% CPU for $((cpu_guard * 5)) seconds; stopping it to protect the host." >&2
        guard_trips=$((guard_trips + 1))
        cpu_guard_record "$sample_pid"
        exit 3
    fi
done
# The loop is over (the guest powered off or the wrapper exited): record the
# launch that was still in progress, if one was being sampled.
if [ "$sampled_emulator" = 1 ]; then
    cpu_guard_record "$sample_pid"
fi

qemu_rc=0
wait "$qemu_pid" 2>/dev/null || qemu_rc=$?
if [ "$qemu_rc" -eq "$RET_RESCUE_ACTIVE" ]; then
    echo "The saved GRUB entry is a rescue entry; stopping the container." >&2
    if [ "${ZD_POWEROFF_CONTAINER:-0}" = 1 ]; then stop_container=1; fi
    exit 0
fi
if [ "$qemu_rc" -eq 0 ]; then
    echo "Guest powered off; stopping the container."
    # Under Compose this exit is the container's, and restart: on-failure leaves a
    # clean exit stopped.  The LXC flow runs this entrypoint as zd1200.service
    # inside the container, where exiting would leave the container up with no
    # appliance in it, so the EXIT trap shuts the container down as well.
    if [ "${ZD_POWEROFF_CONTAINER:-0}" = 1 ]; then
        stop_container=1
    fi
    exit 0
fi
echo "QEMU exited (status $qemu_rc)." >&2
exit 1
