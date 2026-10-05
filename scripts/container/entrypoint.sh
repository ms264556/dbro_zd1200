#!/usr/bin/env bash
# The container's entrypoint (Docker: the Compose command; LXC: zd1200.service).
# Not for running by hand on the host: use install-zd1200-docker.sh or
# install-zd1200-lxc.sh.
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
http_port="${HTTP_PORT:-38080}"
https_port="${HTTPS_PORT-38443}"
network_mode="${NETWORK_MODE:-user}"
# The host interface the guest attaches to (the macvtap's parent in the Docker
# flow, the uplink in the LXC flow).  eth0 when the host has one; otherwise, for
# macvtap, whichever interface carries the default route.
if [ -z "${ZD_HOST_IF:-}" ] && [ "$network_mode" = macvtap ] && [ ! -e /sys/class/net/eth0 ]; then
    ZD_HOST_IF="$(ip -o route show default 2>/dev/null \
        | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
fi
export ZD_HOST_IF="${ZD_HOST_IF:-eth0}"
# The guest's address is whatever it leased, so it is asked over the control
# channel (zd1200-guest-address).  GUEST_IP is only a fallback for the printed
# URL -- Compose always sets one -- and never something to probe: an address
# that is not the guest's would make a healthy guest look dead.
guest_ip="${GUEST_IP:-}"
# 1 once the helper has answered: see refreshed_guest_ip and the display retry.
address_answered=0
address_helper="${ZD_ADDRESS_HELPER:-$work_dir/zd1200-guest-address}"
state_dir="${STATE_DIR:-$work_dir}"
# The vendor artifacts (rootfs.ext2, bzImage, menu.lst, ...).  Relative to this
# script, not the working directory.  Docker mounts it read-only from the host's
# image/; the LXC flow symlinks it to the state dir.
image_dir="${IMAGE_DIR:-$work_dir/image}"
synthetic_disk="${SYNTHETIC_DISK:-$state_dir/synthetic-cf.img}"
vm_snapshot="${VM_SNAPSHOT:-0}"
# Consecutive >95% CPU samples (5s each) before the supervisor stops QEMU.
# The 2.6.32 guest can legitimately spin during TCG boot/keygen phases, which
# false-triggers this watchdog; set 0/off/none to disable it.
cpu_guard="${ZD_CPU_GUARD:-4}"
# How long a stop waits for the guest to flush and power off, in whole seconds.
# Anything else would break the wait loop's arithmetic and skip the wait silently.
case "${ZD_STOP_TIMEOUT:-240}" in
    ''|*[!0-9]*)
        echo "ZD_STOP_TIMEOUT='${ZD_STOP_TIMEOUT}' is not a whole number of seconds; using 240." >&2
        stop_timeout=240 ;;
    *) stop_timeout="${ZD_STOP_TIMEOUT:-240}" ;;
esac
# ACCEL as launch-vm.sh reads it: `auto` probes /dev/kvm; `kvm`/`tcg` force one,
# for a host whose /dev/kvm is usable but whose guest must run emulated.
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

# LXC only (zd1200-ct-address; a no-op under Docker): the container's own LAN
# address is for maintenance, and with ZD_CT_ADDRESS_FOLLOW_QEMU=1 it is released
# while QEMU runs and re-leased when QEMU exits, so only the appliance is on the
# LAN while it runs.
ct_address_helper="${ZD_CT_ADDRESS_HELPER:-/usr/local/sbin/zd1200-ct-address}"
# Default on: the guest shares the container's uplink MAC, so a conf without the
# key must not keep an address under that MAC.
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
            # The guest's control hook starts late in its init, so a request
            # sent just after boot can be lost: send now and again every 5 s
            # until QEMU exits.
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
            # ZD_STOP_TIMEOUT is in seconds; the loop ticks every half second.
            for _ in $(seq 1 "$(( stop_timeout * 2 ))"); do
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
    # The macvtap lives in the host's network namespace (network_mode: host), so
    # nothing else removes it; left behind, it keeps the dead guest's MAC.
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
# A stop must end the script: cleanup clears the traps and returns, and a TERM
# that lands before QEMU exists (during disk preparation) would otherwise go on
# to launch a guest that nothing could stop cleanly any more.
trap 'cleanup 1; exit 0' INT TERM
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
# The guest boots the kernel on its own disk; nothing is passed to QEMU.
#
# The identity to write when the disk is first built.  Serial and MACs live in
# the board-data records on the disk, which the guest kernel reads; once the
# disk exists, what is on it wins (read back below).  Default: MAC1 =
# ZD_CONTAINER_MAC, MAC2 = MAC1 + 1, serial hashed from MAC1
# (boarddata-from-mac.sh).  ZD_BOARDDATA_FROM_MAC=0 pins ZD_SERIAL/ZD_MAC1.
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
# Build the disk if missing, write the board data, and customise whichever roots
# need it (prepare-vm-disks.sh).
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

