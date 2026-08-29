#!/usr/bin/env bash
set -euo pipefail

work_dir="$(cd "$(dirname "$0")" && pwd)"
log_file="${LOG_FILE:-/tmp/zd1200-web.log}"
qemu_pid=""
limiter_pid=""
started_at=$SECONDS
high_cpu_samples=0
ready=0
http_status=""
http_port="${HTTP_PORT:-38080}"
https_port="${HTTPS_PORT-38443}"
network_mode="${NETWORK_MODE:-user}"
guest_ip="${GUEST_IP:-192.168.10.20}"
state_dir="${STATE_DIR:-$work_dir}"
synthetic_disk="${SYNTHETIC_DISK:-$state_dir/synthetic-cf.img}"
persistent_disk="${PERSISTENT_DISK:-$state_dir/zd1200-vm.qcow2}"
vm_snapshot="${VM_SNAPSHOT:-0}"
cpu_limit="${CPU_LIMIT:-}"
# Consecutive >95% CPU samples (5s each) before the supervisor stops QEMU.
# The 2.6.32 guest can legitimately spin during TCG boot/keygen phases, which
# false-triggers this watchdog; set 0/off/none to disable it.
cpu_guard="${ZD_CPU_GUARD:-4}"
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    vm_accel=kvm
else
    vm_accel=tcg
fi

cleanup() {
    trap - EXIT INT TERM
    if [[ "$qemu_pid" =~ ^[0-9]+$ ]] && (( qemu_pid > 1 )); then
        if [[ "$limiter_pid" =~ ^[0-9]+$ ]] && (( limiter_pid > 1 )); then
            kill "$limiter_pid" 2>/dev/null || true
            wait "$limiter_pid" 2>/dev/null || true
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
}
trap cleanup EXIT INT TERM

cd "$work_dir" || exit 1
mkdir -p "$state_dir"

if [ ! -f image/bzImage ]; then
    echo "Missing image/bzImage" >&2
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
        --in "$work_dir/image/bzImage" \
        --out "$patched_kernel"
fi
if ! command -v qemu-img >/dev/null 2>&1; then
    echo "qemu-img is required" >&2
    exit 1
fi
if [ ! -f "$synthetic_disk" ]; then
    echo "Creating persistent synthetic CF base image in $state_dir ..."
    SYNTHETIC_DISK="$synthetic_disk" python3 "$work_dir/make-synthetic-cf.py"
fi
# The serial number and MACs live in the board-data records on the CF image
# (read by the kernel's v54bsp driver; NOT patched into the kernel).  Rewrite
# them on every launch so env changes take effect.  MAC2 = MAC1 + 1.
# In macvlan mode the identity is derived from the container's eth0 MAC (the
# MAC Docker allocated on the macvlan network), so every instance is unique on
# the LAN; set ZD_BOARDDATA_FROM_MAC=0 to force fixed ZD_SERIAL/ZD_MAC1.
if [ "${NETWORK_MODE:-user}" = macvtap ] && [ "${ZD_BOARDDATA_FROM_MAC:-1}" != "0" ]; then
    eval "$("$work_dir/boarddata-from-mac.sh")"
    zd_serial="$SERIAL"
    zd_mac1="$MAC"
    zd_mac2="$MAC2"
else
    zd_serial="${ZD_SERIAL:-123456000789}"
    zd_mac1="${ZD_MAC1:-00:0c:e6:12:00:01}"
    zd_mac2="${ZD_MAC2:-}"
fi
python3 "$work_dir/write-boarddata.py" \
    --disk "$synthetic_disk" \
    --serial "$zd_serial" \
    --mac "$zd_mac1" \
    --model "${ZD_MODEL:-ZD1200}" \
    --customer "${ZD_CUSTOMER:-ruckus}"
