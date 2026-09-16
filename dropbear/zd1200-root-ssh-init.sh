#!/bin/sh
# ZD1200 static-dropbear public-key root listener (TCP 2222).
#
# Installed by scripts/container/patches/60-dropbear-static.sh and started from
# /etc/init.d after the stock S60dropbear (port 22).  It seeds the writable
# authorized_keys from the rootfs copy, then starts a public-key-only dropbear
# with a plain shell.
#
# No -A option is passed: in the vendored dropbear patches -A selects the Ruckus
# authentication mode, and without it standard dropbear auth applies, which is
# what provides publickey.  -s disables password logins.
#
# The stock port-22 service keeps its own invocation (-A none -e /bin/login.sh)
# untouched.
(
    key_src=/etc/zd1200-root-authorized_keys
    hostkey=/etc/airespider/dropbear/dropbear_host_rsa_key

    [ -r "$key_src" ] || exit 0

    # dropbear reads /.ssh/authorized_keys for root (the vendor passwd gives
    # root the home directory "/").  On the ZD1200 /.ssh is already a symlink to
    # /writable/data/dropbear, so the key lives on the writable partition and
    # can be rotated in place without rebuilding the container.  Resolve the
    # symlink rather than assuming the target, and seed it only once: never
    # clobber an operator-managed key.
    ssh_dir=/writable/data/dropbear
    if [ -L /.ssh ]; then
        target=$(ls -l /.ssh 2>/dev/null | sed -n 's/.* -> //p')
        [ -n "$target" ] && ssh_dir="$target"
    fi
    mkdir -p "$ssh_dir"
    chmod 700 "$ssh_dir" 2>/dev/null || true
    if [ ! -s "$ssh_dir/authorized_keys" ]; then
        cp -f "$key_src" "$ssh_dir/authorized_keys"
        chmod 600 "$ssh_dir/authorized_keys"
    fi

    # On a factory appliance sys_init generates the host key during boot; wait
    # for it rather than failing, without blocking the rest of init.
    i=0
    while [ ! -r "$hostkey" ] && [ "$i" -lt 60 ]; do
        i=$((i + 1))
        sleep 2
    done
    [ -r "$hostkey" ] || exit 0

    # Offer the ECDSA host key as well when the optional ECDSA patch generated
    # it, so modern clients do not need -o HostKeyAlgorithms=+ssh-rsa.  RSA is
    # always retained.
    set -- -r "$hostkey"
    ecdsa_hostkey=/etc/airespider/dropbear/dropbear_host_ecdsa_key
    [ -s "$ecdsa_hostkey" ] && set -- "$@" -r "$ecdsa_hostkey"

    exec /usr/sbin/dropbear -p 2222 -P /var/run/zd1200-root-dropbear.pid \
        -s -j -k -e /bin/sh "$@"
) &
exit 0
