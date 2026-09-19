#!/usr/bin/env bash
#
# install-zd1200-lxc.sh — guided installer for running the Ruckus ZoneDirector
# ZD1200 virtual appliance in a Proxmox VE LXC container.
#
# The container is a plain Debian CT: the project's QEMU toolchain and the
# ordered rootfs patches run directly inside it (no Docker), and the guest
# attaches to the LAN through a tap on a bridge inside the CT whose uplink is the
# container's own eth0.  The guest is therefore an ordinary L2 neighbour, so
# unlike the macvtap/Docker setup the Proxmox host and the container can reach
# the guest by IP.
#
# Usage (on the Proxmox host, as root):
#
#   ./install-zd1200-lxc.sh                       # guided (whiptail) install
#   ./install-zd1200-lxc.sh /path/to/zd1200_*.img # guided, source preselected
#   ./install-zd1200-lxc.sh --yes --source FILE --ctid 120 ...   # unattended
#
# Options:
#   --ctid N                 container ID (default: first free id >= 120)
#   --hostname NAME          container hostname (default zd1200)
#   --storage STORAGE        PVE storage for the rootfs (default: local-lvm)
#   --bridge BRIDGE          LAN bridge (default: vmbr0)
#   --rootfs SIZE            container disk size in GiB (default: 20; the
#                            guest artifacts need ~5, and a CF-dump build peaks
#                            near 9 while the writable is extracted)
#   --cores N / --memory MB  container sizing (defaults: 4 / 4096)
#   --start-on-boot / --no-start-on-boot
#   --source PATH            firmware upgrade file or CF card dump (on the host,
#                            or a file already in a PVE storage)
#   --upgrade                upgrade an existing ZD1200 container in place: copy
#                            the current checkout into it and re-customise the
#                            roots from their rollback store, keeping /writable.
#                            Takes no --source.  Uses --ctid to pick the
#                            container, or finds the one this installer made.
#   --writable-from PATH     take /writable + serial from a CF dump while the
#                            kernel/rootfs come from --source firmware
#   --writable-partition S:C override the detected dump geometry
#   --container-mac MAC      override the guest's board MAC seed (default: derived
#                            from the MAC Proxmox allocates for the container)
#   --advanced               ask for container id, storage, sizing and features
#                            (by default only the input and, if there is more than
#                            one, the LAN bridge are asked for)
#   --root-ssh-key PATH      enable public-key root SSH on TCP 2222 (slow: the
#                            static dropbear replacement is built in the CT)
#   --ecdsa / --no-ecdsa     add the ECDSA host key to the SSH service, or not.
#                            On --upgrade the container's current setting is
#                            kept unless one of these is given.
#   --network-monitor / --no-network-monitor
#                            install (or not) the Network Monitor page
#   --no-r600-repair         do not patch the ap-11n-scorpion (R600) AP image
#   --console-tty / --no-console-tty
#                            show the guest's serial console in the Proxmox
#                            "Console" tab, or leave a login prompt there
#   --keep-ct-address        keep the container's own IP address while the guest
#                            runs (default: release it, so only the guest is on
#                            the LAN and in the Proxmox Summary)
#   --static-ip CIDR         give the container a static host IP instead of DHCP
#                            (e.g. 10.222.1.180/24; gateway from --gateway)
#   --gateway IP             default gateway for --static-ip
#   --template PATH          LXC template to use (default: newest local debian-*)
#   --timeout SEC            guest readiness deadline (default 1200)
#   --yes                    do not ask for confirmation
#   --non-interactive        fail instead of prompting (implies --yes)
#   -h | --help
set -euo pipefail

# This script lives at the repository root.  Resolve the root from its own
# location so a copy elsewhere (or a symlink into $PATH) still finds the tree,
# rather than assuming a parent directory.
REPO_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
[ -f "$REPO_ROOT/install-zd1200-lxc.sh" ] || {
    echo "error: cannot locate the repository root (looked in $REPO_ROOT)" >&2
    exit 1
}
# Shared with the Docker entry point (see scripts/install-common.sh).
# shellcheck source=scripts/install-common.sh
. "$REPO_ROOT/scripts/install-common.sh"
DEFAULT_CT_STATE=/var/lib/zd1200
DEFAULT_CT_REPO=/opt/zd1200

CTID=""; CT_HOSTNAME="zd1200"; STORAGE=""; BRIDGE=""; # The container holds the Debian userland + QEMU (~0.5 GiB), the prepared vendor
# artifacts (~1.1 GiB) and the synthetic CF, which is ~1.9 GiB and briefly
# duplicated while it is built (a CF-dump build also keeps the extracted
# writable). 20 GiB leaves room for that transient peak and some growth, and on
# thin storage only the used part is allocated.  PVE's own installer suggests 20
# for a Debian 13 container.
ROOTFS_SIZE=20
CORES=4; MEMORY=4096; ONBOOT=1
SOURCE=""; WRITABLE_FROM=""; WRITABLE_PARTITION=""; CONTAINER_MAC_OVERRIDE=""
ADVANCED=0
ROOT_SSH_KEY=""; ECDSA=1; NETWORK_MONITOR=1; R600_REPAIR=1; CONSOLE_TTY=1; KEEP_CT_ADDRESS=0
STATIC_IP=""; GATEWAY=""; TEMPLATE=""; TIMEOUT=1200
ASSUME_YES=0; INTERACTIVE=1
UPGRADE=0
# Set when the matching option was given explicitly, so an upgrade can keep the
# feature set already configured in the container by default.
ECDSA_SET=0; NETWORK_MONITOR_SET=0; CONSOLE_TTY_SET=0; KEEP_CT_ADDRESS_SET=0

# whiptail geometry (the PVE helper convention).
WT=(whiptail --backtitle "ZD1200 LXC installer" --title "ZD1200" --cancel-button Cancel)


