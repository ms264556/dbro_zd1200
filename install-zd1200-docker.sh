#!/usr/bin/env bash
#
# install-zd1200-docker.sh — build and start the ZD1200 Docker container
# (host-netns, macvtap on the host's physical NIC).  This is the Docker entry
# point, pairing with install-zd1200-lxc.sh for Proxmox: it prepares the
# vendor image (once), creates .env if absent, then builds and starts the
# container from docker/docker-compose.yml (GRUB is compiled in the image build).
#
# Usage:
#   ./install-zd1200-docker.sh firmware.img            # install from firmware alone
#   ./install-zd1200-docker.sh backup.bak firmware.img # configuration backup + firmware
#   ./install-zd1200-docker.sh cfcard_dump.img         # a ZD1200 card dump (self-contained)
#   ./install-zd1200-docker.sh foreign_dump.bin firmware.img
#                                                      # a ZD1100/ZD3000 dump + firmware
#   ./install-zd1200-docker.sh --no-up firmware.img    # only build/prepare (no boot)
#   ./install-zd1200-docker.sh                         # already prepared: start
#   ./install-zd1200-docker.sh --upgrade               # upgrade an existing
#                                                      # appliance in place: rebuild
#                                                      # the container image and
#                                                      # re-customise the roots from
#                                                      # their rollback store, keeping
#                                                      # /writable.  Needs no input.
#   ./install-zd1200-docker.sh --root-ssh-key ~/.ssh/id_ed25519.pub
#                                                      # also build the static dropbear
#                                                      # replacement and enable public-key
#                                                      # root SSH on TCP 2222 (slow build)
#
# The inputs are classified by their contents, not their names.  A firmware
# upgrade file is a complete appliance on its own; a ZD configuration backup
# needs a ZD1200 firmware of the same release; a ZD1200 card dump carries its own
# rootfs and /writable; and a ZD1100/ZD3000 dump needs a ZD1200 firmware of the
# same release.  "Same release" means the first three version components
# (e.g. 9.10.2.0.84 pairs with 9.10.2.0.130).  --source/--firmware, --backup and
# --writable-from remain accepted as named aliases for the positionals.
#
# --upgrade replaces the inputs: it never re-prepares image/ and never rebuilds
# the CF disk (which would discard the appliance's configuration).  Root SSH, the
# ECDSA host key and the Network Monitor setting already installed are kept; a key
# is only replaced when --root-ssh-key is given explicitly.
#
# The container runs under host-netns; see README.md ("Host requirements" and
# "Gotchas") for what the host must provide (MAC-spoofing NIC, KVM optional).
set -euo pipefail

cd "$(dirname "$0")"
# Shared with the Proxmox entry point: console wording, MAC rules, input
# classification and SSH-key validation must behave identically on both.
# shellcheck source=scripts/install-common.sh
. ./scripts/install-common.sh

no_up=0
upgrade=0
r600_repair="${ZD_R600_REPAIR:-1}"
POSITIONALS=(); OPT_FIRMWARE=""; OPT_BACKUP=""; OPT_WRITABLE=""
# resolve_inputs() sets these; a bare run does not call it (see below).
INPUT_KIND=""; INPUT_PATH=""; FIRMWARE_PATH=""
writable_partition=""
root_ssh_key=""
[ -n "${ZD_ARCHIVE:-}" ] && POSITIONALS+=("$ZD_ARCHIVE")
while [ $# -gt 0 ]; do
    case "$1" in
        --no-up) no_up=1; shift ;;
        --upgrade) upgrade=1; shift ;;
        --root-ssh-key)
            [ $# -ge 2 ] || { echo "--root-ssh-key needs a public-key file or key string" >&2; exit 2; }
            root_ssh_key="$2"; shift 2 ;;
        --root-ssh-key=*) root_ssh_key="${1#*=}"; shift ;;
        --source|--firmware)
            [ $# -ge 2 ] || { echo "--source needs a firmware upgrade file" >&2; exit 2; }
            OPT_FIRMWARE="$2"; shift 2 ;;
        --source=*|--firmware=*) OPT_FIRMWARE="${1#*=}"; shift ;;
        --writable-from)
            [ $# -ge 2 ] || { echo "--writable-from needs a dump path" >&2; exit 2; }
            OPT_WRITABLE="$2"; shift 2 ;;
        --writable-from=*) OPT_WRITABLE="${1#*=}"; shift ;;
        --writable-partition)
            [ $# -ge 2 ] || { echo "--writable-partition needs START:COUNT" >&2; exit 2; }
            writable_partition="$2"; shift 2 ;;
        --writable-partition=*) writable_partition="${1#*=}"; shift ;;
        --backup)
            [ $# -ge 2 ] || { echo "--backup needs a ruckus_db_*.bak path" >&2; exit 2; }
            OPT_BACKUP="$2"; shift 2 ;;
        --backup=*) OPT_BACKUP="${1#*=}"; shift ;;
        --no-r600-repair) r600_repair=0; shift ;;
        -h|--help)
            sed -n '2,42p' "$0"
            exit 0
            ;;
        *) POSITIONALS+=("$1"); shift ;;
    esac
