# GRUB 0.97 is i386-only, so build it on amd64 regardless of the target host.
ARG GRUB_BUILDER_PLATFORM=linux/amd64

# ---- GRUB 0.97 bootloader (throwaway builder) -------------------------------
FROM --platform=$GRUB_BUILDER_PLATFORM debian:13-slim AS grub-build

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        binutils \
        ca-certificates \
        curl \
        gcc \
        gcc-multilib \
        libc6-dev \
        libc6-dev-i386 \
        make \
        patch \
        python3 \
    && rm -rf /var/lib/apt/lists/*

COPY guest-src/grub097_src/ /build/guest-src/grub097_src/
RUN /build/guest-src/grub097_src/build.sh --jobs "$(nproc)"

# ---- runtime image ----------------------------------------------------------
FROM debian:13-slim

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        binutils \
        curl \
        e2fsprogs \
        gzip \
        iproute2 \
        procps \
        python3 \
        qemu-system-x86 \
        qemu-utils \
        reiserfsprogs \
        ripgrep \
        udhcpc \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/zd1200
# Container-side scripts (entrypoint, guest-image prep, console helper).  The
# host-side prepare-vendor-image.sh rides along; it is only used by
# build-container.sh before the image exists.
COPY scripts/ /opt/zd1200/
# GRUB artifacts built in the grub-build stage from upstream GRUB 0.97 + the
# AUR/local/Ruckus patch sets (see guest-src/grub097_src/README.md);
# make-synthetic-cf.py builds the boot area from them via build-bootfs.py.
COPY --from=grub-build /build/guest-src/grub097_src/out/ \
     /opt/zd1200/guest-src/grub097_src/out/
# The ordered rootfs patches live in patches/ and run (in lexical filename
# order) against the qcow2 overlay; apply-rootfs-patches.sh decides whether
# they are needed (first run / after an upgrade) before launching QEMU.
COPY patches/ /opt/zd1200/patches/

RUN chmod +x /opt/zd1200/*.sh /opt/zd1200/*.py /opt/zd1200/patches/*.sh \
    && mkdir -p /opt/zd1200/image /var/lib/zd1200 \
    && /opt/zd1200/build-bootfs.py --check

ENV STATE_DIR=/var/lib/zd1200 \
    NETWORK_MODE=macvtap \
    TAP_IF=tap-zd \
    GUEST_IP=192.168.50.10 \
    MEMORY_MB=2048 \
    WEB_WAIT_SECONDS=600

VOLUME ["/var/lib/zd1200"]

HEALTHCHECK --interval=30s --timeout=8s --start-period=10m --retries=3 \
    CMD rg -qF 'System go into READY status.' /tmp/zd1200-web.log || exit 1

CMD ["./run-zd1200-web.sh"]