while [ $# -gt 0 ]; do
    case "$1" in
        --ctid)                 CTID="${2:?}"; shift 2 ;;
        --hostname)             CT_HOSTNAME="${2:?}"; shift 2 ;;
        --storage)              STORAGE="${2:?}"; shift 2 ;;
        --bridge)               BRIDGE="${2:?}"; shift 2 ;;
        --rootfs)               ROOTFS_SIZE="${2:?}"; shift 2 ;;
        --cores)                CORES="${2:?}"; shift 2 ;;
        --memory)               MEMORY="${2:?}"; shift 2 ;;
        --start-on-boot)        ONBOOT=1; shift ;;
        --no-start-on-boot)     ONBOOT=0; shift ;;
        --source)               SOURCE="${2:?}"; shift 2 ;;
        --upgrade)              UPGRADE=1; shift ;;
        --container-mac)        CONTAINER_MAC_OVERRIDE="${2:?}"; shift 2 ;;
        --advanced)             ADVANCED=1; shift ;;
        --writable-from)        WRITABLE_FROM="${2:?}"; shift 2 ;;
        --writable-partition)   WRITABLE_PARTITION="${2:?}"; shift 2 ;;
        --root-ssh-key)         ROOT_SSH_KEY="${2:?}"; shift 2 ;;
        --ecdsa)                ECDSA=1; ECDSA_SET=1; shift ;;
        --no-ecdsa)             ECDSA=0; ECDSA_SET=1; shift ;;
        --network-monitor)      NETWORK_MONITOR=1; NETWORK_MONITOR_SET=1; shift ;;
        --no-network-monitor)   NETWORK_MONITOR=0; NETWORK_MONITOR_SET=1; shift ;;
        --no-r600-repair)       R600_REPAIR=0; shift ;;
        --console-tty)          CONSOLE_TTY=1; CONSOLE_TTY_SET=1; shift ;;
        --no-console-tty)       CONSOLE_TTY=0; CONSOLE_TTY_SET=1; shift ;;
        --keep-ct-address)      KEEP_CT_ADDRESS=1; KEEP_CT_ADDRESS_SET=1; shift ;;
        --static-ip)            STATIC_IP="${2:?}"; shift 2 ;;
        --gateway)              GATEWAY="${2:?}"; shift 2 ;;
        --template)             TEMPLATE="${2:?}"; shift 2 ;;
        --timeout)              TIMEOUT="${2:?}"; shift 2 ;;
        --yes)                  ASSUME_YES=1; shift ;;
        --non-interactive)      ASSUME_YES=1; INTERACTIVE=0; shift ;;
        -h|--help)              sed -n '2,65p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*)                     die "unknown option: $1" ;;
        *)                      SOURCE="$1"; shift ;;
    esac
done

# --------------------------------------------------------------------------
# 0. host checks and discovery
# --------------------------------------------------------------------------
step "checking the Proxmox host"
[ "$(id -u)" = 0 ] || die "run as root on the Proxmox host (it uses pct)"
for c in pct pvesm pveam qm whiptail; do
    command -v "$c" >/dev/null || die "$c not found — is this a Proxmox VE host?"
done
NODE="$(hostname -s)"
PVE_VER="$(pveversion 2>/dev/null | head -1)"
info "node $NODE — $PVE_VER"

if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    HAVE_KVM=1
else
    HAVE_KVM=0
    warn "/dev/kvm is missing or not writable: the guest will run under TCG (slow boots)"
fi

