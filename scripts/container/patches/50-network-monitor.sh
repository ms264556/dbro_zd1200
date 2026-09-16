#!/usr/bin/env bash
#
# 50-network-monitor.sh — install the "Network Monitor" page and its collectors
# into the ZD1200 lab VM root partitions (hda2/hda3), writing the result into
# the flat disk.
#
# This is this fork's rework of the installation that dbro/zd1200 performs at
# boot from a custom initramfs.  Here the vendor rootfs is patched *offline*
# (this script) before QEMU starts, and the ordered patch pipeline re-applies it
# to a spare root after an in-guest firmware upgrade.  It therefore never edits
# the running appliance and needs no vendor pivot hook.
#
# Per partition it installs:
#   * /usr/local/sbin/zd1200-ping-monitor           (i386 static collector)
#   * /usr/local/sbin/zd1200-ping-export            (i386 static daily exporter)
#   * /usr/local/sbin/zd1200-local-getstat          (i386 static getstatd client)
#   * /usr/local/sbin/busybox                       (private copy of the vendor's)
#   * /usr/local/sbin/zd1200-network-snapshot-collect
#   * /usr/local/sbin/zd1200-snapshot-index-publish
#   * /usr/local/sbin/zd1200-ping-daily-publish
#   * /usr/local/sbin/zd1200-ping-monitor-settings-sync
#   * /web/admin10/zd1200-network-monitor.html
#   * /web/admin10/zd1200-network-monitor-worker.js
#   * /web/admin10/zd1200-ping-monitor-* symlinks into /writable
#   * a Troubleshooting menu entry in the app.js / ruckus.js admin bundles
#   * /etc/init.d/S99zd_ping_monitor                (collector scheduler)
#
# The three C helpers are built i386/static/musl by the analytics-helper stage
# of docker/Dockerfile and are staged in ANALYTICS_DIR alongside the payload.
#
# Applied with the same read -> debugfs -> dd channel as the other rootfs
# patches: runs as a standard user (no root, no loop devices, no nbd, no mount)
# and writes only the changed 512-byte blocks back to the disk.
#
# Usage:
#   QCOW=<flat-disk> WORK=<workdir> ANALYTICS_DIR=<dir> ./50-network-monitor.sh
#
# Idempotent: re-running against an already-patched partition rewrites the same
# content and produces no byte changes.
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW="${QCOW:-$(dirname "$BASE")/synthetic-cf.img}"
WORK="${WORK:-$(dirname "$BASE")/.rootfs-patch-work}"
ANALYTICS_DIR="${ANALYTICS_DIR:-$(dirname "$BASE")/analytics}"
ALIGN=512

# name|start_sector|sector_count  (mirrors build-synthetic-cf.py)
PARTITIONS=(
    "hda2|84568|415152"
    "hda3|499720|415152"
)

# --- payload -----------------------------------------------------------------
PAYLOAD_BIN=(
    zd1200-ping-monitor
    zd1200-ping-export
    zd1200-local-getstat
)
PAYLOAD_SCRIPTS=(
    network-snapshot-collect.sh:zd1200-network-snapshot-collect
    snapshot-index-publish.sh:zd1200-snapshot-index-publish
    ping-daily-publish.sh:zd1200-ping-daily-publish
    ping-monitor-settings-sync.sh:zd1200-ping-monitor-settings-sync
)
PING_HTML="$ANALYTICS_DIR/ping-monitor.html"
PING_WORKER="$ANALYTICS_DIR/ping-monitor-worker.js"
PANEL_JS="$ANALYTICS_DIR/zd1200-network-monitor-panel.js"
INIT_SH="$ANALYTICS_DIR/zd1200-network-monitor-init.sh"

for f in "$PING_HTML" "$PING_WORKER" "$PANEL_JS" "$INIT_SH" \
         "${PAYLOAD_BIN[@]/#/$ANALYTICS_DIR/}"; do
    [ -f "$f" ] || { echo "50-network-monitor: missing payload file $f" >&2; exit 1; }
done
for entry in "${PAYLOAD_SCRIPTS[@]}"; do
    [ -f "$ANALYTICS_DIR/${entry%%:*}" ] \
        || { echo "50-network-monitor: missing payload file $ANALYTICS_DIR/${entry%%:*}" >&2; exit 1; }