done

if [ "$upgrade" = 1 ]; then
    if [ "${#POSITIONALS[@]}" -gt 0 ] || [ -n "$OPT_FIRMWARE$OPT_BACKUP$OPT_WRITABLE" ]; then
        echo "--upgrade takes no input: it upgrades the existing appliance in place." >&2
        echo "To apply a backup, restore it from the appliance's Web UI; to move to" >&2
        echo "different firmware, reset the state and install." >&2
        exit 2
    fi
else
    # Sniff the positionals and apply the input rules (scripts/install-common.sh).
    # Only when there is something to resolve: a bare run is the documented
    # "already prepared: start", and resolve_inputs reports no input as an error.
    # With no image/ yet, the prepare step below says what a first run needs.
    if [ "${#POSITIONALS[@]}" -gt 0 ] || [ -n "$OPT_FIRMWARE$OPT_BACKUP$OPT_WRITABLE" ]; then
        resolve_inputs
    fi
fi

# Map the resolved inputs onto prepare-vendor-image.sh's existing interface: a
# positional firmware (or a self-contained ZD1200 dump), --writable-from to pair
# a dump's /writable with it, and --backup to stage a configuration backup.
archive=""; writable_from=""; backup_file=""
case "$INPUT_KIND" in
    firmware-only) archive="$FIRMWARE_PATH" ;;
    backup)        archive="$FIRMWARE_PATH"; backup_file="$INPUT_PATH" ;;
    zd1200-dump)
        if [ -n "$FIRMWARE_PATH" ]; then
            archive="$FIRMWARE_PATH"; writable_from="$INPUT_PATH"
        else
            archive="$INPUT_PATH"
        fi ;;
    foreign-dump)  archive="$FIRMWARE_PATH"; writable_from="$INPUT_PATH" ;;
esac
for f in "$archive" "$writable_from" "$backup_file"; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || { echo "input not found: $f" >&2; exit 1; }
    [ -r "$f" ] || { echo "input is not readable: $f" >&2; exit 1; }
done
if [ -n "$writable_partition" ]; then
    case "$INPUT_KIND" in
        zd1200-dump|foreign-dump) : ;;
        *) echo "--writable-partition is only meaningful with a card dump input" >&2; exit 2 ;;
    esac
fi

# --- docker access: use sudo if this user is not in the docker group --------
docker_cmd=(docker)
if ! docker info >/dev/null 2>&1; then
    if groups 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        echo "Cannot reach the Docker daemon — is dockerd running?" >&2
        exit 1
    elif sudo -n true 2>/dev/null; then
        echo "Not in the docker group, using sudo for docker (or: sudo usermod -aG docker \$USER)."
        docker_cmd=(sudo docker)
    else
        echo "Docker is not usable: add yourself to the docker group or enable sudo." >&2
        exit 1
    fi
fi

# The ap-11n-scorpion (R600) mesh repair patches the AP firmware the image
# delivers.  Disable it for a build that must keep the vendor AP images exactly
# as shipped.
export ZD_R600_REPAIR="$r600_repair"

# The compose file lives in docker/; --project-directory . keeps .env, the
# ./image volume mount and the build context rooted at the repo root.
compose_cmd=("${docker_cmd[@]}" compose --project-directory . -f docker/docker-compose.yml)

# --- 1a. optional public-key root SSH on TCP 2222 ---------------------------
# Supplying a public key enables the static-dropbear replacement build and
# installs a public-key-only root listener on 2222.  The key is staged in
# dropbear-provision/ (gitignored) for the container, and its content is part
# of the rootfs re-patch signature so rotating the key re-customises the disk.
key_line=""
if [ -n "$root_ssh_key" ]; then
    if [ -r "$root_ssh_key" ]; then
        key_line="$(head -n1 "$root_ssh_key" | tr -d '\r')"
    else
        key_line="$root_ssh_key"
    fi
