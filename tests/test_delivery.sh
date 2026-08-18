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
# shellcheck source=../lib/table.sh
. "$ZRO_SRC/lib/table.sh"

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

trace_sender() {
  ZRO_MOCK_ZMMSGTRACE___SENDER_OUT="${OUT:-}" \
  ZRO_MOCK_ZMMSGTRACE___SENDER_ERR="${ERR:-}" \
  ZRO_MOCK_ZMMSGTRACE___SENDER_RC="${RC:-0}" \
  ZRO_MOCK_ZMMSGTRACE_UNREADABLE="${UNREADABLE:-}" \
    zro_trace_sender "$@"
}

trace_msgid() {
  ZRO_MOCK_ZMMSGTRACE___ID_OUT="${OUT:-}" \
  ZRO_MOCK_ZMMSGTRACE___ID_ERR="${ERR:-}" \
  ZRO_MOCK_ZMMSGTRACE___ID_RC="${RC:-0}" \
  ZRO_MOCK_ZMMSGTRACE_UNREADABLE="${UNREADABLE:-}" \
    zro_trace_msgid "$@"
}

traced() { grep '^zmmsgtrace' "$ZRO_MOCK_LOG"; }
vector_f() {
  local filter=$1
  shift
  printf 'zmmsgtrace\t%s\t%s\t--time\t%s,%s\t--year\t%s\t%s' "$filter" "$@"
}
vector() { vector_f --recipient "$@"; }

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

it "one unreadable file among several is disclosed, not refused"
# What this milestone is for. The answer that COULD be found is worth having, so
# it is shown — and the operation says out loud that it is partial, because a
# report assembled from one of two files reads exactly like a complete one.
OUT="$ONE" UNREADABLE="$SYS.1.gz" assert_status "$ZRO_E_PARTIAL" \
  trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO"