# The board data on the disk is authoritative: the guest can change its MAC and
# writes it back there.  Use what is stored for the macvtap and the QEMU NIC.
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

# Only without host networking (ZD_HOST_NET unset): give the container its own
# lease on eth0.  With network_mode: host, eth0 is the host's and is left alone.
if [ "${NETWORK_MODE:-user}" = macvtap ] || [ "${NETWORK_MODE:-user}" = bridge ]; then
    # In host-netns mode eth0 is the host's own interface and already carries
    # the host's IP; running udhcpc on it would try to re-lease and could
    # disturb the host's connectivity.  Skip it unless explicitly asked.
    if [ "${NETWORK_MODE:-user}" = macvtap ] && [ "${ZD_HOST_NET:-0}" != "1" ]; then
        udhcpc -i eth0 -b -q -p /var/run/udhcpc.pid >>"$log_file" 2>&1 || true
    fi
fi
# Everything that needed the container's own address is done; release it for as
# long as QEMU runs.
ct_address down
# The emulator is a grandchild (launch-vm.sh -> qemu-once.py -> qemu-system-i386)
# and /proc/<pid>/stat excludes children, so the CPU guard samples the pid
# qemu-once.py publishes here on every launch.
qemu_pid_file="${ZD_QEMU_PID_FILE:-$state_dir/qemu.pid}"
read_emulator_pid() {
    # The published pid, or nothing if it cannot be trusted: no file, not a
    # number, not running, or recycled (its cmdline is not qemu-system-i386).
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
# ZD_CONTROL_SOCK must be passed through: launch-vm.sh binds ttyS1's chardev
# there and this script and the helpers connect to it.  Without it QEMU uses its
# default path while the clients use the per-instance one, and the address query
# and the orderly stop both fail silently.
setsid env \
    ZD_PREPARED=1 \
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

# CPU_LIMIT was a SIGSTOP duty-cycle cap.  Stopping the emulator stalls the
# guest's block I/O and it never reaches READY, so the knob is gone; a leftover
# setting is reported once and ignored.
if [ -n "${CPU_LIMIT:-}" ]; then
    echo "warning: CPU_LIMIT is set but no longer supported: nothing is capped, and ZD_CPU_GUARD is the CPU backstop. Remove CPU_LIMIT from /etc/zd1200.conf." >&2
fi
case "$cpu_guard" in
    0|off|none) cpu_guard="" ;;
esac
# Armed only under KVM.  A healthy TCG boot holds >95% of a core for tens of
# seconds, so a trip there would stop a good guest; under TCG the loop records
# samples and never stops QEMU.  Figures: docs/TROUBLESHOOTING.md.
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
        echo "High-CPU watchdog: not armed under TCG, where a healthy boot exceeds 95% of a core for tens of seconds; samples are still recorded. See \"CPU guard\" in docs/TROUBLESHOOTING.md." >&2
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
    # Ask the guest.  GUEST_IP is only the fallback when there is no helper or no
    # answer; Compose always sets it, so it is never taken as the answer.  Only
    # the printed URL depends on this.
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
# Readiness is the guest's own console line.  It needs no address, so a guest
# with no lease yet is still seen to be up.
ready_marker="System go into READY status."
deadline=$((SECONDS + wait_seconds))
next_notice=$((SECONDS + 30))
while (( SECONDS < deadline )); do
    # The guest's own announcement, written to $log_file by the console
    # chardev.  No address is involved, so no lease or DHCP state can make a
    # healthy controller look absent.
    if rg -qF "$ready_marker" "$log_file" 2>/dev/null; then
        # For the printed URL only.  The READY line comes before the guest's
        # control hook is listening, so keep asking for a bounded time.
        refreshed_guest_ip
        # The hook was seen answering about a minute after READY.
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

