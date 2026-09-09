# `guest-src/grub097_src/` — build GRUB 0.97 for the ZD1200 boot area

This is where the ZD1200's GRUB 0.97 bootloader is built. No GRUB binary is
committed: the container image build (`docker/Dockerfile`, `grub-build` stage)
runs `build.sh` in a throwaway builder, which applies these patches to the
pristine upstream `grub-0.97` tarball:

1. the **build/boot-relevant subset** of the Arch AUR `grub-legacy` patch series
   — the parts that make 0.97 compile with a modern gcc / binutils;
2. two local fixes (see below): GRUB's broken varargs stack walking, and the
   AUR's autotools changes ported into the tarball's generated files;
3. the two Ruckus ZD1200 patches this repository needs:
   `grub-partition` (partition table read from the ZD "pt sector") and
   `grub-recovery` (the boot-retry / recovery state machine);
4. ext2 only — reiserfs, FAT and every other filesystem are compiled out.

```sh
./guest-src/grub097_src/build.sh            # ~20 s; fetch, patch, build, stage, self-check
./guest-src/grub097_src/build.sh --force    # rebuild even if the signature is unchanged
./guest-src/grub097_src/build.sh --clean    # drop build/ and out/
./guest-src/grub097_src/build.sh --jobs 4
```

`build.sh` is idempotent: it hashes itself, the pinned tarball, every patch and
the `/boot` config files, and no-ops when `out/` already matches. The container
image build calls it once per image build, so repeat runs cost nothing (and the
Docker layer is cached).

## Requirements

The container build needs **no host toolchain at all** — `build.sh` runs in the
image's `grub-build` stage, which installs its own `gcc`/`make`/`patch`/`binutils`
and discards them. Running `build.sh` directly on the host (development only)
needs `gcc` with 32-bit support, `make`, `patch`, `binutils`, `python3` and
`curl`; on Debian/Ubuntu:

```sh
sudo apt-get install -y gcc make patch binutils gcc-multilib libc6-dev-i386 \
                        curl
```

`build.sh` checks for all of these (and for a working `gcc -m32`) before it
starts, and names the missing package instead of failing halfway. No autotools
or texinfo are needed.


## What it produces

`out/lib/grub/i386-pc/` is the complete GRUB tree `scripts/build-bootfs.py`
consumes (compiled binaries + the `/boot` config files from `config/`):

| file | source | size (this host) | sha256 |
|---|---|---|---|
| `stage1` | compiled | 512 | `77c1024a494c2170d0236dabdb795131d8a0f1809792735b3dd7f563ef5d951e` |
| `stage2` | compiled | 89544 | `9777c1cadb7dc1e528ece57080ad458e6e0d19bc30acb58a1f2bd15b8d77a932` |
| `e2fs_stage1_5` | compiled | 8660 | `36c6849cf42e953ad44c83c2afea5ba930266f3d00e9df4b7c85ec8004e89c43` |
| `menu.lst` | copied from `config/` (not compiled) | 1021 | unchanged |
| `default` | copied from `config/` (not compiled) | 191 | unchanged |

`build.sh` prints the hashes of what it just built, so the table above is only a
reference point for this host (Ubuntu, gcc 15.2.0, binutils 2.4x).

It also self-checks the output before declaring success:

- the generated `stage2/Makefile` has `-DFSYS_EXT2FS=1` and no
  `-DFSYS_REISERFS`, i.e. the filesystem selection took effect;
- exactly one `ZD_PART_SECTOR = 3982101` immediate in both `stage2` and
  `e2fs_stage1_5` (proves `grub-partition.patch` is compiled in);
- the `PREVIOUS BOOTUP STATUS` banner in `stage2` (proves `grub-recovery.patch`
  is compiled in);
- the version string `0.97.1.39` in `stage2` and `e2fs_stage1_5`, matching the
  Ruckus `BR2_PACKAGE_GRUB_BUILD="1.39"` patch level.

## Layout

```
build.sh                     the only entry point
config/menu.lst              the /boot menu GRUB reads (not compiled)
config/default              the saved-default state file GRUB writes (not compiled)
patches/aur/series           ordered AUR patch list (subset, PKGBUILD order)
patches/aur/*.patch          the 9 AUR patches that are used
patches/local/series         ordered local-fix list
patches/local/0001-*.patch   the local varargs fix (see below)
patches/local/0002-*.patch   the AUR changes ported into the tarball's generated
                             configure/Makefile.in, so no autotools are needed
patches/ruckus/series        ordered Ruckus patch list
patches/ruckus/*.patch       grub-partition.patch, grub-recovery.patch
COPYING                      GPLv2 (GRUB's license)
dl/                          upstream tarball (fetched, sha256-verified) — gitignored
build/                       extracted + patched + compiled source tree — gitignored
out/                         staged GRUB tree (binaries + config) — gitignored
```

