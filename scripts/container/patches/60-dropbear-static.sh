#!/usr/bin/env bash
#
# 60-dropbear-static.sh — optionally replace the ZD1200's vendor dropbear with
# the static musl build (ms264556/zd_dropbear, vendored under dropbear/) and add
# a public-key-only root SSH listener on TCP 2222.
#
# Why replace it: the vendor /usr/sbin/dropbear is a Ruckus build whose server
# advertises `password` only (no publickey) and whose custom -A option is
# mandatory.  The vendored build adds the Ruckus -e/-A options (so the stock
# /etc/init.d/dropbear port-22 invocation keeps working) and, when -A is NOT
# given, uses standard dropbear auth — including publickey.
#
# This patch is a no-op unless the image carries the built payload
# (/opt/zd1200/dropbear/dropbear, only present when ZD_ROOT_SSH=1) and a public
# key is supplied.  When the payload is absent it REVERTS an earlier install, so
# turning the feature off in install-zd1200-docker.sh restores the vendor binary.
#
# Per partition it installs:
#   * /usr/sbin/dropbear          (vendor saved as /usr/sbin/dropbear.vendor)
#   * /usr/sbin/sftp-server       (SFTPSERVER_PATH of the replacement)
#   * /usr/bin/dropbearkey        (replaces the vendor multicall symlink)
#   * /usr/bin/dropbearconvert    (replaces the vendor multicall symlink)
#   * /etc/zd1200-root-authorized_keys   (seeded to /writable at boot)
#   * /root/.ssh/authorized_keys -> /writable/zd1200-root-ssh/authorized_keys
#   * /etc/init.d/S61zd_root_ssh  (starts dropbear -p 2222 with pubkey only)
#
# Applied with the same read -> debugfs -> dd channel as the other rootfs
# patches; only changed 512-byte blocks reach the disk.
#
# Usage:
#   QCOW=<flat-disk> WORK=<workdir> ./60-dropbear-static.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW="${QCOW:-$(dirname "$BASE")/synthetic-cf.img}"
WORK="${WORK:-$(dirname "$BASE")/.rootfs-patch-work}"
ALIGN=512

DROPBEAR_DIR="${ZD_DROPBEAR_DIR:-$(dirname "$BASE")/dropbear}"
INIT_SRC="$DROPBEAR_DIR/zd1200-root-ssh-init.sh"
AUTHORIZED_KEYS="${ZD_ROOT_SSH_AUTHORIZED_KEYS:-/opt/zd1200/dropbear-provision/authorized_keys}"

# name|start_sector|sector_count  (mirrors build-synthetic-cf.py)
PARTITIONS=(
    "hda2|84568|415152"
    "hda3|499720|415152"
)

PAYLOAD_BIN=(dropbear dropbearkey dropbearconvert sftp-server)

# --- decide whether this patch installs or reverts ---------------------------
enabled=1
for b in "${PAYLOAD_BIN[@]}"; do
    [ -f "$DROPBEAR_DIR/$b" ] || enabled=0
done
[ -f "$INIT_SRC" ] || enabled=0
[ -s "$AUTHORIZED_KEYS" ] || enabled=0
# Whether the feature is available is decided at image-build time (the
# ZD_ROOT_SSH build arg controls whether the payload exists at all), so it must
# not also depend on a runtime environment variable: a plain `docker compose
# up` would otherwise re-disable a working install.

key_line=""
if [ "$enabled" = 1 ]; then
    if [ ! -r "$AUTHORIZED_KEYS" ]; then
        echo "60-dropbear-static: cannot read $AUTHORIZED_KEYS" >&2
        echo "  (the container drops CAP_DAC_OVERRIDE, so the mounted public key must be world-readable)" >&2
        exit 1
    fi
    key_line="$(head -n1 "$AUTHORIZED_KEYS" | tr -d '\r')"
    case "$key_line" in
        ssh-rsa\ *|ssh-ed25519\ *|ecdsa-sha2-nistp256\ *|ecdsa-sha2-nistp384\ *|ecdsa-sha2-nistp521\ *) ;;
        *) echo "60-dropbear-static: $AUTHORIZED_KEYS is not an SSH public key" >&2; exit 1 ;;
    esac
