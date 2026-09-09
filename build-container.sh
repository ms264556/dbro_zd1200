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
#
# The container runs under host-netns; see README.md ("Host requirements" and
# "Gotchas") for what the host must provide (MAC-spoofing NIC, KVM optional).
set -euo pipefail

cd "$(dirname "$0")"

no_up=0
archive="${ZD_ARCHIVE:-}"
for arg in "$@"; do
    case "$arg" in
        --no-up) no_up=1 ;;
        -h|--help)
            sed -n '2,14p' "$0"
            exit 0
            ;;
        *) archive="${arg:-}" ;;
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
    ./scripts/prepare-vendor-image.sh "$archive"
else
    echo "== Reusing image/ (delete it to re-extract, or run scripts/prepare-vendor-image.sh) =="
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

# --- 3. build / start -------------------------------------------------------
if [ "$no_up" = 1 ]; then
    echo "== Building the ZD1200 container image (no boot) =="
    "${compose_cmd[@]}" build
else
    echo "== Building and starting the ZD1200 container =="
    "${compose_cmd[@]}" up -d --build
    echo
    echo "Started. Follow boot:  ${docker_cmd[*]} logs -f zd1200"
    echo "Guest console:         ${docker_cmd[*]} exec zd1200 tail -f /tmp/zd1200-web.log"
fi