# Storage: every storage that can hold container rootfs, with free space.
mapfile -t STORAGES < <(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 {print $1}')
[ "${#STORAGES[@]}" -gt 0 ] || die "no storage supports container rootfs (content rootdir)"
free_gb() { pvesm status --content rootdir 2>/dev/null | awk -v s="$1" '$1==s {printf "%d", $6/1048576}'; }
storage_menu_label() { printf '%s (%s GB free)' "$1" "$(free_gb "$1")"; }

# Bridges: the LAN the guest should join.
mapfile -t BRIDGES < <(awk '/^iface (vmbr|vmbr[0-9])/ {print $2}' /etc/network/interfaces 2>/dev/null | sort -u)
[ "${#BRIDGES[@]}" -gt 0 ] || BRIDGES=(vmbr0)

list_templates() {
    find /var/lib/vz/template/cache /mnt/pve /mnt/*/template/cache -maxdepth 1 \
         -name 'debian-*standard_*.tar.zst' -o -maxdepth 1 -name 'debian-*standard_*.tar.gz' \
         2>/dev/null | sort -u
}
mapfile -t TEMPLATES < <(list_templates)
[ "${#TEMPLATES[@]}" -gt 0 ] || warn "no local debian-* LXC template found"

# Candidate firmware/dump files that already live on this host: anything in a
# PVE storage, plus the usual input directories.
list_sources() {
    local dirs=(/var/lib/vz/template/iso /var/lib/vz/template/cache /var/lib/vz/dump /root /root/zd-inputs /root/images)
    local d f
    for d in "${dirs[@]}"; do
        [ -d "$d" ] || continue
        find "$d" -maxdepth 1 -type f \
             \( -name '*.img' -o -name '*.bin' -o -name '*.7z' -o -name '*.zip' \) 2>/dev/null
    done | sort -u
}

first_free_ctid() {
    local id
    for id in $(seq 120 199); do
        [ -f "/etc/pve/lxc/$id.conf" ] || { printf '%s' "$id"; return; }
    done
    printf '200'
}

# One line describing a bridge, so the choice is informed: its address and
# whether it carries a default route (i.e. is the management LAN).
bridge_hint() {
    local br="$1" addr gateway
    addr="$(ip -4 -o addr show dev "$br" 2>/dev/null | awk '{print $4; exit}')"
    gateway="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"
    if [ -n "$addr" ]; then
        printf '%s%s' "$addr" "$([ -n "$gateway" ] && echo " (has the default route)")"
    else
        echo "no address configured"
    fi
}

next_free_ctid() {
    # A CT id whose /etc/pve/lxc/<id>.conf and /etc/pve/qemu-server/<id>.conf are
    # both absent — avoids colliding with an existing VM as well.
    local id
    for id in $(seq 120 999); do
        [ -f "/etc/pve/lxc/$id.conf" ] && continue
        [ -f "/etc/pve/qemu-server/$id.conf" ] && continue
        printf '%s' "$id"; return
    done
    die "no free container id in 120..999"
}

# --------------------------------------------------------------------------
# 0b. --upgrade: re-provision an existing container from this checkout, without
# touching the firmware image, /writable, or the keys it already holds.
# --------------------------------------------------------------------------
detect_zd1200_ctid() {
    # The container this installer created carries its description marker.
    local f id found=""
    for f in /etc/pve/lxc/*.conf; do
        [ -f "$f" ] || continue
        grep -q 'installed by dbro_zd1200/install-zd1200-lxc.sh' "$f" || continue
        id="$(basename "$f" .conf)"
        [ -n "$found" ] && die "more than one ZD1200 container found ($found, $id); pass --ctid"
        found="$id"
    done
    [ -n "$found" ] || die "no ZD1200 container found (none carries this installer's description); pass --ctid"
    printf '%s' "$found"
}

# ct_conf_get <ctid> <key>: one value from the container's /etc/zd1200.conf.
ct_conf_get() {
    pct exec "$1" -- bash -c "sed -n 's/^$2=//p' /etc/zd1200.conf 2>/dev/null | head -n1" 2>/dev/null || true
}

upgrade_existing_container() {
    [ -n "$SOURCE" ] && die "--upgrade takes no firmware/source argument"
    [ -z "$CTID" ] && CTID="$(detect_zd1200_ctid)"
    [ -f "/etc/pve/lxc/$CTID.conf" ] || die "container $CTID does not exist"
    pct status "$CTID" >/dev/null 2>&1 || die "cannot query container $CTID"

    info "upgrading container $CTID in place (keeping /writable and its keys)"

    # The feature set already configured in the container is the default; an
    # explicitly passed flag still overrides it.
    local v key_line="" ct_key="$DEFAULT_CT_STATE/provision/authorized_keys"
    v="$(ct_conf_get "$CTID" ZD_ECDSA_SSH)"
    [ "$ECDSA_SET" = 1 ] || ECDSA="${v:-1}"
    v="$(ct_conf_get "$CTID" ZD_NETWORK_MONITOR)"
    [ "$NETWORK_MONITOR_SET" = 1 ] || NETWORK_MONITOR="${v:-1}"
    if [ "$CONSOLE_TTY_SET" = 0 ]; then
        if pct exec "$CTID" -- grep -q '^ZD_CONSOLE_SOCK=' /etc/zd1200.conf 2>/dev/null; then
            CONSOLE_TTY=1
        else
            CONSOLE_TTY=0
        fi
    fi
    if [ "$KEEP_CT_ADDRESS_SET" = 0 ]; then
        v="$(ct_conf_get "$CTID" ZD_CT_ADDRESS_FOLLOW_QEMU)"
        if [ "$v" = "0" ]; then KEEP_CT_ADDRESS=1; else KEEP_CT_ADDRESS=0; fi
    fi

    # Keep the provisioned root-SSH key unless a new one was supplied.  Nothing
    # here deletes a key: patch 60 re-installs the rootfs copy from this file.
    if [ -n "$ROOT_SSH_KEY" ]; then
        [ -r "$ROOT_SSH_KEY" ] || die "SSH public key not readable: $ROOT_SSH_KEY"
        key_line="$(read_public_key "$ROOT_SSH_KEY")" || die "$ROOT_SSH_KEY is not an SSH public key"
        info "root SSH key .... replacing with ${key_line%% *}"
    else
        key_line="$(pct exec "$CTID" -- cat "$ct_key" 2>/dev/null | head -n1 | tr -d '\r' || true)"
        [ -n "$key_line" ] && info "root SSH key .... keeping ${key_line%% *}"
    fi

    if [ "$(pct status "$CTID" | awk '{print $2}')" != "running" ]; then
        step "starting container $CTID"
        pct start "$CTID"
        for _ in $(seq 1 30); do
            pct exec "$CTID" -- true >/dev/null 2>&1 && break
            sleep 1
        done
    fi

    step "stopping the appliance"
    # Stop the watchdog first: the guest is about to be down while the roots are
    # patched, and a watchdog that keeps probing would eventually reboot it.
    pct exec "$CTID" -- systemctl stop zd1200-watchdog.service 2>/dev/null || true
    pct exec "$CTID" -- systemctl stop zd1200.service 2>/dev/null || true

    step "copying the current checkout into the container"
    pct exec "$CTID" -- mkdir -p "$DEFAULT_CT_REPO"
    # Replace the checkout's own trees rather than overlaying them: a patch or
    # script deleted in the new revision must not linger in the container, or it
    # stays in the patch signature and keeps being applied.  The built payloads
    # (dropbear/, ruckus-squashfs/) are deliberately kept; the bootstrap rebuilds
    # analytics/ and re-links scripts/container/{image,bl7,analytics,dropbear}.
    pct exec "$CTID" -- bash -c "cd '$DEFAULT_CT_REPO' && rm -rf analytics bl7 docker docs proxmox scripts && rm -f README.md LICENSE install-zd1200-docker.sh install-zd1200-lxc.sh"
    tar -C "$REPO_ROOT" -cf - \
        --exclude='./.git' --exclude='./.reasonix' --exclude='./.boot-test' \
        --exclude='./image' --exclude='./dropbear-provision' --exclude='./proxmox-build' \
        . | pct exec "$CTID" -- tar -C "$DEFAULT_CT_REPO" -xf -

    step "re-provisioning (packages and image/ kept; roots re-customised)"
    bootstrap_args=(
        --repo-dir "$DEFAULT_CT_REPO"
        --state-dir "$DEFAULT_CT_STATE"
        --skip-packages
        --skip-image
        --ct-dhcp
    )
    [ -n "$key_line" ] && bootstrap_args+=(--root-ssh-key "$key_line")
    [ "$ECDSA" = 0 ] && bootstrap_args+=(--no-ecdsa)
    [ "$NETWORK_MONITOR" = 0 ] && bootstrap_args+=(--no-network-monitor)
    [ "$R600_REPAIR" = 0 ] && bootstrap_args+=(--no-r600-repair)
    [ "$CONSOLE_TTY" = 0 ] && bootstrap_args+=(--no-console-tty)
    [ "$KEEP_CT_ADDRESS" = 1 ] && bootstrap_args+=(--keep-ct-address)
    if ! pct exec "$CTID" -- "$DEFAULT_CT_REPO/proxmox/zd1200-ct-bootstrap.sh" "${bootstrap_args[@]}"; then
        die "container upgrade failed — see the output above (the container is left in place: pct enter $CTID)"
    fi

    # The host-side summary helper may have changed with the project.
    install -m 0755 "$REPO_ROOT/proxmox/zd1200-pve-summary-host.sh" /usr/local/sbin/zd1200-pve-summary-host
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart zd1200-pve-summary.timer >/dev/null 2>&1 || true
    /usr/local/sbin/zd1200-pve-summary-host "$CTID" >/dev/null 2>&1 || true

    step "starting the appliance"
    # Drop the previous boot's console log: the readiness check below greps for
    # the guest's READY line, and a stale one would pass instantly.
    pct exec "$CTID" -- rm -f /tmp/zd1200-console.log
    pct exec "$CTID" -- systemctl start --no-block zd1200.service
    info "waiting up to ${TIMEOUT}s for the guest to report READY (watch: pct exec $CTID -- journalctl -fu zd1200)"
    deadline=$((SECONDS + TIMEOUT))
    guest_ip=""
    while (( SECONDS < deadline )); do
        guest_ip="$(pct exec "$CTID" -- bash -c 'cat /var/lib/zd1200/guest-ip 2>/dev/null' || true)"
        if pct exec "$CTID" -- bash -c 'grep -qF "System go into READY status." /tmp/zd1200-console.log 2>/dev/null'; then
            printf '  [%4ds] guest READY\n' "$((SECONDS - (deadline - TIMEOUT)))"
            break
        fi
        if ! pct exec "$CTID" -- systemctl is-active --quiet zd1200.service; then
            warn "the zd1200 service stopped early"
            pct exec "$CTID" -- journalctl -u zd1200 -n 40 --no-pager || true
            break
        fi
        sleep 5
    done

    if [ -n "$guest_ip" ]; then
        guest_url="https://$guest_ip/"
    else
        guest_url="<not known yet: see Address below>"
    fi
    cat <<EOF

Upgrade complete for container $CTID.

  Guest URL ....... $guest_url
  Address ......... pct exec $CTID -- cat /var/lib/zd1200/guest-ip
  Service ......... pct exec $CTID -- systemctl status zd1200
  Logs ............ pct exec $CTID -- journalctl -fu zd1200
  Install log ..... pct exec $CTID -- tail -50 /var/lib/zd1200/install.log
EOF
    if [ -n "$key_line" ]; then
        printf '  Root SSH ........ ssh -p 2222 -i <key> root@%s\n' "${guest_ip:-<guest-ip>}"
    fi
}

if [ "$UPGRADE" = 1 ]; then
    upgrade_existing_container
    exit 0
fi


# --------------------------------------------------------------------------
# 1. source selection
# --------------------------------------------------------------------------
if [ -z "$SOURCE" ]; then
    mapfile -t FOUND < <(list_sources)
    if [ "$INTERACTIVE" = 0 ]; then
        die "--source is required in --non-interactive mode"
    fi
    choices=()
    for f in "${FOUND[@]}"; do
        choices+=("$f" "$(classify_input "$f") — $(( $(stat -c%s "$f") / 1048576 )) MiB")
    done
    choices+=("other" "Enter the path to a firmware file or card dump")
    choices+=("advanced" "Advanced: choose container id, storage, sizing and features")
    picked="$("${WT[@]}" --menu "Which firmware or card dump should it build from?" 22 96 12 "${choices[@]}" 3>&1 1>&2 2>&3)" \
        || die "cancelled"
    case "$picked" in
        other)
            SOURCE="$("${WT[@]}" --inputbox "Path to the firmware upgrade file or card dump:" 10 90 "" 3>&1 1>&2 2>&3)" || die "cancelled"
            ;;
        advanced)
            ADVANCED=1
            SOURCE="$("${WT[@]}" --inputbox "Path to the firmware upgrade file or card dump:" 10 90 "" 3>&1 1>&2 2>&3)" || die "cancelled"
            ;;
        *)  SOURCE="$picked" ;;
    esac
fi

[ -e "$SOURCE" ] || die "source not found: $SOURCE"
[ -f "$SOURCE" ] || die "source is not a regular file: $SOURCE"
[ -r "$SOURCE" ] || die "source is not readable: $SOURCE"

SOURCE_KIND="$(classify_input "$SOURCE" 2>/dev/null || echo unknown)"
case "$SOURCE_KIND" in
    firmware) info "source: $SOURCE (firmware upgrade image)" ;;
    cf-dump)  info "source: $SOURCE (CompactFlash card dump)" ;;
    *)
        if [ "$INTERACTIVE" = 1 ]; then
            "${WT[@]}" --yesno "$(printf 'The source does not look like a ZD1200 firmware upgrade file or a CF card dump:\n\n  %s\n\nContinue anyway? The preparation step will reject it if it is unusable.' "$SOURCE")" 14 78 \
                || die "cancelled"
        fi
        info "source: $SOURCE (unrecognised; will be validated during preparation)"
        ;;
esac

if [ -n "$WRITABLE_FROM" ]; then
    [ -f "$WRITABLE_FROM" ] || die "--writable-from not found: $WRITABLE_FROM"
    [ "$(classify_input "$WRITABLE_FROM")" = cf-dump ] \
        || warn "--writable-from does not look like a CF dump; continuing"
fi

# --------------------------------------------------------------------------
# 2. container settings
# --------------------------------------------------------------------------
# Only the source and (when the host offers a choice) the bridge are asked for.
# Everything else has a usable default derived from what the host actually
# provides, and is shown in the summary before anything is created; all of it can
# be set with the flags (`--help`), or via the source menu's Advanced entry.
if [ "$INTERACTIVE" = 1 ] && [ "${#BRIDGES[@]}" -gt 1 ] && [ -z "$BRIDGE" ]; then
    bridge_choices=()
    for br in "${BRIDGES[@]}"; do
        bridge_choices+=("$br" "$(bridge_hint "$br")")
    done
    BRIDGE="$("${WT[@]}" --menu "Which bridge should the guest join?" 20 84 10 "${bridge_choices[@]}" 3>&1 1>&2 2>&3)" || die "cancelled"
fi

if [ "$INTERACTIVE" = 1 ] && [ "$ADVANCED" = 1 ]; then
    [ -n "$STORAGE" ] || STORAGE="${STORAGES[0]}"

    storage_choices=()
    for st in "${STORAGES[@]}"; do storage_choices+=("$st" "$(storage_menu_label "$st")"); done
    STORAGE="$("${WT[@]}" --menu "Storage for the container rootfs" 20 78 10 "${storage_choices[@]}" 3>&1 1>&2 2>&3)" || die "cancelled"

    basics="$("${WT[@]}" --inputbox "Container ID:" 8 60 "$CTID" 3>&1 1>&2 2>&3)" || die "cancelled"
    CTID="$basics"
    basics="$("${WT[@]}" --inputbox "Container hostname:" 8 60 "$CT_HOSTNAME" 3>&1 1>&2 2>&3)" || die "cancelled"
    CT_HOSTNAME="$basics"
    basics="$("${WT[@]}" --inputbox "Cores:" 8 60 "$CORES" 3>&1 1>&2 2>&3)" || die "cancelled"
    CORES="$basics"
    basics="$("${WT[@]}" --inputbox "Memory (MiB):" 8 60 "$MEMORY" 3>&1 1>&2 2>&3)" || die "cancelled"
    MEMORY="$basics"
    basics="$("${WT[@]}" --inputbox "Disk size (GiB):" 8 60 "$ROOTFS_SIZE" 3>&1 1>&2 2>&3)" || die "cancelled"
    ROOTFS_SIZE="$basics"

    net_menu="$("${WT[@]}" --menu "Container network address" 14 78 2 \
        dhcp "DHCP (the container takes an address from your LAN)" \
        static "Static address (enter it next)" 3>&1 1>&2 2>&3)" || die "cancelled"
    if [ "$net_menu" = static ]; then
        STATIC_IP="$("${WT[@]}" --inputbox "Static address in CIDR form (e.g. 10.222.1.180/24):" 8 70 "$STATIC_IP" 3>&1 1>&2 2>&3)" || die "cancelled"
        GATEWAY="$("${WT[@]}" --inputbox "Default gateway:" 8 70 "$GATEWAY" 3>&1 1>&2 2>&3)" || die "cancelled"
    fi

    feature_args=(--checklist "Optional pieces (space toggles, enter confirms)" 20 90 8)
    feature_args+=("root-ssh" "Public-key root SSH on TCP 2222 (builds dropbear; slow)" "$([ -n "$ROOT_SSH_KEY" ] && echo ON || echo OFF)")
    feature_args+=("ecdsa" "ECDSA SSH host key alongside RSA" "$([ "$ECDSA" = 1 ] && echo ON || echo OFF)")
    feature_args+=("netmon" "Network Monitor page and collectors" "$([ "$NETWORK_MONITOR" = 1 ] && echo ON || echo OFF)")
    feature_args+=("r600" "R600 / ap-11n-scorpion mesh repair" "$([ "$R600_REPAIR" = 1 ] && echo ON || echo OFF)")
    feature_args+=("onboot" "Start the container on host boot" "$([ "$ONBOOT" = 1 ] && echo ON || echo OFF)")
    selected="$("${WT[@]}" "${feature_args[@]}" 3>&1 1>&2 2>&3)" || die "cancelled"
    ECDSA=0; NETWORK_MONITOR=0; R600_REPAIR=0; ONBOOT=0
    case " $selected " in *'"root-ssh"'*) ROOT_SSH_WANTED=1 ;; *) ROOT_SSH_WANTED=0 ;; esac
    case " $selected " in *'"ecdsa"'*) ECDSA=1 ;; esac
    case " $selected " in *'"netmon"'*) NETWORK_MONITOR=1 ;; esac
    case " $selected " in *'"r600"'*) R600_REPAIR=1 ;; esac
    case " $selected " in *'"onboot"'*) ONBOOT=1 ;; esac
    if [ "${ROOT_SSH_WANTED:-0}" = 1 ] && [ -z "$ROOT_SSH_KEY" ]; then
        keyfile="$("${WT[@]}" --inputbox "Path to your SSH public key (.pub):" 8 80 "$HOME/.ssh/id_ed25519.pub" 3>&1 1>&2 2>&3)" || die "cancelled"
        ROOT_SSH_KEY="$keyfile"
    fi
fi

[ -n "$CTID" ] || CTID="$(next_free_ctid)"
[ -n "$STORAGE" ] || STORAGE="${STORAGES[0]}"
[ -n "$BRIDGE" ] || BRIDGE="${BRIDGES[0]}"
if [ -z "$TEMPLATE" ] && [ "${#TEMPLATES[@]}" -gt 0 ]; then
    TEMPLATE="$(printf '%s\n' "${TEMPLATES[@]}" | sort -V | tail -1)"
fi
# The guest needs Debian 13 (its QEMU provides the `igb` NIC model; Debian 12's
# does not).  A user with no template at all should not have to know that, so
# fetch the right one rather than failing with a hint.
if [ -z "$TEMPLATE" ]; then
    step "fetching a Debian 13 LXC template"
    pveam update >/dev/null 2>&1 || true
    tpl_name="$(pveam available --section system 2>/dev/null \
        | awk '$2 ~ /^debian-13-standard_/ && $2 ~ /_amd64\.tar\.zst$/ {print $2}' \
        | sort -V | tail -1)"
    if [ -n "$tpl_name" ]; then
        pveam download local "$tpl_name" >/dev/null 2>&1 || true
        TEMPLATE="/var/lib/vz/template/cache/$tpl_name"
    fi
fi
[ -n "$TEMPLATE" ] || die "could not fetch a Debian 13 template; download one yourself:
       pveam update && pveam download local debian-13-standard_<version>_amd64.tar.zst
     and pass it with --template"
[ -f "$TEMPLATE" ] || die "template not found: $TEMPLATE"
[ -f "/etc/pve/lxc/$CTID.conf" ] && die "container $CTID already exists"
[ -f "/etc/pve/qemu-server/$CTID.conf" ] && die "VM $CTID already exists"
[[ "$CTID" =~ ^[0-9]+$ ]] || die "--ctid must be numeric"
[[ "$CORES" =~ ^[0-9]+$ ]] || die "--cores must be numeric"
[[ "$MEMORY" =~ ^[0-9]+$ ]] || die "--memory must be numeric"

ROOT_SSH_KEY_LINE=""
if [ -n "$ROOT_SSH_KEY" ]; then
    [ -r "$ROOT_SSH_KEY" ] || die "SSH public key not readable: $ROOT_SSH_KEY"
    ROOT_SSH_KEY_LINE="$(read_public_key "$ROOT_SSH_KEY")" \
        || die "$ROOT_SSH_KEY is not an SSH public key"
fi

# --------------------------------------------------------------------------
# 2b. identity
# --------------------------------------------------------------------------
# No MAC is invented here: Proxmox allocates the container's veth MAC itself
# (PVE::Tools::random_ether_addr with the cluster's mac_prefix), and that
# allocation is the unique, cluster-aware identity we build the guest's
# board-data MAC from -- see guest_mac_seed() below and the bootstrap.
# --------------------------------------------------------------------------
# 3. summary + confirmation
# --------------------------------------------------------------------------
summary="$(cat <<EOF
Container
  ID ................ $CTID          hostname ....... $CT_HOSTNAME
  storage ........... $STORAGE ($(free_gb "$STORAGE") GB free)
  template .......... $(basename "$TEMPLATE")
  cores / memory .... $CORES / ${MEMORY} MiB
  rootfs ............ ${ROOTFS_SIZE} GiB
  bridge ............ $BRIDGE   # the LAN the guest (and your APs) will join
  guest MAC ......... derived from the CT's Proxmox-allocated MAC
  address ........... ${STATIC_IP:-DHCP}
  start on boot ..... $([ "$ONBOOT" = 1 ] && echo yes || echo no)
  /dev/kvm .......... $([ "$HAVE_KVM" = 1 ] && echo "yes (fast boots)" || echo "NO (TCG: slow)")

Source
  $SOURCE
  kind .............. $SOURCE_KIND
$([ -n "$WRITABLE_FROM" ] && printf '  /writable from ... %s\n' "$WRITABLE_FROM")
$([ -n "$WRITABLE_PARTITION" ] && printf '  writable partition  %s\n' "$WRITABLE_PARTITION")

Optional pieces
  root SSH (2222) ... $([ -n "$ROOT_SSH_KEY_LINE" ] && printf 'yes (%s)' "${ROOT_SSH_KEY_LINE%% *}" || echo no)
  ECDSA host key .... $([ "$ECDSA" = 1 ] && echo yes || echo no)
  Network Monitor ... $([ "$NETWORK_MONITOR" = 1 ] && echo yes || echo no)
  R600 mesh repair .. $([ "$R600_REPAIR" = 1 ] && echo yes || echo no)
  Console tab ....... $([ "$CONSOLE_TTY" = 1 ] && echo "guest serial console" || echo "container login prompt")
  Container address . $([ "$KEEP_CT_ADDRESS" = 1 ] && echo "kept while the guest runs" || echo "released while the guest runs")
EOF
)"
if [ "$INTERACTIVE" = 1 ] && [ "$ASSUME_YES" = 0 ]; then
    "${WT[@]}" --yesno "$summary

Proceed with the installation?" 30 84 || die "cancelled"
else
    info "$summary"
fi

# --------------------------------------------------------------------------
# 4. create the container
# --------------------------------------------------------------------------
# No hwaddr: let Proxmox allocate the container's MAC (cluster-aware, unique).
net_spec="name=eth0,bridge=$BRIDGE,firewall=0,type=veth"
if [ -n "$STATIC_IP" ]; then
    net_spec+=",ip=$STATIC_IP"
    [ -n "$GATEWAY" ] && net_spec+=",gw=$GATEWAY"
else
    net_spec+=",ip=dhcp"
fi

step "creating container $CTID"
pct create "$CTID" "$TEMPLATE" \
    --hostname "$CT_HOSTNAME" \
    --cores "$CORES" --memory "$MEMORY" --swap 1024 \
    --rootfs "$STORAGE:$ROOTFS_SIZE" \
    --net0 "$net_spec" \
    --features nesting=1,keyctl=1 \
    --unprivileged 1 --ostype debian \
    --onboot "$ONBOOT" \
    --description "Ruckus ZD1200 virtual appliance (installed by dbro_zd1200/install-zd1200-lxc.sh)"

# Device passthrough: /dev/kvm for hardware acceleration and /dev/net/tun for
# QEMU's tap device.  Proxmox's `dev0:` syntax (PVE 8.2+) creates the node in the
# container's /dev; inside an unprivileged CT the container cannot mknod its own
# device nodes, so these must come from the host.
#
# Listing any device in the config marks the CT as "has device passthrough",
# which makes Proxmox pass the environment (not a user-data disk) the next time
# it is needed, so the CT's own `ip=`/`gw=` addressing keeps working.
dev_args=()
[ "$HAVE_KVM" = 1 ] && dev_args+=(--dev0 path=/dev/kvm,mode=0666)
dev_args+=(--dev1 path=/dev/net/tun,mode=0666)
pct set "$CTID" \
    --env LC_ALL=C.UTF-8 --env LANG=C.UTF-8 \
    --hostname "$CT_HOSTNAME" \
    "${dev_args[@]}"

step "starting container $CTID"
pct start "$CTID"

# --------------------------------------------------------------------------
# 5. copy the project into the container
# --------------------------------------------------------------------------
step "copying the project into the container"
pct exec "$CTID" -- mkdir -p "$DEFAULT_CT_REPO"
tar -C "$REPO_ROOT" -cf - \
    --exclude='./.git' --exclude='./.reasonix' --exclude='./.boot-test' \
    --exclude='./image' --exclude='./dropbear-provision' --exclude='./proxmox-build' \
    . | pct exec "$CTID" -- tar -C "$DEFAULT_CT_REPO" -xf -

# Wait for the container's own network (needed for apt and git).
step "waiting for the container network"
ct_online=0
for _ in $(seq 1 30); do
    if pct exec "$CTID" -- getent hosts deb.debian.org >/dev/null 2>&1; then ct_online=1; break; fi
    sleep 2
done
[ "$ct_online" = 1 ] || warn "the container cannot resolve DNS yet; the package install may fail"

# --------------------------------------------------------------------------
# 6. stage the source firmware/dump inside the container
# --------------------------------------------------------------------------
# --------------------------------------------------------------------------
# 5b. pre-flight: install QEMU, then check it supports the guest's NIC model
# --------------------------------------------------------------------------
# The base Debian template has no QEMU, so install it here (the bootstrap skips
# the same work) and then probe it.  The guest needs the `igb` NIC model: the
# stock driver binds to an emulated 82576, and Debian 12's QEMU 7.2 does not
# provide it.  Without this check the install "succeeds" and the container then
# boot-loops forever -- every start fails with `Unsupported NIC model: igb`, the
# guest never boots, and nothing says why.
step "installing QEMU and checking the guest's NIC model is supported"
pct exec "$CTID" -- bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends qemu-system-x86 qemu-utils >/dev/null
' || die "could not install QEMU in container $CTID (no container network?)"

qemu_ver="$(pct exec "$CTID" -- bash -c 'qemu-system-i386 -version 2>/dev/null | head -1' 2>/dev/null || true)"
if pct exec "$CTID" -- bash -c 'qemu-system-i386 -net nic,model=help 2>&1 | tr " " "\n" | grep -qix igb'; then
    info "container QEMU: ${qemu_ver:-unknown} (igb available)"
else
    warn "container QEMU: ${qemu_ver:-unknown}"
    die "this template's QEMU does not provide the 'igb' NIC model the guest
     requires.  Use a Debian 13 template (QEMU 10), e.g.:
       pveam update && pveam download local debian-13-standard_13.6-1_amd64.tar.zst
     then re-run with --template.  Container $CTID was left in place for
     inspection; remove it with: pct destroy $CTID"
fi

step "staging the source inside the container"
ct_dir="$(dirname "$SOURCE")"
pct exec "$CTID" -- mkdir -p /root/zd-inputs
if [ -f "$SOURCE" ]; then
    pct push "$CTID" "$SOURCE" "/root/zd-inputs/$(basename "$SOURCE")"
    ct_source="/root/zd-inputs/$(basename "$SOURCE")"
else
    # An archive (.7z/.zip) is not handled by the preparation step.
    die "unsupported source type for automatic staging: $SOURCE"
fi
ct_writable=""
if [ -n "$WRITABLE_FROM" ]; then
    pct push "$CTID" "$WRITABLE_FROM" "/root/zd-inputs/$(basename "$WRITABLE_FROM")"
    ct_writable="/root/zd-inputs/$(basename "$WRITABLE_FROM")"
fi

# The board-data identity is derived from the container's uplink MAC (as
# install-zd1200-docker.sh derives it from ZD_CONTAINER_MAC).  Read it after the CT has
# started so the guest's MAC is stable for the life of the container.
# The guest's identity is derived inside the bootstrap from the MAC Proxmox
# allocated for the container's veth, so nothing is passed here.  Only an explicit
# --container-mac override is forwarded.
# --------------------------------------------------------------------------
# 7. bootstrap the container
# --------------------------------------------------------------------------
step "provisioning the container (packages, payloads, disk) — this is the slow part"
bootstrap_args=(
    --source "$ct_source"
    --repo-dir "$DEFAULT_CT_REPO"
    --state-dir "$DEFAULT_CT_STATE"
)
if [ -n "$STATIC_IP" ]; then
    bootstrap_args+=(--ct-address "$STATIC_IP")
else
    bootstrap_args+=(--ct-dhcp)
fi
[ -n "$ct_writable" ] && bootstrap_args+=(--writable-from "$ct_writable")
[ -n "$WRITABLE_PARTITION" ] && bootstrap_args+=(--writable-partition "$WRITABLE_PARTITION")
[ -n "$ROOT_SSH_KEY_LINE" ] && bootstrap_args+=(--root-ssh-key "$ROOT_SSH_KEY_LINE")
if [ -n "$CONTAINER_MAC_OVERRIDE" ]; then
    is_mac "$CONTAINER_MAC_OVERRIDE" || die "--container-mac is not a MAC address: $CONTAINER_MAC_OVERRIDE"
    bootstrap_args+=(--container-mac "$CONTAINER_MAC_OVERRIDE")
fi
[ "$ECDSA" = 0 ] && bootstrap_args+=(--no-ecdsa)
[ "$NETWORK_MONITOR" = 0 ] && bootstrap_args+=(--no-network-monitor)
[ "$R600_REPAIR" = 0 ] && bootstrap_args+=(--no-r600-repair)
[ "$CONSOLE_TTY" = 0 ] && bootstrap_args+=(--no-console-tty)
[ "$KEEP_CT_ADDRESS" = 1 ] && bootstrap_args+=(--keep-ct-address)

# The container's own address is only informational (printed in the summary).
ct_host_ip=""
if pct exec "$CTID" -- bash -c 'command -v ip >/dev/null'; then
    ct_host_ip="$(pct exec "$CTID" -- bash -c "ip -4 -o addr show eth0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1" || true)"
fi
[ -n "$ct_host_ip" ] && bootstrap_args+=(--host-ip "$ct_host_ip")

if ! pct exec "$CTID" -- test -x "$DEFAULT_CT_REPO/proxmox/zd1200-ct-bootstrap.sh"; then
    die "the project did not copy into container $CTID correctly (expected $DEFAULT_CT_REPO/proxmox/zd1200-ct-bootstrap.sh)"
fi
if ! pct exec "$CTID" -- "$DEFAULT_CT_REPO/proxmox/zd1200-ct-bootstrap.sh" "${bootstrap_args[@]}"; then
    die "container provisioning failed — see the output above (the container is left in place for inspection: pct enter $CTID)"
fi

# --------------------------------------------------------------------------
# 7b. publish the guest address to this container's Proxmox summary
# --------------------------------------------------------------------------
# The GUI's Summary tab shows the description, which is host-side data.  A timer
# on the host keeps it current from the address the guest reported; it only touches
# CTs that have a state dir (i.e. ones this project installed).
step "installing the Proxmox summary helper on the host"
install -m 0755 "$REPO_ROOT/proxmox/zd1200-pve-summary-host.sh" /usr/local/sbin/zd1200-pve-summary-host
cat > /etc/systemd/system/zd1200-pve-summary.service <<'UNIT'
[Unit]
Description=Publish ZD1200 guest addresses to the Proxmox summary

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/zd1200-pve-summary-host
UNIT

cat > /etc/systemd/system/zd1200-pve-summary.timer <<'UNIT'
[Unit]
Description=Keep ZD1200 guest addresses current in the Proxmox summary

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now zd1200-pve-summary.timer >/dev/null 2>&1 || true
/usr/local/sbin/zd1200-pve-summary-host "$CTID" >/dev/null 2>&1 || true

# --------------------------------------------------------------------------
# 8. systemd service
# --------------------------------------------------------------------------
step "systemd service"
# zd1200-ct-bootstrap.sh already wrote /etc/systemd/system/zd1200.service (and
# the zd1200-net.service that creates the container-side LAN bridge) and enabled
# both; the unit starts the project's ordinary entrypoint.sh.
pct exec "$CTID" -- systemctl is-enabled --quiet zd1200.service \
    || die "the zd1200 service was not installed"

# --------------------------------------------------------------------------
# 9. start and wait for the guest
# --------------------------------------------------------------------------
step "starting the appliance"
# Drop any previous boot's console log so a stale READY line cannot pass the
# readiness check below.
pct exec "$CTID" -- rm -f /tmp/zd1200-console.log
pct exec "$CTID" -- systemctl start --no-block zd1200.service
info "waiting up to ${TIMEOUT}s for the guest to report READY (watch: pct exec $CTID -- journalctl -fu zd1200)"
deadline=$((SECONDS + TIMEOUT))
guest_ip=""
while (( SECONDS < deadline )); do
    guest_ip="$(pct exec "$CTID" -- bash -c 'cat /var/lib/zd1200/guest-ip 2>/dev/null' || true)"
    if pct exec "$CTID" -- bash -c 'grep -qF "System go into READY status." /tmp/zd1200-console.log 2>/dev/null'; then
        printf '  [%4ds] guest READY\n' "$((SECONDS - (deadline - TIMEOUT)))"
        break
    fi
    if ! pct exec "$CTID" -- systemctl is-active --quiet zd1200.service; then
        warn "the zd1200 service stopped early"
        pct exec "$CTID" -- journalctl -u zd1200 -n 40 --no-pager || true
        break
    fi
    sleep 5
done

url_ip="${guest_ip:-${STATIC_IP%%/*}}"
# Keep the ANSI codes in variables: a $(printf ...) command substitution inside
# the heredoc swallows the newline that follows it, which silently glues the next
# output line onto this one.
bold="$(printf '\033[1m')"; reset="$(printf '\033[0m')"
# Build the URL explicitly.  Adjacent ${var:+...}${var:-...} expansions inside
# this heredoc are not parsed reliably by every bash, and they silently duplicate
# the value (observed on PVE 9.2's bash 5.2).  An if is unambiguous.
if [ -n "$url_ip" ]; then
    guest_url="https://$url_ip/"
else
    guest_url="<not known yet: see 'Address' below>"
fi
cat <<EOF

${bold}Installation complete.${reset}

  Container ....... $CTID ($CT_HOSTNAME)
  Console tab ..... $([ "$CONSOLE_TTY" = 1 ] && echo "the guest's serial console" || echo "container login prompt (--no-console-tty)")
  Guest console ... pct exec $CTID -- tail -f /tmp/zd1200-console.log
  Attach console .. pct exec $CTID -- python3 $DEFAULT_CT_REPO/scripts/container/attach-console.py
  Service ......... pct exec $CTID -- systemctl status zd1200
  Logs ............ pct exec $CTID -- journalctl -fu zd1200

  Guest URL ....... $guest_url
  Address ......... pct exec $CTID -- cat /var/lib/zd1200/guest-ip
  From another LAN machine:  curl -kI https://<guest-ip>/admin10/login.jsp

  First boot runs the factory setup wizard; complete it, reboot once (so the
  appliance generates its SSH host key), then log in.
EOF
if [ -n "$ROOT_SSH_KEY_LINE" ]; then
    printf '  Root SSH ........ ssh -p 2222 -i <key> root@%s\n' "${url_ip:-<guest-ip>}"
fi
