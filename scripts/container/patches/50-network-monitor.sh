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
# Set ZD_NETWORK_MONITOR=0 to install nothing (the LXC installer's
# --no-network-monitor): the fresh image then has no page and no collectors, as
# if the feature did not exist.  Its value is part of the patch signature, so
# changing it re-customises the roots.
ZD_NETWORK_MONITOR="${ZD_NETWORK_MONITOR:-1}"
ALIGN=512
# shellcheck source=../patch-lib.sh
. "$(dirname "$BASE")/patch-lib.sh"

if [ "$ZD_NETWORK_MONITOR" = "0" ]; then
    echo "50-network-monitor: disabled (ZD_NETWORK_MONITOR=0); nothing to install"
    exit 0
fi

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
# unless a 7-character lowercase-hex value is supplied (install-zd1200-docker.sh
# derives one from the checked-out Git revision).
VIRTUAL_BUILD_ID="${ZD_VIRTUAL_BUILD_ID:-}"
case "$VIRTUAL_BUILD_ID" in
    ???????)
        case "$VIRTUAL_BUILD_ID" in *[!0-9a-f]*) VIRTUAL_BUILD_ID="";; esac
        ;;
    *) VIRTUAL_BUILD_ID="";;
esac

# Optional: operator defaults for the monitor, seeded into /writable on the
# first boot (analytics/zd1200-network-monitor-init.sh).  Collection is off by
# default, so the interval only matters once monitoring is enabled from the page.
# Both values are validated here so a typo cannot reach the appliance.
MONITOR_DEFAULTS=""
ping_interval="${ZD_PING_INTERVAL_SECONDS:-}"
if [ -n "$ping_interval" ]; then
    case "$ping_interval" in
        *[!0-9]*)
            echo "50-network-monitor: ignoring non-numeric ZD_PING_INTERVAL_SECONDS='$ping_interval'" >&2
            ;;
        *)
            if [ "$ping_interval" -ge 30 ] && [ "$ping_interval" -le 3600 ]; then
                MONITOR_DEFAULTS="MONITOR_INTERVAL_SECONDS=$ping_interval"
            else
                echo "50-network-monitor: ignoring ZD_PING_INTERVAL_SECONDS=$ping_interval (must be 30-3600)" >&2
            fi
            ;;
    esac
fi
ping_targets="${ZD_PING_CLIENT_TARGETS:-}"
if [ -n "$ping_targets" ]; then
    # Same 'MAC|IP|NAME' records separated by ';' that the collector accepts.
    if printf '%s\n' "$ping_targets" | awk -F';' '
            { for (i = 1; i <= NF; i++) {
                  if (split($i, f, "|") != 3) bad = 1
                  for (j = 1; j <= 3; j++) if (f[j] == "") bad = 1
              } }
            END { exit bad ? 1 : 0 }'; then
        MONITOR_DEFAULTS="${MONITOR_DEFAULTS:+$MONITOR_DEFAULTS
}CLIENT_TARGETS=$ping_targets"
    else
        echo "50-network-monitor: ignoring ZD_PING_CLIENT_TARGETS" >&2
        echo "  expected 'MAC|IP|NAME' records separated by ';'" >&2
    fi
fi

rm -rf "$WORK"; mkdir -p "$WORK"

# The ext2/store helpers (fs_stat_meta, write_local, mkdir_p, symlink_force,
# write_deltas) come from patch-lib.sh: every file this patch
# replaces is kept in the root's /.patchrollback store and every file it creates
# is recorded, so a changed patch set can be re-applied from the vendor rootfs.