done
[ -f "$QCOW" ] || { echo "QCOW not found: $QCOW" >&2; exit 1; }

# Optional: label the admin console version with a source revision.  Disabled
# unless a 7-character lowercase-hex value is supplied (build-container.sh
# derives one from the checked-out Git revision).
VIRTUAL_BUILD_ID="${ZD_VIRTUAL_BUILD_ID:-}"
case "$VIRTUAL_BUILD_ID" in
    ???????)
        case "$VIRTUAL_BUILD_ID" in *[!0-9a-f]*) VIRTUAL_BUILD_ID="";; esac
        ;;
    *) VIRTUAL_BUILD_ID="";;
esac

rm -rf "$WORK"; mkdir -p "$WORK"

say() { printf '\n== %s\n' "$*"; }

# --- ext2 helpers (identical approach to the other rootfs patches) -----------
stat_meta() {
    debugfs -R "stat $2" "$1" 2>/dev/null \
        | awk '{ for (i = 1; i <= NF; i++) {
                     if ($i == "Type:")  t = $(i+1)
                     else if ($i == "Mode:")  m = $(i+1)
                     else if ($i == "User:")  u = $(i+1)
                     else if ($i == "Group:") g = $(i+1)
                 }} END { if (t != "") print t, m, u, g }'
}

# write_local <img> <fspath> <localfile> [mode] [uid] [gid]
# debugfs 'write' creates mode 0644 uid/gid 0, so preserve the metadata of an
# existing target (or apply the given defaults for a new one) and verify the
# content round-trips before it can reach the disk.
write_local() {
    local img="$1" fspath="$2" localfile="$3"
    local dmode="${4:-0644}" duid="${5:-0}" dgid="${6:-0}"
    local t m u g mode_field
    read -r t m u g <<< "$(stat_meta "$img" "$fspath")"
    if [ -z "$t" ]; then
        m="$dmode"; u="$duid"; g="$dgid"
    elif [ "$t" != "regular" ]; then
        echo "  ! $fspath was not a regular file (type '$t'); replacing it" >&2
        m="$dmode"; u="$duid"; g="$dgid"
    fi
    # debugfs 'write' lands as mode 0644 uid/gid 0 and debugfs wants the whole
    # 16-bit mode, so rebuild S_IFREG | permission-bits (0100000 | 0755 = 0100755).
    mode_field="$(printf '010%04o' "$(( 0$m & 07777 ))")"
    printf 'rm %s\nwrite %s %s\n' "$fspath" "$localfile" "$fspath" > "$WORK/cmds.$$"
    debugfs -w -f "$WORK/cmds.$$" "$img" >/dev/null 2>&1
    rm -f "$WORK/cmds.$$"
    debugfs -w -R "set_inode_field $fspath mode $mode_field" "$img" >/dev/null 2>&1 || true
    debugfs -w -R "set_inode_field $fspath uid $u" "$img" >/dev/null 2>&1 || true
    debugfs -w -R "set_inode_field $fspath gid $g" "$img" >/dev/null 2>&1 || true
    if ! debugfs -R "dump $fspath $WORK/verify.$$" "$img" >/dev/null 2>&1 \
       || ! cmp -s "$WORK/verify.$$" "$localfile"; then
        echo "  !! content verification failed for $fspath; aborting" >&2
        rm -f "$WORK/verify.$$"
        return 1
    fi
    rm -f "$WORK/verify.$$"
    return 0
}

mkdir_p() {
    local img="$1" path="$2" p="" part
    local IFS='/'
    for part in $path; do
        [ -n "$part" ] || continue
        p="$p/$part"
        [ -n "$(stat_meta "$img" "$p")" ] && continue
        debugfs -w -R "mkdir $p" "$img" >/dev/null 2>&1 || true
    done
}

# symlink_force <img> <linkpath> <target>  (replaces a file or symlink)
symlink_force() {
    local img="$1" link="$2" target="$3"
    debugfs -w -R "rm $link" "$img" >/dev/null 2>&1 || true
    debugfs -w -R "symlink $link $target" "$img" >/dev/null 2>&1
}

