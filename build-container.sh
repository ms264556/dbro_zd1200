#!/usr/bin/env bash
#
# build-container.sh — build and start the ZD1200 Docker container (host-netns,
# macvtap on the host's physical NIC).  This is the one entry point: it prepares
# the vendor image (once), creates .env if absent, then builds and starts the
# container from docker/docker-compose.yml (GRUB is compiled in the image build).
#
# Usage:
#   ./build-container.sh /path/to/zd1200_*.img       # first run: extract + build + start
#   ./build-container.sh                             # already extracted: build + start
#   ./build-container.sh --no-up /path/to/*.img      # only build the image (no boot)
#   ./build-container.sh --root-ssh-key ~/.ssh/id_ed25519.pub
#                                                    # also build the static dropbear
#                                                    # replacement and enable public-key
#                                                    # root SSH on TCP 2222 (slow build)
#
# The container runs under host-netns; see README.md ("Host requirements" and
# "Gotchas") for what the host must provide (MAC-spoofing NIC, KVM optional).
set -euo pipefail

cd "$(dirname "$0")"

no_up=0
archive="${ZD_ARCHIVE:-}"
root_ssh_key=""
while [ $# -gt 0 ]; do
    case "$1" in
        --no-up) no_up=1; shift ;;
        --root-ssh-key)
            [ $# -ge 2 ] || { echo "--root-ssh-key needs a public-key file or key string" >&2; exit 2; }
            root_ssh_key="$2"; shift 2 ;;
        --root-ssh-key=*) root_ssh_key="${1#*=}"; shift ;;
        -h|--help)
            sed -n '2,17p' "$0"
            exit 0
            ;;
        *) archive="${1:-}"; shift ;;
    esac
done

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

# The compose file lives in docker/; --project-directory . keeps .env, the
# ./image volume mount and the build context rooted at the repo root.
compose_cmd=("${docker_cmd[@]}" compose --project-directory . -f docker/docker-compose.yml)

# --- 1. extract the vendor image (once) --------------------------------------
# prepare-vendor-image.sh decrypts the download and unpacks it into image/ (gitignored),
# the vendor-derived artifacts the container mounts read-only at /opt/zd1200/image.
if [ ! -f image/rootfs.ext2 ]; then
    if [ -z "$archive" ]; then
        echo "First run needs the ZD1200 firmware upgrade file (downloaded .img):" >&2
        echo "  $0 /path/to/zd1200_<version>.img" >&2
        exit 1
    fi
    echo "== Extracting the firmware image from $archive =="
    ./scripts/build/prepare-vendor-image.sh "$archive"
else
    echo "== Reusing image/ (delete it to re-extract, or run scripts/build/prepare-vendor-image.sh) =="
fi

# --- 2. .env + a unique container MAC ----------------------------------------
if [ ! -f .env ]; then
    cp docker/.env.example .env
    echo "== Created .env from docker/.env.example =="
    echo "   Edit ZD_SIGN_CERT_HOST if your signing-cert payload is elsewhere."
fi

# The guest's board-data MAC is derived from ZD_CONTAINER_MAC + 1.  Generate a
# unique, locally-administered MAC once (host NIC OUI + random device part) and
# keep it in .env, so the identity is stable across container recreates.
if ! grep -qE '^ZD_CONTAINER_MAC=([0-9a-f]{2}:){5}[0-9a-f]{2}$' .env; then
    base_mac="$(cat /sys/class/net/eth0/address 2>/dev/null || true)"
    if printf '%s' "$base_mac" | grep -qE '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'; then
        first_octet=$(( 0x${base_mac:0:2} | 0x02 ))          # locally administered
        oui_mid="${base_mac:3:5}"                            # xx:xx
        first_octet="$(printf '%02x' "$first_octet")"
    else
        first_octet="02"; oui_mid="00:00"
    fi
    rand_lo="$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n' | sed 's/\(..\)/\1:/g;s/:$//')"
    container_mac="$first_octet:$oui_mid:$rand_lo"
    if grep -q '^ZD_CONTAINER_MAC=' .env; then
        sed -i "s/^ZD_CONTAINER_MAC=.*/ZD_CONTAINER_MAC=$container_mac/" .env
    else
        printf '\nZD_CONTAINER_MAC=%s\n' "$container_mac" >> .env
    fi
    echo "== Generated a unique container MAC: $container_mac (guest MAC1 = this) =="
fi

# --- 2b. optional source revision shown on the admin console ----------------
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

# --- 2c. optional public-key root SSH on TCP 2222 ---------------------------
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
if [ -n "$key_line" ]; then
    case "$key_line" in
        ssh-rsa\ *|ssh-ed25519\ *|ecdsa-sha2-nistp256\ *|ecdsa-sha2-nistp384\ *|ecdsa-sha2-nistp521\ *) ;;
        *) echo "--root-ssh-key is not an SSH public key: $key_line" >&2; exit 2 ;;
    esac
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

# --- 3. build / start -------------------------------------------------------
if [ "$no_up" = 1 ]; then
    echo "== Building the ZD1200 container image (no boot) =="
    "${compose_cmd[@]}" build
else
    echo "== Building and starting the ZD1200 container =="
    "${compose_cmd[@]}" up -d --build
    echo
    echo "Started. Follow boot:  ${docker_cmd[*]} logs -f zd1200"
    echo "Guest console:         ${docker_cmd[*]} exec zd1200 tail -f /tmp/zd1200-console.log"
fi
