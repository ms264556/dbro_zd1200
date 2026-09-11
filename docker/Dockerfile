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
# Container-side scripts (entrypoint, guest-image prep, console helper) plus the
# ordered rootfs patches (scripts/container/patches/, run in lexical filename
# order against the qcow2 overlay).  prepare-vm-disks.sh decides whether the
# patches are needed (first run / after an upgrade) before launching QEMU.
# Host-only tooling under scripts/build/ and scripts/test/ is not copied.
COPY scripts/container/ /opt/zd1200/

RUN chmod +x /opt/zd1200/*.sh /opt/zd1200/*.py /opt/zd1200/patches/*.sh \
    && mkdir -p /opt/zd1200/image /var/lib/zd1200

ENV STATE_DIR=/var/lib/zd1200 \
    NETWORK_MODE=macvtap \
    TAP_IF=tap-zd \
    GUEST_IP=192.168.50.10 \
    MEMORY_MB=2048 \
    WEB_WAIT_SECONDS=600

VOLUME ["/var/lib/zd1200"]

HEALTHCHECK --interval=30s --timeout=8s --start-period=10m --retries=3 \
    CMD rg -qF 'System go into READY status.' /tmp/zd1200-console.log || exit 1

CMD ["./entrypoint.sh"]