it "and still answers from the file it could read"
# The scripting variables are set INSIDE the substitution, not in front of it: an
# assignment-only command sets them in this shell, and a leaked UNREADABLE makes
# every case below it assert against a tracer nobody asked for.
out=$(OUT="$ONE" UNREADABLE="$SYS.1.gz" \
  trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO" 2>/dev/null)
assert_contains "$out" "$(cat "$ONE")"
assert_contains "$out" "Bulunan ileti  : 1"
assert_contains "$out" "$SYS.2.gz (1)"
# Both files were asked about: the skip is the tracer's answer for one of them,
# not this program deciding in advance which files to open.
: >"$ZRO_MOCK_LOG"
OUT="$ONE" UNREADABLE="$SYS.1.gz" \
  trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO" >/dev/null 2>&1
assert_eq "$(traced | wc -l | tr -d ' ')" "2"

it "the banner names the skipped file, what the tool said, and the repair"
assert_contains "$out" "EKSIK TARAMA"
assert_contains "$out" "$SYS.1.gz"
assert_contains "$out" "unable to open file"
# The usual cause is ownership on the log file, which breaks Zimbra's own tooling
# too, so naming the tool that repairs it is the right outcome.
assert_contains "$out" "zmfixperms"
# And the one sentence the whole ticket exists for: an answer missing a file is
# not proof of absence.
assert_contains "$out" "KANITLAMAZ"

it "the banner comes before the answer it is a caveat about"
# A disclosure below the report it qualifies is read after the conclusion has
# already been drawn, which is the same as not disclosing it.
banner_line=$(printf '%s\n' "$out" | grep -n 'EKSIK TARAMA' | head -n 1 | cut -d: -f1)
result_line=$(printf '%s\n' "$out" | grep -n 'Bulunan ileti' | head -n 1 | cut -d: -f1)
assert_eq "$([ "$banner_line" -lt "$result_line" ] && printf yes || printf no)" "yes"

it "and counts as scanned only the files it actually read"
# The count above the file list is what an operator reads as coverage. Counting a
# file the tracer never opened would make the banner a contradiction of the line
# below it.
assert_contains "$out" "Taranan log    : 1 dosya"
assert_not_contains "$out" "2 dosya"

it "the skipped file is in the activity log as well as on the screen"
# Never silent by any path: an administrator reading the log afterwards learns
# which file was missed without the operator having to have reported it.
logged=$(OUT="$ONE" UNREADABLE="$SYS.1.gz" \
  trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO" 2>&1 >/dev/null)
assert_contains "$logged" "$SYS.1.gz"

it "nothing found in the files it could read is still a partial scan"
# THE FAILURE THIS TICKET REMOVES. An operator who reads "kayit bulunamadi" from a
# scan that could not open half its files concludes the message never arrived, and
# goes on to make the wrong decision. So an empty answer with a file missing is
# reported as the partial scan it is, never as a plain no-result.
OUT="$NONE" UNREADABLE="$SYS.1.gz" assert_status "$ZRO_E_PARTIAL" \
  trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO"
out=$(OUT="$NONE" UNREADABLE="$SYS.1.gz" \
  trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO" 2>/dev/null)
assert_contains "$out" "EKSIK TARAMA"
assert_contains "$out" "Bulunan ileti  : 0"

it "a complete scan carries no banner at all"
# A disclosure printed when nothing was skipped is noise, and noise is how a real
# disclosure stops being read.
out=$(OUT="$ONE" trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO")
assert_not_contains "$out" "EKSIK"
assert_not_contains "$out" "UYARI"

it "no file readable at all is a log failure, not a partial scan"
# Nothing was scanned, so there is no partial answer to disclose — only a log this
# tool could not read. Reporting it as partial would claim a coverage of zero
# files as an answer.
OUT="$ONE" UNREADABLE="$(printf '%s\n%s' "$SYS.1.gz" "$SYS.2.gz")" \
  assert_status "$ZRO_E_NO_LOG" \
  trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO"

it "and produces no output at all, partial or otherwise"
out=$(OUT="$ONE" UNREADABLE="$(printf '%s\n%s' "$SYS.1.gz" "$SYS.2.gz")" \
  trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO" 2>/dev/null)
assert_eq "$out" ""

it "and keeps what the tool said, so the screen can name the cause"
OUT="$ONE" UNREADABLE="$(printf '%s\n%s' "$SYS.1.gz" "$SYS.2.gz")" \
  trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO" >/dev/null 2>&1
assert_contains "$(zro_last_error)" "unable to open file"
assert_contains "$(zro_last_error)" "$SYS.1.gz"

it "a failure that is not an unreadable log still refuses the whole operation"
# A partial scan discloses files the TRACER COULD NOT OPEN, and says the rest were
# covered. A timeout, or a status nobody here recognises, says nothing about what
# was covered — so there is no honest partial answer to assemble from it, and the
# operation is refused as it was before.
RC=2 assert_status 2 trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO"
out=$(RC=2 trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO" 2>/dev/null)
assert_eq "$out" ""
ZRO_MOCK_TIMEOUT_FIRE=1 OUT="$ONE" assert_status "$ZRO_E_TIMEOUT" \
  trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO"

it "but a refusal after a skip still names the file that was skipped"
# A refusal may abandon the answer; it may not abandon the disclosure. The older
# file is skipped, and the one after it fails with a status nobody here recognises:
# the operation is refused, and what the operator is shown still names the log that
# was never read. Otherwise this is the one path where a skipped file is silent.
UNREADABLE="$SYS.2.gz" RC=2 assert_status 2 \
  trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO"
assert_contains "$(zro_last_error)" "$SYS.2.gz"
assert_contains "$(zro_last_error)" "unable to open file"

it "and it survives a message from the tracer longer than the bound"
# THE REASON THE BOUND IS NOT ENFORCED INSIDE THE ERROR STORE, asserted rather than
# left to a comment. What the command said is bounded HERE and the skipped file is
# named after it, so a tracer that printed a stack trace cannot spend the whole
# budget and push the disclosure off the end of the message. The bound moved one
# layer down, into zro_set_error, would turn a bound into a silence.
#
# PADDING RATHER THAN A CAPTURE, and in the tree this test already owns rather than
# in tests/fixtures. What is under test is a length: no stderr any Zimbra tool has
# printed on the lab server is longer than the bound, and a fixture claiming one
# would be inventing it. The padding says nothing recognisable on purpose — a
# tracer message that named an unreadable file would be read as a skip and would
# never reach the refusal this case is about.
LONG_ERR="$TREE/tracer-stderr-over-the-bound.txt"
head -c "$(( ZRO_ERROR_KEEP_BYTES * 2 ))" /dev/zero | tr '\0' 'x' >"$LONG_ERR"
UNREADABLE="$SYS.2.gz" RC=2 ERR="$LONG_ERR" assert_status 2 \
  trace 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO"
assert_contains "$(zro_last_error)" "Okunamayan log dosyalari"
assert_contains "$(zro_last_error)" "$SYS.2.gz"

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

# ------------------------------------------------- the other two filters --
#
# Sender answers whether a user's outbound message actually left. Message-id
# answers the precise question an operator has while holding a bounce report or
# a forwarded header, where an address alone is too broad.
#
# Both take the path the recipient trace already takes — one invocation per
# selected file, each carrying the year derived from that file, every value
# quoted for the regular-expression layer. So what these cases assert is that
# the path really is shared: a filter with a quoting rule, a window rule or a
# per-file rule of its own would be a second implementation to keep in step.

it "sends the sender filter, the window, the year and the file it is asked about"
: >"$ZRO_MOCK_LOG"
OUT="$ONE" trace_sender 'ahmet.yilmaz@example.com' "$W_LIVE_FROM" "$W_LIVE_TO" >/dev/null
assert_eq "$(traced)" \
  "$(vector_f --sender 'ahmet\.yilmaz@example\.com' 20260730080000 20260730110000 2026 "$SYS")"

it "sends the message-id filter the same way"
: >"$ZRO_MOCK_LOG"
OUT="$ONE" trace_msgid 'CAabc123@example.com' "$W_LIVE_FROM" "$W_LIVE_TO" >/dev/null
assert_eq "$(traced)" \
  "$(vector_f --id 'CAabc123@example\.com' 20260730080000 20260730110000 2026 "$SYS")"

it "each filter reaches the tracer in the one spelling the allowlist approves"
# The short forms -r, -s and -i name the same operations and are refused by the
# gate, so a call site that used one would fail closed rather than quietly.
assert_not_contains "$(traced)" "$(printf '\t-i\t')"
: >"$ZRO_MOCK_LOG"
OUT="$ONE" trace_sender 'ahmet.yilmaz@example.com' "$W_LIVE_FROM" "$W_LIVE_TO" >/dev/null
assert_not_contains "$(traced)" "$(printf '\t-s\t')"

it "traces by sender once per selected file, each with that file's own year"
# The same window that proves the year is derived per file for the recipient
# filter, asserted again here: the defect it removes is a property of the
# tracer, not of one filter, so a second code path would bring it back.
: >"$ZRO_MOCK_LOG"
OUT="$ONE" trace_sender 'ahmet.yilmaz@example.com' "$W_NY_FROM" "$W_NY_TO" >/dev/null
assert_contains "$(traced)" "$(printf '\t--year\t2025\t%s' "$SYS.4.gz")"
assert_contains "$(traced)" "$(printf '\t--year\t2026\t%s' "$SYS.3.gz")"

it "traces by message-id once per selected file, each with that file's own year"
: >"$ZRO_MOCK_LOG"
OUT="$ONE" trace_msgid 'CAabc123@example.com' "$W_NY_FROM" "$W_NY_TO" >/dev/null
assert_contains "$(traced)" "$(printf '\t--year\t2025\t%s' "$SYS.4.gz")"
assert_contains "$(traced)" "$(printf '\t--year\t2026\t%s' "$SYS.3.gz")"
# One line per file and no line without a year: the year travels with the file
# whichever filter asked for it.
assert_eq "$(traced | cut -f8 | sort -u | wc -l | tr -d ' ')" "$(traced | wc -l | tr -d ' ')"
assert_eq "$(traced | cut -f6 | sort -u | tr -d ' \n')" "--year"

it "quotes the sender for the regular-expression layer, as it does the recipient"
# ADR-0002's address again: '+' is a quantifier, so unescaped this reports no
# record for an address that has one — on the screen that answers whether a
# user's own message ever left.
: >"$ZRO_MOCK_LOG"
OUT="$ONE" trace_sender 'ali+fatura@example.com' "$W_LIVE_FROM" "$W_LIVE_TO" >/dev/null
assert_contains "$(traced)" "$(printf 'zmmsgtrace\t--sender\tali\\+fatura@example\\.com\t')"

it "quotes a message-id, which carries more metacharacters than an address"
: >"$ZRO_MOCK_LOG"
# The single quotes are the point: the '$' has to reach the validator and the
# quoter exactly as an operator would paste it, unexpanded.
# shellcheck disable=SC2016
OUT="$ONE" trace_msgid 'CA+abc.123$x@mail.example.com' "$W_LIVE_FROM" "$W_LIVE_TO" >/dev/null
# shellcheck disable=SC2016
assert_contains "$(traced)" \
  "$(printf 'zmmsgtrace\t--id\tCA\\+abc\\.123\\$x@mail\\.example\\.com\t')"

it "hands the message-id over in the case it was typed"
# The tracer matches this filter case-sensitively, so anything this program did
# to the case would decide the answer. It does nothing to it.
: >"$ZRO_MOCK_LOG"
OUT="$ONE" trace_msgid 'CAabcXYZ@Mail.EXAMPLE.com' "$W_LIVE_FROM" "$W_LIVE_TO" >/dev/null
assert_contains "$(traced)" "$(printf '\t--id\tCAabcXYZ@Mail\\.EXAMPLE\\.com\t')"

it "searches the identifier a header carries, without its angle brackets"
# What an operator has in hand is a header line: 'Message-ID: <CAabc@example.com>'.
# The tracer records the identifier WITHOUT its delimiters, so a pattern carrying
# them matches nothing at all — and on this screen nothing at all reads as proof
# the message never arrived.
: >"$ZRO_MOCK_LOG"
OUT="$ONE" trace_msgid '<CAabc123@example.com>' "$W_LIVE_FROM" "$W_LIVE_TO" >/dev/null
assert_contains "$(traced)" "$(printf '\t--id\tCAabc123@example\\.com\t')"
assert_not_contains "$(traced)" '<'

it "strips only a matching pair, and only from the ends"
assert_out_eq 'CAabc123@example.com' zro_trace_msgid_bare '<CAabc123@example.com>'
assert_out_eq 'CAabc123@example.com' zro_trace_msgid_bare 'CAabc123@example.com'
assert_out_eq 'a<b>c@example.com' zro_trace_msgid_bare 'a<b>c@example.com'
assert_out_eq '<CAabc123@example.com' zro_trace_msgid_bare '<CAabc123@example.com'
assert_out_eq 'CAabc123@example.com>' zro_trace_msgid_bare 'CAabc123@example.com>'
assert_out_eq '' zro_trace_msgid_bare '<>'
assert_out_eq '' zro_trace_msgid_bare ''

it "refuses an invalid sender without running anything"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_INPUT" zro_trace_sender 'ahmet@example.com; id' "$W_LIVE_FROM" "$W_LIVE_TO"
assert_status "$ZRO_E_INPUT" zro_trace_sender '-s' "$W_LIVE_FROM" "$W_LIVE_TO"
assert_status "$ZRO_E_INPUT" zro_trace_sender '' "$W_LIVE_FROM" "$W_LIVE_TO"
assert_status "$ZRO_E_INPUT" zro_trace_sender
assert_status "$ZRO_E_INPUT" zro_trace_sender 'ahmet.yilmaz@example.com' 'dun' "$W_LIVE_TO"
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "refuses an invalid message-id without running anything"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_INPUT" zro_trace_msgid $'CAabc\n123@example.com' "$W_LIVE_FROM" "$W_LIVE_TO"
assert_status "$ZRO_E_INPUT" zro_trace_msgid 'Message-ID: <CAabc@example.com>' "$W_LIVE_FROM" "$W_LIVE_TO"
assert_status "$ZRO_E_INPUT" zro_trace_msgid '-i' "$W_LIVE_FROM" "$W_LIVE_TO"
# Nothing but the delimiters is nothing to search for, and a filter that matched
# everything is not what the operator asked about.
assert_status "$ZRO_E_INPUT" zro_trace_msgid '<>' "$W_LIVE_FROM" "$W_LIVE_TO"
# One wrapper comes off, never two. What is left is judged as the identifier it
# claims to be, so a doubly wrapped value is refused rather than half-unwrapped
# into a search that does not match what the screen would show.
assert_status "$ZRO_E_INPUT" zro_trace_msgid '<<CAabc123@example.com>>' "$W_LIVE_FROM" "$W_LIVE_TO"
assert_status "$ZRO_E_INPUT" zro_trace_msgid '<CAabc123@example.com' "$W_LIVE_FROM" "$W_LIVE_TO"
assert_status "$ZRO_E_INPUT" zro_trace_msgid '' "$W_LIVE_FROM" "$W_LIVE_TO"
assert_status "$ZRO_E_INPUT" zro_trace_msgid
assert_status "$ZRO_E_INPUT" zro_trace_msgid 'CAabc123@example.com' "$W_LIVE_TO" "$W_LIVE_FROM"
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "names what each answer was searched by"
# The report says which question it answers. An operator who reads a sender
# trace as a recipient trace draws the opposite conclusion from the same lines.
OUT="$ONE" out=$(trace_sender 'ahmet.yilmaz@example.com' "$W_28_FROM" "$W_28_TO")
assert_contains "$out" "Gonderen       : ahmet.yilmaz@example.com"
assert_not_contains "$out" "Alici          :"
OUT="$ONE" out=$(trace_msgid 'CAabc123@example.com' "$W_28_FROM" "$W_28_TO")
assert_contains "$out" "Ileti kimligi  : CAabc123@example.com"

it "and answers by sender and by message-id exactly as it answers by recipient"
# One engine, three doors: the window, the counting, the per-file headings and
# the report itself do not know which filter was used.
OUT="$TWO" out=$(trace_sender 'ahmet.yilmaz@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO")
assert_contains "$out" "Bulunan ileti  : 4"
assert_contains "$out" "Varis araligi  : 2026-07-28 00:00:00 - 2026-07-28 23:59:59"
assert_contains "$out" "VARIS"
assert_contains "$out" "$(cat "$TWO")"
OUT="$NONE" assert_status "$ZRO_E_NO_RESULT" \
  trace_msgid 'CAabc123@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO"
OUT="$ONE" UNREADABLE="$SYS.1.gz" assert_status "$ZRO_E_PARTIAL" \
  trace_msgid 'CAabc123@example.com' "$W_28_DAY_FROM" "$W_28_DAY_TO"

it "every filter the allowlist approves is reachable and has a label"
# Two declarations held equal, the way the window presets and the binary roots
# are: the allowlist owns what may run, this module owns how to run it and what
# to call it on the screen. A filter approved and unreachable is an operation
# that reads as available and never answers; a filter reachable and unapproved
# would not pass the gate.
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  filter=${entry#*:}
  : >"$ZRO_MOCK_LOG"
  zro_trace_exec "$filter" 'pattern' >/dev/null 2>&1
  assert_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'zmmsgtrace\t%s\tpattern' "$filter")"
  assert_ok zro_trace_label "$filter"
done <<EOF
$(zro_allow_entries | grep '^zmmsgtrace:')
EOF

it "a filter nobody approved cannot be expressed at all"
# The filters this milestone does not expose are refused before the gate sees
# them, because there is no call site that could name one. The denial is the
# defect code, not an operator error, and nothing runs.
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_DENIED" zro_trace_exec --srchost 'mail.example.com'
assert_status "$ZRO_E_DENIED" zro_trace_exec --desthost 'mail.example.com'
assert_status "$ZRO_E_DENIED" zro_trace_exec -r 'ahmet.yilmaz@example.com'
assert_status "$ZRO_E_DENIED" zro_trace_exec ''
assert_status "$ZRO_E_DENIED" zro_trace_exec
assert_fail zro_trace_label --srchost
assert_fail zro_trace_label ''
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

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
