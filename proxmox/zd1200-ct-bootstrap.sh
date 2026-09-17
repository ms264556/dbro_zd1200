#!/usr/bin/env bash
#
# proxmox/zd1200-ct-bootstrap.sh — provision an LXC container in place, so it can
# run the ZD1200 QEMU guest directly (no Docker) and supervise it with systemd.
#
# This script is executed INSIDE the container by install-zd1200-lxc.sh
# (`pct exec <id> -- .../zd1200-ct-bootstrap.sh ...`).  It expects the repository
# to have been copied to $REPO_DIR ($CT_REPO_DIR) first.  It is idempotent: run
# it again to rebuild the payloads or after changing the feature set.
#
# The container needs three things a plain Debian CT lacks:
#   * /dev/kvm   (passed through by the installer when the host has it) — the
#                guest boots in ~1-2 minutes with KVM, minutes without;
#   * /dev/net/tun (passed through by the installer) — QEMU's tap device;
#   * a bridge with the container's eth0 as a port, so the guest's tap is an
#     ordinary L2 neighbour (the Proxmox host can reach it; macvtap cannot).
#
# Design: the container is the "runtime image".  Everything host-only stays on
# the host: the PVE host never builds or patches guest images.  All the vendor
# artifacts and compiled payloads live under $STATE_DIR (persistent), and the
# repo checkout stays read-only in spirit — the installer only adds symlinks
# under scripts/container/ that point at $STATE_DIR.
#
# Usage:
#   zd1200-ct-bootstrap.sh [options]
#
# Options:
#   --source PATH            firmware upgrade file or CF dump (default:
#                            $STATE_DIR/source/<single file>)
#   --writable-from PATH     CF dump to take /writable + serial from
#   --writable-partition S:C override the detected /writable partition
#   --root-ssh-key FILE      public key for the root SSH listener on TCP 2222
#                            (builds the static dropbear replacement; slow)
#   --no-ecdsa               do not add an ECDSA host key to the SSH service
#   --no-network-monitor     skip the Network Monitor page + collectors
#   --no-r600-repair         skip the ap-11n-scorpion (R600) mesh repair
#   --ct-dhcp                the CT's own address comes from DHCP (default)
#   --ct-address CIDR        the CT's own static address
#   --host-ip IP             container's own IP on the LAN (informational)
#   --guest-ip IP            expected guest IP (used for the printed URL)
#   --state-dir DIR          derived-artifact directory (default /var/lib/zd1200)
#   --repo-dir DIR           repository checkout (default /opt/zd1200)
#   --reconfigure            rewrite /etc/zd1200.conf even if it exists (the
#                            container MAC is re-derived; only do this for a
#                            fresh identity, not for a running appliance)
#   --skip-packages          don't apt-get install the CT packages
#   --skip-payloads          don't (re)build the i386 helpers / squashfs tools
#   --skip-image             don't re-run the vendor image preparation
#   --skip-disks             don't rebuild/patch the guest disk
#   -h | --help
#
# Every step is skipped when its output already exists, so a re-run is cheap.
set -euo pipefail

