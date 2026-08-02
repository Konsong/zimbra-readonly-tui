#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"

it "exposes the documented exit codes"
assert_eq "$ZRO_E_INPUT" "10"
assert_eq "$ZRO_E_TIMEOUT" "22"
assert_eq "$ZRO_E_CANCEL" "40"
assert_eq "$ZRO_E_DENIED" "90"
assert_eq "$ZRO_E_BADUSER" "91"
assert_eq "$ZRO_E_NOCAP" "92"

it "zro_log writes to stderr, never stdout"
assert_out_eq "" zro_log info "should not appear on stdout"

it "zro_log labels the level"
captured=$(zro_log warn "disk almost full" 2>&1 >/dev/null)
assert_contains "$captured" "warn"
assert_contains "$captured" "disk almost full"

it "zro_first_existing returns the first executable path"
assert_out_eq "/bin/sh" zro_first_existing /nonexistent/zzz /bin/sh

it "zro_first_existing fails when nothing exists"
assert_fail zro_first_existing /nonexistent/aaa /nonexistent/bbb

# The one place this program asks the clock about a moment. The log inventory's
# year, the arrival window's bounds and the tracer's own time option all come
# through here, and each of them decides whether a trace finds anything at all.
it "zro_clock_fmt renders a timestamp as local wall clock"
export TZ=UTC
assert_out_eq "2026-07-30" zro_clock_fmt '%Y-%m-%d' 1785405600
assert_out_eq "2026" zro_clock_fmt '%Y' 1785405600
assert_out_eq "20260730100000" zro_clock_fmt '%Y%m%d%H%M%S' 1785405600
# The zone decides the answer, and there is no arithmetic here that pretends
# otherwise: this tool's only time model is the local wall clock.
assert_eq "$( TZ=Europe/Istanbul; zro_clock_fmt '%H:%M' 1785405600 )" "13:00"

it "zro_clock_fmt refuses a timestamp that is not one"
assert_status "$ZRO_E_INPUT" zro_clock_fmt '%Y' 'now'
assert_status "$ZRO_E_INPUT" zro_clock_fmt '%Y' '2026-07-30'
assert_status "$ZRO_E_INPUT" zro_clock_fmt '%Y' ''
assert_status "$ZRO_E_INPUT" zro_clock_fmt '%Y'
assert_status "$ZRO_E_INPUT" zro_clock_fmt '' 1785405600
assert_status "$ZRO_E_INPUT" zro_clock_fmt

it "zro_clock_fmt reports a clock it cannot run rather than answering empty"
# An empty answer would reach a command line as a missing year or a missing
# window bound, and the tracer reads either as a wider search that found nothing.
rc=0; ( ZRO_DATE_BIN=/nonexistent/date; zro_clock_fmt '%Y' 1785405600 ) >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "$ZRO_E_UNAVAILABLE"
rc=0; ( ZRO_DATE_BIN=''; zro_clock_fmt '%Y' 1785405600 ) >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "$ZRO_E_UNAVAILABLE"

it "one separator carries every pair this program passes between functions"
assert_eq "$ZRO_TAB" "$(printf '\t')"

it "zro_tmpfile creates a file readable only by the owner"
tmp=$(zro_tmpfile)
assert_eq "$(stat -c '%a' "$tmp")" "600"
rm -f -- "$tmp"

it "zro_tmpfile returns a fresh path each call"
a=$(zro_tmpfile); b=$(zro_tmpfile)
assert_not_contains "$a" "$b"
rm -f -- "$a" "$b"

it "zro_human_bytes formats magnitudes"
assert_out_eq "0 B" zro_human_bytes 0
assert_out_eq "1.0 KB" zro_human_bytes 1024
assert_out_eq "1.5 MB" zro_human_bytes 1572864
assert_out_eq "2.0 GB" zro_human_bytes 2147483648

it "zro_human_bytes rejects a non-numeric argument"
assert_status "$ZRO_E_INPUT" zro_human_bytes "12; rm -rf /"

# ------------------------------------------------- the files a session keeps --
#
# A value a session has to remember across a command substitution cannot be a
# variable: menu code runs operations inside $( ), and an assignment made there
# dies with the subshell. The two this module owns are joined by any a later module
# needs for the same reason, which is why they are REGISTERED rather than listed
# here — this module depends on nothing and is not going to learn what a mailbox is.

it "the files this module owns are the ones it starts with"
assert_contains "$(printf '%s\n' "${ZRO_SESSION_FILES[@]}")" "$ZRO_ERROR_FILE"
assert_contains "$(printf '%s\n' "${ZRO_SESSION_FILES[@]}")" "$ZRO_MODE_FILE"

it "a module may register one of its own"
extra=$(mktemp)
zro_session_file "$extra"
assert_contains "$(printf '%s\n' "${ZRO_SESSION_FILES[@]}")" "$extra"

it "and every registered file is removed at exit"
# Registration is worth nothing if the sweep still names two files by hand: a
# module that added one and was never cleaned up would leave a proof of existence
# on disk for the next session to read.
zro_set_error "something"
zro_reset_mode
printf 'x\n' >"$extra"
zro_cleanup
assert_fail test -e "$extra"
assert_fail test -e "$ZRO_ERROR_FILE"
assert_fail test -e "$ZRO_MODE_FILE"

it "a registration with no path is refused rather than sweeping nothing"
assert_status "$ZRO_E_INPUT" zro_session_file ""
assert_status "$ZRO_E_INPUT" zro_session_file

zro_t_report
