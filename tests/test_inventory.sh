#!/usr/bin/env bash
# The log inventory's pure half: which files an arrival window covers, which
# paths may be admitted at all, and which names are rotation variants.
#
# NO FILESYSTEM IS TOUCHED BELOW. Every pair here is a string, which is the whole
# point of the split: the off-by-one this module exists to prevent — rotation runs
# in the early morning, so the file rotated on one morning holds the previous
# day's lines — is checked for the price of a string instead of a fixture tree.
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/table.sh
. "$ZRO_SRC/lib/table.sh"
# shellcheck source=../lib/inventory.sh
. "$ZRO_SRC/lib/inventory.sh"

# Local wall clock is this tool's only time model, and a derived year is read out
# of a timestamp below. Pinned here so the suite does not depend on the zone of
# whoever runs it.
export TZ=UTC

# One rotation family, as logrotate leaves it: daily, compressed, no
# delaycompress, so the most recent rotated file is already gzipped. Rotation
# fires from cron.daily at 03:20, which is why each file's own timestamp names
# the day AFTER the lines it holds.
R3=1785122400    # 2026-07-27 03:20 — holds up to the 27th, 03:20
R2=1785208800    # 2026-07-28 03:20 — holds the 27th 03:20 → the 28th 03:20
R1=1785295200    # 2026-07-29 03:20 — holds the 28th 03:20 → the 29th 03:20
LIVE=1785405600  # 2026-07-30 10:00 — still being appended to

P3=/var/log/zimbra.log.3.gz
P2=/var/log/zimbra.log.2.gz
P1=/var/log/zimbra.log.1.gz
PLIVE=/var/log/zimbra.log

family() {
  printf '%s\t%s\n' "$R3" "$P3" "$R2" "$P2" "$R1" "$P1" "$LIVE" "$PLIVE"
}

paths_of() { printf '%s\n' "$1" | cut -f2; }

# Windows, as absolute local timestamps. A preset computes these in code; the
# ticket that adds the screen owns that arithmetic, so they are literals here.
W28_NOON=1785240000    # 2026-07-28 12:00
W28_EVENING=1785261600 # 2026-07-28 18:00
W28_START=1785196800   # 2026-07-28 00:00
W28_END=1785283199     # 2026-07-28 23:59:59
W29_START=1785283200   # 2026-07-29 00:00
W29_END=1785369599     # 2026-07-29 23:59:59

# THE BUG THIS MODULE EXISTS TO PREVENT. An operator asking about the afternoon
# of the 28th must be given the file rotated on the MORNING OF THE 29th. Selecting
# by the date in a filename, or by a file's own timestamp, hands back
# zimbra.log.2.gz instead and the trace silently finds nothing.
it "a window on one day selects the file rotated the following morning"
out=$(family | zro_inv_select "$W28_NOON" "$W28_EVENING" 2>/dev/null)
assert_eq "$out" "$(printf '2026\t%s' "$P1")"

it "and not the file whose own timestamp names that day"
assert_not_line "$(paths_of "$out")" "$P2"
assert_not_line "$(paths_of "$out")" "$PLIVE"

it "a whole day's window also selects the file holding its first hours"
# Midnight to 03:20 on the 28th is in the file rotated on the 28th; the rest of
# the day is in the file rotated on the 29th. Both, oldest first.
out=$(family | zro_inv_select "$W28_START" "$W28_END" 2>/dev/null)
assert_eq "$out" "$(printf '2026\t%s\n2026\t%s' "$P2" "$P1")"
assert_not_line "$(paths_of "$out")" "$PLIVE"

it "yesterday's window reaches into the file still being written"
out=$(family | zro_inv_select "$W29_START" "$W29_END" 2>/dev/null)
assert_eq "$out" "$(printf '2026\t%s\n2026\t%s' "$P1" "$PLIVE")"