REPO_DIR="${CT_REPO_DIR:-/opt/zd1200}"
STATE_DIR="${ZD_CT_STATE_DIR:-/var/lib/zd1200}"
IMAGE_DIR="$STATE_DIR/image"
SOURCE=""
CONTAINER_MAC=""
WRITABLE_FROM=""
WRITABLE_PARTITION=""
ROOT_SSH_KEY=""
ECDSA=1
NETWORK_MONITOR=1
R600_REPAIR=1
HOST_IP=""
GUEST_IP=""
DO_PACKAGES=1
DO_PAYLOADS=1
RECONFIGURE=0
DO_IMAGE=1
DO_DISKS=1
CONF=/etc/zd1200.conf

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# Verbose step output goes to a log file rather than the console: the rootfs patch
# pipeline narrates every changed 512-byte block and every debugfs command, which
# buries the progress in hundreds of lines.  stderr stays on the console so a real
# failure is visible immediately, and the log is named in the summary and in
# docs/TROUBLESHOOTING.md.
INSTALL_LOG="${ZD_INSTALL_LOG:-$STATE_DIR/install.log}"
run_logged() {
    local description="$1"; shift
    printf '  %s...\n' "$description"
    "$@" >>"$INSTALL_LOG" 2> >(tee -a "$INSTALL_LOG" >&2) || {
        warn "$description failed; last lines of $INSTALL_LOG:"
        tail -25 "$INSTALL_LOG" >&2 || true
        exit 1
    }
}
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --source)               SOURCE="${2:?--source needs a path}"; shift 2 ;;
        --container-mac)        CONTAINER_MAC="${2:?}"; shift 2 ;;
        --ct-dhcp)              ZD_CT_ADDRESS=dhcp; shift ;;
        --ct-address)           ZD_CT_ADDRESS="${2:?}"; shift 2 ;;
        --writable-from)        WRITABLE_FROM="${2:?}"; shift 2 ;;
        --writable-partition)   WRITABLE_PARTITION="${2:?}"; shift 2 ;;
        --root-ssh-key)         ROOT_SSH_KEY="${2:?}"; shift 2 ;;
        --no-ecdsa)             ECDSA=0; shift ;;
        --no-network-monitor)   NETWORK_MONITOR=0; shift ;;
        --no-r600-repair)       R600_REPAIR=0; shift ;;
        --host-ip)              HOST_IP="${2:?}"; shift 2 ;;
        --guest-ip)             GUEST_IP="${2:?}"; shift 2 ;;
        --state-dir)            STATE_DIR="${2:?}"; shift 2 ;;
        --repo-dir)             REPO_DIR="${2:?}"; shift 2 ;;
        --skip-packages)        DO_PACKAGES=0; shift ;;
        --skip-payloads)        DO_PAYLOADS=0; shift ;;
        --skip-image)           DO_IMAGE=0; shift ;;
        --skip-disks)           DO_DISKS=0; shift ;;
        --reconfigure)          RECONFIGURE=1; shift ;;
        -h|--help)              sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[ "$(id -u)" = 0 ] || die "run as root inside the container"
mkdir -p "$STATE_DIR"
: >"$INSTALL_LOG" 2>/dev/null || true
# Everything the pipeline shells out to.  A wrong (tiny) template is the usual
# cause when one is missing; --skip-packages still needs python3/bash/ip.
for cmd in bash python3 sha256sum tar gzip dd ip debugfs e2fsck; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is missing: the container image does not look like a Debian LXC template"
done
[ -d "$REPO_DIR/scripts/container" ] || die "repository not found at $REPO_DIR (copy it in first)"
CC="$REPO_DIR/scripts/container"
mkdir -p "$STATE_DIR" "$IMAGE_DIR"

# localise_mac <mac>: the address with the locally-administered bit set.  Used
# only for the fallback identity when no Proxmox-allocated MAC is available.
localise_mac() {
    local mac="$1" o1 rest
    IFS=: read -r o1 rest <<<"$mac"
    printf '%02x:%s\n' "$(( 0x$o1 | 0x02 ))" "$rest"
}

# guest_mac_seed <container-uplink-mac>: the MAC the guest's board data is built
# from.  It must differ from the container's own uplink MAC (see the identity
# block); uniqueness is inherited from the MAC Proxmox allocated for the
# container, so flipping the last octet is enough.
guest_mac_seed() {
    local mac="$1" prefix last
    prefix="$(printf '%s' "$mac" | cut -d: -f1-5)"
    last="$(printf '%s' "$mac" | awk -F: '{print $6}')"
    if [ -n "$prefix" ] && [ -n "$last" ]; then
        printf '%s:%02x\n' "$prefix" "$(( 0x$last ^ 0x01 ))"
    else
        localise_mac "$mac"
    fi
}

