#!/usr/bin/env bash
# The delivery trace: what the mail transfer agent's log says about a message.
set -uo pipefail
#
# EVERY tracing fixture here is SYNTHETIC. It is assembled from the print
# statements documented in docs/research/2026-07-29-zimbra-cli-read-only-
# reference.md §B.11, which were read out of the tool's source — not captured
# from a server. M1 shipped two production bugs from fixtures written from
# memory, so nothing here may depend on the report's internal shape beyond the
# one predicate this milestone declares: whether any message was found. These
# tests therefore assert on the argument vector, the found/not-found decision,
# the exit codes and the text the operator is shown, and on no column, field
# name or timestamp of the report.
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ZIMBRA_LIBEXEC="$ZRO_TEST_ROOT/mocks/libexec"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* "$ZRO_TEST_ROOT"/mocks/libexec/* 2>/dev/null || true

# shellcheck source=../lib/validate.sh
. "$ZRO_SRC/lib/validate.sh"
# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"
# shellcheck source=../lib/delivery.sh
. "$ZRO_SRC/lib/delivery.sh"

ZRO_MOCK_LOG=$(mktemp);  export ZRO_MOCK_LOG
ZRO_ERROR_FILE=$(mktemp); export ZRO_ERROR_FILE
export ZRO_MOCK_ID_USER=zimbra
FIX="$ZRO_TEST_ROOT/fixtures"
ONE="$FIX/zmmsgtrace_synthetic_one_message.txt"
TWO="$FIX/zmmsgtrace_synthetic_two_messages.txt"
NONE="$FIX/zmmsgtrace_synthetic_no_match.txt"

# The mock keys its answer on the filter flag alone.
trace() {
  ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="${OUT:-}" \
  ZRO_MOCK_ZMMSGTRACE___RECIPIENT_ERR="${ERR:-}" \
  ZRO_MOCK_ZMMSGTRACE___RECIPIENT_RC="${RC:-0}" \
    zro_trace_recipient "$@"
}

it "sends the recipient filter and the address, and nothing else"
# Asserted as the whole line, not a substring: this milestone traces the tool's
# own default file, so a file path, a time window or a year appearing in the
# vector is a scope the operator did not ask for and a test must catch.
: >"$ZRO_MOCK_LOG"
OUT="$ONE" trace 'ahmet.yilmaz@example.com' >/dev/null
assert_eq "$(grep '^zmmsgtrace' "$ZRO_MOCK_LOG")" \
  "$(printf '%s\t%s\t%s' zmmsgtrace --recipient 'ahmet\.yilmaz@example\.com')"

it "escapes a regular-expression metacharacter before the address leaves"
# ADR-0002's address: '+' is a quantifier, so unescaped this reports no delivery
# record for an address that has one.
: >"$ZRO_MOCK_LOG"
OUT="$ONE" trace 'ali+fatura@example.com' >/dev/null
assert_eq "$(grep '^zmmsgtrace' "$ZRO_MOCK_LOG")" \
  "$(printf '%s\t%s\t%s' zmmsgtrace --recipient 'ali\+fatura@example\.com')"

it "runs as zimbra through the timeout wrapper like every other command"
: >"$ZRO_MOCK_LOG"
OUT="$ONE" trace 'ahmet.yilmaz@example.com' >/dev/null
log=$(cat "$ZRO_MOCK_LOG")
assert_contains "$log" "$(printf 'timeout\t-k\t5')"
assert_not_contains "$log" "runuser"

it "as root, runs the trace as zimbra with no per-binary exception"
: >"$ZRO_MOCK_LOG"
OUT="$ONE" ZRO_MOCK_ID_USER=root trace 'ahmet.yilmaz@example.com' >/dev/null
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'runuser\t-u\tzimbra\t--')"

it "shows the report exactly as it arrived"
OUT="$ONE" out=$(trace 'ahmet.yilmaz@example.com')
assert_contains "$out" "$(cat "$ONE")"

it "reports how many messages were found"
OUT="$ONE" out=$(trace 'ahmet.yilmaz@example.com')
assert_contains "$out" "1"
OUT="$TWO" out=$(trace 'ahmet.yilmaz@example.com')
assert_contains "$out" "2"
assert_contains "$out" "$(cat "$TWO")"

it "names the address that was traced"
OUT="$ONE" out=$(trace 'ahmet.yilmaz@example.com')
assert_contains "$out" "ahmet.yilmaz@example.com"

it "says which logs were searched, so nothing found is not read as nothing happened"
OUT="$ONE" out=$(trace 'ahmet.yilmaz@example.com')
assert_contains "$out" "log"

it "reports no result rather than success when nothing matched"
# The tool exits 0 whether or not anything matched, which is the whole reason
# this predicate exists.
OUT="$NONE" assert_status "$ZRO_E_NO_RESULT" trace 'ahmet.yilmaz@example.com'
OUT="$NONE" out=$(trace 'ahmet.yilmaz@example.com'); assert_eq "$out" ""

it "an unmatched trace still ran successfully underneath"
: >"$ZRO_MOCK_LOG"
OUT="$NONE" trace 'ahmet.yilmaz@example.com' >/dev/null 2>&1
assert_contains "$(cat "$ZRO_MOCK_LOG")" "zmmsgtrace"

it "refuses an invalid address without running anything"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_INPUT" zro_trace_recipient 'ahmet@example.com; id'
assert_status "$ZRO_E_INPUT" zro_trace_recipient '-r'
assert_status "$ZRO_E_INPUT" zro_trace_recipient ''
assert_status "$ZRO_E_INPUT" zro_trace_recipient
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "a log it could not open is reported as the documented log failure"
# The tool dies with a message and an exit status of its own — Perl hands back
# whatever errno was set, which can collide with the codes this program defines.
# So the message decides, and the operator gets 'log unreadable' rather than a
# foreign number that would draw the wrong screen.
RC=13 ERR="$FIX/zmmsgtrace_synthetic_unreadable.err" \
  assert_status "$ZRO_E_NO_LOG" trace 'ahmet.yilmaz@example.com'

it "keeps what the tool said, whichever code it mapped to"
RC=13 ERR="$FIX/zmmsgtrace_synthetic_unreadable.err" \
  trace 'ahmet.yilmaz@example.com' >/dev/null 2>&1
assert_contains "$(zro_last_error)" "unable to open file"

it "passes an unrecognised failure status through unchanged"
RC=2 assert_status 2 trace 'ahmet.yilmaz@example.com'

it "a slow trace is cut off with the documented timeout code"
ZRO_MOCK_TIMEOUT_FIRE=1 OUT="$ONE" \
  assert_status "$ZRO_E_TIMEOUT" trace 'ahmet.yilmaz@example.com'

it "opens no mailbox"
: >"$ZRO_MOCK_LOG"
OUT="$ONE" trace 'ahmet.yilmaz@example.com' >/dev/null
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "zmmailbox"
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "zmprov"

# The one place in this milestone that depends on the report's internal shape.
# It is isolated here so that re-verifying it against output captured from a real
# server is a single-function job.
it "counts the messages a report introduces"
assert_out_eq "0" zro_trace_message_count ""
assert_out_eq "0" zro_trace_message_count
assert_out_eq "0" zro_trace_message_count "$(cat "$NONE")"
assert_out_eq "1" zro_trace_message_count "$(cat "$ONE")"
assert_out_eq "2" zro_trace_message_count "$(cat "$TWO")"

it "counts an introduction only where the report puts one"
# Indented text is a recipient block or a hop line, never a new message, and a
# log line that merely mentions the words is not one either.
assert_out_eq "0" zro_trace_message_count "  Message ID 'CAabc123@example.com'"
assert_out_eq "0" zro_trace_message_count "554 5.7.1 no Message ID here"

rm -f -- "$ZRO_MOCK_LOG" "$ZRO_ERROR_FILE"
zro_t_report
