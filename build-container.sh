#!/usr/bin/env bash
#
# build-container.sh — build and start the ZD1200 Docker container (host-netns,
# macvtap on the host's physical NIC), exactly as RUNBOOK.md §3-4 describes.
#
# This is the one obvious entry point: it prepares the vendor image (once),
# creates .env if absent, then builds and starts the container.  No macvlan
# re-invention — it just runs the documented `docker compose up -d --build`.
#
# Usage:
#   ./build-container.sh                      # build + start the container
#   ./build-container.sh /abs/zd1200_*.img.tgz  # also prepare image/ first
#   ./build-container.sh --no-up              # only build the image (no boot)
#
# The container runs under host-netns; see RUNBOOK.md §7b/c for the two things
# that had to be right (the macvtap on the physical NIC, and ZD_BOARDDATA_FROM_MAC=0).
set -euo pipefail

cd "$(dirname "$0")"

no_up=0
archive=""
for arg in "$@"; do
    case "$arg" in
        --no-up) no_up=1 ;;
        -h|--help)
            sed -n '2,20p' "$0"
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

# --- 1. vendor image (only when missing) ------------------------------------
if [ ! -f image/rootfs.ext2 ]; then
    if [ -z "$archive" ]; then
        echo "image/rootfs.ext2 is missing — pass the decrypted ZD1200 archive as \$1," >&2
        echo "or set ZD_ARCHIVE and re-run (e.g. /abs/path/to/zd1200_10.5.1.0.282*.img.tgz)." >&2
        exit 1
    fi
    echo "== Preparing image/ from vendor archive =="
    ./prepare-vendor-image.sh "$archive"
else
    echo "== image/ already present (re-run prepare-vendor-image.sh to refresh) =="
fi

# --- 2. .env -----------------------------------------------------------------
if [ ! -f .env ]; then
    cp .env.example .env
    echo "== Created .env from .env.example =="
    echo "   Edit ZD_SIGN_CERT_HOST if your signing-cert payload is elsewhere."
fi

# --- 3. build / start -------------------------------------------------------
if [ "$no_up" = 1 ]; then
    echo "== Building the ZD1200 container image (no boot) =="
    "${docker_cmd[@]}" compose build
else
    echo "== Building and starting the ZD1200 container =="
    "${docker_cmd[@]}" compose up -d --build
    echo
    echo "Started. Follow boot:  ${docker_cmd[*]} logs -f zd1200"
    echo "Guest console:         ${docker_cmd[*]} exec zd1200 tail -f /tmp/zd1200-web.log"
fi