# --------------------------------------------------------------------------
# 1. packages
# --------------------------------------------------------------------------
# The base debian-*-standard template already has e2fsprogs, tar, gzip, python3
# and ca-certificates; everything else the toolchain needs is installed here.
# gcc-multilib/musl-tools are needed to rebuild the i386 guest helpers (the
# helper sources are compiled statically, exactly as the Dockerfile does).
if [ "$DO_PACKAGES" = 1 ]; then
    log "installing container packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        qemu-system-x86 qemu-utils \
        e2fsprogs \
        python3 \
        curl \
        iproute2 \
        nodejs \
        ripgrep \
        procps \
        gzip \
        tar \
        util-linux \
        ca-certificates \
        unzip \
        iputils-arping \
        iputils-ping \
        bridge-utils \
        build-essential \
        git \
        zlib1g-dev \
        >/dev/null
    # i386 toolchain for the Network Monitor helpers (the guest is i386 Linux).
    if [ "$NETWORK_MONITOR" = 1 ]; then
        dpkg --add-architecture i386
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends \
            gcc:i386 make:i386 musl-tools:i386 libc6-dev:i386 zlib1g-dev:i386 >/dev/null 2>&1 \
            || warn "the i386 toolchain could not be installed; the Network Monitor helpers may be stale"
    fi
fi

# --------------------------------------------------------------------------
# 2. runtime layout
# --------------------------------------------------------------------------
# The container-side scripts resolve their payloads relative to their own
# directory (the Docker image layout: /opt/zd1200 + /opt/zd1200/image).  Keep
# the repository where it is and add the few links that make the checkout look
# like that layout, with the derived artifacts living under $STATE_DIR.
log "linking the runtime layout"
ln -sfn "$STATE_DIR/image" "$CC/image"
ln -sfn "$REPO_DIR/bl7" "$CC/bl7"
ln -sfn "$REPO_DIR/analytics" "$CC/analytics"
ln -sfn "$REPO_DIR/dropbear" "$CC/dropbear"
mkdir -p "$REPO_DIR/ruckus-squashfs"
[ -e "$CC/ruckus-squashfs" ] || ln -sfn "$REPO_DIR/ruckus-squashfs" "$CC/ruckus-squashfs"
mkdir -p "$STATE_DIR/provision"
[ -e "$REPO_DIR/dropbear-provision" ] || ln -sfn "$STATE_DIR/provision" "$REPO_DIR/dropbear-provision"

