# `bootfs-src/` — source-built GRUB artifacts for the ZD1200 boot area

These are the **GPL-source-built** GRUB binaries/config that replace the vendor
bootfs the repo used to ship.  They are built from the Ruckus/Arris ZD1200 GPL
source release (see *Provenance* below), not extracted from vendor firmware, so
the repo redistributes no vendor binaries.

`build-bootfs.py` turns this tree into the bootable boot area the container writes
at sector 0 of the synthetic CF (MBR + embedded stage1.5 + the `/boot`
filesystem); `make-synthetic-cf.py` calls it in-process.  Nothing here is bootable
as-is: GRUB's `stage1`/`stage1_5` carry no on-disk blocklist until they are
*installed* into an image.

## Provenance

| | |
|---|---|
| Upstream GPL source | Ruckus/Arris ZD1200 GPL release — <https://sourceforge.net/projects/zd1200.arris/files/> |
| Mirror | <https://github.com/ms264556/zd1200_task> |
| Local checkout | `~/zd1200/zd1200_task` (its `origin` remote is the mirror above) |
| GRUB source tarball | `zd1200_task/buildroot/dl/grub-0.97.tar.gz` (sha256 `4e1d15d12dbd3e9208111d6b806ad5a9857ca8850c47877d36575b904559260b`) |
| Profile / build | `zd1200_task/buildroot/profiles/zd1200`, `zd1200_task/buildroot/build/zd1200/build_i386_release` |
| GRUB version | `GNU GRUB 0.97.1.39` (Ruckus patch level 1.39) |
| Artifacts copied from | `zd1200_task/buildroot/build/zd1200/build_i386_release/grub_bld/lib/grub/i386-pc/` (byte-identical to the `release/bootfs.i386.ext2.zd1200.img` filesystem) |

Ruckus patches compiled in (`zd1200_task/buildroot/package/grub/`):
`grub-0.97-any-ipmi`, `grub-e1000`, `grub-partition`, `grub-recovery`,
`grub-10-ledcontrol`, `grub-20-led-zd5000`.

## Files

Only the pieces the boot chain actually needs are kept (the other `*_stage1_5`
variants and the `grub`/`grub-install` host tools are not used here).

| file | size | sha256 |
|---|---|---|
| `lib/grub/i386-pc/stage1` | 512 | `77c1024a494c2170d0236dabdb795131d8a0f1809792735b3dd7f563ef5d951e` |
| `lib/grub/i386-pc/e2fs_stage1_5` | 7656 | `1a910755341f8e31c257d7efbf576d7f4565294b51ba5cd54ab0c1490d17d741` |
| `lib/grub/i386-pc/stage2` | 87874 | `49c1bb6d5c4e03c9681a58c5d0ed6ffeb0b24502ff97777737f73b7ca5ea7b31` |
| `lib/grub/i386-pc/menu.lst` | 1021 | `f8551a8b972b9a7eefe35224b4a07f40d6de9402c4986f6b7b2f264e54d8bf3a` |
| `lib/grub/i386-pc/default` | 191 | `18c664b268ccf1f63c3d9758e381d121925253e7e16fa9f3ab4c780188a30aa0` |

`menu.lst` is the profile's verbatim copy.  It uses ZD3000-era geometry
(`/dev/sda*`, current = root A); `build-bootfs.py` rewrites the two `kernel`
lines to the ZD1200 layout (`/dev/hda*`, current = root B) — see `BOOTFS.md`.

## Refreshing from a new build

Clone the ZD1200 GPL source (mirror: <https://github.com/ms264556/zd1200_task>),
build the `zd1200` profile, then copy the rebuilt artifacts:

```sh
BR=~/zd1200/zd1200_task/buildroot/build/zd1200/build_i386_release/grub_bld/lib/grub/i386-pc
cp -p "$BR"/{stage1,stage2,e2fs_stage1_5,menu.lst,default} bootfs-src/lib/grub/i386-pc/
sha256sum bootfs-src/lib/grub/i386-pc/*    # update the table above
```

## License / GPL compliance

The GRUB 0.97 sources these binaries were built from are **GNU GPL version 2 or
later**; `COPYING` in this directory is the license text that ships with that
source. Distributing the compiled GRUB binaries here means the corresponding
source must be available:

- Upstream ZD1200 GPL release: <https://sourceforge.net/projects/zd1200.arris/files/>
- Mirror: <https://github.com/ms264556/zd1200_task> — the `zd1200` profile,
  the GRUB tarball (`buildroot/dl/grub-0.97.tar.gz`) and the Ruckus patches
  (`buildroot/package/grub/`)
- Local checkout the copy here came from: `~/zd1200/zd1200_task`

`build-bootfs.py` only rearranges and patches these binaries at build time; it
adds no third-party code. Everything else in this repository is MIT-licensed —
see the root `LICENSE`.