## Which AUR patches are used, and why

Kept — these are required to build with a current toolchain, or to boot the
ZD1200's ext2 filesystem:

| patch | why |
|---|---|
| `snapshot.patch` | carries modern-build fixes despite its name: `${LDFLAGS}` in the absolute-link probe (`acinclude.m4`) and `--build-id=none` handling — without the LDFLAGS hunk configure fails with `gcc cannot link at address 2000` |
| `2gb_limit.patch` | `memcheck()` takes `unsigned long`, not `int`; the guest runs with 2048 MB RAM, so addresses at/above 2 GB must not be truncated |
| `mprotect.patch` | makes the simulated stack executable so the host-side `grub` shell runs on a modern kernel (nested-function trampolines) |
| `objcopy-absolute.patch` | `objcopy --only-section=.text` / `-R .note* -R .comment*`, so modern binutils build-ids don't corrupt stage1/stage1_5 |
| `no-reorder-functions.patch` | `-fno-reorder-functions` for stage2 |
| `modern-automake.patch` | `AM_PROG_AS` + `pkgdatadir` rename so `autoreconf` works with automake 1.18 |
| `no-combine-stack-adjustments.patch` | `-fno-combine-stack-adjustments` for stage2 |
| `no-pie.patch` | `-fno-PIE` for stage1/stage2 and `-no-pie` at link time |
| `static-vars-on-stack.patch` | nested-function/stack fix for gcc 7+ |

Dropped — features, non-ext2 filesystems, or host-only tooling:

| patch | why dropped |
|---|---|
| `graphics.patch`, `splashimage_help.patch` | graphical splash screen |
| `raid.patch`, `raid_cciss.patch` | software RAID |
| `savedefault.patch`, `pointer-recast-hack.patch` | AUR's `savedefault` rewrite (`--once`, `prev:default` format); the ZD1200 menu only uses `savedefault N`/`default saved`, and Ruckus's `grub-recovery` was written against vanilla `savedefault_func` |
| `ext4_support.patch`, `ext4_fix_variable_sized_inodes.patch`, `ext4_block_group.patch` | ext4 support |
| `ext3_256byte_inode.patch` | 256-byte inodes; the vendor `rootfs.ext2` is ext2 rev 0 (128-byte inodes) |
| `initrd_max_address.patch` | initrd load address; the normal ZD1200 boot entries have no initrd |
| `print_func.patch`, `menu.lst_gnu-hurd.patch`, `crossreference_manpages.patch` | extra `print` command / docs |
| `geometry-26kernel.patch`, `grub-special_device_names.patch`, `grub-xvd_drives.patch`, `intelmac.patch` | host-tool device/geometry handling (and it needs the two patches above to apply) |
| `grub-install_*.patch`, `find-grub-dir.patch`, `use_grub-probe_in_grub-install.patch`, `xfs_freeze.patch` | `util/grub-install.in` (host install script; not used here) |

The result of this pruning: `stage2/fsys_ext2fs.c` is **byte-identical to
pristine upstream GRUB 0.97** — the same ext2 driver Ruckus's buildroot
compiled, since none of Ruckus's six patches touch it either.

## Local fix: `patches/local/0001-fix-varargs-hacks.patch`

GRUB 0.97 walks the arguments of `grub_printf`, `grub_sprintf` and
`convert_to_ascii` by taking the address of a named parameter and stepping past
it (`int *dataptr = (int *) &format; dataptr++;`,
`unsigned long num = *((&c) + 1);`). That only works if the compiler keeps the
incoming arguments adjacent to that parameter, which gcc ≥ 4.x does not at
`-O1`/`-O2`/`-Os`. The result with gcc 15 and the AUR flags was:

- every `%d`/`%x`/`%u` printed garbage (`GNU GRUB version 0.97.1.39 (100K lower /
  100K upper memory)` where the multiboot info actually held 639K / 2096000K);
- the config-file load failed, so GRUB fell straight to its `grub>` command line
  and never booted the kernel (the machine-memory map itself was correct — the
  garbage was only in the printing, and `reset()` derives the config buffer from
  `mbi`, which the broken paths then clobbered).

The patch replaces the stack walking with the compiler's builtin varargs
(`__builtin_va_list`/`__builtin_va_start`/`__builtin_va_arg`/`__builtin_va_end`
— `stdarg.h` is unavailable because GRUB builds with `-nostdinc`) and makes
`convert_to_ascii`'s value an explicit `unsigned long` parameter; every caller
already passed it. Verified by `scripts/boot-test.sh`: before the patch the guest
stopped at the GRUB prompt with an empty serial console, after it the guest
reaches `init` and the controller's READY marker.

## Local fix: `patches/local/0002-modern-toolchain-in-generated-files.patch`