# --------------------------------------------------------------------------
# 3. build the payloads that are compiled rather than copied
# --------------------------------------------------------------------------
if [ "$DO_PAYLOADS" = 1 ]; then
    # Order matters: build the native Ruckus squashfs tools BEFORE adding the
    # i386 architecture below.  `dpkg --add-architecture i386` changes gcc's
    # default library search, after which a native link can no longer resolve
    # -lz (observed: "/bin/ld: cannot find -lz" on Debian 13).
    # 3a. the ap-11n-scorpion (R600) mesh repair needs the matching historical
    # LZMA squashfs tools, built from the pinned GPL-2.0 source (the Dockerfile
    # builds the same revision in its ruckus-squashfs-tools stage).
    if [ "$R600_REPAIR" = 1 ]; then
        if [ ! -x "$REPO_DIR/ruckus-squashfs/mksquashfs" ]; then
            log "building the Ruckus squashfs tools (R600 mesh repair)"
            RUCKUS_SRC="$STATE_DIR/build/ruckus_ap_firmware_mod"
            RUCKUS_REV=3d9e4add414228eac4091f301e813d14130c3d61
            rm -rf "$RUCKUS_SRC"
            mkdir -p "$RUCKUS_SRC"
            git init -q "$RUCKUS_SRC"
            git -C "$RUCKUS_SRC" remote add origin https://github.com/ms264556/ruckus_ap_firmware_mod.git
            git -C "$RUCKUS_SRC" fetch -q --depth 1 origin "$RUCKUS_REV"
            git -C "$RUCKUS_SRC" checkout -q --detach FETCH_HEAD
            make -C "$RUCKUS_SRC/src/squashfs4.0-ruckus-lzma" -j"$(nproc)" \
                >"$STATE_DIR/build/squashfs-build.log" 2>&1 \
                || { tail -20 "$STATE_DIR/build/squashfs-build.log" >&2; die "squashfs build failed"; }
            cp "$RUCKUS_SRC/src/squashfs4.0-ruckus-lzma/mksquashfs" \
               "$RUCKUS_SRC/src/squashfs4.0-ruckus-lzma/unsquashfs" \
               "$REPO_DIR/ruckus-squashfs/"
        fi
    else
        # Without the repair the tools are never called, but
        # build-synthetic-cf.py insists they exist.  Leave inert placeholders.
        for t in mksquashfs unsquashfs; do
            [ -x "$REPO_DIR/ruckus-squashfs/$t" ] || {
                printf '#!/bin/sh\nexit 0\n' > "$REPO_DIR/ruckus-squashfs/$t"
                chmod +x "$REPO_DIR/ruckus-squashfs/$t"
            }
        done
    fi

    # 3b. Network Monitor guest helpers: static i386, built with the
    # distribution's musl-gcc + the SQLite release contemporary with the
    # guest's Linux 2.6.32 (see the Dockerfile's analytics-helper stage).
    if [ "$NETWORK_MONITOR" = 1 ]; then
        if ! command -v musl-gcc >/dev/null 2>&1; then
            # Required even when --skip-packages was used: the guest-side
            # collectors are i386 binaries and the patch pipeline needs them.
            log "installing the i386 helper toolchain (musl-gcc)"
            export DEBIAN_FRONTEND=noninteractive
            dpkg --add-architecture i386
            apt-get update -qq
            # libc6-dev:i386 is required: gcc:i386 alone cannot find the i386
            # bits/wordsize.h that glibc's headers include.
            apt-get install -y -qq --no-install-recommends \
                gcc:i386 make:i386 musl-tools:i386 libc6-dev:i386 zlib1g-dev:i386 >/dev/null 2>&1 || true
        fi
        command -v musl-gcc >/dev/null 2>&1 \
            || die "musl-gcc is unavailable: the Network Monitor helpers cannot be built (pass --no-network-monitor to skip them)"
        log "building the Network Monitor helpers (i386, static)"
        SQLITE_VER=3071700
        SQLITE_SHA=022ef41bd83a1333faf40dc8f1f8469205f4a18c30dc5e137889ba7ea924ef30
        SRC="$STATE_DIR/build/sqlite-amalgamation-$SQLITE_VER"
        if [ ! -f "$SRC/sqlite3.c" ]; then
            mkdir -p "$STATE_DIR/build"
            ( cd "$STATE_DIR/build"
              curl -fsSL "https://www.sqlite.org/2013/sqlite-amalgamation-$SQLITE_VER.zip" -o sqlite.zip
              echo "$SQLITE_SHA  sqlite.zip" | sha256sum -c -
              # python3 is guaranteed by the base template; skip the unzip dep.
              python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall()" sqlite.zip )
        fi
        A="$REPO_DIR/analytics"
        musl-gcc -std=c99 -Os -static -s -DSQLITE_OMIT_LOAD_EXTENSION -I"$SRC" \
            "$A/zd1200-ping-monitor.c" "$SRC/sqlite3.c" -o "$A/zd1200-ping-monitor"
        musl-gcc -std=c99 -Os -static -s -DSQLITE_OMIT_LOAD_EXTENSION -I"$SRC" \
            "$A/zd1200-ping-export.c" "$SRC/sqlite3.c" -lm -o "$A/zd1200-ping-export"
        musl-gcc -std=c99 -Os -static -s \
            "$A/zd1200-local-getstat.c" -o "$A/zd1200-local-getstat"
    fi

    # 3c. optional static dropbear (public-key root SSH on TCP 2222).  The
    # vendored builder fetches its own musl.cc cross toolchain, so this is the
    # slowest optional step and only runs when a public key was supplied.
    if [ -n "$ROOT_SSH_KEY" ] && [ ! -x "$REPO_DIR/dropbear/dropbear" ]; then
        log "building the static dropbear replacement (slow: cross toolchain + sources)"
        mkdir -p "$STATE_DIR/provision"
        printf '%s\n' "$ROOT_SSH_KEY" > "$STATE_DIR/provision/authorized_keys"
        chmod 644 "$STATE_DIR/provision/authorized_keys"
        sh "$REPO_DIR/dropbear/build-zd1200-dropbear.sh" \
            --work "$STATE_DIR/build/dropbear-work" \
            --out "$REPO_DIR/dropbear" \
            >"$STATE_DIR/build/dropbear-build.log" 2>&1 \
            || { tail -20 "$STATE_DIR/build/dropbear-build.log" >&2; die "dropbear build failed"; }
    fi
fi

# --------------------------------------------------------------------------
# 4. prepare the vendor image (firmware decrypt / CF-dump parse)
# --------------------------------------------------------------------------
if [ "$DO_IMAGE" = 1 ] && [ ! -f "$IMAGE_DIR/rootfs.ext2" ]; then
    log "preparing the vendor image (decrypt/parse)"
    [ -n "$SOURCE" ] || die "no source firmware/dump: pass --source or place it in $STATE_DIR/source/"
    [ -f "$SOURCE" ] || die "source not found: $SOURCE"
    prepare_args=("$SOURCE")
    [ -n "$WRITABLE_FROM" ] && prepare_args+=(--writable-from "$WRITABLE_FROM")
    [ -n "$WRITABLE_PARTITION" ] && prepare_args+=(--writable-partition "$WRITABLE_PARTITION")
    # sys_* temp files must not land in the image dir: the script replaces its
    # output directory's contents.  TMPDIR under $STATE_DIR keeps the extraction
    # staging on the same filesystem (a rename-free copy, and enough room).
    mkdir -p "$STATE_DIR/tmp"
    TMPDIR="$STATE_DIR/tmp" \
    IMAGE_DIR="$IMAGE_DIR" \
        run_logged "decrypting/parsing the input (log: $INSTALL_LOG)" \
        bash "$REPO_DIR/scripts/build/prepare-vendor-image.sh" "${prepare_args[@]}"
    rm -rf "$STATE_DIR/tmp"
fi

# --------------------------------------------------------------------------
# 5. configuration file consumed by the systemd unit
# --------------------------------------------------------------------------
# The identity is captured in $CONF on the first run.  Re-deriving it later
# would change the appliance's serial and MAC, so keep an existing file unless
# the operator explicitly asks for a reconfigure (or the disk was removed).
NEED_CONF=1
if [ -s "$CONF" ] && [ "$RECONFIGURE" != 1 ]; then
    NEED_CONF=0
    log "keeping the existing $CONF"
fi
[ "$NEED_CONF" = 1 ] && log "writing $CONF"
SIGN_DIR="$IMAGE_DIR/signing-cert"

if [ "$NEED_CONF" = 1 ]; then
# The guest's board-data identity (serial + MAC1/MAC2), exactly as
# install-zd1200-docker.sh derives it from the ZD_CONTAINER_MAC it writes into .env.
#
# $CONTAINER_MAC is the identity *seed*.  The installer generates a unique
# locally-administered one; --container-mac overrides it.  It must differ from
# the container's own uplink MAC: the veth is a LAN port, so a guest sharing the
# container's MAC is treated by the LAN's DHCP server as the same client and is
# offered the address the container already holds (which the guest refuses).
if [ -z "$CONTAINER_MAC" ]; then
    CONTAINER_MAC="$(ip link show "${ZD_HOST_IF:-eth0}" 2>/dev/null | awk '/ether/{print $2; exit}')"
fi
if printf '%s' "$CONTAINER_MAC" | grep -qE '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$'; then
    # The guest's board-data MAC is derived from the MAC Proxmox allocated for the
    # container (cluster-aware and unique), but must NOT equal the container's own
    # uplink MAC.  The Docker flow may share it because the container's eth0 there
    # is a macvtap, invisible to the LAN; in an LXC the veth IS a LAN port, and a
    # guest sharing its MAC is treated by the LAN's DHCP server as the same
    # client: it is offered the address the container already holds and refuses it,
    # looping on DISCOVER forever (verified on PVE 9.2 with a Debian 13 CT).
    seed="$(guest_mac_seed "$CONTAINER_MAC")"
    eval "$(ZD_CONTAINER_MAC="$seed" "$CC/boarddata-from-mac.sh" 2>/dev/null)" \
        || warn "could not derive the board identity from $seed"
    log "guest board identity: MAC1=$MAC (seed $CONTAINER_MAC)"
    # Hard guard: a guest MAC equal to the container's own uplink MAC breaks
    # DHCP on the LAN (see above), and it is a silent failure otherwise.
    uplink_mac="$(ip link show "${ZD_HOST_IF:-eth0}" 2>/dev/null | awk '/ether/{print tolower($2); exit}')"
    if [ -n "$uplink_mac" ] && [ "$(printf '%s' "$MAC" | tr 'A-Z' 'a-z')" = "$uplink_mac" ]; then
        die "the guest board MAC ($MAC) equals the container's uplink MAC; pass --container-mac <seed> with a different value"
    fi
else
    warn "no usable uplink MAC ($CONTAINER_MAC); using the fixed fallback identity"
fi
ZD_SERIAL="${SERIAL:-123456000789}"
ZD_MAC1="${MAC:-00:0c:e6:12:00:01}"
ZD_MAC2="${MAC2:-}"
{
    printf '# ZD1200 LXC runtime configuration (written by zd1200-ct-bootstrap.sh).\n'
    printf '# Sourced by zd1200.service; edit with `systemctl edit` or rerun the\n'
    printf '# installer.  Keep the shell-quoting simple.\n'
    printf 'NETWORK_MODE=bridge\n'
    printf 'ZD_BRIDGE_IF=br-zd\n'
    printf 'ZD_HOST_IF=eth0\n'
    printf 'TAP_IF=tap-zd\n'
    printf 'STATE_DIR=%s\n' "$STATE_DIR"
    printf 'IMAGE_DIR=%s\n' "$STATE_DIR/image"
    printf 'SYNTHETIC_DISK=%s\n' "$STATE_DIR/synthetic-cf.img"
    printf 'ZD_SIGN_CERT_DIR=%s\n' "$SIGN_DIR"
    printf 'ZD_ROOT_SSH_AUTHORIZED_KEYS=%s/provision/authorized_keys\n' "$STATE_DIR"
    printf 'ZD_ROOT_SSH=%s\n' "$([ -x "$REPO_DIR/dropbear/dropbear" ] && echo 1 || echo 0)"
    printf 'ZD_ECDSA_SSH=%s\n' "$ECDSA"
    printf 'ZD_CONTAINER_CONTROL=1\n'
    printf 'ZD_STOP_TIMEOUT=240\n'
    printf 'WEB_WAIT_SECONDS=900\n'
    printf 'MEMORY_MB=2048\n'
    printf 'CPU_MODEL=n270\n'
    printf 'KERNEL_EXTRA=nohz=off\n'
    # How the container itself is addressed (installer's CT net spec): the
    # network unit waits for the lease/address before moving it onto the bridge.
    case "${ZD_CT_ADDRESS:-dhcp}" in
        dhcp|"") printf 'ZD_CT_DHCP=1\n' ;;
        *)       printf 'ZD_CT_ADDRESS=%s\n' "$ZD_CT_ADDRESS" ;;
    esac
    # The entrypoint's high-CPU guard: QEMU sustained above 95% CPU means the
    # guest is spinning, and a spinning guest is exactly how the appliance wedges
    # (the Docker flow leaves this at its default of 4 samples / 20s).  Keep it on
    # but allow a longer run than the default, because a legitimate boot and the
    # first-boot key generation are bursty.  24 samples = 120s of continuous
    # saturation before QEMU is stopped; systemd then restarts the stack, which
    # reboots the guest.  Set ZD_CPU_GUARD=0 to disable.
    printf 'ZD_CPU_GUARD=%s\n' "${ZD_CPU_GUARD:-24}"
    # Auto-reboot the guest if it stops answering.  The appliance this replaced
    # had its guest OS wedge solid (QEMU alive, guest silent, both LAN addresses
    # dark) and nothing noticed for hours; this turns that into a self-healing
    # event.  Set ZD_GUEST_WATCHDOG=0 to disable.
    printf 'ZD_GUEST_WATCHDOG=%s\n' "${ZD_GUEST_WATCHDOG:-1}"
    printf 'ZD_GUEST_WATCHDOG_FAILURES=%s\n' "${ZD_GUEST_WATCHDOG_FAILURES:-5}"
    printf 'ZD_CONTAINER_MAC=%s\n' "$CONTAINER_MAC"
    printf 'ZD_BOARDDATA_FROM_MAC=1\n'
    printf 'ZD_SERIAL=%s\n' "$ZD_SERIAL"
    printf 'ZD_MAC1=%s\n' "$ZD_MAC1"
    [ -n "$ZD_MAC2" ] && printf 'ZD_MAC2=%s\n' "$ZD_MAC2"
    [ -n "$GUEST_IP" ] && printf 'GUEST_IP=%s\n' "$GUEST_IP"
    [ -n "$HOST_IP" ] && printf 'ZD_HOST_IP=%s\n' "$HOST_IP"
    printf 'ZD_NETWORK_MONITOR=%s\n' "$NETWORK_MONITOR"
} > "$CONF"
chmod 600 "$CONF"
fi

