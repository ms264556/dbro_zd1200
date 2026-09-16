#!/usr/bin/env bash
#
# 80-ecdsa-hostkey.sh — add an ECDSA host key to the ZD1200 administrative SSH
# service, keeping RSA.  This is the fork's equivalent of dbro/zd1200's
# ZD_ENABLE_ECDSA_SSH.
#
# Why: the stock controller presents only an RSA/SHA-1 host key, which modern
# OpenSSH clients reject by default, forcing every connection to pass
# `-o HostKeyAlgorithms=+ssh-rsa`.  Adding a nistp256 host key lets clients
# negotiate normally while RSA remains available to legacy ones.
#
# Per partition it installs:
#   * /etc/init.d/S59zd_ecdsa_hostkey — generates the key before S60dropbear,
#     storing it next to the RSA key on the writable partition
#     (/etc/airespider -> /writable/etc/airespider), so it persists across
#     firmware upgrades;
#   * /etc/init.d/dropbear — the stock launcher, with a second `-r` for the
#     ECDSA key.  The pristine copy is kept as /etc/init.d/dropbear.vendor.
#
# The root SSH listener on 2222 (patch 60) adds the same key when it exists.
#
# Controlled by ZD_ECDSA_SSH (default 1); setting it to 0 reverts the change.
#
# Usage: QCOW=<flat-disk> WORK=<workdir> ZD_ECDSA_SSH=1 ./80-ecdsa-hostkey.sh
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QCOW="${QCOW:-$(dirname "$BASE")/synthetic-cf.img}"
WORK="${WORK:-$(dirname "$BASE")/.rootfs-patch-work}"
ALIGN=512

INIT_TARGET="/etc/init.d/dropbear"
INIT_BACKUP="/etc/init.d/dropbear.vendor"
KEYGEN_TARGET="/etc/init.d/S59zd_ecdsa_hostkey"
ECDSA_KEY="/etc/airespider/dropbear/dropbear_host_ecdsa_key"
RSA_REF="-r /etc/airespider/dropbear/dropbear_host_rsa_key"

# name|start_sector|sector_count  (mirrors build-synthetic-cf.py)
PARTITIONS=(
    "hda2|84568|415152"
    "hda3|499720|415152"
)

[ -f "$QCOW" ] || { echo "QCOW not found: $QCOW" >&2; exit 1; }

ecdsa_enabled=1
case "${ZD_ECDSA_SSH:-1}" in
    0|false|no|off) ecdsa_enabled=0 ;;
esac

rm -rf "$WORK"; mkdir -p "$WORK"
say() { printf '\n== %s\n' "$*"; }
if [ "$ecdsa_enabled" = 1 ]; then
    say "ECDSA host key: ENABLED"
else
    say "ECDSA host key: disabled (reverting)"
fi

cat > "$WORK/S59zd_ecdsa_hostkey" <<'ZD_ECDSA_KEYGEN'
#!/bin/sh
# Generate an ECDSA host key for the administrative SSH service so modern
# clients (which reject the RSA/SHA-1 host key by default) can connect without
# -o HostKeyAlgorithms=+ssh-rsa.  RSA is retained: /etc/init.d/dropbear passes
# both -r keys.
#
# /etc/airespider is a symlink to /writable/etc/airespider, so the key persists
# across firmware upgrades.  Runs as S59, before S60dropbear.
key=/etc/airespider/dropbear/dropbear_host_ecdsa_key
log=/writable/zd1200-ssh-recovery.log

[ -s "$key" ] && exit 0
keygen=/usr/bin/dropbearkey
if [ ! -x "$keygen" ]; then
    echo "ECDSA: no dropbearkey available; administrative SSH stays RSA-only" >> "$log"
    exit 0
fi
mkdir -p /etc/airespider/dropbear
if "$keygen" -t ecdsa -f "$key" >> "$log" 2>&1; then
    chmod 600 "$key" 2>/dev/null || true
    echo "ECDSA host key generated" >> "$log"
else
    echo "ECDSA host key generation failed; administrative SSH stays RSA-only" >> "$log"
fi
exit 0
ZD_ECDSA_KEYGEN
chmod 755 "$WORK/S59zd_ecdsa_hostkey"

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

rm_path() { debugfs -w -R "rm $2" "$1" >/dev/null 2>&1 || true; }

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

