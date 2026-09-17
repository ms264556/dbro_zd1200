# Static ZD1200 dropbear replacement (optional)

This directory vendors the source patches and build script from the author's
[`ms264556/zd_dropbear`](https://github.com/ms264556/zd_dropbear) project
(revision `2d8bb0e`, "fix auth none"). It produces a **static musl i386**
`dropbear` 2026.94, `dropbearkey`, `dropbearconvert` and OpenSSH 9.9p2
`sftp-server` that replace the ZD1200's own uClibc binaries.

## Why this exists

The vendor `/usr/sbin/dropbear` on 10.5.1.0.282 is a Ruckus-modified build
whose server advertises **`password` only** — public-key authentication is not
compiled in, and its custom `-A` option is mandatory. The upstream project's
`ZD_ROOT_SSH_PUBLIC_KEY` promise therefore cannot be satisfied with the vendor
binary.

The vendored patches add the Ruckus options to a modern upstream dropbear:

| patch | effect |
|---|---|
| `0001-sftpserver-path.patch` | `SFTPSERVER_PATH` → `/usr/sbin/sftp-server` |
| `0002-ruckus-e-and-a-options.patch` | `-e <shell>` (alternative shell) and `-A <authmeth>` (`none` / `file:<users>:<passwords>`) |
| `0003-none-auth-bypass.patch` | `-A none` accepts the SSH `none` method immediately (the stock port-22 behaviour) |
| `0004-any-user-authnone.patch` | `-A none` accepts any username, synthesizing a root login for `/bin/login.sh` |
| `0005-login-entry-authnone.patch` | login accounting is non-fatal for non-system users |

With `-A none` the replacement is a drop-in for the stock `/etc/init.d/dropbear`
invocation (port 22, `-e /bin/login.sh`). **Without `-A`, standard dropbear auth
applies — including `publickey`** — which is what the optional root listener on
TCP 2222 uses.

## Build

Only built when explicitly requested, because it downloads a ~110 MB musl.cc
cross toolchain and builds three source trees:

```sh
./install-zd1200-docker.sh --root-ssh-key ~/.ssh/id_ed25519.pub
```

`docker/Dockerfile` then runs the vendored `build-zd1200-dropbear.sh` in the
`zd-dropbear` stage; without the flag the stage is a no-op and nothing is
downloaded. The build is a native cross-build (the toolchain is `musl.cc`'s
`i486-linux-musl-cross`), so it needs no i386 container.

The upstream tarballs and the toolchain are pinned by `SHA256SUMS`; the Docker
fetch stage verifies them before building. The only change to the vendored
script is that each download is skipped when the file is already present, so the
fetch stage can pre-place the pinned tarballs.

The `musl.cc` toolchain runs on **x86_64 build hosts**; on Linux ARM64 this
optional build is unavailable (the rest of the project still builds and runs,
with QEMU TCG). Nothing is downloaded at all unless `--root-ssh-key` is given.

## Runtime layout (installed by `scripts/container/patches/60-dropbear-static.sh`)

| payload | destination |
|---|---|
| `dropbear` | `/usr/sbin/dropbear` (vendor binary saved as `/usr/sbin/dropbear.vendor`) |
| `sftp-server` | `/usr/sbin/sftp-server` |
| `dropbearkey` | `/usr/bin/dropbearkey` (replaces the vendor multicall symlink) |
| `dropbearconvert` | `/usr/bin/dropbearconvert` (replaces the vendor multicall symlink) |
| public key | `/etc/zd1200-root-authorized_keys`, seeded once to `/.ssh/authorized_keys` → `/writable/data/dropbear/authorized_keys` |
| listener | `/etc/init.d/S61zd_root_ssh` — `dropbear -p 2222 -s -j -k -e /bin/sh -r <vendor host key>` |

The listener passes **no** `-A`, so it uses public-key auth only (`-s` disables
passwords) and runs `/bin/sh`. Port 22 keeps its stock `-A none` + `login.sh`
behaviour.

The authorized key lives on the writable partition (`/.ssh` is a vendor symlink
to `/writable/data/dropbear`), so it can be rotated in place:

```sh
ssh -p 2222 root@<guest-ip> 'cat > /.ssh/authorized_keys' < new_key.pub
```

The build-time key only seeds the file when it does not already exist; a key
placed there manually is never overwritten.

## License

Patches and build script are the `zd_dropbear` author's work. Dropbear is MIT;
OpenSSH and zlib carry their own licenses. Nothing from the vendor firmware is
committed here.