it "the newest file has no upper bound, so a window after it still selects it"
# The newest file is the one being appended to. Bounding it by its own timestamp
# would leave a window on a quiet server matching nothing at all.
out=$(family | zro_inv_select "$((LIVE + 3600))" "$((LIVE + 7200))" 2>/dev/null)
assert_eq "$out" "$(printf '2026\t%s' "$PLIVE")"

it "the oldest file has no lower bound, so an ancient window still selects it"
out=$(family | zro_inv_select 1000 2000 2>/dev/null)
assert_eq "$out" "$(printf '2026\t%s' "$P3")"

it "the order the pairs arrive in decides nothing"
reversed=$(family | sed '1!G;h;$!d')
out=$(printf '%s\n' "$reversed" | zro_inv_select "$W28_START" "$W28_END" 2>/dev/null)
assert_eq "$out" "$(printf '2026\t%s\n2026\t%s' "$P2" "$P1")"

it "an empty inventory yields an empty selection rather than an error"
rc=0
out=$(printf '' | zro_inv_select "$W28_START" "$W28_END" 2>/dev/null) || rc=$?
assert_eq "$rc" "0"
assert_eq "$out" ""

it "one rotation instant is read once, however many copies of it exist"
# gzip preserves the modification time, so the two forms of the same rotated file
# — which exist together during the daily window before the compress cron runs —
# carry the SAME timestamp and the same lines. Reading both would report every
# message twice.
out=$(printf '%s\t%s\n' \
        "$R1" /opt/zimbra/log/mailbox.log.2026-07-28 \
        "$R1" /opt/zimbra/log/mailbox.log.2026-07-28.gz \
        "$LIVE" /opt/zimbra/log/mailbox.log \
      | zro_inv_select "$W28_NOON" "$W28_EVENING" 2>/dev/null)
assert_eq "$out" "$(printf '2026\t%s' /opt/zimbra/log/mailbox.log.2026-07-28.gz)"

it "the file still being written keeps the newest interval when it ties"
# logrotate creates the replacement in the same second it renames the original,
# so on a quiet server the live file and the file it replaced can share a
# timestamp. The live file is newest by definition, and reading its interval as
# the older of the two would point every window at the wrong file.
out=$(printf '%s\t%s\n' "$R2" "$PLIVE" "$R2" "$P1" "$R3" "$P2" \
      | zro_inv_select "$W28_NOON" "$W28_EVENING" 2>/dev/null)
assert_eq "$out" "$(printf '2026\t%s' "$PLIVE")"

# Each file is traced on its own so that the year can come from that file, which
# is what removes the tracer's guess-the-year-from-the-clock defect.
it "each selected file carries the year of its own modification time"
Y2025=1767151200 # 2025-12-31 03:20
Y2026=1767237600 # 2026-01-01 03:20
out=$(printf '%s\t%s\n' \
        "$Y2025" /var/log/zimbra.log.2.gz \
        "$Y2026" /var/log/zimbra.log.1.gz \
      | zro_inv_select 1767052800 1767312000 2>/dev/null)
assert_eq "$out" "$(printf '2025\t%s\n2026\t%s' \
                     /var/log/zimbra.log.2.gz /var/log/zimbra.log.1.gz)"

it "the year comes from the timestamp and never from the name"
# ADR-0002's rule, pinned. The residual it leaves is named in lib/inventory.sh:
# the file rotated on 1 January carries the new year for the old year's lines.
out=$(printf '%s\t%s\n' "$Y2026" /var/log/zimbra.log-20251231.gz \
      | zro_inv_select 1767237000 1767238000 2>/dev/null)
assert_eq "$out" "$(printf '2026\t%s' /var/log/zimbra.log-20251231.gz)"

it "a path outside the permitted set is refused and logged"
bad="/var/log/zimbra.log.1'x.gz"
out=$(printf '%s\t%s\n' "$R1" "$bad" "$LIVE" "$PLIVE" \
      | zro_inv_select "$W28_NOON" "$W28_EVENING" 2>/dev/null)