# Single source of truth from here on: the file is what the service reads.
set -a
# shellcheck disable=SC1090
. "$CONF"
set +a

# --------------------------------------------------------------------------
# 5b. container-side units: the LAN bridge and the guest service
# --------------------------------------------------------------------------
log "installing the container units"
install -m 0755 "$REPO_DIR/proxmox/zd1200-ct-net.sh" /usr/local/sbin/zd1200-ct-net
install -m 0755 "$REPO_DIR/proxmox/zd1200-guest-healthcheck" /usr/local/sbin/zd1200-guest-healthcheck
install -m 0755 "$REPO_DIR/proxmox/zd1200-guest-address" /usr/local/sbin/zd1200-guest-address
install -m 0755 "$REPO_DIR/proxmox/zd1200-guest-watchdog" /usr/local/sbin/zd1200-guest-watchdog
if ! getent group kvm >/dev/null 2>&1; then
    groupadd -r kvm 2>/dev/null || true
fi

cat > /etc/systemd/system/zd1200-net.service <<'UNIT'
[Unit]
Description=ZD1200 LAN bridge (container uplink becomes a bridge port)
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target zd1200.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=-/etc/zd1200.conf
ExecStart=/usr/local/sbin/zd1200-ct-net

[Install]
WantedBy=multi-user.target
UNIT