# ui_layout_of <img>  -> "<flavor>|<webroot>"
#   10       : 10.x admin console, /web/admin10, webpack bundles in /web/build
#   9edison  : 9.12/9.13 "Edison" console, /web/admin, menu in
#              edison/js/common/systemMenu.js
#   9classic : 9.9-9.11 classic console, /web/admin, menu compiled into
#              admin_template.mod (patched through a DOM hook in scripts/util.js)
ui_layout_of() {
    if [ -n "$(fs_stat_meta "$1" /web/admin10)" ]; then
        echo "10|/web/admin10"
    elif [ -n "$(fs_stat_meta "$1" /web/admin/edison/js/common/systemMenu.js)" ]; then
        echo "9edison|/web/admin"
    elif [ -n "$(fs_stat_meta "$1" /web/admin)" ]; then
        echo "9classic|/web/admin"
    else
        echo "10|/web/admin10"
    fi
}

# install_edison_menu <img> <webroot>
# Adds a "Network Monitor" sub-item under the Edison "Monitor" menu and installs
# the small module it loads, which renders the report page in a full-height
# iframe (the Edison shell loads a JS class into #system_main_div, not a page).
install_edison_menu() {
    local img="$1" webroot="$2"
    local menu="$WORK/systemMenu.js" module="$WORK/zd1200NetworkMonitor.js"
    debugfs -R "dump $webroot/edison/js/common/systemMenu.js $menu" "$img" >/dev/null 2>&1 || {
        echo "  !! systemMenu.js not readable" >&2
        return 1
    }
    if ! grep -q 'zd1200NetworkMonitorControl' "$menu"; then
        # Anchor on the Monitor menu's subItems array (the file is not minified,
        # so this literal is stable across 9.12/9.13 builds).
        sed -i 's@{menubar:R.monitor, subItems:\[@{menubar:R.monitor, subItems:[{name:"Network Monitor",action:"zd1200NetworkMonitorControl",jsPath:"mon/zd1200NetworkMonitor.js"},@' "$menu"
    fi
    if ! grep -q 'zd1200NetworkMonitorControl' "$menu"; then
        echo "  !! Edison Monitor menu anchor not found in systemMenu.js" >&2
        return 1
    fi
    cp "$menu" "$WORK/systemMenu.patched"
    write_local "$img" "$webroot/edison/js/common/systemMenu.js" "$menu" 0644

    cat > "$module" <<EOF
// Network Monitor panel for the Edison (9.12/9.13) admin console.
// Loaded by systemMenu.js via Common.load(); renders the report page in an
// iframe so it reuses the 10.x page verbatim.
var zd1200NetworkMonitorControl = Class.create({
    initialize: function(el) {
        el.update('<iframe id="zd1200-ping-monitor-frame" src="$UI_BASE/zd1200-network-monitor.html?ui=9" style="width:100%;height:100%;min-height:640px;border:0;display:block;"></iframe>');
    }
});
EOF
    mkdir_p "$img" "$webroot/edison/js/mon"
    write_local "$img" "$webroot/edison/js/mon/zd1200NetworkMonitor.js" "$module" 0644
    echo "  patched $webroot/edison/js/common/systemMenu.js + js/mon/zd1200NetworkMonitor.js"
    return 0
}