# --- admin-console bundle patching -------------------------------------------
# Port of dbro/zd1200's V4 menu patch (boot-initrd-handoff, upstream 10aeb90).
# The menu link points at the stock "Network Connectivity" JSP, whose normal
# header/left navigation provide the shell; the appended panel script swaps only
# that page's main content for the report iframe on the dedicated hash.
MARKER='zd1200_ping_monitor'
PANEL_MARKER='zd1200-ping-monitor-content-v4'
MENU_URL='/admin10/admin_pingtool.jsp#zd1200_network_monitor'

arm_menu_bundle() {
    local bundle="$1" bundle_name="$2"
    sed -i \
        -e 's@id:"zd1200_ping_monitor",title:"Ping Monitor"@id:"zd1200_ping_monitor",title:"Network Monitor"@g' \
        -e 's@id:"zd1200_ping_monitor",title:"Performance History"@id:"zd1200_ping_monitor",title:"Network Monitor"@g' \
        -e 's@{id:"zd1200_ping_monitor",title:"Network Monitor",url:"/admin10/zd1200-ping-monitor.html"}@{id:"zd1200_ping_monitor",title:"Network Monitor",url:"'"$MENU_URL"'"}@g' \
        -e 's@{id:"zd1200_ping_monitor",title:"Network Monitor",location:"zd1200_ping_monitor",url:"/admin10/app.jsp#zd1200_ping_monitor"}@{id:"zd1200_ping_monitor",title:"Network Monitor",url:"'"$MENU_URL"'"}@g' \
        -e 's@{id:"zd1200_ping_monitor",title:"Network Monitor",url:"javascript:window.zd1200ShowPingMonitor()"}@{id:"zd1200_ping_monitor",title:"Network Monitor",url:"'"$MENU_URL"'"}@g' \
        -e 's@{id:"zd1200_ping_monitor",title:"Network Monitor",url:"/admin10/admin_pingtool.jsp#zd1200_ping_monitor"}@{id:"zd1200_ping_monitor",title:"Network Monitor",url:"'"$MENU_URL"'"}@g' \
        -e 's@id:"TROUBLESHOOTING",title:Msg.CF_TROUBLESHOOTING||"TROUBLESHOOTING"@id:"Troubleshooting",title:Msg.CF_Troubleshooting||"Troubleshooting"@g' \
        -e 's@title:"Network Monitor",url:"'"$MENU_URL"'}\]@title:"Network Monitor",url:"'"$MENU_URL"'"}\]@g' \
        "$bundle"

    if ! grep -q "$MARKER" "$bundle"; then
        if [ "$bundle_name" = app ]; then
            sed -i \
                -e 's|children:\[a,n,r\]})|children:[a,n,r,{id:"zd1200_ping_monitor",title:"Network Monitor",url:"'"$MENU_URL"'"}]})|g' \
                -e 's|children:\[n,r\]})|children:[n,r,{id:"zd1200_ping_monitor",title:"Network Monitor",url:"'"$MENU_URL"'"}]})|g' \
                "$bundle"
        else
            sed -i \
                -e 's|children:\[n,i,r\]})|children:[n,i,r,{id:"zd1200_ping_monitor",title:"Network Monitor",url:"'"$MENU_URL"'"}]})|g' \
                -e 's|children:\[i,r\]})|children:[i,r,{id:"zd1200_ping_monitor",title:"Network Monitor",url:"'"$MENU_URL"'"}]})|g' \
                "$bundle"
        fi
    fi

    if ! grep -q "$MARKER" "$bundle" \
       || ! grep -qF "title:\"Network Monitor\",url:\"$MENU_URL\"" "$bundle"; then
        echo "  ! $bundle_name.js: Network Monitor menu entry missing or malformed" >&2
        return 1
    fi

    # Drop an earlier appended overlay implementation, if present.  The vendor
    # webpack bundle is one long line, so the appended block starts on its own
    # line with ";(function(){" and ends with "})();".
    if grep -q 'var frameId="zd1200-ping-monitor-frame"' "$bundle"; then
        if awk '
            BEGIN { dropping = 0 }
            !dropping && /;\(function\(\)\{$/ {
                sub(/;\(function\(\)\{$/, "")
                print
                dropping = 1
                next
            }
            dropping {
                if ($0 == "})();") dropping = 0
                next
            }
            { print }
        ' "$bundle" > "$bundle.tmp.$$"; then
            mv -f "$bundle.tmp.$$" "$bundle"
        else
            rm -f "$bundle.tmp.$$"
            return 1
        fi
    fi

    # Only the legacy bundle hosts the content panel; the SPA bundle just
    # follows the menu URL into the same shell.
    if [ "$bundle_name" = ruckus ] && ! grep -q "$PANEL_MARKER" "$bundle"; then
        cat "$PANEL_JS" >> "$bundle"
    fi
    return 0
}

apply_version_patch() {
    local bundle="$1" bundle_name="$2"
    [ -n "$VIRTUAL_BUILD_ID" ] || return 0
    case "$bundle_name" in
        app)
            sed -i \
                -e 's@sysVersion:function(e){var t=Msg.SysVersion;return(""==t?e:t)+" virtual [0-9a-f][0-9a-f]*"}@sysVersion:function(e){var t=Msg.SysVersion;return""==t?e:t}@g' \
                -e "s@sysVersion:function(e){var t=Msg.SysVersion;return\"\"==t?e:t}@sysVersion:function(e){var t=Msg.SysVersion;return(\"\"==t?e:t)+\" virtual $VIRTUAL_BUILD_ID\"}@g" \
                "$bundle"
            ;;
        ruckus)
            sed -i \
                -e 's@sysVersion:function(t){var e=Msg.SysVersion;return(""==e?t:e)+" virtual [0-9a-f][0-9a-f]*"}@sysVersion:function(t){var e=Msg.SysVersion;return""==e?t:e}@g' \
                -e "s@sysVersion:function(t){var e=Msg.SysVersion;return\"\"==e?t:e}@sysVersion:function(t){var e=Msg.SysVersion;return(\"\"==e?t:e)+\" virtual $VIRTUAL_BUILD_ID\"}@g" \
                "$bundle"
            ;;
        scripts)
            sed -i \
                -e 's@Render.sysVersion=function(version){var v=Msg.SysVersion;return(""==v?version:v)+" virtual [0-9a-f][0-9a-f]*"}@Render.sysVersion=function(version){var v=Msg.SysVersion;return""==v?version:v}@g' \
                -e "s@Render.sysVersion=function(version){var v=Msg.SysVersion;return\"\"==v?version:v}@Render.sysVersion=function(version){var v=Msg.SysVersion;return(\"\"==v?version:v)+\" virtual $VIRTUAL_BUILD_ID\"}@g" \
                "$bundle"
            ;;
        utilold)
            local tmp="$bundle.tmp.$$"
            if awk -v id="$VIRTUAL_BUILD_ID" '
                BEGIN { scope = 0; patched = 0 }
                $0 == "_Fv.sysVersion=function(_184e){" { scope = 1 }
                scope && $0 ~ /^return _184e(\+" virtual [0-9a-f]+")?;$/ {
                    print "return _184e+\" virtual " id "\";"
                    patched++
                    next
                }
                scope && $0 ~ /^return v(\+" virtual [0-9a-f]+")?;$/ {
                    print "return v+\" virtual " id "\";"
                    patched++
                    scope = 0
                    next
                }
                { print }
                END { if (patched != 2) exit 3 }
            ' "$bundle" > "$tmp"; then
                mv -f "$tmp" "$bundle"
            else
                rm -f "$tmp"
                echo "  ! utilOld.js: version signature not found" >&2
            fi
            ;;
    esac
    return 0
}