# Live health, not a log marker.  The old check grepped the serial log for the
# guest's READY line, which stays there forever: once the guest wedged (QEMU
# alive, guest not answering, both interfaces dark) the container still reported
# healthy.  Probe the running appliance instead -- reachability of its own
# address at L2, its web port, and a fresh DHCP lease for its MAC.
cat > /etc/systemd/system/zd1200-healthcheck.service <<'UNIT'
[Unit]
Description=Probe the running ZD1200 guest
After=zd1200.service

[Service]
Type=oneshot
EnvironmentFile=-/etc/zd1200.conf
ExecStart=/usr/local/sbin/zd1200-guest-healthcheck
UNIT

cat > /etc/systemd/system/zd1200-healthcheck.timer <<'UNIT'
[Unit]
Description=Periodically probe the running ZD1200 guest

[Timer]
OnBootSec=8min
OnUnitActiveSec=60s

[Install]
WantedBy=timers.target
UNIT

# Recovery: if the guest stops answering for a run of probes, reboot it.  A
# wedged guest is invisible to Proxmox (QEMU stays up), so this is the only thing
# that heals it without a human.
cat > /etc/systemd/system/zd1200-watchdog.service <<'UNIT'
[Unit]
Description=Recover the ZD1200 guest if it stops answering
After=zd1200.service

