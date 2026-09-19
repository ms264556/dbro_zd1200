# ap-11n-scorpion (R600) mesh repair

**The APs must already be running Solo 104 or 106 firmware before they will join a
controller delivering a repaired image** — the repair yields an unsigned image and
older AP firmware rejects it. Upgrade the APs through their own standalone upgrade
page first.

ZoneDirector 10.5.1.0.276 introduced a mesh receive-path bug in the shared
`ap-11n-scorpion` AP firmware. A wired Root AP looks healthy while a wireless
Mesh AP shows as connected but does not pass ordinary Layer-2 traffic. 10.5.1.0.282
(the release this project recommends) still has it.

These files are ported from [`dbro/zd1200`](https://github.com/dbro/zd1200)
and applied to the staged `/writable` tree by
`scripts/container/build-synthetic-cf.py`, so the repaired image is what the
controller delivers to APs.

| file | purpose |
|---|---|
| `ruckus_bl7.py` | parse/rebuild Ruckus `.bl7` containers; signed-ISI/FSI → unsigned-UI conversion |
| `patch_binary_artifact.py` | masked binary patch engine (signature + wildcards, exact-one-match) |
| `binary_patch_catalog.py` / `.json` / `.schema.json` | the patch rules; only `ap_11n_scorpion_wlan_ko` is used here |
| `patch_r600_bl7.py` | unsquash the AP rootfs, patch `wlan.ko`, re-squash, rebuild the BL7 |
| `patch-scorpion-payload.py` | fork wrapper: find the shared image, dedupe aliases, patch, resize control files |

## What the wrapper does

In the vendor payload one real image is aliased by many model directories:

```
firmwares/r600/10.5.1.0.282/rcks_fw.bl7      -> rcks_fw.bl7.main
firmwares/r600/10.5.1.0.282/rcks_fw.bl7.bkup -> ../../ap-patch/patch000/ap-11n-scorpion/.../rcks_fw.bl7.main
firmwares/r600/10.5.1.0.282/rcks_fw.bl7.main -> ../../ap-patch/patch000/ap-11n-scorpion/.../rcks_fw.bl7.main
```

Resolving those symlinks yields a single target to patch (the FSI image under
`ap-patch/`), and the aliasing model directories (`r600`, `r500`, `t300`, …)
identify the `*_cntrl.rcks` files whose two size fields must be rewritten
because the patched image is a different length. The wrapper skips non-10.5.1
payloads, which do not have the bug and ship a different signed image.

## SquashFS tools

The AP rootfs is historical LZMA SquashFS, so the matching `unsquashfs` /
`mksquashfs` are built from the GPL-2.0
[`ms264556/ruckus_ap_firmware_mod`](https://github.com/ms264556/ruckus_ap_firmware_mod)
project (pinned revision `3d9e4add414228eac4091f301e813d14130c3d61`) by the
`ruckus-squashfs-tools` stage of `docker/Dockerfile`, and installed at
`/opt/zd1200/ruckus-squashfs/`.

## Important scope

The repair targets **AC Wave 1 APs (e.g. R600)**: every model whose AP image
resolves to the same vendor `ap-11n-scorpion` BL7 gets the repaired image. An AP
running fully signed FSI firmware will reject the resulting unsigned UI image, so
it must first be moved to Solo 104 or 106 through its standalone upgrade page. See
the upstream project's README for that procedure.
