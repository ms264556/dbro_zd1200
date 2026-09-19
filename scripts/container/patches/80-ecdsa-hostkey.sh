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
# shellcheck source=../patch-lib.sh
. "$(dirname "$BASE")/patch-lib.sh"

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

install_ecdsa() {
    local img="$1"
    write_local "$img" "$KEYGEN_TARGET" "$WORK/S59zd_ecdsa_hostkey" 0755

    if [ -z "$(fs_stat_meta "$img" "$INIT_TARGET")" ]; then
        echo "  ! $INIT_TARGET missing; only the key generator was installed" >&2
        return 0
    fi
    if [ -n "$(fs_stat_meta "$img" "$INIT_BACKUP")" ]; then
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
        [ -n "$(fs_stat_meta "$img" "$f")" ] && installed=1
    done
    [ "$installed" = 1 ] || return 0
    if [ -n "$(fs_stat_meta "$img" "$INIT_BACKUP")" ]; then
        debugfs -R "dump $INIT_BACKUP $WORK/dropbear-init.restore" "$img" >/dev/null 2>&1
        if [ -s "$WORK/dropbear-init.restore" ]; then
            write_local "$img" "$INIT_TARGET" "$WORK/dropbear-init.restore" 0755
        fi
    fi
    remove_path "$img" "$INIT_BACKUP"
    remove_path "$img" "$KEYGEN_TARGET"
}

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
        read -r t _ _ _ <<< "$(fs_stat_meta "$WORK/$name.verify.img" "$KEYGEN_TARGET")"
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