# install_classic_menu <img> <webroot>
# The classic (9.9-9.11) console builds its left menu inside the compiled
# admin_template.mod, which cannot be regenerated offline.  Instead append a
# small DOM hook to the plain /web/scripts/util.js that adds a "Network Monitor"
# entry to the rendered menu once the page is up.
install_classic_menu() {
    local img="$1" webroot="$2"
    local util="$WORK/util.js"
    debugfs -R "dump /web/scripts/util.js $util" "$img" >/dev/null 2>&1 || {
        echo "  !! scripts/util.js not readable" >&2
        return 1
    }
    if ! grep -q 'zd1200NetworkMonitorControl' "$util"; then
        cat >> "$util" <<EOF

// --- Network Monitor menu hook (this fork) --------------------------------
// The classic console renders its menu from the compiled admin_template.mod as
// <td id="mainmenu">...<ul><li><span id="monitor_aps">Access Points</span></li>
// ...</ul>...</td>.  Append a real Monitor-section row client-side.
// marker: zd1200NetworkMonitorControl
(function () {
    var URL = "$UI_BASE/zd1200-network-monitor.html";
    var LABEL = "Network Monitor";
    function tag(node, name) {
        return node && node.tagName && node.tagName.toLowerCase() === name;
    }
    function addEntry() {
        if (document.getElementById("zd1200_ping_monitor")) return;
        var anchor = document.getElementById("monitor_aps")
                  || document.getElementById("monitor_map");
        if (!anchor) return;
        var ul = anchor;
        while (ul && !tag(ul, "ul")) ul = ul.parentNode;
        if (!ul) return;
        var anchorLi = anchor;
        while (anchorLi && !tag(anchorLi, "li")) anchorLi = anchorLi.parentNode;
        var li = document.createElement("li");
        var span = document.createElement("span");
        span.id = "zd1200_ping_monitor";
        span.style.cursor = "pointer";
        span.appendChild(document.createTextNode(LABEL));
        li.appendChild(span);
        span.onclick = function () { window.location.href = URL; };
        if (anchorLi && anchorLi.parentNode === ul) {
            ul.insertBefore(li, anchorLi.nextSibling);
        } else {
            ul.appendChild(li);
        }
    }
    if (document.readyState === "complete") { addEntry(); }
    else if (window.addEventListener) {
        window.addEventListener("DOMContentLoaded", addEntry, false);
        window.addEventListener("load", addEntry, false);
    } else if (window.attachEvent) { window.attachEvent("onload", addEntry); }
})();
EOF
    fi
    if ! grep -q 'zd1200NetworkMonitorControl' "$util"; then
        echo "  !! classic menu hook could not be appended" >&2
        return 1
    fi
    cp "$util" "$WORK/util.patched"
    write_local "$img" /web/scripts/util.js "$util" 0644
    echo "  patched /web/scripts/util.js with the Network Monitor menu hook"
    return 0
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
            # Anchor on the Troubleshooting node rather than on its children:
            # the child identifiers/order change between firmware builds
            # (10.5.1: [a,n,r], 10.2.1: [n,r], 10.1.2: [n,a,r] / [a,r]).  The
            # bundle is minified, so [^]]* walks to the end of that node's
            # children array.
            sed -i \
                -e 's@\(id:"Troubleshooting",title:Msg.CF_Troubleshooting||"Troubleshooting",children:\[[^]]*\)\]})@\1,{id:"zd1200_ping_monitor",title:"Network Monitor",url:"'"$MENU_URL"'"}]})@g' \
                "$bundle"
        else
            # Same anchor for the legacy bundle.
            sed -i \
                -e 's@\(id:"Troubleshooting",title:Msg.CF_Troubleshooting||"Troubleshooting",children:\[[^]]*\)\]})@\1,{id:"zd1200_ping_monitor",title:"Network Monitor",url:"'"$MENU_URL"'"}]})@g' \
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
    if [ -n "$(fs_stat_meta "$img" "$relpath.gz")" ]; then
        gzip -9 -c "$localfile" > "$gz"
        write_local "$img" "$relpath.gz" "$gz"
    fi
    echo "  patched $relpath"
    return 0
}

say "reading the flat disk $QCOW"
ln -sf "$QCOW" "$WORK/flat.raw"