install_ecdsa() {
    local img="$1"
    write_local "$img" "$KEYGEN_TARGET" "$WORK/S59zd_ecdsa_hostkey" 0755

    if [ -z "$(stat_meta "$img" "$INIT_TARGET")" ]; then
        echo "  ! $INIT_TARGET missing; only the key generator was installed" >&2
        return 0
    fi
    if [ -n "$(stat_meta "$img" "$INIT_BACKUP")" ]; then
        debugfs -R "dump $INIT_BACKUP $WORK/dropbear-init.pristine" "$img" >/dev/null 2>&1
    else
        debugfs -R "dump $INIT_TARGET $WORK/dropbear-init.current" "$img" >/dev/null 2>&1
        # Normalise away any ECDSA -r an earlier run added, then keep it.
        sed "s# -r $ECDSA_KEY##g" "$WORK/dropbear-init.current" > "$WORK/dropbear-init.pristine"
        if [ -s "$WORK/dropbear-init.pristine" ]; then
            write_local "$img" "$INIT_BACKUP" "$WORK/dropbear-init.pristine" 0755
        fi
    fi
    if [ ! -s "$WORK/dropbear-init.pristine" ]; then
        echo "  ! could not read $INIT_TARGET; init not patched" >&2
        return 0
    fi
    sed "s#\\($RSA_REF\\)#\\1 -r $ECDSA_KEY#" \
        "$WORK/dropbear-init.pristine" > "$WORK/dropbear-init.patched"
    if cmp -s "$WORK/dropbear-init.pristine" "$WORK/dropbear-init.patched"; then
        echo "  ! '$RSA_REF' not found in $INIT_TARGET; init not patched" >&2
        return 0
    fi
    write_local "$img" "$INIT_TARGET" "$WORK/dropbear-init.patched" 0755
    echo "  $INIT_TARGET now passes the ECDSA host key"
}

revert_ecdsa() {
    local img="$1" installed=0 f
    for f in "$KEYGEN_TARGET" "$INIT_BACKUP"; do
        [ -n "$(stat_meta "$img" "$f")" ] && installed=1
    done
    [ "$installed" = 1 ] || return 0
    if [ -n "$(stat_meta "$img" "$INIT_BACKUP")" ]; then
        debugfs -R "dump $INIT_BACKUP $WORK/dropbear-init.restore" "$img" >/dev/null 2>&1
        if [ -s "$WORK/dropbear-init.restore" ]; then
            write_local "$img" "$INIT_TARGET" "$WORK/dropbear-init.restore" 0755
        fi
    fi
    rm_path "$img" "$INIT_BACKUP"
    rm_path "$img" "$KEYGEN_TARGET"
}

say "reading the flat disk $QCOW"
ln -sf "$QCOW" "$WORK/flat.raw"

patched_any=0
for part in "${PARTITIONS[@]}"; do
    IFS='|' read -r name start sectors <<< "$part"
    say "[$name] extracting partition (sector $start, ${sectors}s)"
    dd if="$WORK/flat.raw" of="$WORK/$name.img" bs=$ALIGN skip="$start" count="$sectors" status=none
    cp "$WORK/$name.img" "$WORK/$name.orig.img"

    if [ "$ecdsa_enabled" = 1 ]; then
        say "[$name] adding the ECDSA host key"
        install_ecdsa "$WORK/$name.img"
    else
        say "[$name] reverting the ECDSA host key"
        revert_ecdsa "$WORK/$name.img"
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
    if [ "$ecdsa_enabled" = 1 ]; then
        read -r t _ _ _ <<< "$(stat_meta "$WORK/$name.verify.img" "$KEYGEN_TARGET")"
        [ "$t" = "regular" ] || { echo "FAIL $name: $KEYGEN_TARGET missing" >&2; exit 1; }
        debugfs -R "dump $INIT_TARGET $WORK/init.check" "$WORK/$name.verify.img" >/dev/null 2>&1
        if grep -q -- "$ECDSA_KEY" "$WORK/init.check"; then
            echo "OK   $name: $INIT_TARGET passes the ECDSA host key"
        else
            echo "FAIL $name: $INIT_TARGET does not reference the ECDSA host key" >&2
            exit 1
        fi
    else
        echo "OK   $name: ECDSA host key reverted"
    fi
done

if [ "$ecdsa_enabled" = 1 ]; then
    say "done — ECDSA host key installed in $QCOW"
else
    say "done — ECDSA host key reverted in $QCOW"
fi