# process_bundle <img> <rootfs-path> <name> <menu|version>
process_bundle() {
    local img="$1" relpath="$2" name="$3" mode="$4"
    local localfile="$WORK/bundle-$name.js" orig="$WORK/bundle-$name.orig.js"
    local gz="$WORK/bundle-$name.js.gz"
    debugfs -R "dump $relpath $localfile" "$img" >/dev/null 2>&1 || true
    if [ ! -s "$localfile" ]; then
        echo "  - $relpath absent; skipping"
        return 0
    fi
    cp "$localfile" "$orig"
    if [ "$mode" = menu ]; then
        arm_menu_bundle "$localfile" "$name" || true
    fi
    apply_version_patch "$localfile" "$name"
    if cmp -s "$orig" "$localfile"; then
        echo "  $relpath unchanged"
        return 0
    fi
    # Never write a bundle that does not parse: a single unbalanced quote in the
    # injected menu entry would break the whole admin console.  nodejs is part
    # of the runtime image; if it is unavailable, fall back to the marker checks
    # already performed above.
    if command -v node >/dev/null 2>&1; then
        if ! node --check "$localfile" >/dev/null 2>&1; then
            echo "  !! $relpath: patched JavaScript failed syntax validation" >&2
            node --check "$localfile" 2>&1 | head -5 >&2 || true
            return 1
        fi
    fi
    write_local "$img" "$relpath" "$localfile"
    if [ -n "$(stat_meta "$img" "$relpath.gz")" ]; then
        gzip -9 -c "$localfile" > "$gz"
        write_local "$img" "$relpath.gz" "$gz"
    fi
    echo "  patched $relpath"
    return 0
}

