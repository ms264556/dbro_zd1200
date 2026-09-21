#!/usr/bin/env bash
#
# scripts/build/proxmox/zd1200-pve-summary-host.sh — show each ZD1200 guest's
# address in the Proxmox GUI's Summary tab.
#
# Runs on the PVE host (installed by install-zd1200-lxc.sh as a timer).  A
# container cannot write its own description -- that is host-side data and `pct`
# does not exist inside a container -- so the host does it, reading the address the
# guest reported (cached by the container at /var/lib/zd1200/guest-ip).
#
# Only our own two lines are managed; anything the operator wrote is preserved.
#
# Usage: zd1200-pve-summary-host.sh [ctid ...]   (default: every CT that has a
#        /var/lib/zd1200/guest-ip, i.e. one this project installed)
set -u

# Which containers to touch: the ones given, or every container that has the
# state directory this project creates.  Read through `pct exec` rather than
# poking at /var/lib/lxc/<id>/rootfs, which does not exist for all storage types.
if [ "$#" -gt 0 ]; then
    ids=("$@")
else
    mapfile -t ids < <(pct list | awk 'NR>1 {print $1}' | sort -n)
fi
[ "${#ids[@]}" -gt 0 ] || exit 0

for id in "${ids[@]}"; do
    case "$id" in ''|*[!0-9]*) continue ;; esac
    addr="$(pct exec "$id" -- cat /var/lib/zd1200/guest-ip 2>/dev/null | head -n1 | tr -d ' \r\n')"
    case "$addr" in ''|*[!0-9.]*) continue ;; esac

    conf="/etc/pve/lxc/$id.conf"
    [ -r "$conf" ] || continue

    # Proxmox keeps a container's description as '#'-prefixed comment lines on the
    # config file (that is what the Summary tab shows and what
    # `pct set --description` writes), and it percent-encodes the value on the way
    # in.  Our two lines therefore use no character that needs encoding -- no ':',
    # which also makes the "unchanged" check below work on re-runs instead of
    # re-encoding the text a little more each pass.
    current="$(grep -E '^#' "$conf" 2>/dev/null | sed 's/^#//' | tr '\n' ' ')"

    if printf '%s' "$current" | grep -qF "Guest IP = $addr"; then
        continue
    fi

    notes="$(printf '%b' "$current" \
        | sed 's/%0A/\n/g' \
        | grep -vE '^(Guest IP|Guest URL)[ :=]|^Guest URL = https%3A' \
        | sed '/^[[:space:]]*$/d')"
    notes="$(printf '%s\nGuest IP = %s\nGuest URL = https://%s/' "$notes" "$addr" "$addr")"
    pct set "$id" --description "$notes" >/dev/null 2>&1 || true
done
exit 0
