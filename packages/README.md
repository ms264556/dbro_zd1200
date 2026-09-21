# Payload packages

The self-contained payloads this project ships into the appliance, one directory
per package. The Docker flow builds them in `docker/Dockerfile` stages; the LXC
flow builds them inside the CT via
`scripts/container/proxmox/zd1200-ct-bootstrap.sh`. Either way they are installed
by the ordered rootfs patches or by the guest-disk builder.

| package | what it is | installed by |
|---|---|---|
| `analytics/` | the Network Monitor web page, its guest collectors and the i386 helper sources | `scripts/container/patches/50-network-monitor.sh` |
| `dropbear/` | patches and build script for the optional static musl dropbear (public-key root SSH on TCP 2222) | `scripts/container/patches/60-dropbear-static.sh` |
| `mesh-patch/` | the ap-11n-scorpion (R600) AP-firmware mesh repair, on vendored Ruckus BL7 tooling | `scripts/container/build-synthetic-cf.py` |

`analytics` and `dropbear` are compiled (i386/static/musl and a musl cross-build
respectively), so their build stages produce the binaries the patches install.
`mesh-patch` is Python and runs in place; only the historical LZMA SquashFS tools
it needs are built, into `ruckus-squashfs/` — a build output, not a package.

See each directory's `README.md` for detail. Upstream provenance and licensing
are noted there.