patched_any=0
menu_missing=0
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    say "[$name] extracting partition (sector $start, ${sectors}s)"
    extract_part "$name" "$start" "$sectors"
    snapshot_orig "$name"
    IMG="$WORK/$name.img"
    pr_init "$IMG"

    say "[$name] installing the Network Monitor payload"
    mkdir_p "$WORK/$name.img" /usr/local/sbin

    # Which admin console does this release ship?  See ui_layout_of().
    IFS='|' read -r UI_FLAVOR WEB_ROOT <<< "$(ui_layout_of "$WORK/$name.img")"
    case "$UI_FLAVOR" in
        10) UI_BASE=/admin10 ;;
        *)  UI_BASE=/admin ;;
    esac
    echo "  admin console: $UI_FLAVOR ($WEB_ROOT, url base $UI_BASE)"
    mkdir_p "$WORK/$name.img" "$WEB_ROOT"

    # A private copy of the vendor busybox gives the collectors a stable
    # /usr/local/sbin/busybox with the applets they use (the stock root has no
    # standalone sed/awk utilities, only the multicall /bin/busybox).
    if [ -z "$(fs_stat_meta "$WORK/$name.img" /bin/busybox)" ]; then
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

    write_local "$WORK/$name.img" "$WEB_ROOT/zd1200-network-monitor.html" "$PING_HTML" 0644
    write_local "$WORK/$name.img" "$WEB_ROOT/zd1200-network-monitor-worker.js" "$PING_WORKER" 0644
    write_local "$WORK/$name.img" /etc/init.d/S99zd_ping_monitor "$INIT_SH" 0755

    if [ -n "$VIRTUAL_BUILD_ID" ] && [ "$UI_FLAVOR" = 10 ]; then
        printf '%s\n' "$VIRTUAL_BUILD_ID" > "$WORK/virtual-build-id"
        write_local "$WORK/$name.img" /etc/zd1200-virtual-build-id "$WORK/virtual-build-id" 0444
    fi

    if [ -n "$MONITOR_DEFAULTS" ]; then
        printf '%s\n' "$MONITOR_DEFAULTS" > "$WORK/ping-monitor-defaults.conf"
        write_local "$WORK/$name.img" /etc/zd1200-ping-monitor-defaults.conf \
            "$WORK/ping-monitor-defaults.conf" 0644
    else
        # No defaults configured any more: drop a file an earlier build installed,
        # so a fresh /writable is never seeded from a stale image.  remove_path
        # records it for rollback first.
        remove_path "$WORK/$name.img" /etc/zd1200-ping-monitor-defaults.conf
    fi

    say "[$name] linking the monitor data endpoints into $WEB_ROOT"
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
        symlink_force "$WORK/$name.img" "$WEB_ROOT/${spec%%|*}" \
            "/writable/zd1200-ping-monitor/${spec##*|}"
    done

    case "$UI_FLAVOR" in
        10)
            say "[$name] adding the Troubleshooting menu entry"
            process_bundle "$WORK/$name.img" /web/build/app.js app menu
            process_bundle "$WORK/$name.img" /web/build/ruckus.js ruckus menu
            process_bundle "$WORK/$name.img" /web/build/scripts.min.js scripts version
            process_bundle "$WORK/$name.img" /web/scripts/utilOld.js utilold version
            if ! grep -q "$MARKER" "$WORK/bundle-app.js" 2>/dev/null \
               && ! grep -q "$MARKER" "$WORK/bundle-ruckus.js" 2>/dev/null; then
                menu_missing=1
            fi
            ;;
        9edison)
            say "[$name] adding the Network Monitor menu entry (Edison console)"
            if ! install_edison_menu "$WORK/$name.img" "$WEB_ROOT" \
               || ! grep -q 'zd1200NetworkMonitorControl' "$WORK/systemMenu.patched" 2>/dev/null; then
                menu_missing=1
            fi
            # 9.13 also ships the classic console, and that is what login.jsp
            # lands on (dashboard.jsp), so add the classic menu hook as well.
            if [ -n "$(fs_stat_meta "$WORK/$name.img" /web/admin/admin_template.mod)" ]; then
                say "[$name] adding the Network Monitor menu entry (classic console)"
                if ! install_classic_menu "$WORK/$name.img" "$WEB_ROOT" \
                   || ! grep -q 'zd1200NetworkMonitorControl' "$WORK/util.patched" 2>/dev/null; then
                    menu_missing=1
                fi
            fi
            ;;
        9classic)
            say "[$name] adding the Network Monitor menu entry (classic console)"
            if ! install_classic_menu "$WORK/$name.img" "$WEB_ROOT" \
               || ! grep -q 'zd1200NetworkMonitorControl' "$WORK/util.patched" 2>/dev/null; then
                menu_missing=1
            fi
            ;;
    esac

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
    IFS='|' read -r V_FLAVOR V_ROOT <<< "$(ui_layout_of "$WORK/$name.verify.img")"
    for bin in zd1200-ping-monitor zd1200-ping-export zd1200-local-getstat \
               zd1200-network-snapshot-collect zd1200-snapshot-index-publish \
               zd1200-ping-daily-publish zd1200-ping-monitor-settings-sync; do
        read -r t _ u g <<< "$(fs_stat_meta "$WORK/$name.verify.img" "/usr/local/sbin/$bin")"
        [ "$t" = "regular" ] || { echo "FAIL $name: /usr/local/sbin/$bin missing" >&2; exit 1; }
    done
    read -r t _ _ _ <<< "$(fs_stat_meta "$WORK/$name.verify.img" "$V_ROOT/zd1200-network-monitor.html")"
    [ "$t" = "regular" ] || { echo "FAIL $name: monitor page missing" >&2; exit 1; }
    read -r t _ _ _ <<< "$(fs_stat_meta "$WORK/$name.verify.img" /etc/init.d/S99zd_ping_monitor)"
    [ "$t" = "regular" ] || { echo "FAIL $name: collector init script missing" >&2; exit 1; }
    case "$V_FLAVOR" in
        10)
            if debugfs -R "dump /web/build/ruckus.js $WORK/ruckus.final" "$WORK/$name.verify.img" >/dev/null 2>&1 \
               && grep -q "$PANEL_MARKER" "$WORK/ruckus.final"; then
                echo "OK   $name: ruckus.js carries the Network Monitor panel"
            else
                echo "  ! $name: ruckus.js panel signature not found after patch" >&2
            fi
            ;;
        9edison)
            debugfs -R "dump $V_ROOT/edison/js/common/systemMenu.js $WORK/systemMenu.final" "$WORK/$name.verify.img" >/dev/null 2>&1
            if grep -q 'zd1200NetworkMonitorControl' "$WORK/systemMenu.final" 2>/dev/null; then
                echo "OK   $name: Edison systemMenu.js carries the Network Monitor entry"
            else
                echo "  ! $name: Edison menu entry not found after patch" >&2
            fi
            read -r t _ _ _ <<< "$(fs_stat_meta "$WORK/$name.verify.img" "$V_ROOT/edison/js/mon/zd1200NetworkMonitor.js")"
            [ "$t" = "regular" ] || { echo "FAIL $name: Edison monitor module missing" >&2; exit 1; }
            if [ -n "$(fs_stat_meta "$WORK/$name.verify.img" /web/admin/admin_template.mod)" ]; then
                debugfs -R "dump /web/scripts/util.js $WORK/util.final" "$WORK/$name.verify.img" >/dev/null 2>&1
                if grep -q 'zd1200NetworkMonitorControl' "$WORK/util.final" 2>/dev/null; then
                    echo "OK   $name: classic util.js carries the Network Monitor menu hook"
                else
                    echo "  ! $name: classic menu hook not found after patch" >&2
                fi
            fi
            ;;
        9classic)
            debugfs -R "dump /web/scripts/util.js $WORK/util.final" "$WORK/$name.verify.img" >/dev/null 2>&1
            if grep -q 'zd1200NetworkMonitorControl' "$WORK/util.final" 2>/dev/null; then
                echo "OK   $name: classic util.js carries the Network Monitor menu hook"
            else
                echo "  ! $name: classic menu hook not found after patch" >&2
            fi
            ;;
    esac
done

if [ "$menu_missing" = 1 ]; then
    echo "  ! Network Monitor menu entry could not be added to this release's" >&2
    echo "    admin console; the page and collectors are installed and reachable" >&2
    echo "    directly, but not linked from the menu." >&2
fi

say "done — Network Monitor installed in $QCOW"
