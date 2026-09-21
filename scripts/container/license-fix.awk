# license-fix.awk — reconcile a ZoneDirector /writable AP license list with the
# ZD1200 this guest is running as.
#
# Input:  the license list named on the command line (read through any symlink).
# Output: the reconciled list on stdout.  A list this cannot make sense of is
#         echoed unchanged; the caller detects "nothing to do" by comparing.
#
#   -v serial=...   this box's board serial (/bin/SERIAL)
#   -v marker=...   generated-by stamp that identifies the compensating license
#   -v builtin=...  the ZD1200's built-in AP count (5)
#
# The transform is deliberately text-only (busybox/gawk on the guest; no XML
# library there):
#
#   * every <license> element's serial-number is pointed at this box's serial —
#     the list came from another box, so its serials name that box; and
#   * one compensating <license> is added so that
#         sum(inc-ap) == max-ap - builtin
#     The vendor license manager treats the root max-ap as the built-in APs plus
#     the sum of the <license> inc-ap values, so a foreign list — a ZD1100 with 6
#     or 11 built-ins, a ZD3000 with 50 or 100 — would otherwise lose
#     (foreign built-in - 5) APs.
#
# The compensating element is stamped generated-by=<marker>, which makes this a
# one-shot: a list that already carries the stamp is left exactly as it is (only
# the serial repair continues to apply).  A later license purchase adds its own
# <license> and raises max-ap by the same amount, so the compensation never needs
# to move — and re-deriving it could only shrink or drop the built-in APs the
# element exists to preserve.  It is also marked DELETABLE="false", the attribute
# the web UI's Delete button honours, so it cannot be removed by hand; if it is
# removed some other way, the next boot finds no stamp and re-adds it.
#
# Installed as /etc/zd-license-fix.awk by
# scripts/container/patches/25-writable-license.sh and run from
# /etc/init.d/S49zd_license; unit-tested by scripts/test/license-fix-test.sh.

function find_gt(s, i,    n) {
    n = length(s)
    while (i <= n) {
        if (substr(s, i, 1) == ">") return i
        i++
    }
    return 0
}

# The value of a name="..." attribute in a tag, or "" when the tag has none.  The
# leading space keeps `id` from matching inside `feature-id`, and `name` from
# matching inside `feature-name`.
function attr(tag, name,    re, s) {
    re = "[ \t]" name "=\"[^\"]*\""
    if (!match(tag, re)) return ""
    s = substr(tag, RSTART + 1, RLENGTH - 1)
    sub(/^[^=]*="/, "", s)
    sub(/"$/, "", s)
    return s
}

function set_attr(tag, name, value,    re) {
    re = "[ \t]" name "=\"[^\"]*\""
    if (!match(tag, re)) return tag
    return substr(tag, 1, RSTART - 1) substr(tag, RSTART, 1) \
           name "=\"" value "\"" substr(tag, RSTART + RLENGTH)
}

# Force DELETABLE="false" on a tag, adding the attribute when it is absent.  The
# web UI's Delete button is disabled for a row whose DELETABLE is not "true"
# (absent means deletable), so this is what keeps the compensating license from
# being removed by hand.  Additive only — it never touches inc-ap.
function mark_undeletable(tag,    body, ending) {
    if (attr(tag, "DELETABLE") == "false") return tag
    if (match(tag, /[ \t]DELETABLE="[^"]*"/)) return set_attr(tag, "DELETABLE", "false")
    ending = (substr(tag, length(tag) - 1) == "/>") ? " />" : ">"
    body = substr(tag, 1, length(tag) - 1)
    if (substr(body, length(body)) == "/") body = substr(body, 1, length(body) - 1)
    sub(/[ \t]+$/, "", body)
    return body " DELETABLE=\"false\"" ending
}

# Read the whole file as a single record so a trailing (or missing) newline is
# preserved exactly: 0x01 never appears in an XML license list, so using it as
# the record separator makes $0 the entire file.
BEGIN { RS = "\001" }
{ text = text $0 }

END {
    root_at = index(text, "<license-list")
    if (!root_at) { printf "%s", text; exit 0 }
    root_end = find_gt(text, root_at)
    if (!root_end) { printf "%s", text; exit 0 }
    root = substr(text, root_at, root_end - root_at + 1)
    max_ap = attr(root, "max-ap")
    if (max_ap == "") { printf "%s", text; exit 0 }
    max_ap += 0

    # A list with no children is a self-closing root: give it a real end tag so
    # the compensating license has somewhere to go.
    if (substr(root, length(root) - 1) == "/>") {
        newroot = substr(root, 1, length(root) - 2)
        sub(/[ \t]+$/, "", newroot)
        text = substr(text, 1, root_at - 1) newroot ">\n</license-list>" \
               substr(text, root_end + 1)
    }

    # Repair every <license> serial-number and total the inc-ap values that are
    # not ours — those are what the built-in count is added to.
    out = ""
    pos = 1
    sum_others = 0
    have_marker = 0
    max_id = 0
    while ((p = index(substr(text, pos), "<license ")) > 0) {
        p = pos + p - 1
        q = find_gt(text, p)
        if (!q) break
        tag = substr(text, p, q - p + 1)
        out = out substr(text, pos, p - pos)
        if (serial != "") tag = set_attr(tag, "serial-number", serial)
        inc = attr(tag, "inc-ap"); inc = (inc == "" ? 0 : inc + 0)
        id = attr(tag, "id"); if (id != "" && id + 0 > max_id) max_id = id + 0
        if (attr(tag, "generated-by") == marker) {
            have_marker = 1
            tag = mark_undeletable(tag)
        } else sum_others += inc
        out = out tag
        pos = q + 1
    }
    text = out substr(text, pos)

    target = max_ap - builtin
    if (target < 0) target = 0
    desired = target - sum_others          # what the compensating license must add

    # The stamp makes this a one-shot: a list that already carries it keeps its
    # element as stamped (the protective attribute above is the only thing that
    # may be added).  A later license purchase adds its own <license> and raises
    # max-ap by the same amount, so `desired` would not move anyway -- and
    # re-deriving it here could only shrink or drop the built-in APs this element
    # exists to preserve.
    if (!have_marker && desired > 0) {
        close_at = index(text, "</license-list>")
        if (close_at) {
            new_id = max_id + 1
            elem = "    <license id=\"" new_id "\" name=\"" desired \
                   " AP Management\" inc-ap=\"" desired "\" generated-by=\"" \
                   marker "\" serial-number=\"" serial \
                   "\" status=\"0\" detail=\"\" DELETABLE=\"false\" />"
            text = substr(text, 1, close_at - 1) elem "\n" substr(text, close_at)
        }
    }

    printf "%s", text
}