fi

[ -f "$QCOW" ] || { echo "QCOW not found: $QCOW" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"
if [ "$enabled" = 1 ]; then
    printf '%s\n' "$key_line" > "$WORK/authorized_keys"
    chmod 600 "$WORK/authorized_keys"
fi

say() { printf '\n== %s\n' "$*"; }
if [ "$enabled" = 1 ]; then
    say "static dropbear replacement: ENABLED (key ${key_line%% *})"
else
    say "static dropbear replacement: disabled (vendor dropbear left/restored)"
fi

# --- ext2 helpers (same approach as the other rootfs patches) ----------------
stat_meta() {
    debugfs -R "stat $2" "$1" 2>/dev/null \
        | awk '{ for (i = 1; i <= NF; i++) {
                     if ($i == "Type:")  t = $(i+1)
                     else if ($i == "Mode:")  m = $(i+1)
                     else if ($i == "User:")  u = $(i+1)
                     else if ($i == "Group:") g = $(i+1)
                 }} END { if (t != "") print t, m, u, g }'
}

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

symlink_force() {
    local img="$1" link="$2" target="$3"
    debugfs -w -R "rm $link" "$img" >/dev/null 2>&1 || true
    debugfs -w -R "symlink $link $target" "$img" >/dev/null 2>&1
}

rm_path() {
    debugfs -w -R "rm $2" "$1" >/dev/null 2>&1 || true
}

# --- delta write (only changed 512-byte blocks reach the disk) ---------------
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

install_payload() {
    local img="$1"
    # Preserve the vendor binary once so the feature can be turned back off.
    if [ -n "$(stat_meta "$img" /usr/sbin/dropbear)" ] \
       && [ -z "$(stat_meta "$img" /usr/sbin/dropbear.vendor)" ]; then
        debugfs -R "dump /usr/sbin/dropbear $WORK/dropbear.vendor" "$img" >/dev/null 2>&1
        if [ -s "$WORK/dropbear.vendor" ]; then
            write_local "$img" /usr/sbin/dropbear.vendor "$WORK/dropbear.vendor" 0755
        fi
    fi
    write_local "$img" /usr/sbin/dropbear "$DROPBEAR_DIR/dropbear" 0755
    write_local "$img" /usr/sbin/sftp-server "$DROPBEAR_DIR/sftp-server" 0755
    # The replacement is a single binary per tool, not a Ruckus multicall, so
    # the vendor symlinks to /usr/sbin/dropbear must become real files.
    write_local "$img" /usr/bin/dropbearkey "$DROPBEAR_DIR/dropbearkey" 0755
    write_local "$img" /usr/bin/dropbearconvert "$DROPBEAR_DIR/dropbearconvert" 0755
    write_local "$img" /etc/zd1200-root-authorized_keys "$WORK/authorized_keys" 0600
    # The vendor passwd gives root the home directory "/", so dropbear reads
    # /.ssh/authorized_keys.  The vendor rootfs already ships /.ssh as a symlink
    # to /writable/data/dropbear, which keeps the key on the writable partition
    # where it can be rotated without rebuilding the container.  Recreate the
    # symlink only if an earlier run (or an offline fsck) removed it; never
    # convert it into a directory.
    if [ -z "$(stat_meta "$img" /.ssh)" ]; then
        symlink_force "$img" /.ssh /writable/data/dropbear
    fi
    # dropbear's checkusername rejects a user whose login shell is not listed in
    # /etc/shells, and the vendor list omits /bin/sh - which is root's shell.
    # Add it (the same set dbro/zd1200 writes) and keep the vendor copy for a
    # clean revert.
    if [ -n "$(stat_meta "$img" /etc/shells)" ]; then
        debugfs -R "dump /etc/shells $WORK/shells.orig" "$img" >/dev/null 2>&1
        if [ -s "$WORK/shells.orig" ] && ! grep -qx '/bin/sh' "$WORK/shells.orig"; then
            [ -n "$(stat_meta "$img" /etc/shells.vendor)" ] \
                || write_local "$img" /etc/shells.vendor "$WORK/shells.orig" 0644
            { cat "$WORK/shells.orig"; printf '/bin/sh\n'; } > "$WORK/shells.new"
            write_local "$img" /etc/shells "$WORK/shells.new" 0644
        fi
    fi
    write_local "$img" /etc/init.d/S61zd_root_ssh "$INIT_SRC" 0755
}