[Service]
Type=simple
EnvironmentFile=-/etc/zd1200.conf
ExecStart=/usr/local/sbin/zd1200-guest-watchdog
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
UNIT

cat > /etc/systemd/system/zd1200.service <<'UNIT'
[Unit]
Description=ZoneDirector ZD1200 virtual appliance (QEMU guest)
Documentation=https://github.com/ms264556/dbro_zd1200
After=network-online.target zd1200-net.service
Wants=network-online.target zd1200-net.service
StartLimitIntervalSec=0

[Service]
Type=simple
EnvironmentFile=-/etc/zd1200.conf
WorkingDirectory=REPO_DIR_PLACEHOLDER
ExecStart=REPO_DIR_PLACEHOLDER/scripts/container/entrypoint.sh
Restart=on-failure
RestartSec=10
TimeoutStopSec=300
KillMode=mixed

[Install]
WantedBy=multi-user.target
UNIT
# The heredoc above is quoted so $ and backslashes stay literal; substitute the
# repo path afterwards (the unit must not depend on the installer's shell).
sed -i "s#REPO_DIR_PLACEHOLDER#$REPO_DIR#g" /etc/systemd/system/zd1200.service

systemctl daemon-reload
systemctl enable zd1200-net.service zd1200.service >/dev/null 2>&1 || true
systemctl enable zd1200-healthcheck.timer zd1200-watchdog.service >/dev/null 2>&1 || true
# Start them here as well as enabling them.  These units are created *after* the
# container booted, so multi-user.target/timers.target have already been reached
# and `enable` alone will never start them: the guest would run with no health
# probing and no recovery until the next container reboot.
systemctl start zd1200-net.service >/dev/null 2>&1 || true
systemctl start zd1200-healthcheck.timer >/dev/null 2>&1 || true
systemctl start zd1200-watchdog.service >/dev/null 2>&1 || true
# NOTE: zd1200.service is deliberately NOT started here.  Its entrypoint runs
# prepare-vm-disks.sh too, and doing that concurrently with step 6 below (each
# rm -rf's the same scratch directory) corrupts the patch run.  The installer (or
# the operator) starts the service once the disk is ready.

