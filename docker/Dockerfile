# ZD1200 lab container image.
#
# The runtime stage is the one that ships: Debian + QEMU + the guest-image
# tooling and the ordered rootfs patches.  It also carries the "Network
# Monitor" analytics payload (analytics/), whose guest-side helpers are i386
# binaries compiled by the two build stages below.
#
# The guest is an i386 Linux 2.6.32 system, so the helpers must be i386 and
# statically linked even when Docker builds the surrounding image on ARM64.
ARG ANALYTICS_HELPER_PLATFORM=linux/386
ARG DEBIAN_IMAGE=debian:13-slim

# ---------------------------------------------------------------------------
# Stage 1: fetch the helper sources and the i386 toolchain (on the BUILD host).
#
# BuildKit's emulated 32-bit network sandbox cannot resolve DNS on some Docker
# hosts, so the i386 toolchain is downloaded here as .deb files and only
# installed in the i386 stage below.
# ---------------------------------------------------------------------------
FROM --platform=$BUILDPLATFORM $DEBIAN_IMAGE AS analytics-sources

ARG DEBIAN_FRONTEND=noninteractive
# Use a SQLite release contemporary with the ZD1200's Linux 2.6.32 guest.
# Modern SQLite builds returned SQLITE_IOERR when opening its live database.
ARG SQLITE_YEAR=2013
ARG SQLITE_AMALGAMATION=3071700
ARG SQLITE_AMALGAMATION_SHA256=022ef41bd83a1333faf40dc8f1f8469205f4a18c30dc5e137889ba7ea924ef30

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "https://www.sqlite.org/${SQLITE_YEAR}/sqlite-amalgamation-${SQLITE_AMALGAMATION}.zip" \
        -o /tmp/sqlite-amalgamation.zip \
    && echo "${SQLITE_AMALGAMATION_SHA256}  /tmp/sqlite-amalgamation.zip" | sha256sum -c - \
    && unzip -q /tmp/sqlite-amalgamation.zip -d /src

RUN dpkg --add-architecture i386 \
    && apt-get update \
    && apt-get -y --download-only --no-install-recommends \
        install gcc:i386 make:i386 musl-tools:i386 \
    && mkdir -p /packages \
    && cp /var/cache/apt/archives/*.deb /packages/

# ---------------------------------------------------------------------------
# Stage 2: compile the i386 static guest helpers.
# ---------------------------------------------------------------------------
FROM --platform=$ANALYTICS_HELPER_PLATFORM $DEBIAN_IMAGE AS analytics-helper

ARG DEBIAN_FRONTEND=noninteractive
ARG SQLITE_AMALGAMATION=3071700

COPY --from=analytics-sources /src/sqlite-amalgamation-${SQLITE_AMALGAMATION} \
     /src/sqlite-amalgamation-${SQLITE_AMALGAMATION}
COPY --from=analytics-sources /packages /packages

RUN dpkg --force-confold --force-architecture -i /packages/*.deb || true \
    && rm -rf /packages

COPY analytics/zd1200-ping-monitor.c \
     analytics/zd1200-ping-export.c \
     analytics/zd1200-local-getstat.c \
     /src/

RUN mkdir -p /out \
    && musl-gcc -std=c99 -Os -static -s \
        -DSQLITE_OMIT_LOAD_EXTENSION \
        -I"/src/sqlite-amalgamation-${SQLITE_AMALGAMATION}" \
        /src/zd1200-ping-monitor.c \
        "/src/sqlite-amalgamation-${SQLITE_AMALGAMATION}/sqlite3.c" \
        -o /out/zd1200-ping-monitor \
    && musl-gcc -std=c99 -Os -static -s \
        -DSQLITE_OMIT_LOAD_EXTENSION \
        -I"/src/sqlite-amalgamation-${SQLITE_AMALGAMATION}" \
        /src/zd1200-ping-export.c \
        "/src/sqlite-amalgamation-${SQLITE_AMALGAMATION}/sqlite3.c" \
        -lm \
        -o /out/zd1200-ping-export \
    && musl-gcc -std=c99 -Os -static -s \
        /src/zd1200-local-getstat.c \
        -o /out/zd1200-local-getstat

# ---------------------------------------------------------------------------
# Stage 3: the runtime image.
# ---------------------------------------------------------------------------
FROM $DEBIAN_IMAGE

ARG DEBIAN_FRONTEND=noninteractive

# nodejs is not used at run time: the Network Monitor patch runs `node --check`
# on every admin bundle it rewrites, so a malformed edit can never reach the
# guest disk and break the console.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        binutils \
        curl \
        e2fsprogs \
        gzip \
        iproute2 \
        nodejs \
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
# order against the flat CF disk).  prepare-vm-disks.sh decides whether the
# patches are needed (first run / after an upgrade) before launching QEMU.
# Host-only tooling under scripts/build/ and scripts/test/ is not copied.
#
# The analytics/ payload is the Network Monitor feature: the page, its worker,
# the guest shell collectors and the source of the i386 helpers.  The compiled
# helpers are overlaid from the analytics-helper stage; the patch installs all
# of it into the guest root partitions.
COPY scripts/container/ /opt/zd1200/
COPY analytics/ /opt/zd1200/analytics/
COPY --from=analytics-helper \
     /out/zd1200-ping-monitor \
     /out/zd1200-ping-export \
     /out/zd1200-local-getstat \
     /opt/zd1200/analytics/

RUN chmod +x /opt/zd1200/*.sh /opt/zd1200/*.py /opt/zd1200/patches/*.sh \
        /opt/zd1200/analytics/*.sh \
        /opt/zd1200/analytics/zd1200-ping-monitor \
        /opt/zd1200/analytics/zd1200-ping-export \
        /opt/zd1200/analytics/zd1200-local-getstat \
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
