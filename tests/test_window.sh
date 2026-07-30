#!/usr/bin/env bash
# The arrival window: which span of time a trace is restricted to.
#
# The preset arithmetic is PURE and is checked with no clock at all — 'now' and
# the start of the day are arguments, so every case below is a question about a
# fixed moment rather than about the moment the suite happens to run in.
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/validate.sh
. "$ZRO_SRC/lib/validate.sh"
# shellcheck source=../lib/window.sh
. "$ZRO_SRC/lib/window.sh"

# Local wall clock is this tool's only time model, and the thin half below reads
# one out of the clock. Pinned so the suite does not depend on the zone of
# whoever runs it.
export TZ=UTC

# 2026-07-30 16:45:20 local, and the midnight that day began at.
NOW=1785429920
TODAY=1785369600      # 2026-07-30 00:00:00
YESTERDAY=1785283200  # 2026-07-29 00:00:00

win() { zro_win_preset "$1" "$NOW" "$TODAY"; }

it "the last hour ends now and starts an hour before it"
assert_out_eq "$(printf '%s\t%s' 1785426320 "$NOW")" win hour

it "the last 24 hours is a rolling day, not yesterday"
assert_out_eq "$(printf '%s\t%s' 1785343520 "$NOW")" win day

it "the last 7 days is a rolling week"
assert_out_eq "$(printf '%s\t%s' 1784825120 "$NOW")" win week

it "yesterday is the calendar day, from its midnight to its last second"
# THE CASE THIS FUNCTION EXISTS FOR. 'now - 86400' would answer "this time
# yesterday": asked at 16:45 it would miss yesterday morning entirely and reach
# into today, so an operator asking about yesterday would be shown today.
assert_out_eq "$(printf '%s\t%s' "$YESTERDAY" 1785369599)" win yesterday