elif [ -n "${ZD_ROOT_SSH_PUBLIC_KEY:-}" ]; then
    if [ -r "${ZD_ROOT_SSH_PUBLIC_KEY}" ]; then
        key_line="$(head -n1 "${ZD_ROOT_SSH_PUBLIC_KEY}" | tr -d '\r')"
    else
        key_line="${ZD_ROOT_SSH_PUBLIC_KEY}"
    fi
fi
# An upgrade keeps the key that is already provisioned (and the 2222 listener it
# enables): treating "the flag was not repeated" as "disable root SSH" would
# silently remove access.  A supplied key always wins, so rotating it still works.
if [ -z "$key_line" ] && [ "$upgrade" = 1 ] && [ -s dropbear-provision/authorized_keys ]; then
    key_line="$(head -n1 dropbear-provision/authorized_keys | tr -d '\r')"
    echo "== Keeping the existing root SSH key (${key_line%% *}) =="
fi
if [ -n "$key_line" ]; then
    key_line="$(read_public_key "$key_line")" \
        || { echo "--root-ssh-key is not an SSH public key: $key_line" >&2; exit 2; }
    mkdir -p dropbear-provision
    printf '%s\n' "$key_line" > dropbear-provision/authorized_keys
    # 0644, not 0600: it is a public key, and the container drops
    # CAP_DAC_OVERRIDE so it could not read a root-only host file.
    chmod 644 dropbear-provision/authorized_keys
    export ZD_ROOT_SSH=1
    export ZD_ROOT_SSH_PROVISION=./dropbear-provision
    echo "== Root SSH on TCP 2222 enabled (${key_line%% *}) =="
    echo "   The image build compiles the static dropbear replacement; the first"
    echo "   build downloads a ~110 MB cross toolchain and is slow."
else
    export ZD_ROOT_SSH=0
fi

# --- 1. build the container image --------------------------------------------
# The image doubles as the prepare helper: it carries e2fsprogs (debugfs),
# python3, tar and gzip, so the host needs no filesystem tooling to unpack a
# firmware archive or a card dump.  Built from docker/Dockerfile alone; it does
# not need image/ to exist yet.
echo "== Building the ZD1200 container image =="
"${compose_cmd[@]}" build

# --- 2. prepare image/ (once), inside that image -----------------------------
# prepare-vendor-image.sh decrypts the firmware / parses the dump and writes the
# vendor-derived artifacts into image/ (gitignored), which the container mounts
# read-only at /opt/zd1200/image.
image_name="local/zd1200-qemu"
# image/ is prepared once, from a specific set of inputs, and is then reused.
# Record which inputs those were, so a later run with a different firmware
# re-prepares instead of silently installing the release that happened to be
# prepared first.  Hashes, not paths: the same file at a new path is the same
# image.
image_stamp="image/.prepared-from"
inputs_fingerprint() {
    local f sum out=""
    for f in "$archive" "$writable_from" "$backup_file"; do
        if [ -n "$f" ]; then
            sum="$(sha256sum "$f" | awk '{print $1}')" || return 1
            out="${out}${sum}"$'\n'
        fi
    done
    printf '%swritable-partition=%s\n' "$out" "${writable_partition:-}"
}

prepare_from=""
prepared=0
if [ ! -f image/rootfs.ext2 ]; then
    if [ "$upgrade" = 1 ]; then
        echo "--upgrade needs an existing install (image/rootfs.ext2 missing)." >&2
        echo "Install once with a firmware image first:" >&2
        echo "  $0 /path/to/zd1200_<version>.img" >&2
        exit 1
    fi
    if [ -z "$archive" ]; then
        echo "First run needs a ZD1200 firmware upgrade file or a CF card dump:" >&2
        echo "  $0 /path/to/zd1200_<version>.img     # firmware upgrade" >&2
        echo "  $0 /path/to/cfcard_dump.img          # dd or ImageUSB card dump" >&2
        exit 1
    fi
    [ -f "$archive" ] || { echo "Input not found: $archive" >&2; exit 1; }
    mkdir -p image
    prepared=1
    prepare_from="$(inputs_fingerprint)"