# The CPU guard: sample the emulator's utime+stime every 5 s and, when armed,
# stop QEMU after $cpu_guard consecutive samples at >= 95% of a core.  The pid
# is re-read from $qemu_pid_file each sample because a guest reset relaunches
# the emulator; with no live pid the guard samples the wrapper, which cannot
# trip, and says so.
#
# Each launch also writes "High-CPU watchdog record:" lines -- at a relaunch,
# before a trip, when the loop ends, every $guard_record_every samples and from
# the stop handler -- holding that launch's counters so far.  The last line for
# an emulator_pid is the authoritative one.
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
    # $1 = the emulator pid.  Nothing is recorded while the wrapper fallback is
    # being sampled: the line would name a pid that owns none of QEMU's CPU.
    [ "$sampled_emulator" = 1 ] || return 0
    cpu_guard_record "$1"
}
sample_pid=""
sampled_emulator=0
previous_ticks=0
previous_sample=$SECONDS
# Record from the stop handler too: the runtime's SIGKILL usually lands inside
# cleanup()'s wait, before the post-loop record.  `|| true` because set -e
# applies inside a trap action and a stop must not fail on a log line.
trap 'cpu_guard_record_current "$sample_pid" || true; cleanup 1; exit 0' INT TERM

# --- the guest watchdog (Docker) ---------------------------------------------
# Probes the guest over the control channel and, after a run of failures,
# reboots it (zd1200-guest-watchdog).  The LXC flow runs the same script as
# zd1200-watchdog.service.  Here the guest is a macvtap on the host's uplink,
# so the evidence that it is still on the LAN is that macvtap's transmit counter
# (a neighbour-table lookup would miss a guest that lives on a VLAN).
# ZD_GUEST_WATCHDOG=0 disables it.
watchdog_pid=""
# ZD_GUEST_WATCHDOG_CHILD=0: the flow supervises the watchdog itself (LXC), and
# a second copy here would use the wrong L2 lookup and share its state file.
if [ "${ZD_GUEST_WATCHDOG_CHILD:-1}" = "0" ]; then
    echo "Guest watchdog: not started here; this flow supervises it (ZD_GUEST_WATCHDOG_CHILD=0)."
elif [ "${ZD_GUEST_WATCHDOG:-1}" != "0" ] && [ -x "$work_dir/zd1200-guest-watchdog" ]; then
    # A watchdog started here watches a guest that has not booted yet, so it must
    # begin in its warm-up phase, not resume the state a previous run left.
    rm -f "${ZD_WATCHDOG_RUN_DIR:-/run}/zd1200-watchdog.state"
    # The transmit counter of the guest's macvtap is only there in macvtap mode; in
    # any other launch mode (user-mode networking, a test tap) there is no layer-2
    # evidence to read.
    watchdog_link_kind=macvtap
    [ "${network_mode:-}" = macvtap ] || watchdog_link_kind=none
    setsid env \
        ZD_GUEST_WATCHDOG_INTERVAL="${ZD_GUEST_WATCHDOG_INTERVAL:-60}" \
        ZD_GUEST_WATCHDOG_FAILURES="${ZD_GUEST_WATCHDOG_FAILURES:-5}" \
        ZD_GUEST_WATCHDOG_COOLDOWN="${ZD_GUEST_WATCHDOG_COOLDOWN:-900}" \
        ZD_GUEST_WATCHDOG_SILENT="${ZD_GUEST_WATCHDOG_SILENT:-600}" \
        ZD_WATCHDOG_LINK_KIND="${ZD_WATCHDOG_LINK_KIND:-$watchdog_link_kind}" \
        ZD_WATCHDOG_GUEST_LINK="${ZD_WATCHDOG_GUEST_LINK:-${ZD_MACVTAP_IF:-mvt0}}" \
        ZD_MAC1="$zd_mac1" \
        ZD_CONTROL_SOCK="$control_sock" \
        STATE_DIR="$state_dir" \
        ZD_WATCHDOG_LOG="$log_file" \
        ZD_HEALTHCHECK_HELPER="${ZD_HEALTHCHECK_HELPER:-$work_dir/zd1200-guest-healthcheck}" \
        ZD_ADDRESS_HELPER="${ZD_ADDRESS_HELPER:-$address_helper}" \
        "$work_dir/zd1200-guest-watchdog" &
    # No redirect: the watchdog appends to $log_file itself, so redirecting its
    # stdout there as well would log every line twice.
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
        # A different process than last time (first sample, a relaunch, or no
        # readable pid): close the previous launch's record and start counting
        # afresh rather than subtract ticks across two processes.
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
    # Also record mid-launch: a stop's SIGKILL can land before the post-loop
    # record, and under TCG this line is the only trace the guard leaves.
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
