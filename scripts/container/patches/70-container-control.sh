#!/usr/bin/env bash
#
# 70-container-control.sh — install the guest side of the container's orderly
# shutdown channel.
#
# QEMU exposes a second serial port (ttyS1) as a private, non-networked channel.
# When the container is stopped, entrypoint.sh writes "reboot" on it (see
# scripts/container/entrypoint.sh) and launch-vm.sh exits after the resulting
# guest reset instead of relaunching QEMU.  This hook performs the guest half:
# it reads that one command and runs the stock reboot path, so the controller
# flushes its databases and the kernel unmounts /writable before the reset.
#
# Why not ACPI: the guest boots with ACPI on (`-machine pc`, so it can enumerate
# both vCPUs; see launch-vm.sh), but QMP system_powerdown is an ACPI
# power-*button* event that needs a userspace handler (there is no acpid here),
# so it is ignored.  The reboot path works and is exercised by boot-test.sh.
#
# Applied with the same read -> debugfs -> dd channel as the other rootfs
# patches; only changed 512-byte blocks reach the disk.
#
# Usage: QCOW=<flat-disk> WORK=<workdir> ./70-container-control.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW="${QCOW:-$(dirname "$BASE")/synthetic-cf.img}"
WORK="${WORK:-$(dirname "$BASE")/.rootfs-patch-work}"
ALIGN=512
# shellcheck source=../patch-lib.sh
. "$(dirname "$BASE")/patch-lib.sh"

TARGET="/etc/init.d/S98zd_container_control"

# The roots this run may touch: prepare-vm-disks.sh passes its per-root
# selection in ZD_PATCH_PARTS; with none set this is the full root pair
# (patch-lib.sh:patch_parts), which is how the patch tests drive it.
load_patch_parts

