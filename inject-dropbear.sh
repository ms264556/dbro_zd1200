#!/usr/bin/env bash
#
# inject-dropbear.sh — lay the ZD1200 static dropbear + sftp-server into the
# vendor rootfs seed (image/rootfs.ext2) and configure an ADDITIONAL dropbear
# instance on port 2222 that gives an ash shell to authorized_keys users.
#
# Works on the vendor-derived rootfs seed that make-synthetic-cf.py copies
# verbatim into hda1/hda2/hda3, so the changes reach every root partition.
# Runs as a normal user (debugfs only; no root/loop/mount).
#
# Because debugfs refuses to overwrite an existing file ("Ext2 file already
# exists"), the existing /usr/sbin/dropbear is 'rm'ed first and the new one is
# then 'write'ed (removed then added) so the new binary overlays the vendor one.
#
# Rootfs files deliberately left untouched:
#   /etc/passwd  — vendor symlink -> /writable/etc/config/passwd
#   /etc/shadow  — vendor regular file (0600)
#   /etc/dropbear — vendor FIPS dropbear dir (host key we add has a new name)
#
# The vendor /usr/bin/dropbearkey and /usr/bin/dropbearconvert are symlinks
# -> ../sbin/dropbear (applet-style).  Our static dropbear does NOT dispatch on
# argv[0] (no DROPBEAR_MULTI), so those links now point at an sshd.  We replace
# them here with the real static executables from the custom build so the key
# helpers remain usable.
#
# Root must be resolvable by the static-musl getpwnam() on the VERY FIRST boot,
# before the controller generates /writable/etc/config/passwd.  So the /writable
# data partition (hda4) is seeded with passwd/shadow by make-synthetic-cf.py;
# the first-run wizard overrides them later.  No passwd/shadow is written into
# the rootfs itself.
#
# Usage: ./inject-dropbear.sh [ROOTFS_IMG] [DROPBEAR_OUT_DIR]
set -euo pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG="${1:-$BASE/image/rootfs.ext2}"
OUT="${2:-$BASE/dropbear-provision/bin}"

DB="${OUT}/dropbear"
SFTP="${OUT}/sftp-server"
DBKEY="${OUT}/dropbearkey"
DBCONV="${OUT}/dropbearconvert"

AUTHK="${BASE}/dropbear-provision/id_ed25519.pub"
HOSTKEY="${BASE}/dropbear-provision/hostkey_2222"
PTMX="${BASE}/dropbear-provision/ptmx.tar"

[ -f "$IMG" ] || { echo "rootfs image missing: $IMG"; exit 1; }
[ -f "$DB" ] && [ -f "$SFTP" ] && [ -f "$DBKEY" ] && [ -f "$DBCONV" ] \
    || { echo "dropbear/sftp/key binaries missing in $OUT"; exit 1; }
[ -f "$AUTHK" ] || { echo "test pubkey missing: $AUTHK"; exit 1; }
[ -f "$HOSTKEY" ] || { echo "port-2222 host key missing: $HOSTKEY"; exit 1; }
[ -f "$PTMX" ] || { echo "ptmx.tar missing: $PTMX"; exit 1; }

say() { printf '\n== %s\n' "$*"; }

CMD="$BASE/.inject-dropbear.cmds"

# --- /usr/sbin binaries: remove the vendor dropbear, then add the new one.
# The vendor /usr/bin/dropbearkey and /usr/bin/dropbearconvert are applet
# symlinks -> ../sbin/dropbear; our static build does NOT dispatch by argv[0],
# so they now point at an sshd.  Replace those symlinks with the real static
# executables so the key helpers remain usable.  sftp-server is added for the
# sftp subsystem.  (None of these are at /usr/sbin in the vendor rootfs.)
printf 'rm /usr/sbin/dropbear\nwrite %s /usr/sbin/dropbear\n' "$DB" >> "$CMD"
printf 'write %s /usr/sbin/sftp-server\n' "$SFTP" >> "$CMD"
printf 'rm /usr/bin/dropbearkey\nwrite %s /usr/bin/dropbearkey\n' "$DBKEY" >> "$CMD"
printf 'rm /usr/bin/dropbearconvert\nwrite %s /usr/bin/dropbearconvert\n' "$DBCONV" >> "$CMD"