if [ ! -f "$persistent_disk" ]; then
    qemu-img create -q -f qcow2 -F raw -b "$synthetic_disk" "$persistent_disk"
    echo "Created persistent VM disk overlay: $persistent_disk"
    # Hint #6: the stock sys_init mounts the empty ext2 data volume (hda4) with
    # the ReiserFS-only `nolog` option, which fails on ext2, so /writable never
    # mounts rw and first-boot (certs/web/SSH) never completes.  Apply
    # patch-rootfs.sh to the freshly created overlay, before QEMU opens it.  It
    # runs as an ordinary user (qemu-img flatten + debugfs + qemu-io), so no
    # root/loop/mount is needed; the overlay is patched in place.
    echo "Patching rootfs (nolog) into the VM overlay ..."
    QCOW="$persistent_disk" WORK="$state_dir/.rootfs-patch-work" \
        "$work_dir/patch-rootfs.sh"
    # Bake the image-signing bypass / upgrade entitlement (the license): patches
    # /bin/sys_wrapper.sh (check_sign_cert), writes the patch-storage payload and
    # refreshes /file_list.txt for sys_wrapper.sh.  Runs after patch-rootfs.sh on
    # the same freshly-created overlay, before QEMU opens it.  Needs the signing
    # cert payload mounted at ZD_SIGN_CERT_DIR; warn (don't abort) if it's absent
    # so the guest can still boot, just without the license baked in.
    if [ -f "$work_dir/patch-rootfs-signing.sh" ]; then
        echo "Baking signing bypass / upgrade entitlement into the VM overlay ..."
        # patch-rootfs-signing.sh takes CERT_DIR as $1 (positional) and ignores a
        # CERT_DIR env var — pass it as an argument.
        if QCOW="$persistent_disk" WORK="$state_dir/.rootfs-patch-work" \
            "$work_dir/patch-rootfs-signing.sh" \
            "${ZD_SIGN_CERT_DIR:-/opt/zd1200/signing-cert}"; then
            echo "Signing bypass baked into the VM overlay."
        else
            echo "WARNING: could not bake the signing bypass (cert dir missing?);" >&2
            echo "         the guest will boot WITHOUT the license/upgrade entitlement." >&2
        fi
    fi
fi

: > "$log_file"

# macvlan: obtain the container's LAN IP from the DHCP server.  The macvlan
# network carries no useful Docker-assigned address (Docker only pools a
# vestigial subnet; udhcpc's deconfig flushes it), so udhcpc keeps retrying
# in the background until the LAN grants a lease - which also gives mDNS
# multicast a real L2 path.
if [ "${NETWORK_MODE:-user}" = macvtap ]; then
    # In host-netns mode eth0 is the host's own interface and already carries
    # the host's IP; running udhcpc on it would try to re-lease and could
    # disturb the host's connectivity.  Skip it unless explicitly asked.
    if [ "${ZD_HOST_NET:-0}" != "1" ]; then
        udhcpc -i eth0 -b -q -p /var/run/udhcpc.pid >>"$log_file" 2>&1 || true
    fi
    # The macvlan bridge isolates this container from its macvtap guest, so the
    # container can neither reach nor ARP-scan the guest.  sniff-guest-dhcp.py
    # watches the LAN (eth0) for the DHCP reply addressed to the guest MAC and
    # records the guest's dynamic lease to $state_dir/guest-ip (and the log).
    if [ -f "$work_dir/sniff-guest-dhcp.py" ]; then
        python3 "$work_dir/sniff-guest-dhcp.py" "$zd_mac1" "$state_dir/guest-ip" \
            >>"$log_file" 2>&1 &
    fi
fi
setsid env KERNEL="$patched_kernel" \
    INITRD="" \
    DISK_IMAGE="$persistent_disk" DISK_FORMAT=qcow2 DISK_CACHE=writeback SNAPSHOT="$vm_snapshot" PACE_GUEST=0 \
    ACCEL="$vm_accel" \
    HTTP_PORT="$http_port" \
    HTTPS_PORT="$https_port" \
    NETWORK_MODE="$network_mode" \
    TAP_IF="${TAP_IF:-tap-zd}" \
    ZD_MAC1="$zd_mac1" \
    ZD_MAC2="$zd_mac2" \
    nice -n 10 ./run-zd1200-qemu.sh \
    >>"$log_file" 2>&1 </dev/null &
qemu_pid=$!

sleep 3

# CPU_LIMIT is opt-in for KVM. TCG retains its historical 60% safety cap
# unless CPU_LIMIT is set to 0/off/none (no duty-cycle limiting at all).
if [ -z "$cpu_limit" ] && [ "$vm_accel" = tcg ]; then
    cpu_limit=60
fi
case "$cpu_limit" in
    0|off|none) cpu_limit="" ;;
esac
if [ -n "$cpu_limit" ]; then
    if ! [[ "$cpu_limit" =~ ^[0-9]+$ ]] || (( cpu_limit < 1 || cpu_limit > 95 )); then
        echo "CPU_LIMIT must be an integer from 1 through 95, or 0/off/none to disable." >&2
        exit 2
    fi
    python3 "$work_dir/limit-process-cpu.py" "$qemu_pid" "$cpu_limit" &
    limiter_pid=$!
    echo "QEMU CPU duty cycle capped at ${cpu_limit}% while the VM runs."
fi
case "$cpu_guard" in
    0|off|none) cpu_guard="" ;;