elif [ "$upgrade" = 1 ]; then
    echo "== Reusing image/ (--upgrade never re-prepares) =="
elif [ -z "$archive" ]; then
    # No input given: the documented "already prepared, just start" run.
    echo "== Reusing image/ (no input given; delete image/ to re-prepare) =="
else
    want="$(inputs_fingerprint)"
    have="$(cat "$image_stamp" 2>/dev/null || true)"
    if [ -n "$have" ] && [ "$want" = "$have" ]; then
        echo "== Reusing image/ (already prepared from $archive) =="
    elif [ -n "$have" ]; then
        echo "== image/ was prepared from different inputs; re-preparing from $archive =="
        prepared=1
        prepare_from="$want"
    else
        echo "== image/ does not record what it was prepared from; re-preparing from $archive =="
        prepared=1
        prepare_from="$want"
    fi
fi

if [ "$prepared" = 1 ]; then
    prepare_args=("/input/$(basename "$archive")")
    run_mounts=(-v "$PWD:/repo" -v "$(cd "$(dirname "$archive")" && pwd):/input:ro")
    if [ -n "$writable_from" ]; then
        [ -f "$writable_from" ] || { echo "--writable-from not found: $writable_from" >&2; exit 1; }
        run_mounts+=(-v "$(cd "$(dirname "$writable_from")" && pwd):/writable-input:ro")
        prepare_args+=(--writable-from "/writable-input/$(basename "$writable_from")")
    fi
    if [ -n "$backup_file" ]; then
        run_mounts+=(-v "$(cd "$(dirname "$backup_file")" && pwd):/backup-input:ro")
        prepare_args+=(--backup "/backup-input/$(basename "$backup_file")")
    fi
    [ -n "$writable_partition" ] && prepare_args+=(--writable-partition "$writable_partition")
    echo "== Preparing image/ from $archive (inside the container image) =="
    "${docker_cmd[@]}" run --rm \
        --user "$(id -u):$(id -g)" \
        "${run_mounts[@]}" \
        -e TMPDIR=/repo/image \
        -e EXPECTED_ARCHIVE_SHA256="${EXPECTED_ARCHIVE_SHA256:-}" \
        "$image_name" /bin/bash /repo/scripts/build/prepare-vendor-image.sh "${prepare_args[@]}"
    # Only after a successful prepare: a half-written image/ must not look
    # current.
    printf '%s\n' "$prepare_from" > "$image_stamp"
    echo "== image/ prepared; recorded its inputs in $image_stamp =="
else
    echo "   (delete image/ to force a re-prepare)"
fi

# Stage the configuration backup the guest applies on its first boot.  The fresh
# prepare above already validated and staged it; when image/ was reused there is
# no firmware metadata to validate against, so rewrite the backup here and let
# the guest's verify-backup check the release (it logs a failure and keeps the
# factory configuration).  The rewrite also unlocks a ZD1100/ZD3000 backup, so
# any model's backup restores.  Clear a backup a previous run left behind when
# this run did not ask for one, so a factory-reset reinstall cannot silently pick
# it up.
if [ "$upgrade" = 0 ]; then
    if [ -n "$backup_file" ]; then
        if [ "$prepared" = 0 ]; then
            python3 scripts/build/unlock-backup.py "$backup_file" image/backup.bak
            rm -f image/backup-management-ip
            echo "== Staged the configuration backup for the guest's first-boot restore =="
        fi
    else
        rm -f image/backup.bak image/backup-management-ip
    fi
fi

# --- 3. .env + a unique container MAC ----------------------------------------
if [ ! -f .env ]; then
    cp docker/.env.example .env
    echo "== Created .env from docker/.env.example =="
    echo "   Edit ZD_SIGN_CERT_HOST if your signing-cert payload is elsewhere."
fi

