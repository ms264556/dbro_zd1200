#!/bin/sh
# Bridge ZD's persistent setpref journal into a small root-owned settings file.
# The browser remains the only writer of the native preference. This helper
# accepts only the three validated attributes from that exact preference node.
set -eu

bb=/usr/local/sbin/busybox
state_dir=/writable/zd1200-ping-monitor
journal=/writable/etc/airespider/ajax_config.log
cache=$state_dir/settings-cache.conf

attribute() {
    printf '%s\n' "$1" \
        | "$bb" sed -n "s/.* $2=\"\([^\"]*\)\".*/\1/p" \
        | "$bb" head -n 1
}

emit_if_valid() {
    monitoring_enabled=$1
    monitoring_interval=$2
    updated=$3
    valid=1
    case "$monitoring_enabled" in 0|1) ;; *) valid=0;; esac
    case "$updated" in ''|*[!0-9]*) valid=0;; esac
    case "$monitoring_interval" in ''|*[!0-9]*) valid=0;; esac
    [ "$valid" = 1 ] && [ "$monitoring_interval" -ge 30 ] \
        && [ "$monitoring_interval" -le 3600 ] || valid=0
    [ "$valid" = 1 ] || return 1
    printf 'HAS_NATIVE_SETTINGS=1\n'
    printf 'MONITORING_ENABLED=%s\n' "$monitoring_enabled"
    printf 'MONITOR_INTERVAL_SECONDS=%s\n' "$monitoring_interval"
    printf 'PREFERENCE_UPDATED_AT=%s\n' "$updated"
}

mkdir -p "$state_dir"
umask 077
if [ -r "$journal" ]; then
    record=$("$bb" grep 'updater="zd1200-ping-monitor"' "$journal" 2>/dev/null \
        | "$bb" grep 'action="setpref"' \
        | "$bb" tail -n 1 || true)
    element=$(printf '%s\n' "$record" \
        | "$bb" sed -n 's/.*\(<zd1200-ping-monitor [^>]*\/>\).*/\1/p')
    if [ -n "$element" ]; then
        enabled=$(attribute "$element" enabled)
        if [ -z "$enabled" ]; then
            # One-time compatibility for a controller that saved the earlier
            # two-toggle prototype. The next Apply writes the compact form.
            old_ping=$(attribute "$element" ping-enabled)
            old_snapshot=$(attribute "$element" snapshot-enabled)
            case "$old_ping:$old_snapshot" in
                0:0) enabled=0;;
                0:1|1:0|1:1) enabled=1;;
            esac
        fi
        candidate=$(emit_if_valid \
            "$enabled" \
            "$(attribute "$element" interval)" \
            "$(attribute "$element" updated-at)" || true)
        if [ -z "$candidate" ]; then
            # Accept the last prototype's ping interval once; the browser
            # writes the single-interval form on its next Apply.
            candidate=$(emit_if_valid "$enabled" \
                "$(attribute "$element" ping-interval)" \
                "$(attribute "$element" updated-at)" || true)
        fi
        if [ -n "$candidate" ]; then
            temporary=$cache.tmp.$$
            printf '%s\n' "$candidate" > "$temporary"
            chmod 600 "$temporary"
            mv -f "$temporary" "$cache"
        fi
    fi
fi

[ -r "$cache" ] || exit 0
monitoring_enabled=$(sed -n 's/^MONITORING_ENABLED=//p' "$cache" | head -n 1)
monitoring_interval=$(sed -n 's/^MONITOR_INTERVAL_SECONDS=//p' "$cache" | head -n 1)
updated=$(sed -n 's/^PREFERENCE_UPDATED_AT=//p' "$cache" | head -n 1)
emit_if_valid "$monitoring_enabled" "$monitoring_interval" "$updated"