revert_payload() {
    local img="$1" installed=0 f
    for f in /usr/sbin/dropbear.vendor /etc/zd1200-root-authorized_keys /etc/init.d/S61zd_root_ssh /etc/shells.vendor; do
        [ -n "$(stat_meta "$img" "$f")" ] && installed=1
    done
    [ "$installed" = 1 ] || return 0
    if [ -n "$(stat_meta "$img" /usr/sbin/dropbear.vendor)" ]; then
        debugfs -R "dump /usr/sbin/dropbear.vendor $WORK/dropbear.restore" "$img" >/dev/null 2>&1
        if [ -s "$WORK/dropbear.restore" ]; then
            write_local "$img" /usr/sbin/dropbear "$WORK/dropbear.restore" 0755
        fi
    fi
    if [ -n "$(stat_meta "$img" /etc/shells.vendor)" ]; then
        debugfs -R "dump /etc/shells.vendor $WORK/shells.restore" "$img" >/dev/null 2>&1
        if [ -s "$WORK/shells.restore" ]; then
            write_local "$img" /etc/shells "$WORK/shells.restore" 0644
        fi
    fi
    symlink_force "$img" /usr/bin/dropbearkey ../sbin/dropbear
    symlink_force "$img" /usr/bin/dropbearconvert ../sbin/dropbear
    rm_path "$img" /usr/sbin/dropbear.vendor
    rm_path "$img" /etc/shells.vendor
    rm_path "$img" /usr/sbin/sftp-server
    rm_path "$img" /etc/zd1200-root-authorized_keys
    rm_path "$img" /etc/init.d/S61zd_root_ssh
}

patched_any=0
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    say "[$name] extracting partition (sector $start, ${sectors}s)"
    dd if="$WORK/flat.raw" of="$WORK/$name.img" bs=$ALIGN skip="$start" count="$sectors" status=none
    cp "$WORK/$name.img" "$WORK/$name.orig.img"

    if [ "$enabled" = 1 ]; then
        say "[$name] installing the static dropbear replacement"
        install_payload "$WORK/$name.img"
    else
        say "[$name] reverting any previous static dropbear install"
        revert_payload "$WORK/$name.img"
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
    if [ "$enabled" = 1 ]; then
        for b in dropbear dropbearkey dropbearconvert sftp-server; do
            case "$b" in
                dropbear|sftp-server) p="/usr/sbin/$b" ;;
                *) p="/usr/bin/$b" ;;
            esac
            read -r t _ _ _ <<< "$(stat_meta "$WORK/$name.verify.img" "$p")"
            [ "$t" = "regular" ] || { echo "FAIL $name: $p is not a regular file" >&2; exit 1; }
        done
        read -r t _ _ _ <<< "$(stat_meta "$WORK/$name.verify.img" /etc/init.d/S61zd_root_ssh)"
        [ "$t" = "regular" ] || { echo "FAIL $name: S61zd_root_ssh missing" >&2; exit 1; }
        echo "OK   $name: static dropbear + 2222 listener installed"
    else
        read -r t _ _ _ <<< "$(stat_meta "$WORK/$name.verify.img" /usr/sbin/dropbear)"
        [ "$t" = "regular" ] || { echo "FAIL $name: vendor /usr/sbin/dropbear missing" >&2; exit 1; }
        echo "OK   $name: vendor dropbear in place"
    fi
done

if [ "$enabled" = 1 ]; then
    say "done — static dropbear + root SSH on 2222 installed in $QCOW"
else
    say "done — static dropbear reverted in $QCOW"
fi