assert_not_contains "$out" "$bad"
err=$( { printf '%s\t%s\n' "$R1" "$bad" \
         | zro_inv_select "$W28_NOON" "$W28_EVENING" >/dev/null; } 2>&1 )
assert_contains "$err" "$bad"

it "a year that cannot be derived is refused, never printed empty"
# The tracer takes an empty year and answers "nothing found", which is the exact
# defect deriving the year per file exists to remove. So no line is better than a
# line without one.
out=$( { ( ZRO_DATE_BIN=/nonexistent/date
           family | zro_inv_select "$W28_NOON" "$W28_EVENING" ); } 2>/dev/null )
assert_eq "$out" ""
err=$( { ( ZRO_DATE_BIN=/nonexistent/date
           family | zro_inv_select "$W28_NOON" "$W28_EVENING" ) >/dev/null; } 2>&1 )
assert_contains "$err" "$P1"

it "a pair with a timestamp that is not a number is refused and logged"
err=$( { printf '%s\t%s\n' 'now' "$PLIVE" \
         | zro_inv_select "$W28_NOON" "$W28_EVENING" >/dev/null; } 2>&1 )
assert_contains "$err" "$PLIVE"

it "a pair with no timestamp at all is refused and logged, not quietly dropped"
# A blank field must not read as the blank line that ends every heredoc.
err=$( { printf '\t%s\n' "$PLIVE" \
         | zro_inv_select "$W28_NOON" "$W28_EVENING" >/dev/null; } 2>&1 )
assert_contains "$err" "$PLIVE"

it "a malformed arrival window is refused as invalid input"
assert_status "$ZRO_E_INPUT" zro_inv_select 'yesterday' "$W28_END"
assert_status "$ZRO_E_INPUT" zro_inv_select "$W28_START" ''
assert_status "$ZRO_E_INPUT" zro_inv_select "$W28_START"
assert_status "$ZRO_E_INPUT" zro_inv_select
# An end before its start is a caller defect, not an empty answer: answering
# "nothing found" to a window that cannot exist is the ambiguity this feature
# exists to remove.
assert_status "$ZRO_E_INPUT" zro_inv_select "$W28_END" "$W28_START"

it "admits every path shape the inventory can produce"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  assert_ok zro_inv_path_ok "$p"
done <<'EOF'
/var/log/zimbra.log
/var/log/zimbra.log.1.gz
/opt/zimbra/log/mailbox.log.2026-07-29.gz
/opt/zimbra/log/audit.log-20260728.gz
/tmp/zro-test.d/var/log/zimbra.log
EOF

it "refuses a path carrying anything the permitted set does not name"
# The tracer opens compressed input through a /bin/sh command line with the
# filename interpolated inside single quotes and NOT escaped, so a quote in a
# path is the one character that turns a log reader into a shell. The rest are
# refused for the same reason a validator refuses them: nothing here needs them.
# shellcheck disable=SC2016
for p in "/var/log/zimbra.log.1'x.gz" \
         '/var/log/zimbra log' \
         '/var/log/$(id).log' \
         '/var/log/zimbra.log;id' \
         '/var/log/`id`' \
         '/var/log/zimbra.log|cat' \
         '/var/log/zimbra*.log' \
         '/var/log/zimbra?.log' \
         '/var/log/../etc/passwd' \
         '/var/log/..' \
         'var/log/zimbra.log' \
         '-/var/log/zimbra.log' \
         '' \
         $'/var/log/zimbra.log\n/etc/passwd'; do
  assert_fail zro_inv_path_ok "$p"
done
assert_fail zro_inv_path_ok

it "recognises both rotation naming schemes, compressed and not"
B=/var/log/zimbra.log
# .1/.2.gz is logrotate's numbered form; -20260728 is the same program with
# dateext set, which Zimbra sets neither way so the distro default decides;
# .2026-07-29 is log4j2's, whose compression is a separate cron and therefore
# leaves both forms on disk for part of every day.
for c in "$B" "$B.1" "$B.1.gz" "$B.14" "$B.14.gz" "$B.365" \
         "$B.2026-07-29" "$B.2026-07-29.gz" \
         "$B-20260728" "$B-20260728.gz"; do
  assert_ok zro_inv_variant_ok "$B" "$c"