esac
if [ -n "$cpu_guard" ]; then
    if ! [[ "$cpu_guard" =~ ^[0-9]+$ ]] || (( cpu_guard < 1 )); then
        echo "ZD_CPU_GUARD must be a positive integer, or 0/off/none to disable." >&2
        exit 2
    fi
    echo "High-CPU watchdog: stopping QEMU after ${cpu_guard} samples (${cpu_guard}x5s) above 95% CPU."
fi

echo "ZD1200 is starting; waiting for the web service..."
wait_seconds="${WEB_WAIT_SECONDS:-${WEB_WAIT_LOOPS:-180}}"
if ! [[ "$wait_seconds" =~ ^[0-9]+$ ]] || (( wait_seconds < 1 )); then
    echo "WEB_WAIT_SECONDS must be a positive integer." >&2
    exit 2
fi
if [ -n "$cpu_limit" ]; then
    echo "Startup is CPU-limited and has a ${wait_seconds}s readiness deadline."
else
    echo "Startup runs at full speed and has a ${wait_seconds}s readiness deadline."
fi
if [ "$network_mode" = tap ] || [ "$network_mode" = macvtap ]; then
    probe_base="https://$guest_ip"
else
    probe_base="https://127.0.0.1:$https_port"
fi
# A macvlan parent does not loop broadcasts back to its own port, so an
# macvtap guest (a sibling macvlan on the same parent) is NOT reachable from
# this container by its LAN IP: curling $guest_ip would always time out.  In
# macvtap mode detect readiness from the guest's serial console instead, which
# this entrypoint writes to $log_file.  Other modes keep the HTTP probe.
if [ "$network_mode" = macvtap ]; then
    probe_method=console
else
    probe_method=http
fi
ready_marker="System go into READY status."
deadline=$((SECONDS + wait_seconds))
next_notice=$((SECONDS + 30))
while (( SECONDS < deadline )); do
    if [ "$probe_method" = console ]; then
        # macvtap: the guest is a sibling macvlan on the same parent as this
        # container, so it is unreachable by LAN IP from here.  Detect READY
        # from the guest's serial console (written to $log_file) instead.
        if rg -qF "$ready_marker" "$log_file" 2>/dev/null; then
            # Prefer the guest lease learned from the LAN by sniff-guest-dhcp.py
            # (the macvlan bridge isolates this container from its guest).
            if [ -s "$state_dir/guest-ip" ]; then
                ready_ip="$(cat "$state_dir/guest-ip")"
            else
                ready_ip="$guest_ip"
            fi
            ready_url="https://$ready_ip/admin10/login.jsp"
            ready_kind="web service"
            echo "ZD1200 $ready_kind is ready (guest console reported: '$ready_marker')."
            echo "HTTP:  http://$ready_ip/"
            echo "HTTPS: $ready_url"
            if [ "$ready_ip" = "$guest_ip" ]; then
                # No lease observed yet — the guest IP may not match the
                # configured ZD_GUEST_IP; tell the user how to confirm it.
                echo "Note: guest IP is dynamic on DHCP; if $guest_ip is not its lease,"
                echo "      find it from another LAN host (e.g. arp-scan --localnet)."
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
            if [ "$network_mode" = tap ] || [ "$network_mode" = macvtap ]; then
                echo "HTTP:  http://$guest_ip/"
            else
                echo "HTTP:  http://127.0.0.1:$http_port/"
            fi
            echo "HTTPS: $ready_url"
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

# Keep supervising the VM instead of blocking in wait(1).  The old embedded
# kernel should idle with HLT; sustained full-core TCG use indicates a guest
# spin loop and is not acceptable on a laptop.
clock_ticks="$(getconf CLK_TCK)"
previous_ticks="$(awk '{print $14 + $15}' "/proc/$qemu_pid/stat")"
previous_sample=$SECONDS
while kill -0 "$qemu_pid" 2>/dev/null; do
    sleep 5
    current_ticks="$(awk '{print $14 + $15}' "/proc/$qemu_pid/stat" 2>/dev/null || echo "$previous_ticks")"
    current_sample=$SECONDS
    sample_seconds=$((current_sample - previous_sample))
    (( sample_seconds > 0 )) || sample_seconds=1
    cpu=$(( (current_ticks - previous_ticks) * 100 / clock_ticks / sample_seconds ))
    previous_ticks="$current_ticks"
    previous_sample="$current_sample"
    if (( cpu >= 95 )); then
        high_cpu_samples=$((high_cpu_samples + 1))
    else
        high_cpu_samples=0
    fi
    if [ -n "$cpu_guard" ] && (( high_cpu_samples >= cpu_guard )); then
        echo "QEMU stayed above 95% CPU for $((cpu_guard * 5)) seconds; stopping it to protect the host." >&2
        exit 3
    fi
done

echo "QEMU exited." >&2
exit 1