# --- /etc/shells: the controller's first-boot passwd sets root's shell to
# /bin/sh, but the vendor /etc/shells lists only /bin/ash + /sbin/rkscli.
# dropbear's checkusername rejects a login user whose shell isn't in
# /etc/shells ("invalid shell"), which surfaces as a pubkey-auth denial.
# Add /bin/sh (busybox ash) so root's shell is accepted, and keep the rest.
SHELLS="$BASE/dropbear-provision/shells"
debugfs -R 'dump /etc/shells' "$IMG" "$SHELLS" 2>/dev/null || printf '/bin/ash\n/sbin/rkscli\n' > "$SHELLS"
grep -qx '/bin/ash' "$SHELLS" 2>/dev/null || printf '/bin/ash\n' >> "$SHELLS"
grep -qx '/bin/sh'  "$SHELLS" 2>/dev/null || printf '/bin/sh\n'  >> "$SHELLS"
grep -qx '/sbin/rkscli' "$SHELLS" 2>/dev/null || printf '/sbin/rkscli\n' >> "$SHELLS"
printf 'rm /etc/shells\nwrite %s /etc/shells\n' "$SHELLS" >> "$CMD"

# --- authorized_keys in the standard per-user location ----------------------
# /root exists (vendor 0755); /root/.ssh does not, so create it.  With no -D
# flag dropbear uses the default ~/.ssh, i.e. /root/.ssh/authorized_keys.
printf 'mkdir /root/.ssh\n' >> "$CMD"
printf 'write %s /root/.ssh/authorized_keys\n' "$AUTHK" >> "$CMD"

# --- host key + ptmx.tar for the port-2222 instance --------------------------
# The stock dropbear host key lives in /etc/airespider; the vendor /etc/dropbear
# holds only FIPS post-dropbear keys, so this new name is collision-free.
printf 'write %s /etc/dropbear/dropbear_ed25519_host_key\n' "$HOSTKEY" >> "$CMD"
printf 'write %s /etc/dropbear/ptmx.tar\n' "$PTMX" >> "$CMD"

# --- port-2222 init script + runlevel symlink ------------------------------
printf 'write %s /etc/init.d/dropbear2222\n' "$BASE/dropbear-provision/dropbear2222" >> "$CMD"
printf 'rm /etc/init.d/S61dropbear2222\nsymlink /etc/init.d/S61dropbear2222 dropbear2222\n' >> "$CMD"

# --- port-22 (stock) init must also get a pty ------------------------------
# The vendor /dev is a static tree with NO /dev/ptmx (pty master), so an
# interactive port-22 SSH session has no pty and dropbear's openpty() fails.
# Restore /dev/ptmx (char 5,2) from the baked ptmx.tar inside the stock
# /etc/init.d/dropbear itself, so the stock port-22 dropbear is self-sufficient
# and independent of the port-2222 instance.  Idempotent: guarded by a comment.
DB22_INIT="$BASE/dropbear-provision/init.d.dropbear"
if debugfs -R "dump /etc/init.d/dropbear $DB22_INIT" "$IMG" 2>/dev/null && [ -s "$DB22_INIT" ]; then
    if ! grep -q 'Restore /dev/ptmx' "$DB22_INIT"; then
        awk '/Starting sshd/{
            print
            print "# Restore /dev/ptmx (char 5,2) + mount devpts so an interactive"
            print "# port-22 SSH session gets a working pty (the vendor /dev has neither)."
            print "if [ ! -e /dev/ptmx ] && [ -f /etc/dropbear/ptmx.tar ]; then"
            print "    mount -o remount,rw / 2>/dev/null"
            print "    tar -xf /etc/dropbear/ptmx.tar -C / 2>/dev/null"
            print "    chmod 666 /dev/ptmx 2>/dev/null"
            print "    mount -o remount,ro / 2>/dev/null"
            print "fi"
            print "mountpoint -q /dev/pts 2>/dev/null || mount -t devpts devpts /dev/pts 2>/dev/null"
            next
        } { print }' "$DB22_INIT" > "$DB22_INIT.new"
        mv "$DB22_INIT.new" "$DB22_INIT"
        printf 'rm /etc/init.d/dropbear\nwrite %s /etc/init.d/dropbear\n' "$DB22_INIT" >> "$CMD"
    fi