Ports the AUR `configure.ac`/`Makefile.am` changes into the tarball's
pre-generated `configure`/`Makefile.in` (version string, objcopy probes and
rules, `STAGE1_CFLAGS`/`STAGE2_CFLAGS`/`GRUB_CFLAGS`), so no autotools are
needed. `build.sh` passes `LDFLAGS="-no-pie -Wl,--build-id=none"`, which is what
those AUR checks used to append. The artifacts are byte-identical to a build that
regenerates the autotools output.

## Provenance

| | |
|---|---|
| GRUB source | `grub-0.97.tar.gz`, <https://alpha.gnu.org/gnu/grub/grub-0.97.tar.gz> |
| Tarball sha256 | `4e1d15d12dbd3e9208111d6b806ad5a9857ca8850c47877d36575b904559260b` (same file Ruckus shipped in `buildroot/dl/` and the AUR PKGBUILD fetches) |
| AUR package | `grub-legacy` 0.97-30, <https://aur.archlinux.org/cgit/aur.git/tree/?h=grub-legacy> |
| AUR commit used | `09bff601c22c23f6a0fc3549392066e8fa3ea031` (2025-05-12, "fix gcc 14/15/16 build issues") |
| Ruckus patches | ZD1200 GPL release, `buildroot/package/grub/`; <https://sourceforge.net/projects/zd1200.arris/files/>, mirror <https://github.com/ms264556/zd1200_task> |
| Build options | `buildroot/package/grub/grub.mk` (`GRUB_FLAG`), narrowed to ext2 |

The AUR patches are vendored rather than fetched so the build is reproducible
and reviewable offline; only the tarball is downloaded, and it is checksum-pinned.

## How this differs from the vendor-built binaries

The repository used to commit GRUB binaries built by Ruckus's own buildroot
(cross-compiled i386, 2008-era toolchain) under `bootfs-src/`. Those are gone:
`bootfs-src/` has been removed and the binaries are built from source instead.
For reference, the two builds differ as follows:

| | Ruckus buildroot (removed `bootfs-src/`) | this build |
|---|---|---|
| toolchain | Ruckus cross i386 (2008-era gcc/binutils) | host gcc 15.2.0 + binutils, `-m32` |
| Ruckus patches | all 6 (`any-ipmi`, `e1000`, `partition`, `recovery`, `10-ledcontrol`, `20-led-zd5000`) | the 2 this repo needs (`partition`, `recovery`) |
| modern-host patches | none | the 9-patch AUR subset + 2 local fixes (varargs, generated-file flags) |
| filesystems | ext2 + reiserfs | ext2 only |
| version string | `0.97.1.39` | `0.97.1.39` (preserved via `AC_INIT`) |
| `stage1` | `77c1024a…` | `77c1024a…` (identical) |
| `stage2` | 87874 | 89544 |
| `e2fs_stage1_5` | 7656 | 8660 |

`stage1` is unaffected by the added fixes and comes out byte-identical. The
slightly larger `stage2`/`e2fs_stage1_5` still fit the boot area with room to
spare: `e2fs_stage1_5` is 17 sectors against the 61-sector gap before hda1, and
`stage2` is 89544 bytes against GRUB's 128 KiB stage2 limit.

`grub-partition.patch` is applied verbatim, so the compiled-in sector is still
the platform-0 value **3982101**. `scripts/build-bootfs.py` keeps rewriting that
immediate to the ZD1200's **3927001** (`ZD_PART_SECTOR_ZD1200`) when it builds
the boot area.

The host-side `grub` shell segfaults when it enters the simulated stage2 on a
modern host (Ubuntu 26.04, gcc 15, glibc 2.43) — the same happens with the full
unpruned AUR series, so it is not caused by the pruning. `build.sh` therefore no
longer builds it (or `util/`) at all; nothing in the container uses those tools,
and only `stage1`, `stage2` and `e2fs_stage1_5` are written to the boot area.

## How it is used

The container image build runs `build.sh` in its `grub-build` stage and copies
the resulting `guest-src/grub097_src/out/` into the image at
`/opt/zd1200/guest-src/grub097_src/out/`,
where `scripts/build-bootfs.py` reads it (and `scripts/apply-rootfs-patches.sh`
includes it in the boot-area signature, so a GRUB change rebuilds the synthetic
CF). Verified end-to-end with `scripts/boot-test.sh`:

```
./build-container.sh --no-up     # builds GRUB (if changed) + the container image
./scripts/boot-test.sh --expect ready    # PASS: grub 2s, kernel 2s, init 7s, ready 30s
```

## License / GPL compliance

GRUB 0.97 is **GPLv2-or-later**; `COPYING` here is its license text. The
binaries this directory produces are covered by the same terms, and the
corresponding source is the upstream tarball (URL and sha256 above) plus the
vendored patch series in `patches/`. The rest of the repository is MIT — see the
root `LICENSE`.