# --- delta write (only changed 512-byte blocks reach the disk) ---------------
# Returns 0 when bytes were written, 1 when the partition was unchanged.
write_deltas() {
    local name="$1" start="$2" off len abs_start
    python3 - "$WORK/$name.orig.img" "$WORK/$name.img" "$ALIGN" > "$WORK/$name.runs" <<'PYEOF'
import sys
orig = open(sys.argv[1], 'rb').read()
new  = open(sys.argv[2], 'rb').read()
al   = int(sys.argv[3])
assert len(orig) == len(new), "partition size changed"
blocks = [i for i in range(0, len(orig), al) if orig[i:i + al] != new[i:i + al]]
runs = []
for b in blocks:
    if runs and b == runs[-1][1]:
        runs[-1] = (runs[-1][0], b + al)
    else:
        runs.append((b, b + al))
for s, e in runs:
    print(s, e - s)
PYEOF
    if [ ! -s "$WORK/$name.runs" ]; then
        return 1
    fi
    abs_start=$((start * ALIGN))
    while read -r off len; do
        dd if="$WORK/$name.img" of="$WORK/chunk.bin" bs=$ALIGN \
           skip=$((off / ALIGN)) count=$((len / ALIGN)) status=none
        dd if="$WORK/chunk.bin" of="$QCOW" bs=$ALIGN \
           seek=$(((abs_start + off) / ALIGN)) count=$((len / ALIGN)) conv=notrunc status=none
    done < "$WORK/$name.runs"
    return 0
}

say "reading the flat disk $QCOW"
ln -sf "$QCOW" "$WORK/flat.raw"