# --------------------------------------------------------------------------
# 6. boot the guest once so the disk is built and patched
# --------------------------------------------------------------------------
# prepare-vm-disks.sh builds the synthetic CF, writes the board data and applies
# the ordered rootfs patches.  Run it here (rather than letting the first
# service start do it) so the installer can report progress and so the guest IP
# can be discovered before the service is enabled.
if [ "$DO_DISKS" = 1 ]; then
    log "building and customising the guest disk (a few minutes)"
    STATE_DIR="$STATE_DIR" \
    SYNTHETIC_DISK="$STATE_DIR/synthetic-cf.img" \
    IMAGE_DIR="$IMAGE_DIR" \
    ZD_SERIAL="$ZD_SERIAL" ZD_MAC1="$ZD_MAC1" \
    ZD_MODEL="${ZD_MODEL:-ZD1200}" ZD_CUSTOMER="${ZD_CUSTOMER:-ruckus}" \
    ZD_SIGN_CERT_DIR="$SIGN_DIR" \
    ZD_ECDSA_SSH="$ECDSA" \
    ZD_NETWORK_MONITOR="$NETWORK_MONITOR" \
    ZD_R600_REPAIR="$R600_REPAIR" \
    ZD_ROOT_SSH_AUTHORIZED_KEYS="$STATE_DIR/provision/authorized_keys" \
    ZD_VIRTUAL_BUILD_ID="${ZD_VIRTUAL_BUILD_ID:-}" \
        run_logged "building and patching the guest disk (several minutes; log: $INSTALL_LOG)" \
        "$CC/prepare-vm-disks.sh"
fi

log "bootstrap complete"