it "yesterday reaches neither into today nor into the day before"
out=$(win yesterday)
start=${out%%	*}
end=${out#*	}
assert_eq "$(zro_win_human "$start")" "2026-07-29 00:00:00"
assert_eq "$(zro_win_human "$end")" "2026-07-29 23:59:59"

it "yesterday is the same window whatever time of day it is asked at"
# The rolling presets move with the clock; this one may not. Asked one minute
# after midnight and one minute before it, the answer has to be identical.
early=$(zro_win_preset yesterday "$((TODAY + 60))" "$TODAY")
late=$(zro_win_preset yesterday "$((TODAY + 86340))" "$TODAY")
assert_eq "$early" "$late"
assert_eq "$early" "$(printf '%s\t%s' "$YESTERDAY" 1785369599)"

it "yesterday's window covers the early-morning hours a rotation cuts through"
# Rotation fires from cron.daily at 03:20, so yesterday's lines are split across
# two files. The window has to include the hours before the rotation, or the log
# inventory has nothing to select for them.
out=$(win yesterday)
start=${out%%	*}
assert_eq "$([ "$start" -lt $((YESTERDAY + 12000)) ] && printf yes || printf no)" "yes"

it "every preset ends at or before the moment it was asked"
# A window reaching into the future would ask the tracer about lines no file can
# hold yet, and would read as a search that found nothing.
for name in $ZRO_WIN_PRESETS; do
  out=$(win "$name")
  end=${out#*	}
  assert_eq "$([ "$end" -le "$NOW" ] && printf yes || printf no)" "yes"
done

it "every preset starts before it ends"
for name in $ZRO_WIN_PRESETS; do
  out=$(win "$name")
  assert_eq "$([ "${out%%	*}" -lt "${out#*	}" ] && printf yes || printf no)" "yes"
done

it "declares four presets and no fifth"
assert_eq "$ZRO_WIN_PRESETS" "hour day yesterday week"

it "refuses a preset it does not declare, rather than answering with a default"
assert_status "$ZRO_E_INPUT" zro_win_preset month "$NOW" "$TODAY"
assert_status "$ZRO_E_INPUT" zro_win_preset '' "$NOW" "$TODAY"
assert_status "$ZRO_E_INPUT" zro_win_preset

it "refuses a clock reading that is not a number"
assert_status "$ZRO_E_INPUT" zro_win_preset hour 'now' "$TODAY"
assert_status "$ZRO_E_INPUT" zro_win_preset hour "$NOW" 'today'
assert_status "$ZRO_E_INPUT" zro_win_preset hour "$NOW"
assert_status "$ZRO_E_INPUT" zro_win_preset hour '' ''
# A day that starts after the moment it holds is a caller defect, and yesterday
# computed from it would be a window nobody asked for.
assert_status "$ZRO_E_INPUT" zro_win_preset yesterday "$TODAY" "$NOW"

it "refuses a window that would reach before the epoch"
assert_status "$ZRO_E_INPUT" zro_win_preset week 100 100
assert_status "$ZRO_E_INPUT" zro_win_preset yesterday 100 100

it "asks nothing of the clock"
# Purity, asserted rather than assumed: the presets must answer with no date
# binary at all, which is what lets the cases above pin a moment instead of
# following whatever moment the suite runs in.
assert_eq "$( ZRO_DATE_BIN=/nonexistent/date; win yesterday )" \
  "$(printf '%s\t%s' "$YESTERDAY" 1785369599)"

# --- the clock: thin ------------------------------------------------------

it "reads the current time as a whole number of seconds"
now=$(zro_win_now)
case $now in
  ''|*[!0-9]*) zro_t_fail "not a timestamp: [$now]" ;;
  *)           zro_t_pass ;;
esac

it "finds the midnight a timestamp's own day began at"
assert_out_eq "$TODAY" zro_win_day_start "$NOW"
assert_out_eq "$TODAY" zro_win_day_start "$TODAY"
assert_out_eq "$TODAY" zro_win_day_start $((TODAY + 86399))
assert_out_eq "$YESTERDAY" zro_win_day_start $((TODAY - 1))

it "reads a time of day whose fields are not octal numbers"
# 08:09:08 is a valid time and three invalid octal numbers.
assert_out_eq "$TODAY" zro_win_day_start $((TODAY + 8 * 3600 + 9 * 60 + 8))

it "refuses a timestamp that is not a number, and a clock it cannot run"
assert_status "$ZRO_E_INPUT" zro_win_day_start 'today'
assert_status "$ZRO_E_INPUT" zro_win_day_start ''
assert_status "$ZRO_E_INPUT" zro_win_day_start
# Overridden inside a subshell: a temporary assignment in front of a function
# call persists after it returns in bash, which would leak into the next case.
rc=0; ( ZRO_DATE_BIN=/nonexistent/date; zro_win_day_start "$NOW" ) >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "$ZRO_E_UNAVAILABLE"
rc=0; ( ZRO_DATE_BIN=''; zro_win_now ) >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "$ZRO_E_UNAVAILABLE"

it "renders a timestamp the way an operator reads one"
assert_out_eq "2026-07-30 16:45:20" zro_win_human "$NOW"
assert_status "$ZRO_E_INPUT" zro_win_human 'now'
assert_status "$ZRO_E_INPUT" zro_win_human

# --- the explicit range ---------------------------------------------------

it "converts an explicit range into two absolute timestamps"
assert_out_eq "$(printf '%s\t%s' 1785283200 1785369599)" \
  zro_win_explicit '2026-07-29 00:00:00' '2026-07-29 23:59:59'
assert_out_eq "$(printf '%s\t%s' 1785312000 1785315600)" \
  zro_win_explicit '2026-07-29 08:00' '2026-07-29 09:00'

it "reads an explicit range as local wall clock, with no zone arithmetic"
# The same text in another zone is another moment, and that is the model: the
# tracer reads syslog lines that carry no zone either.
assert_eq "$( TZ=Europe/Istanbul; zro_win_epoch '2026-07-29 08:00' )" "1785301200"
assert_eq "$( TZ=UTC; zro_win_epoch '2026-07-29 08:00' )" "1785312000"

it "refuses a malformed explicit range with the invalid-input code"
assert_status "$ZRO_E_INPUT" zro_win_explicit 'dun' '2026-07-29 09:00'
assert_status "$ZRO_E_INPUT" zro_win_explicit '2026-07-29 08:00' 'now'
assert_status "$ZRO_E_INPUT" zro_win_explicit '2026-07-29' '2026-07-29'
assert_status "$ZRO_E_INPUT" zro_win_explicit '2026-07-29 08:00' ''
assert_status "$ZRO_E_INPUT" zro_win_explicit '2026-07-29 08:00'
assert_status "$ZRO_E_INPUT" zro_win_explicit
assert_status "$ZRO_E_INPUT" zro_win_explicit '2026-07-29 08:00; id' '2026-07-29 09:00'

it "refuses a day the calendar does not have"
# Shaped like a date, and not one. The validator deliberately leaves this to the
# calendar the clock already carries rather than keeping its own leap rules.
assert_status "$ZRO_E_INPUT" zro_win_explicit '2026-02-30 08:00' '2026-03-01 08:00'
assert_status "$ZRO_E_INPUT" zro_win_epoch '2026-04-31 08:00'
assert_status "$ZRO_E_INPUT" zro_win_epoch '2025-02-29 08:00'
# The leap day that does exist, so the case above proves something.
assert_ok zro_win_epoch '2024-02-29 08:00'

it "refuses a range that ends before it starts, rather than swapping the ends"
assert_status "$ZRO_E_INPUT" zro_win_explicit '2026-07-29 09:00' '2026-07-29 08:00'

it "accepts a range of one instant"
# Empty of lines, but it is what the operator asked for and it is visible on the
# report header, which is not the same as a window they did not choose.
assert_ok zro_win_explicit '2026-07-29 08:00' '2026-07-29 08:00'

zro_t_report