# The guest's MAC1 is ZD_CONTAINER_MAC (MAC2 = MAC1 + 1).  Generate a unique,
# locally-administered MAC once and keep it in .env, so the identity is stable
# across container recreates.  The last octet is made even so MAC2 is the next
# odd number in the same prefix.
if ! grep -qE '^ZD_CONTAINER_MAC=([0-9a-f]{2}:){5}[0-9a-f]{2}$' .env; then
    container_mac="$(random_mac)"
    container_mac="$(printf '%s:%02x' "${container_mac%:*}" "$(( 0x${container_mac##*:} & 0xFE ))")"
    if grep -q '^ZD_CONTAINER_MAC=' .env; then
        sed -i "s/^ZD_CONTAINER_MAC=.*/ZD_CONTAINER_MAC=$container_mac/" .env
    else
        printf '\nZD_CONTAINER_MAC=%s\n' "$container_mac" >> .env
    fi
    echo "== Generated a unique container MAC: $container_mac (guest MAC1 = this) =="
fi

# --- 3a. per-instance interface and socket names -----------------------------
# network_mode: host makes the macvtap interface and the /tmp chardev sockets
# global to the host, so a second container using the default names would find
# the first one's macvtap, overwrite its MAC and bind over its sockets — the
# first guest then goes dark.  Derive unique names from ZD_CONTAINER_NAME and
# record them in .env; the historical names are kept for the default instance so
# an existing install does not move.
inst="$(sed -n 's/^ZD_CONTAINER_NAME=//p' .env 2>/dev/null | tail -n1)"
inst="${inst:-zd1200}"
if [ "$inst" = "zd1200" ]; then
    macvtap_if="mvt0"
    control_sock="/tmp/zd1200-control.sock"
    console_sock="/tmp/zd1200-console.sock"
    console_log="/tmp/zd1200-console.log"
else
    # IFNAMSIZ is 16, so "mvt-" + at most 11 characters fits.
    short="$(printf '%s' "$inst" | tr -c 'a-zA-Z0-9' '-' | cut -c1-11)"
    macvtap_if="mvt-$short"
    control_sock="/tmp/zd1200-control-$inst.sock"
    console_sock="/tmp/zd1200-console-$inst.sock"
    console_log="/tmp/zd1200-console-$inst.log"
fi
set_env_key() {  # set_env_key KEY VALUE
    if grep -q "^$1=" .env 2>/dev/null; then
        sed -i "s|^$1=.*|$1=$2|" .env
    else
        printf '%s=%s\n' "$1" "$2" >> .env
    fi
}
set_env_key ZD_MACVTAP_IF "$macvtap_if"
set_env_key ZD_CONTROL_SOCK "$control_sock"
set_env_key ZD_CONSOLE_SOCK "$console_sock"
set_env_key LOG_FILE "$console_log"
if [ "$inst" != "zd1200" ]; then
    echo "== Instance '$inst': macvtap $macvtap_if, console $console_log =="
fi

# --- 3b. optional source revision shown on the admin console ----------------
# The Network Monitor patch appends " virtual <rev>" to the ZoneDirector version
# so the running controller identifies the source it was built from.  Derive it
# from the checked-out revision unless .env pins one explicitly; Compose passes
# it to the container, where it is included in the patch signature.
if ! grep -qE '^ZD_VIRTUAL_BUILD_ID=..*' .env 2>/dev/null \
   && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    ZD_VIRTUAL_BUILD_ID="$(git rev-parse --short=7 HEAD 2>/dev/null | cut -c1-7 || true)"
    export ZD_VIRTUAL_BUILD_ID
    [ -n "$ZD_VIRTUAL_BUILD_ID" ] \
        && echo "== Admin console will report source revision: virtual $ZD_VIRTUAL_BUILD_ID =="
fi

# --- 4. start ---------------------------------------------------------------
# The image was built in step 1; compose up only creates/starts the container.
if [ "$no_up" = 1 ]; then
    if [ "$upgrade" = 1 ]; then
        echo "== Image rebuilt for upgrade (not started). =="
        echo "   Start it with: ${compose_cmd[*]} up -d --force-recreate"
    else
        echo "== Image built (not started). =="
    fi
elif [ "$upgrade" = 1 ]; then
    echo "== Upgrading the ZD1200 appliance in place =="
    echo "   The state volume (and /writable) is kept; the roots are re-customised"
    echo "   from their rollback store on start."
    "${compose_cmd[@]}" up -d --force-recreate
    echo
    echo "Upgraded. Follow it:   ${docker_cmd[*]} logs -f $inst"
    echo "Guest console:         ${docker_cmd[*]} exec $inst tail -f $console_log"
else
    echo "== Starting the ZD1200 container =="
    "${compose_cmd[@]}" up -d
    echo
    echo "Started. Follow boot:  ${docker_cmd[*]} logs -f $inst"
    echo "Guest console:         ${docker_cmd[*]} exec $inst tail -f $console_log"
fi