patched_any=0
menu_missing=0
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    say "[$name] extracting partition (sector $start, ${sectors}s)"
    dd if="$WORK/flat.raw" of="$WORK/$name.img" bs=$ALIGN skip="$start" count="$sectors" status=none
    cp "$WORK/$name.img" "$WORK/$name.orig.img"

    say "[$name] installing the Network Monitor payload"
    mkdir_p "$WORK/$name.img" /usr/local/sbin

    # A private copy of the vendor busybox gives the collectors a stable
    # /usr/local/sbin/busybox with the applets they use (the stock root has no
    # standalone sed/awk utilities, only the multicall /bin/busybox).
    if [ -z "$(stat_meta "$WORK/$name.img" /bin/busybox)" ]; then
        echo "  ! $name: /bin/busybox missing; the collectors will need it" >&2
    else
        debugfs -R "dump /bin/busybox $WORK/busybox" "$WORK/$name.img" >/dev/null 2>&1
        write_local "$WORK/$name.img" /usr/local/sbin/busybox "$WORK/busybox" 0755
    fi

    for bin in "${PAYLOAD_BIN[@]}"; do
        write_local "$WORK/$name.img" "/usr/local/sbin/$bin" "$ANALYTICS_DIR/$bin" 0755
    done
    for entry in "${PAYLOAD_SCRIPTS[@]}"; do
        src="${entry%%:*}"; dst="${entry##*:}"
        write_local "$WORK/$name.img" "/usr/local/sbin/$dst" "$ANALYTICS_DIR/$src" 0755
    done

    write_local "$WORK/$name.img" /web/admin10/zd1200-network-monitor.html "$PING_HTML" 0644
    write_local "$WORK/$name.img" /web/admin10/zd1200-network-monitor-worker.js "$PING_WORKER" 0644
    write_local "$WORK/$name.img" /etc/init.d/S99zd_ping_monitor "$INIT_SH" 0755

    if [ -n "$VIRTUAL_BUILD_ID" ]; then
        printf '%s\n' "$VIRTUAL_BUILD_ID" > "$WORK/virtual-build-id"
        write_local "$WORK/$name.img" /etc/zd1200-virtual-build-id "$WORK/virtual-build-id" 0444
    fi

    say "[$name] linking the monitor data endpoints into /web/admin10"
    for spec in \
        "zd1200-ping-monitor-snapshot-manifest.json|snapshot-manifest.json" \
        "zd1200-ping-monitor-snapshot-index|snapshot-index" \
        "zd1200-ping-monitor-settings.json|settings.json" \
        "zd1200-ping-monitor-live-status.json|live-status.json" \
        "zd1200-ping-monitor-events-status.json|events-status.json" \
        "zd1200-ping-monitor-telemetry-status.json|telemetry-status.json" \
        "zd1200-ping-monitor-snapshots|snapshots" \
        "zd1200-ping-monitor-targets.json|targets.json" \
        "zd1200-ping-monitor-daily-manifest.json|daily-manifest.json" \
        "zd1200-ping-monitor-daily|daily" ; do
        symlink_force "$WORK/$name.img" "/web/admin10/${spec%%|*}" \
            "/writable/zd1200-ping-monitor/${spec##*|}"
    done

    say "[$name] adding the Troubleshooting menu entry"
    process_bundle "$WORK/$name.img" /web/build/app.js app menu
    process_bundle "$WORK/$name.img" /web/build/ruckus.js ruckus menu
    process_bundle "$WORK/$name.img" /web/build/scripts.min.js scripts version
    process_bundle "$WORK/$name.img" /web/scripts/utilOld.js utilold version
    if ! grep -q "$MARKER" "$WORK/bundle-app.js" 2>/dev/null \
       && ! grep -q "$MARKER" "$WORK/bundle-ruckus.js" 2>/dev/null; then
        menu_missing=1
    fi

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
    for bin in zd1200-ping-monitor zd1200-ping-export zd1200-local-getstat \
               zd1200-network-snapshot-collect zd1200-snapshot-index-publish \
               zd1200-ping-daily-publish zd1200-ping-monitor-settings-sync; do
        read -r t _ u g <<< "$(stat_meta "$WORK/$name.verify.img" "/usr/local/sbin/$bin")"
        [ "$t" = "regular" ] || { echo "FAIL $name: /usr/local/sbin/$bin missing" >&2; exit 1; }
    done
    read -r t _ _ _ <<< "$(stat_meta "$WORK/$name.verify.img" /web/admin10/zd1200-network-monitor.html)"
    [ "$t" = "regular" ] || { echo "FAIL $name: monitor page missing" >&2; exit 1; }
    read -r t _ _ _ <<< "$(stat_meta "$WORK/$name.verify.img" /etc/init.d/S99zd_ping_monitor)"
    [ "$t" = "regular" ] || { echo "FAIL $name: collector init script missing" >&2; exit 1; }
    if debugfs -R "dump /web/build/ruckus.js $WORK/ruckus.final" "$WORK/$name.verify.img" >/dev/null 2>&1 \
       && grep -q "$PANEL_MARKER" "$WORK/ruckus.final"; then
        echo "OK   $name: ruckus.js carries the Network Monitor panel"
    else
        echo "  ! $name: ruckus.js panel signature not found after patch" >&2
    fi
done

if [ "$menu_missing" = 1 ]; then
    echo "  ! Network Monitor menu entry was not found in either admin bundle;" >&2
    echo "    the page is installed but not linked from the Troubleshooting menu." >&2
fi

say "done — Network Monitor installed in $QCOW"