done

it "refuses a name that is not a rotation variant of its base"
for c in "$B.xz" "$B.1.xz" "$B.1.zst" "$B.1.bz2" "$B.gz" "$B.bak" \
         "$B.20260728" "$B-2026-07-28" "$B.2026-7-9" "$B.1.gz.1" \
         "${B}x" "${B}2026-07-29" /var/log/other.log /var/log; do
  assert_fail zro_inv_variant_ok "$B" "$c"
done
assert_fail zro_inv_variant_ok "$B"
assert_fail zro_inv_variant_ok

it "declares the three base names and no fourth"
assert_eq "$(zro_inv_keys)" "$(printf 'syslog\nmailbox\naudit')"

it "declares no proxy log"
# The proxy log's rotation is the only one that delays compression, so its most
# recent rotated file is plain text while every other file's is already gzipped.
# Leaving it out keeps that inversion out of this module entirely.
assert_not_contains "$(printf '%s' "$ZRO_INVENTORY")" "nginx"

it "every declared log names an overridable variable, never a path"
# The value in the table is a variable NAME, optionally followed by a path under
# it. A root written out here would be one the operator cannot override and the
# suite cannot point at a fixture tree.
bad=""
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  var=${entry#*:}
  var=${var%%/*}
  case $var in
    ZRO_[A-Z0-9_]*) case $var in *[!A-Z0-9_]*) bad="$bad [$entry]" ;; esac ;;
    *) bad="$bad [$entry]" ;;
  esac
done <<EOF
$(zro_inv_entries)
EOF
assert_eq "$bad" ""

it "every declared log entry is a name-and-root pair"
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  case $entry in
    ?*:?*) zro_t_pass ;;
    *)     zro_t_fail "malformed inventory entry: $entry" ;;
  esac
done <<EOF
$(zro_inv_entries)
EOF

it "resolves each base under the root it declares"
assert_out_eq "/var/log/zimbra.log" zro_inv_base_path syslog
assert_out_eq "/opt/zimbra/log/mailbox.log" zro_inv_base_path mailbox
assert_out_eq "/opt/zimbra/log/audit.log" zro_inv_base_path audit

it "follows the roots when they are overridden"
# Overridden inside a subshell: a temporary assignment in front of a function
# call persists after it returns in bash, which would leak into the next case.
assert_eq "$( ZRO_SYSLOG_FILE=/tmp/z.log; zro_inv_base_path syslog )" "/tmp/z.log"
assert_eq "$( ZRO_LOG_DIR=/tmp/l; zro_inv_base_path mailbox )" "/tmp/l/mailbox.log"

it "refuses a base name it does not declare, and says so"
assert_fail zro_inv_base_path nginx
assert_fail zro_inv_base_path sync
assert_fail zro_inv_base_path ''
assert_fail zro_inv_base_path
err=$( { zro_inv_base_path nginx >/dev/null; } 2>&1 )
assert_contains "$err" "nginx"

it "refuses a base whose root variable is empty rather than resolving bare"
rc=0; ( ZRO_LOG_DIR=''; zro_inv_base_path mailbox ) >/dev/null 2>&1 || rc=$?
assert_eq "$([ "$rc" -ne 0 ] && printf 'refused')" "refused"
rc=0; ( ZRO_SYSLOG_FILE=''; zro_inv_base_path syslog ) >/dev/null 2>&1 || rc=$?
assert_eq "$([ "$rc" -ne 0 ] && printf 'refused')" "refused"
err=$( { ( ZRO_LOG_DIR=''; zro_inv_base_path mailbox ) >/dev/null; } 2>&1 )
assert_contains "$err" "ZRO_LOG_DIR"

zro_t_report
