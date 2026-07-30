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

# Local wall clock is this tool's only time model, and the windows below are
# absolute timestamps. Pinned so the suite does not depend on the zone of whoever
# runs it.
export TZ=UTC

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ZIMBRA_LIBEXEC="$ZRO_TEST_ROOT/mocks/libexec"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* "$ZRO_TEST_ROOT"/mocks/libexec/* 2>/dev/null || true

# The log tree the window selects from. Built here rather than committed, because
# what these cases turn on is modification times and a checkout does not carry
# them. The root is overridden before the inventory is sourced, so its production
# default is never reached — no test can create /var/log/zimbra.log, which is why
# that seam exists at all.
TREE=$(mktemp -d)
mkdir -p "$TREE/var/log" "$TREE/empty"
export ZRO_SYSLOG_FILE="$TREE/var/log/zimbra.log"
export ZRO_LOG_DIR="$TREE/zimbra/log"

# shellcheck source=../lib/validate.sh
. "$ZRO_SRC/lib/validate.sh"
# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"
# shellcheck source=../lib/inventory.sh
. "$ZRO_SRC/lib/inventory.sh"
# shellcheck source=../lib/window.sh
. "$ZRO_SRC/lib/window.sh"
# shellcheck source=../lib/delivery.sh
. "$ZRO_SRC/lib/delivery.sh"

ZRO_MOCK_LOG=$(mktemp);  export ZRO_MOCK_LOG
ZRO_ERROR_FILE=$(mktemp); export ZRO_ERROR_FILE
export ZRO_MOCK_ID_USER=zimbra
FIX="$ZRO_TEST_ROOT/fixtures"
ONE="$FIX/zmmsgtrace_synthetic_one_message.txt"
TWO="$FIX/zmmsgtrace_synthetic_two_messages.txt"
NONE="$FIX/zmmsgtrace_synthetic_no_match.txt"

SYS="$TREE/var/log/zimbra.log"
mk() {
  printf 'Jul 28 14:02:11 mail postfix/smtp[1]: placeholder\n' >"$1"
  touch -d "$2" -- "$1"
}

# The syslog family as logrotate leaves it: daily, compressed, no delaycompress,
# fired from cron.daily at 03:20 — so each rotated file's own timestamp names the
# day AFTER the lines it holds. The two oldest sit either side of a new year, so
# that the year derived per file is a value the cases below can tell apart.
mk "$SYS"             '2026-07-30 10:00'  # 1785405600
mk "$SYS.1.gz"        '2026-07-29 03:20'  # 1785295200
mk "$SYS.2.gz"        '2026-07-28 03:20'  # 1785208800
mk "$SYS.3.gz"        '2026-01-01 03:20'  # 1767237600
mk "$SYS.4.gz"        '2025-12-31 03:20'  # 1767151200

# Windows, as absolute local timestamps.
W_LIVE_FROM=1785398400   # 2026-07-30 08:00
W_LIVE_TO=1785409200     # 2026-07-30 11:00
W_28_FROM=1785240000     # 2026-07-28 12:00, the afternoon of the 28th
W_28_TO=1785261600       # 2026-07-28 18:00
W_28_DAY_FROM=1785196800 # 2026-07-28 00:00, the whole day: two files
W_28_DAY_TO=1785283199   # 2026-07-28 23:59:59
W_NY_FROM=1767139200     # 2025-12-31 00:00, reaching across the year boundary
W_NY_TO=1767247800       # 2026-01-01 06:10

# The mock keys its answer on the filter flag alone.
trace() {
  ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="${OUT:-}" \
  ZRO_MOCK_ZMMSGTRACE___RECIPIENT_ERR="${ERR:-}" \
  ZRO_MOCK_ZMMSGTRACE___RECIPIENT_RC="${RC:-0}" \
  ZRO_MOCK_ZMMSGTRACE_UNREADABLE="${UNREADABLE:-}" \
    zro_trace_recipient "$@"
}

traced() { grep '^zmmsgtrace' "$ZRO_MOCK_LOG"; }
vector() { printf 'zmmsgtrace\t--recipient\t%s\t--time\t%s,%s\t--year\t%s\t%s' "$@"; }

it "sends the filter, the window, the year and the one file it is asked about"
# Asserted as the whole line, not a substring: an argument this program did not
# put there is a scope the operator did not ask for, and a missing --time or
# --year is a window silently wider than the one on the screen.
: >"$ZRO_MOCK_LOG"
OUT="$ONE" trace 'ahmet.yilmaz@example.com' "$W_LIVE_FROM" "$W_LIVE_TO" >/dev/null
assert_eq "$(traced)" \
  "$(vector 'ahmet\.yilmaz@example\.com' 20260730080000 20260730110000 2026 "$SYS")"

it "bounds the window in the tracer's own format, to the second"
# YYYYMMDDHHMMSS, from the tool's POD. A shorter bound is read as a wider window.
assert_contains "$(traced)" "$(printf '\t--time\t20260730080000,20260730110000\t')"

it "invokes the tracer once per selected file, each with its own file and year"
# The whole day of the 28th spans the rotation that fired on the morning of the
# 28th, so two files hold it. One invocation each, oldest first.
: >"$ZRO_MOCK_LOG"
OUT="$ONE" trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO" >/dev/null
assert_eq "$(traced)" "$(printf '%s\n%s' \
  "$(vector 'ahmet\.yilmaz@example\.com' 20260728000000 20260728235959 2026 "$SYS.2.gz")" \
  "$(vector 'ahmet\.yilmaz@example\.com' 20260728000000 20260728235959 2026 "$SYS.1.gz")")"

it "asks about exactly the files the window covers and no others"
assert_eq "$(traced | wc -l | tr -d ' ')" "2"
assert_not_contains "$(traced)" "$SYS.3.gz"
# The live file is a prefix of every rotated name, so this is a line question
# rather than a substring one.
assert_not_line "$(traced | cut -f8)" "$SYS"

it "the year comes from each file's own modification time, not from the clock"
# THE DEFECT THIS TICKET REMOVES. The tracer guesses the year once from the local
# clock, so a time-bounded search of a log rotated in a different year silently
# returns nothing. This window reaches across a new year: the file rotated on 31
# December is traced with 2025 and the one rotated on 1 January with 2026, each in
# its own invocation, and one guessed year could not have served both.
: >"$ZRO_MOCK_LOG"
OUT="$ONE" trace 'ahmet.yilmaz@example.com' "$W_NY_FROM" "$W_NY_TO" >/dev/null
assert_contains "$(traced)" "$(printf '\t--year\t2025\t%s' "$SYS.4.gz")"
assert_contains "$(traced)" "$(printf '\t--year\t2026\t%s' "$SYS.3.gz")"
assert_contains "$(traced)" "$(printf '\t--time\t20251231000000,20260101061000\t')"

it "a window on one afternoon reaches the file rotated the following morning"
# Rotation runs in the early morning, so the 28th's afternoon is in the file
# rotated on the 29th. Selecting by the date in a name would hand back .2.gz and
# the trace would find nothing at all.
: >"$ZRO_MOCK_LOG"
OUT="$ONE" trace 'ahmet.yilmaz@example.com' "$W_28_FROM" "$W_28_TO" >/dev/null
assert_eq "$(traced)" \
  "$(vector 'ahmet\.yilmaz@example\.com' 20260728120000 20260728180000 2026 "$SYS.1.gz")"

it "takes no file path from its caller"
# The path is derived from the inventory, never from an argument. A fourth
# argument is ignored rather than trusted, and nothing outside the tree reaches
# the vector.
: >"$ZRO_MOCK_LOG"
OUT="$ONE" trace 'ahmet.yilmaz@example.com' "$W_LIVE_FROM" "$W_LIVE_TO" /etc/passwd >/dev/null
assert_not_contains "$(traced)" "/etc/passwd"
assert_eq "$(traced)" \
  "$(vector 'ahmet\.yilmaz@example\.com' 20260730080000 20260730110000 2026 "$SYS")"

it "escapes a regular-expression metacharacter before the address leaves"
# ADR-0002's address: '+' is a quantifier, so unescaped this reports no delivery
# record for an address that has one.
: >"$ZRO_MOCK_LOG"
OUT="$ONE" trace 'ali+fatura@example.com' "$W_LIVE_FROM" "$W_LIVE_TO" >/dev/null
assert_contains "$(traced)" "$(printf 'zmmsgtrace\t--recipient\tali\\+fatura@example\\.com\t')"

it "runs as zimbra through the timeout wrapper like every other command"
: >"$ZRO_MOCK_LOG"
OUT="$ONE" trace 'ahmet.yilmaz@example.com' "$W_LIVE_FROM" "$W_LIVE_TO" >/dev/null
log=$(cat "$ZRO_MOCK_LOG")
assert_contains "$log" "$(printf 'timeout\t-k\t5')"
assert_not_contains "$log" "runuser"

it "as root, runs the trace as zimbra with no per-binary exception"
: >"$ZRO_MOCK_LOG"
OUT="$ONE" ZRO_MOCK_ID_USER=root \
  trace 'ahmet.yilmaz@example.com' "$W_LIVE_FROM" "$W_LIVE_TO" >/dev/null
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'runuser\t-u\tzimbra\t--')"

it "shows the report exactly as it arrived"
OUT="$ONE" out=$(trace 'ahmet.yilmaz@example.com' "$W_LIVE_FROM" "$W_LIVE_TO")
assert_contains "$out" "$(cat "$ONE")"

it "presents several files as one answer with a total count"
# Two files, one message each: the operator is told four things — how many were
# found altogether, how many files were read, which ones, and how many came from
# each. The last of those is what keeps the total honest, below.
OUT="$ONE" out=$(trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO")
assert_contains "$out" "Bulunan ileti  : 2"
assert_contains "$out" "2 dosya"
assert_contains "$out" "$SYS.2.gz (1)"
assert_contains "$out" "$SYS.1.gz (1)"

it "counts every message in every file it read, and says the total is a sum"
# The total cannot be the number of DISTINCT messages: the tracer re-initialises
# per file, so a message whose hops straddle a rotation is introduced once in each
# file and counted in both. Telling those apart would mean parsing the report
# further, against output nobody has captured from a server — so the count is
# presented as what it is, per file and summed, rather than as a claim it cannot
# support.
OUT="$TWO" out=$(trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO")
assert_contains "$out" "Bulunan ileti  : 4"
assert_contains "$out" "$SYS.1.gz (2)"
assert_contains "$out" "toplam, dosya basina bulunanlarin toplamidir"
assert_contains "$out" "$(cat "$TWO")"

it "says nothing of the sort when one file answered the question"
# A caveat about a rotation boundary that was not crossed is noise, and noise is
# how a real disclosure stops being read.
OUT="$TWO" out=$(trace 'ahmet.yilmaz@example.com' "$W_28_FROM" "$W_28_TO")
assert_contains "$out" "1 dosya"
assert_not_contains "$out" "toplam, dosya basina"

it "names the file each report came from"
# Not decoration: the tracer re-initialises per file, so a message whose hops
# straddle a rotation is reported as fragments. An operator who cannot see which
# file a fragment came from has no way to know that is what they are reading.
OUT="$ONE" out=$(trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO")
assert_eq "$(printf '%s\n' "$out" | grep -c '^----- ')" "2"

it "names the address and the window the answer belongs to"
OUT="$ONE" out=$(trace 'ahmet.yilmaz@example.com' "$W_28_FROM" "$W_28_TO")
assert_contains "$out" "ahmet.yilmaz@example.com"
assert_contains "$out" "2026-07-28 12:00:00 - 2026-07-28 18:00:00"

it "says the window is the message's arrival time, not its delivery time"
# A message that arrived before the window and was delivered inside it does not
# appear. An operator who reads the window as a delivery window will conclude the
# message never arrived.
OUT="$ONE" out=$(trace 'ahmet.yilmaz@example.com' "$W_28_FROM" "$W_28_TO")
assert_contains "$out" "VARIS"
assert_contains "$out" "Varis araligi"
assert_not_contains "$out" "teslim araligi"

it "reports no result rather than success when nothing matched in any file"
# The tool exits 0 whether or not anything matched, which is the whole reason
# this predicate exists.
OUT="$NONE" assert_status "$ZRO_E_NO_RESULT" \
  trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO"
OUT="$NONE" out=$(trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO")
assert_eq "$out" ""

it "an unmatched trace still ran, on every file the window covered"
: >"$ZRO_MOCK_LOG"
OUT="$NONE" trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO" >/dev/null 2>&1
assert_eq "$(traced | wc -l | tr -d ' ')" "2"

it "refuses an invalid address without running anything"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_INPUT" zro_trace_recipient 'ahmet@example.com; id' "$W_LIVE_FROM" "$W_LIVE_TO"
assert_status "$ZRO_E_INPUT" zro_trace_recipient '-r' "$W_LIVE_FROM" "$W_LIVE_TO"
assert_status "$ZRO_E_INPUT" zro_trace_recipient '' "$W_LIVE_FROM" "$W_LIVE_TO"
assert_status "$ZRO_E_INPUT" zro_trace_recipient
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "refuses a malformed window without running anything"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_INPUT" zro_trace_recipient 'ahmet.yilmaz@example.com' 'yesterday' "$W_LIVE_TO"
assert_status "$ZRO_E_INPUT" zro_trace_recipient 'ahmet.yilmaz@example.com' "$W_LIVE_FROM" ''
assert_status "$ZRO_E_INPUT" zro_trace_recipient 'ahmet.yilmaz@example.com' "$W_LIVE_FROM"
assert_status "$ZRO_E_INPUT" zro_trace_recipient 'ahmet.yilmaz@example.com'
# An end before its start is a caller defect, not an empty window: answering
# "nothing arrived" to a window that cannot exist is the ambiguity this whole
# feature exists to remove.
assert_status "$ZRO_E_INPUT" zro_trace_recipient 'ahmet.yilmaz@example.com' "$W_LIVE_TO" "$W_LIVE_FROM"
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "one unreadable file among several refuses the whole operation"
# Strict, on purpose. A report assembled from one of two files reads exactly like
# a complete answer, and an operator who concludes from it that a message never
# arrived goes on to make the wrong decision. The next ticket discloses the
# skipped file instead of refusing.
OUT="$ONE" UNREADABLE="$SYS.1.gz" assert_status "$ZRO_E_NO_LOG" \
  trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO"

it "and produces no partial output at all"
OUT="$ONE" UNREADABLE="$SYS.1.gz" out=$(trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO" 2>/dev/null)
assert_eq "$out" ""
# Proof that the refusal is about the second file rather than about never having
# started: the first file was read before the refusal.
: >"$ZRO_MOCK_LOG"
OUT="$ONE" UNREADABLE="$SYS.1.gz" \
  trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO" >/dev/null 2>&1
assert_contains "$(traced)" "$SYS.2.gz"

it "keeps what the tool said about the file it could not open"
OUT="$ONE" UNREADABLE="$SYS.1.gz" \
  trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO" >/dev/null 2>&1
assert_contains "$(zro_last_error)" "unable to open file"
assert_contains "$(zro_last_error)" "$SYS.1.gz"

it "a log it could not open is reported as the documented log failure"
# The tool dies with a message and an exit status of its own — Perl hands back
# whatever errno was set, which can collide with the codes this program defines.
# So the message decides, and the operator gets 'log unreadable' rather than a
# foreign number that would draw the wrong screen.
RC=13 ERR="$FIX/zmmsgtrace_synthetic_unreadable.err" assert_status "$ZRO_E_NO_LOG" \
  trace 'ahmet.yilmaz@example.com' "$W_LIVE_FROM" "$W_LIVE_TO"

it "passes an unrecognised failure status through unchanged"
RC=2 assert_status 2 trace 'ahmet.yilmaz@example.com' "$W_LIVE_FROM" "$W_LIVE_TO"

it "a slow trace is cut off with the documented timeout code"
ZRO_MOCK_TIMEOUT_FIRE=1 OUT="$ONE" assert_status "$ZRO_E_TIMEOUT" \
  trace 'ahmet.yilmaz@example.com' "$W_LIVE_FROM" "$W_LIVE_TO"

it "a window with no log file behind it is a log failure, never an empty answer"
# The oldest file in a family has no lower bound and the newest no upper one, so
# every window intersects something as long as one file exists. An empty
# selection therefore means there was nothing to read — and reporting "no
# records" for it would be the exact ambiguity this feature exists to remove.
: >"$ZRO_MOCK_LOG"
rc=0
( ZRO_SYSLOG_FILE="$TREE/empty/zimbra.log"
  OUT="$ONE" trace 'ahmet.yilmaz@example.com' "$W_LIVE_FROM" "$W_LIVE_TO" ) >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "$ZRO_E_NO_LOG"
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "a log root the inventory refuses is reported as the denial it is"
rc=0
( ZRO_SYSLOG_FILE="$TREE/we'ird.log"
  OUT="$ONE" trace 'ahmet.yilmaz@example.com' "$W_LIVE_FROM" "$W_LIVE_TO" ) >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "$ZRO_E_DENIED"

it "opens no mailbox"
: >"$ZRO_MOCK_LOG"
OUT="$ONE" trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO" >/dev/null
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "zmmailbox"
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "zmprov"

it "renders a window bound the way the tracer documents it"
assert_out_eq "20260728120000" zro_trace_stamp "$W_28_FROM"
assert_out_eq "20260101000000" zro_trace_stamp 1767225600
assert_status "$ZRO_E_INPUT" zro_trace_stamp 'now'
assert_status "$ZRO_E_INPUT" zro_trace_stamp ''
assert_status "$ZRO_E_INPUT" zro_trace_stamp
rc=0; ( ZRO_DATE_BIN=/nonexistent/date; zro_trace_stamp "$W_28_FROM" ) >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "$ZRO_E_UNAVAILABLE"

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
rm -rf -- "$TREE"
zro_t_report