else
    echo "  ! could not dump /etc/init.d/dropbear; leaving the port-22 init untouched" >&2
fi

say "applying $(wc -l < "$CMD") debugfs operations to $IMG"
debugfs -w -f "$CMD" "$IMG" 2>/dev/null || { echo "debugfs failed"; exit 1; }

# --- set owner/modes so dropbear's checkpubkeyperms passes ------------------
# authorized_keys lives at /root/.ssh/authorized_keys; dropbear's perms check
# walks every path component up to '/': all must be root-owned and NOT
# group/other-writable.  /root is vendor 0755 (fine); /root/.ssh is created
# 0700 and the file 0600.  set_inode_field takes the mode in octal.
mode() { # mode path
  debugfs -w -R "set_inode_field $2 mode $1" "$IMG" >/dev/null 2>&1 || true
}
mode 0100755 /usr/sbin/dropbear
mode 0100755 /usr/sbin/sftp-server
mode 0100755 /usr/bin/dropbearkey
mode 0100755 /usr/bin/dropbearconvert
mode 0100755 /etc/init.d/dropbear2222
mode 0100755 /etc/init.d/dropbear
mode 040700 /root/.ssh        # directory: 04 = S_IFDIR (do NOT use 010)
mode 0100600 /root/.ssh/authorized_keys
mode 0100600 /etc/dropbear/dropbear_ed25519_host_key
mode 0100644 /etc/dropbear/ptmx.tar
mode 0100644 /etc/shells
# /etc/dropbear (vendor) is left as-is.  /etc/passwd (symlink) and /etc/shadow
# are untouched.  /dev/ptmx (char 5,2) is created at BOOT by the dropbear2222
# init (remount / rw, tar from ptmx.tar, remount ro) because debugfs cannot
# link a char node into /dev reliably.  Do NOT add it here.

say "verifying"
for f in /usr/sbin/dropbear /usr/sbin/sftp-server /usr/bin/dropbearkey /usr/bin/dropbearconvert /root/.ssh /root/.ssh/authorized_keys /etc/dropbear/dropbear_ed25519_host_key /etc/dropbear/ptmx.tar /etc/init.d/dropbear2222 /etc/shells; do
  printf '  %-42s ' "$f"
  info="$(debugfs -R "stat $f" "$IMG" 2>/dev/null | awk -F': *' '/Type:|Mode:/{gsub(/^ +| +$/,"",$2); printf "%s ", $2}')"
  [ -n "$info" ] && echo "$info" || echo "MISSING"
done
echo "  /etc/passwd ->"; debugfs -R 'stat /etc/passwd' "$IMG" 2>/dev/null | grep -i "Fast link" | sed 's/^/    /'
echo "  /etc/shadow type -> $(debugfs -R 'stat /etc/shadow' "$IMG" 2>/dev/null | awk -F': *' '/Type:/{gsub(/ +$/,"",$2); print $2}')"
echo "  /root/.ssh/authorized_keys ->"; debugfs -R 'cat /root/.ssh/authorized_keys' "$IMG" 2>/dev/null | sed 's/^/    /'
echo "  /etc/shells ->"; debugfs -R 'cat /etc/shells' "$IMG" 2>/dev/null | sed 's/^/    /'

say "done.  Re-run prepare-vendor-image.sh to restore the pristine rootfs seed."
rm -f "$CMD"