[ -f "$QCOW" ] || { echo "QCOW not found: $QCOW" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"

cat > "$WORK/S98zd_container_control" <<'ZD_CONTAINER_CONTROL'
#!/bin/sh
# Container lifecycle control over the second serial port (ttyS1), a private
# non-networked channel.  Three commands are understood:
#
#   reboot   the container is stopping: run the stock reboot path so the
#            controller flushes its databases and the kernel unmounts /writable.
#   address  report this guest's own address.  The guest is the authority on its
#            lease -- asking it avoids the container having to sniff DHCP or
#            sweep the LAN for a matching MAC.
#   diag     report interfaces, addresses and bound drivers (a NIC experiment
#            made observable without console credentials).
#   ready    report whether the management HTTPS port is bound.  The guest is
#            also the authority on its own service: asking it here means the
#            container never has to reach the guest over IP, which matters
#            because the container's own address can move and the guest's
#            address may be held locally for display (see the LXC flow).
#
# Replies are written back on the same port as "ZD-<KEY>=<value>".
# Runs in the background and never blocks init.
(
    # devtmpfs normally provides this; fall back to a static node (ttyS 4:65).
    [ -c /dev/ttyS1 ] || mknod /dev/ttyS1 c 4 65 2>/dev/null || exit 0

    # Report the network state: which interfaces exist, what addresses they hold
    # and which driver each one is bound to.  This is what makes a NIC experiment
    # observable without logging into the appliance, whose console needs credentials
    # the operator may not have.
    guest_diag() {
        for dev in $(ls /sys/class/net 2>/dev/null); do
            [ "$dev" = lo ] && continue
            addr=$(ip -4 -o addr show dev "$dev" 2>/dev/null \
                   | awk '{print $4}' | cut -d/ -f1 | head -n1)
            drv=$(basename "$(readlink /sys/class/net/$dev/device/driver 2>/dev/null)" 2>/dev/null)
            echo "ZD-IF=$dev addr=${addr:-none} driver=${drv:-none}" > /dev/ttyS1
        done
        for m in igb2 igb e1000e e1000; do
            if [ -d "/sys/module/$m" ]; then
                echo "ZD-MODULE=$m loaded" > /dev/ttyS1
            fi
        done
        if service_up; then
            echo "ZD-SERVICE-443=listening" > /dev/ttyS1
        else
            echo "ZD-SERVICE-443=-" > /dev/ttyS1
        fi
        service_detail
        echo "ZD-END=diag" > /dev/ttyS1
    }

    guest_address() {
        # The stock stack manages the interface it created for the management
        # address; report whatever address that interface holds now.
        for dev in br0 uif0 eth0; do
            addr=$(ip -4 -o addr show dev "$dev" 2>/dev/null \
                   | awk '{print $4}' | cut -d/ -f1 | head -n1)
            [ -n "$addr" ] && { echo "$addr"; return; }
        done
    }

    # Is the management HTTPS service answering?  A real local request, not a
    # socket-table read.
    #
    # A /proc/net/tcp read cannot answer this: it does not see a listener bound
    # to a specific address rather than the wildcard, an IPv6-only listener, or
    # one in another network namespace, and it can report "not listening" on a
    # guest whose wizard is demonstrably serving (the container's host gets a 302
    # to /admin10/wizard.jsp while the guest's /proc/net/tcp shows no 443 listener
    # at all).  All of those look identical to "down".
    #
    # So ask the guest's own stack instead.  curl is on the appliance
    # (/bin/curl).  Exit status decides; any HTTP reply counts, because the
    # question is whether the service is up, not what it says.
    service_ready() {
        for url in https://127.0.0.1:443/ https://localhost:443/; do
            if curl -ksS -o /dev/null --max-time 6 "$url" 2>/dev/null; then
                return 0
            fi
        done
        return 1
    }

    # Fallback for a guest without curl: the socket-table read, widened to IPv6
    # and to a listener bound anywhere.  Kept separate so it is clear which
    # answer was used.
    service_listening_any() {
        port="$1"
        awk -v p="$port" 'NR > 1 && $4 == "0A" {
                split($2, a, ":")
                if (toupper(a[2]) == sprintf("%04X", p)) { found = 1; exit }
            }
            END { exit(found ? 0 : 1) }' /proc/net/tcp /proc/net/tcp6 2>/dev/null
    }

    service_up() {
        if command -v curl >/dev/null 2>&1; then
            service_ready && return 0 || return 1
        fi
        service_listening_any 443
    }

    # What this script can actually see of the listening sockets.  The raw
    # evidence is reported next to the verdict so a "down" answer can be told
    # apart from a view that simply cannot see the listener.
    #
    # Every reply MUST be written to /dev/ttyS1.  A bare printf goes to this
    # hook's stdout, which is the container's console (ttyS0) -- so a missing
    # redirect leaks the control-channel reply onto the appliance's serial
    # console, where the PVE Console tab shows it (the watchdog drives a
    # healthcheck probe every 60s, which is why it appeared periodically).
    service_detail() {
        n4=0; n6=0; ports=""
        if [ -r /proc/net/tcp ]; then
            n4=$(awk 'NR > 1' /proc/net/tcp 2>/dev/null | wc -l)
            ports=$(awk 'NR > 1 && $4 == "0A" { split($2, a, ":"); print a[2] }' /proc/net/tcp 2>/dev/null | tr '\n' ',')
        fi
        [ -r /proc/net/tcp6 ] && n6=$(awk 'NR > 1' /proc/net/tcp6 2>/dev/null | wc -l)
        printf 'ZD-NET-TCP-ENTRIES=%s\n' "${n4:-0}" > /dev/ttyS1
        printf 'ZD-NET-TCP6-ENTRIES=%s\n' "${n6:-0}" > /dev/ttyS1
        printf 'ZD-NET-TCP-LISTEN=%s\n' "${ports%,}" > /dev/ttyS1
    }

    while IFS= read -r command; do
        case "$command" in
            reboot)
                echo "ZD-CONTAINER-CONTROL: orderly shutdown requested" >/dev/console
                sync
                exec /sbin/reboot
                ;;
            diag)
                guest_diag
                ;;
            address)
                addr=$(guest_address)
                if [ -n "$addr" ]; then
                    echo "ZD-GUEST-IP=$addr" > /dev/ttyS1
                else
                    echo "ZD-GUEST-IP=" > /dev/ttyS1
                fi
                ;;
            ready)
                if service_up; then
                    echo "ZD-SERVICE-443=listening" > /dev/ttyS1
                else
                    echo "ZD-SERVICE-443=-" > /dev/ttyS1
                fi
                ;;
        esac
    done < /dev/ttyS1
) &
exit 0
ZD_CONTAINER_CONTROL
chmod 755 "$WORK/S98zd_container_control"
printf '%s\n' "$TARGET" > /dev/null

say "reading the flat disk $QCOW"
ln -sf "$QCOW" "$WORK/flat.raw"

patched_any=0
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    say "[$name] extracting partition (sector $start, ${sectors}s)"
    extract_part "$name" "$start" "$sectors"
    snapshot_orig "$name"
    IMG="$WORK/$name.img"
    pr_init "$IMG"

    say "[$name] installing $TARGET"
    write_local "$WORK/$name.img" "$TARGET" "$WORK/S98zd_container_control" 0755

    if write_deltas "$name" "$start"; then
        patched_any=1
    else
        echo "  no byte changes for $name"
    fi
done

if [ "$patched_any" = 0 ]; then
    say "no patch produced changes; nothing written to the disk"
    exit 0
fi

say "verifying: re-reading the disk and comparing each partition"
ln -sf "$QCOW" "$WORK/flat.verify.raw"
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    dd if="$WORK/flat.verify.raw" of="$WORK/$name.verify.img" bs=$ALIGN \
       skip="$start" count="$sectors" status=none
    if cmp -s "$WORK/$name.verify.img" "$WORK/$name.img"; then
        echo "OK   $name: disk matches the patched partition image"
    else
        echo "FAIL $name: disk does not match the patched partition image" >&2
        exit 1
    fi
    read -r t _ _ _ <<< "$(fs_stat_meta "$WORK/$name.verify.img" "$TARGET")"
    [ "$t" = "regular" ] || { echo "FAIL $name: $TARGET missing" >&2; exit 1; }
    echo "OK   $name: $TARGET installed"
done

say "done — container control hook installed in $QCOW"
