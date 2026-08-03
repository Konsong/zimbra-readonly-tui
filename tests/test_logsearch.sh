#!/usr/bin/env bash
# The log search's engine: what it reads, what it matches, what it refuses, and
# what it says when the answer does not cover everything it was meant to.
#
# The fixture TREE is built here rather than committed, for the reason
# tests/test_logview.sh gives: what these cases turn on is which files exist under
# the declared roots, and a checkout carries neither the compression nor the
# modification times. The fixture CONTENT is committed, and is real: every line in
# it was written by the lab server. A pattern is only worth what the text it was
# matched against is worth.
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ZIMBRA_LIBEXEC="$ZRO_TEST_ROOT/mocks/libexec"
export ZRO_SYSTEM_BIN="$ZRO_TEST_ROOT/mocks/system"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
export ZRO_NICE_BIN="$ZRO_TEST_ROOT/mocks/bin/nice"
export ZRO_IONICE_BIN="$ZRO_TEST_ROOT/mocks/bin/ionice"
export ZRO_MOCK_ID_USER=zimbra
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* "$ZRO_TEST_ROOT"/mocks/libexec/* \
         "$ZRO_TEST_ROOT"/mocks/system/* 2>/dev/null || true

# Local wall clock is this tool's only time model; the zone is pinned so the suite
# does not depend on the zone of whoever runs it.
export TZ=UTC

TREE=$(mktemp -d)
mkdir -p "$TREE/var/log" "$TREE/zimbra/log"
export ZRO_SYSLOG_FILE="$TREE/var/log/zimbra.log"
export ZRO_LOG_DIR="$TREE/zimbra/log"

# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/validate.sh
. "$ZRO_SRC/lib/validate.sh"
# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"
# shellcheck source=../lib/inventory.sh
. "$ZRO_SRC/lib/inventory.sh"
# shellcheck source=../lib/window.sh
. "$ZRO_SRC/lib/window.sh"
# shellcheck source=../lib/logview.sh
. "$ZRO_SRC/lib/logview.sh"
# The message-id lookup unwraps a pasted identifier through the delivery trace's
# own function rather than through a second copy of that rule.
# shellcheck source=../lib/delivery.sh
. "$ZRO_SRC/lib/delivery.sh"
# shellcheck source=../lib/logsearch.sh
. "$ZRO_SRC/lib/logsearch.sh"

FIX="$ZRO_TEST_ROOT/fixtures"
SYS="$TREE/var/log/zimbra.log"
MBOX="$TREE/zimbra/log/mailbox.log"
AUDIT="$TREE/zimbra/log/audit.log"

# THE FILE THE SEARCH EXISTS FOR. Padding first, then the captured outcome lines,
# then padding again — so that a reader which took the last lines of the file, or
# the first, would find nothing at all. The outcomes sit in the middle exactly as
# they do on the lab server, where they are in the first fifth of a log five times
# longer than the bounded viewer's reach.
pad() { seq 1 "$1" | sed 's/^/Aug  2 12:00:00 posta postfix\/smtpd[1]: padding line /'; }
{ pad 300; cat "$FIX/zimbra_log_outcomes.txt"; pad 300; } >"$SYS"
touch -d '2026-07-30 10:00' -- "$SYS"
# One rotated file, compressed, holding the same outcomes: what a window wider
# than today has to reach, and through the one decompression form that leaves the
# file where it was.
{ pad 50; cat "$FIX/zimbra_log_outcomes.txt"; } | gzip -c >"$SYS.1.gz"
touch -d '2026-07-29 03:20' -- "$SYS.1.gz"

cat "$FIX/audit_log_sessions.txt" >"$AUDIT"
touch -d '2026-07-30 09:00' -- "$AUDIT"
cat "$FIX/mailbox_log_errors.txt" >"$MBOX"
touch -d '2026-07-30 09:30' -- "$MBOX"
chmod 644 -- "$SYS" "$SYS.1.gz" "$AUDIT" "$MBOX"

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG
ZRO_ERROR_FILE=$(mktemp); export ZRO_ERROR_FILE

# A window covering everything on this tree, and one covering only the live file.
WIDE_S=$(date -d '2026-07-01 00:00' '+%s')
WIDE_E=$(date -d '2026-08-01 00:00' '+%s')
LIVE_S=$(date -d '2026-07-29 12:00' '+%s')
LIVE_E=$(date -d '2026-08-01 00:00' '+%s')

# The matched lines and nothing else: everything below the header rule, with the
# per-file headings and the blank lines between blocks taken out. The rule is a
# long run of dashes and a heading is five and a space, which is what tells them
# apart here.
body() {
  printf '%s\n' "$1" | sed -n '/^-------/,$p' | tail -n +2 \
    | grep -v '^----- ' | grep -v '^$'
}
# The file headings, in the order the answer carries them.
blocks() { printf '%s\n' "$1" | grep '^----- ' ; }
ran() { grep -E '^(grep|gzip|tail)' "$ZRO_MOCK_LOG"; }

# --- the named questions, against log lines a real server wrote ---------------

it "finds the rejected message, which is the one with no queue id"
# A rejection is refused before DATA, so it carries the literal NOQUEUE where every
# other line carries an id — and it is exactly the message an operator is looking
# for when they say the mail never arrived.
out=$(zro_logsearch_named rejected '' "$LIVE_S" "$LIVE_E" 2>/dev/null)
assert_eq "$?" "0"
assert_contains "$out" "NOQUEUE: reject:"
assert_contains "$(body "$out")" "olmayan-kullanici@example.com"
assert_not_contains "$(body "$out")" "status=deferred"

it "finds the two deferred messages and their two different causes"
out=$(zro_logsearch_named deferred '' "$LIVE_S" "$LIVE_E" 2>/dev/null)
assert_eq "$(body "$out" | grep -c 'status=deferred')" "2"
assert_contains "$out" "Host or domain name not found"
assert_contains "$out" "Connection refused"

it "finds the bounced message and the notification it produced"
# Two lines, and the second is the one that names the report that went back to the
# sender. A question keyed on the status field alone would drop it.
out=$(zro_logsearch_named bounced '' "$LIVE_S" "$LIVE_E" 2>/dev/null)
assert_contains "$out" "status=bounced"
assert_contains "$out" "sender non-delivery notification"

it "finds local delivery by the hop that means a mailbox took the message"
# The first status=sent on a Zimbra server only means amavis accepted it. The lmtp
# hop with dsn=2.1.5 is the one that means somebody received it.
out=$(zro_logsearch_named delivered '' "$LIVE_S" "$LIVE_E" 2>/dev/null)
assert_contains "$out" "postfix/lmtp"
assert_contains "$out" "250 2.1.5 Delivery OK"

it "finds both a successful session and a failed one"
# The level differs — INFO against WARN — and the failure appends an error field.
# Keying on either half would answer half the question an operator asked.
out=$(zro_logsearch_named sessions '' "$LIVE_S" "$LIVE_E" 2>/dev/null)
assert_contains "$out" "cmd=Auth; account=zimbra; protocol=soap;"
assert_contains "$out" "invalid password"
assert_contains "$out" "external LDAP auth failed"

it "and does not answer an administrative change as a session"
assert_not_contains "$(zro_logsearch_named sessions '' "$LIVE_S" "$LIVE_E" 2>/dev/null)" \
  "cmd=CreateAccount"

it "finds a mailbox error where Zimbra really writes one"
# Not at ERROR: this server has none in five days. What a user's failure looks
# like is a bare stack trace with no level at all, and two INFO lines.
out=$(zro_logsearch_named mboxerror '' "$LIVE_S" "$LIVE_E" 2>/dev/null)
assert_contains "$out" "ServiceException: system failure: mailbox not found"
assert_contains "$out" "handler exception"
assert_contains "$out" "Error occurred during authentication"

it "and does not fill the answer with start-up warnings"
# Every WARN on the lab server in five days was one of six start-up lines. A
# question that matched them would bury the line the operator came for.
assert_not_contains "$(zro_logsearch_named mboxerror '' "$LIVE_S" "$LIVE_E" 2>/dev/null)" \
  "no Zimbra-Extension-Class"

it "searches each question's own log, and not one the operator picked"
: >"$ZRO_MOCK_LOG"
zro_logsearch_named sessions '' "$LIVE_S" "$LIVE_E" >/dev/null 2>&1
assert_contains "$(ran)" "$AUDIT"
assert_not_contains "$(ran)" "$SYS"
: >"$ZRO_MOCK_LOG"
zro_logsearch_named mboxerror '' "$LIVE_S" "$LIVE_E" >/dev/null 2>&1
assert_contains "$(ran)" "$MBOX"

it "names a question for every declared pattern, and a pattern for every question"
# Two declarations held equal, the way the window presets and the menu that offers
# them are. A question with no pattern is a menu entry that answers nothing; a
# pattern with no question is a search nobody can reach.
missing=""
while IFS= read -r id; do
  [ -n "$id" ] || continue
  zro_logsearch_pattern "$id" >/dev/null 2>&1 || missing="$missing [$id]"
  zro_logsearch_question_label "$id" >/dev/null 2>&1 || missing="$missing [label:$id]"
  zro_logview_label "$(zro_logsearch_question_log "$id")" >/dev/null 2>&1 ||
    missing="$missing [log:$id]"
done <<EOF
$(zro_logsearch_questions)
EOF
assert_eq "$missing" ""
assert_fail zro_logsearch_pattern nosuchquestion
assert_fail zro_logsearch_pattern ''
assert_fail zro_logsearch_question_log nosuchquestion

it "and no pattern this tool owns could be read as a flag"
# They reach a command line in the data position, where a leading dash is not data
# at all. The gate would refuse one; this is what keeps one from being written.
bad=""
while IFS= read -r id; do
  [ -n "$id" ] || continue
  case $(zro_logsearch_pattern "$id") in
    -*) bad="$bad [$id]" ;;
    '') bad="$bad [empty:$id]" ;;
  esac
done <<EOF
$(zro_logsearch_questions)
EOF
assert_eq "$bad" ""

# --- the address filter -------------------------------------------------------

it "narrows a question to one address, matching it literally"
out=$(zro_logsearch_named deferred 'kullanici@nosuchdomain.invalid' "$LIVE_S" "$LIVE_E" 2>/dev/null)
assert_eq "$(body "$out" | grep -c .)" "1"
assert_contains "$out" "nosuchdomain.invalid"
assert_not_contains "$(body "$out")" "kuyruk-test@dc01.example.com"

it "and says on the answer that it was narrowed"
assert_contains "$out" "Adres suzgeci"

it "an address with punctuation in it matches itself"
# THE WHOLE REASON THE FILTER IS A LITERAL. '+' and '.' are quantifiers and
# wildcards to a pattern engine, so the same address matched as a pattern finds
# either nothing or somebody else's mail.
printf 'Aug  2 16:49:03 posta postfix/smtp[1]: A1: to=<ali+fatura@example.com>, status=deferred (x)\n' >>"$SYS"
printf 'Aug  2 16:49:03 posta postfix/smtp[1]: A2: to=<aliXfatura@example.com>, status=deferred (x)\n' >>"$SYS"
out=$(zro_logsearch_named deferred 'ali+fatura@example.com' "$LIVE_S" "$LIVE_E" 2>/dev/null)
assert_eq "$(body "$out" | grep -c .)" "1"
assert_contains "$out" "ali+fatura@example.com"
assert_not_contains "$(body "$out")" "aliXfatura"

it "refuses a filter that is not an address"
# The named door takes at most an address, and judges it as one. Anything else is
# a caller defect: this is not the free-text door and may not become one by way of
# an unvalidated filter.
assert_status "$ZRO_E_INPUT" zro_logsearch_named deferred 'not an address' "$LIVE_S" "$LIVE_E"
assert_status "$ZRO_E_INPUT" zro_logsearch_named deferred '-v' "$LIVE_S" "$LIVE_E"
assert_status "$ZRO_E_INPUT" zro_logsearch_named deferred 'status=' "$LIVE_S" "$LIVE_E"

# --- the questions that are about everybody -----------------------------------

it "finds one message by its identifier, in every shape the log writes it"
# The same identifier is written three ways — the cleanup stage's `message-id=<X>`,
# amavis's `Message-ID: <X>`, and the mailbox server's `msgid=<X>` — so the bare
# identifier is what finds all of them. A search for any one of the three forms
# would find a third of the truth.
out=$(zro_logsearch_msgid 'delivered-1785678543@capture.example.com' "$LIVE_S" "$LIVE_E" 2>/dev/null)
assert_eq "$?" "0"
assert_contains "$out" "message-id=<delivered-1785678543@capture.example.com>"
assert_contains "$out" "Message-ID: <delivered-1785678543@capture.example.com>"
assert_contains "$out" "ileti kimligi: delivered-1785678543@capture.example.com"

it "and takes the angle brackets off a pasted header value"
# What an operator has in hand carries them. Unwrapped through the delivery
# trace's own function, so the value searched for and the value on the screen are
# one string on both screens.
wrapped=$(zro_logsearch_msgid '<delivered-1785678543@capture.example.com>' "$LIVE_S" "$LIVE_E" 2>/dev/null)
assert_eq "$(body "$wrapped")" "$(body "$out")"

it "and matches it literally, so a lookalike identifier is not this message"
printf 'Aug  2 16:49:03 posta postfix/cleanup[1]: X1: message-id=<deliveredX1785678543@capture.example.com>\n' >>"$SYS"
out=$(zro_logsearch_msgid 'delivered-1785678543@capture.example.com' "$LIVE_S" "$LIVE_E" 2>/dev/null)
assert_not_contains "$(body "$out")" "deliveredX1785678543"

it "refuses an identifier that is not one, and runs nothing"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_INPUT" zro_logsearch_msgid '' "$LIVE_S" "$LIVE_E"
assert_status "$ZRO_E_INPUT" zro_logsearch_msgid 'iki parca' "$LIVE_S" "$LIVE_E"
assert_status "$ZRO_E_INPUT" zro_logsearch_msgid '-v' "$LIVE_S" "$LIVE_E"
assert_status "$ZRO_E_INPUT" zro_logsearch_msgid '<yarim' "$LIVE_S" "$LIVE_E"
assert_eq "$(ran)" ""

it "finds mail that arrived from one domain, by its envelope sender"
out=$(zro_logsearch_sender_domain 'example.com' "$LIVE_S" "$LIVE_E" 2>/dev/null)
assert_eq "$?" "0"
assert_contains "$out" "from=<ahmet.yilmaz@example.com>"
assert_contains "$out" "gonderen alan adi: example.com"

it "and does not answer mail SENT TO that domain as mail received from it"
# THE CASE THAT DECIDED THE PATTERN. The captured rejection carries
# to=<someone@example.org> on a line that also carries from=<...@example.com>, so
# any whole-line match for the domain would report a message sent to a
# correspondent as one received from them — the wrong answer to act on.
assert_contains "$(printf '%s\n' "$(cat "$FIX/zimbra_log_outcomes.txt")")" "to=<someone@example.org>"
assert_status "$ZRO_E_NO_RESULT" zro_logsearch_sender_domain 'example.org' "$LIVE_S" "$LIVE_E"

it "and does not answer the client's own greeting as a sender either"
# The same line carries helo=<foreign.example.net>, which is what the connecting
# host called itself and not where the mail came from.
assert_status "$ZRO_E_NO_RESULT" zro_logsearch_sender_domain 'foreign.example.net' "$LIVE_S" "$LIVE_E"

it "and finds it whatever case either end wrote it in"
# A DOMAIN IS THE SAME DOMAIN HOWEVER IT IS WRITTEN, at both ends: the operator
# may type it any way, and the sending client's envelope is logged as it was given.
# A case-sensitive search would answer "nothing arrived from there" about mail that
# did — on the one screen that presents an empty answer as proof.
#
# The mixed case is written `eXAMPLE` rather than `Example` on purpose:
# tests/test_bash_compat.sh bans the bash 4.4 parameter transformations as bare
# substrings, and `@E` in a fixture line reads as one of them.
printf 'Aug  2 16:49:03 posta postfix/qmgr[1]: X4: from=<Ahmet.Yilmaz@eXAMPLE.com>, size=1\n' >>"$SYS"
out=$(zro_logsearch_sender_domain 'example.com' "$LIVE_S" "$LIVE_E" 2>/dev/null)
assert_contains "$(body "$out")" "Ahmet.Yilmaz@eXAMPLE.com"
out=$(zro_logsearch_sender_domain 'EXAMPLE.com' "$LIVE_S" "$LIVE_E" 2>/dev/null)
assert_contains "$(body "$out")" "ahmet.yilmaz@example.com"
assert_contains "$(body "$out")" "Ahmet.Yilmaz@eXAMPLE.com"

it "and the identifier beside it is matched case-sensitively, which is its own rule"
# The opposite rule for the opposite reason: an identifier is a token some agent
# generated rather than a name, so folding case there would report a different
# message as this one.
printf 'Aug  2 16:49:03 posta postfix/cleanup[1]: X5: message-id=<CASE-1785678543@capture.example.com>\n' >>"$SYS"
assert_status "$ZRO_E_NO_RESULT" \
  zro_logsearch_msgid 'case-1785678543@capture.example.com' "$LIVE_S" "$LIVE_E"
assert_ok zro_logsearch_msgid 'CASE-1785678543@capture.example.com' "$LIVE_S" "$LIVE_E"

it "and the case-folded form is the only one that folds case"
: >"$ZRO_MOCK_LOG"
zro_logsearch_sender_domain 'example.com' "$LIVE_S" "$LIVE_E" >/dev/null 2>&1
assert_contains "$(ran)" "$(printf 'grep\t-a\t-E\t-i')"
: >"$ZRO_MOCK_LOG"
zro_logsearch_named rejected '' "$LIVE_S" "$LIVE_E" >/dev/null 2>&1
assert_not_contains "$(ran)" "$(printf '\t-i\t')"
: >"$ZRO_MOCK_LOG"
zro_logsearch_text syslog 'padding' "$LIVE_S" "$LIVE_E" >/dev/null 2>&1
assert_not_contains "$(ran)" "$(printf '\t-i\t')"

it "and reads the dots in a domain as dots"
# Without escaping, 'mail.example.com' would also match 'mailXexample.com', which
# is a different organisation. The value is validated as a domain first and escaped
# second, and neither protection is trusted on its own.
assert_out_eq 'from=<[^>]*@example\.com>' zro_logsearch_sender_pattern 'example.com'
assert_out_eq 'from=<[^>]*@mail\.example\.com>' zro_logsearch_sender_pattern 'mail.example.com'
printf 'Aug  2 16:49:03 posta postfix/qmgr[1]: X2: from=<x@exampleXcom>, size=1\n' >>"$SYS"
out=$(zro_logsearch_sender_domain 'example.com' "$LIVE_S" "$LIVE_E" 2>/dev/null)
assert_not_contains "$(body "$out")" "exampleXcom"

it "and a subdomain is a different domain, in both directions"
printf 'Aug  2 16:49:03 posta postfix/qmgr[1]: X3: from=<x@mail.example.com>, size=1\n' >>"$SYS"
out=$(zro_logsearch_sender_domain 'example.com' "$LIVE_S" "$LIVE_E" 2>/dev/null)
assert_not_contains "$(body "$out")" "x@mail.example.com"
out=$(zro_logsearch_sender_domain 'mail.example.com' "$LIVE_S" "$LIVE_E" 2>/dev/null)
assert_contains "$(body "$out")" "x@mail.example.com"
assert_not_contains "$(body "$out")" "ahmet.yilmaz@example.com"

it "refuses anything that is not a domain, and runs nothing"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_INPUT" zro_logsearch_sender_domain '' "$LIVE_S" "$LIVE_E"
assert_status "$ZRO_E_INPUT" zro_logsearch_sender_domain 'ahmet@example.com' "$LIVE_S" "$LIVE_E"
assert_status "$ZRO_E_INPUT" zro_logsearch_sender_domain 'example.com|x' "$LIVE_S" "$LIVE_E"
assert_status "$ZRO_E_INPUT" zro_logsearch_sender_domain '.*' "$LIVE_S" "$LIVE_E"
assert_status "$ZRO_E_INPUT" zro_logsearch_sender_domain 'https://example.com' "$LIVE_S" "$LIVE_E"
assert_status "$ZRO_E_INPUT" zro_logsearch_sender_domain '-example.com' "$LIVE_S" "$LIVE_E"
assert_eq "$(ran)" ""

it "and no domain that passes validation can carry a pattern into the reader"
# The value reaches an extended regular expression, which is the one place in this
# module it does. What keeps that safe is the validator above and the escaping
# below it — so this asks the validator directly, of every metacharacter there is.
#
# Driven over the tool's OWN declared set of metacharacters rather than a list
# written out here: a character added to that declaration and forgotten in this
# case would be exactly the one nobody checked.
bad="" metas=$ZRO_RE_META
for (( i = 0; i < ${#metas}; i++ )); do
  m=${metas:i:1}
  # A bare metacharacter is not a domain, and neither is a real domain wearing one.
  zro_validate_domain "$m" && bad="$bad [$m]"
  zro_validate_domain "example${m}com" && bad="$bad [example${m}com]"
done
# The dot is the one metacharacter a domain really contains, and it is escaped
# rather than refused.
assert_eq "$bad" " [example.com]"

it "answers both questions in one scan of the window, and asks about no account"
: >"$ZRO_MOCK_LOG"
zro_logsearch_msgid 'delivered-1785678543@capture.example.com' "$LIVE_S" "$LIVE_E" >/dev/null 2>&1
assert_eq "$(ran | grep -c .)" "1"
: >"$ZRO_MOCK_LOG"
zro_logsearch_sender_domain 'example.com' "$LIVE_S" "$LIVE_E" >/dev/null 2>&1
assert_eq "$(ran | grep -c .)" "1"
log=$(cat "$ZRO_MOCK_LOG")
assert_not_contains "$log" "zmprov"
assert_not_contains "$log" "zmmailbox"
assert_not_contains "$log" "zmmsgtrace"

it "names a log and a label for every declared lookup"
missing=""
while IFS= read -r id; do
  [ -n "$id" ] || continue
  zro_logsearch_lookup_label "$id" >/dev/null 2>&1 || missing="$missing [label:$id]"
  zro_logview_label "$(zro_logsearch_lookup_log "$id")" >/dev/null 2>&1 ||
    missing="$missing [log:$id]"
done <<EOF
$(zro_logsearch_lookups)
EOF
assert_eq "$missing" ""
assert_fail zro_logsearch_lookup_log nosuchlookup
assert_fail zro_logsearch_lookup_label ''

it "and a lookup is not a named question, nor the other way round"
# Two tables with two contracts: a named question lists what happened and takes at
# most an address, a lookup asks whether one value is there at all. An id in both
# would be a question whose behaviour depends on which table was read first.
overlap=""
while IFS= read -r id; do
  [ -n "$id" ] || continue
  zro_logsearch_question_log "$id" >/dev/null 2>&1 && overlap="$overlap [$id]"
done <<EOF
$(zro_logsearch_lookups)
EOF
assert_eq "$overlap" ""

# The padding lines added by the cases above are left in place: what follows reads
# the file for its own patterns, and a longer file is a truer one.

# --- free text ----------------------------------------------------------------

it "matches free text literally, wherever in the file it is"
out=$(zro_logsearch_text syslog 'B0CC6104BA2' "$LIVE_S" "$LIVE_E" 2>/dev/null)
assert_contains "$out" "queued as B0CC6104BA2"
assert_contains "$out" "duz metin: B0CC6104BA2"

it "and treats a pattern an operator types as the text it is"
# A search for a queue id, a host name or a message-id is a search for punctuation.
# Matched as a pattern, '.' matches anything and the answer names somebody else.
printf 'Aug  2 16:49:03 posta postfix/smtp[1]: B1: to=<x@a.b>, relay=dc01.example.com[1]\n' >>"$SYS"
printf 'Aug  2 16:49:03 posta postfix/smtp[1]: B2: to=<x@a.b>, relay=dc01Xexample.com[1]\n' >>"$SYS"
out=$(zro_logsearch_text syslog 'dc01.example.com' "$LIVE_S" "$LIVE_E" 2>/dev/null)
assert_not_contains "$(body "$out")" "dc01Xexample.com"

it "searches whichever declared log the operator chose"
assert_ok zro_logsearch_text audit 'cmd=Auth' "$LIVE_S" "$LIVE_E"
assert_ok zro_logsearch_text mailbox 'LmtpServer' "$LIVE_S" "$LIVE_E"

it "refuses a log the inventory does not declare, and runs nothing"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_DENIED" zro_logsearch_text nginx 'x' "$LIVE_S" "$LIVE_E"
assert_status "$ZRO_E_DENIED" zro_logsearch_text '' 'x' "$LIVE_S" "$LIVE_E"
assert_eq "$(ran)" ""

it "refuses text that would stop being one value, and runs nothing"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_INPUT" zro_logsearch_text syslog '' "$LIVE_S" "$LIVE_E"
assert_status "$ZRO_E_INPUT" zro_logsearch_text syslog '-v' "$LIVE_S" "$LIVE_E"
assert_status "$ZRO_E_INPUT" zro_logsearch_text syslog "$(printf 'a\nb')" "$LIVE_S" "$LIVE_E"
assert_status "$ZRO_E_INPUT" zro_logsearch_text syslog "$(printf 'a\tb')" "$LIVE_S" "$LIVE_E"
long=$(printf 'a%.0s' $(seq 1 300))
assert_status "$ZRO_E_INPUT" zro_logsearch_text syslog "$long" "$LIVE_S" "$LIVE_E"
assert_eq "$(ran)" ""

it "and admits the punctuation an operator actually arrives holding"
assert_ok zro_logsearch_validate_text 'ali+fatura@example.com'
assert_ok zro_logsearch_validate_text '<CAabc123@example.com>'
assert_ok zro_logsearch_validate_text 'B0CC6104BA2:'
assert_ok zro_logsearch_validate_text 'status=deferred'

it "and a phrase, because that is what an operator arrives holding most often"
# THE THING NOBODY ANTICIPATED IS USUALLY A SENTENCE. Every one of these is a
# fragment of a real log line from the lab server, and refusing the space would
# leave this door open only to values that happen to be single tokens.
assert_ok zro_logsearch_validate_text 'connection refused'
assert_ok zro_logsearch_validate_text 'Recipient address rejected'
assert_ok zro_logsearch_validate_text '250 2.1.5 Delivery OK'
out=$(zro_logsearch_text syslog 'Connection refused' "$LIVE_S" "$LIVE_E" 2>/dev/null)
assert_contains "$out" "kuyruk-test@dc01.example.com"
assert_contains "$out" "duz metin: Connection refused"

it "but not a space where nothing on the screen would show it"
# Leading and trailing spaces are invisible in the line that says what was
# searched for, so an answer of nothing would have no visible cause.
assert_fail zro_logsearch_validate_text ' alpha'
assert_fail zro_logsearch_validate_text 'alpha '
assert_fail zro_logsearch_validate_text ' '

# --- the whole of every file --------------------------------------------------

it "reads every file in the window from its first line, not from its end"
# THE DECISION THE MODULE IS BUILT ON. The outcome lines sit 300 lines into a file
# whose end holds 300 more, so a reader bounded by input finds nothing here — and
# reports that as though it meant something.
out=$(zro_logsearch_named rejected '' "$LIVE_S" "$LIVE_E" 2>/dev/null)
assert_contains "$out" "NOQUEUE: reject:"
assert_contains "$out" "TAMAMI okundu"

it "and the reader was given no bound on what it read"
# Asserted on the argv, which is what proves it: the cap is on matches, and there
# is no line count anywhere in the vector.
: >"$ZRO_MOCK_LOG"
zro_logsearch_named rejected '' "$LIVE_S" "$LIVE_E" >/dev/null 2>&1
assert_contains "$(ran)" "$(printf 'grep\t-a\t-E\t-m')"
assert_not_contains "$(ran)" "tail"

it "reads the compressed rotation too, and leaves it compressed"
out=$(zro_logsearch_named rejected '' "$WIDE_S" "$WIDE_E" 2>/dev/null)
assert_contains "$out" "$SYS.1.gz"
assert_contains "$out" "2 dosya"
assert_ok test -f "$SYS.1.gz"
assert_fail test -e "$SYS.1"

it "and reached it through the decompression that writes to stdout"
: >"$ZRO_MOCK_LOG"
zro_logsearch_named rejected '' "$WIDE_S" "$WIDE_E" >/dev/null 2>&1
assert_contains "$(ran)" "$(printf 'gzip\t-dc\t%s' "$SYS.1.gz")"

it "names every file it searched, with what it found in each"
out=$(zro_logsearch_named rejected '' "$WIDE_S" "$WIDE_E" 2>/dev/null)
assert_contains "$out" "$SYS ("
assert_contains "$out" "$SYS.1.gz ("

it "and puts each file's lines under the name of the file they came from"
# A week's window reaches five files on a real server, and a rotated mail log's
# lines carry no year. Two files' lines run together are a chronology that does not
# exist, so each block says where it came from — the same heading the delivery
# trace puts above each file's report.
assert_contains "$out" "----- $SYS -----"
assert_contains "$out" "----- $SYS.1.gz -----"

it "searches the newest file first, because the cap ends the scan where it got to"
# THE ORDER THE CAP MAKES IMPORTANT. Reading oldest first means a capped scan
# never opens today's log — so an operator asking what happened this morning would
# be answered out of last week, with the newest file listed as unread. Reversed,
# what the cap costs is the oldest file, which is the one they are least likely to
# have meant.
assert_eq "$(zro_logsearch_files syslog "$WIDE_S" "$WIDE_E" | cut -f2)" \
  "$(printf '%s\n%s' "$SYS" "$SYS.1.gz")"
# And the answer reads in that order too: the live file's block comes first.
assert_eq "$(blocks "$out")" \
  "$(printf -- '----- %s -----\n----- %s -----' "$SYS" "$SYS.1.gz")"

it "states the window it searched, and that the window chose files not lines"
# The bound this screen CANNOT enforce, said out loud. Nothing here parses a
# timestamp, so a selected file is searched whole and the answer can carry lines
# from either side of the window's edges.
assert_contains "$out" "Aralik"
assert_contains "$out" "DOSYA secimine uygulanir"

it "requires a window, and refuses one that is not one"
assert_status "$ZRO_E_INPUT" zro_logsearch_named rejected '' '' ''
assert_status "$ZRO_E_INPUT" zro_logsearch_named rejected '' 'dun' 'bugun'
assert_status "$ZRO_E_INPUT" zro_logsearch_named rejected '' "$LIVE_E" "$LIVE_S"

it "declares what it is about to read before it reads anything"
plan=$(zro_logsearch_plan syslog "$WIDE_S" "$WIDE_E")
assert_eq "${plan%%	*}" "2"
bytes=${plan#*	}
assert_ok test "$bytes" -gt 0
# The declared cost is the sum of the files the same selection will hand the scan,
# so what the operator confirmed and what gets read are one list.
sum=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  sum=$((sum + ${line%%	*}))
done <<EOF
$(zro_logsearch_files syslog "$WIDE_S" "$WIDE_E")
EOF
assert_eq "$bytes" "$sum"

it "and the plan is empty when the window covers a log this host does not have"
rm -f -- "$AUDIT"
assert_out_eq "$(printf '0\t0')" zro_logsearch_plan audit "$WIDE_S" "$WIDE_E"
assert_status "$ZRO_E_NO_LOG" zro_logsearch_named sessions '' "$WIDE_S" "$WIDE_E"
cat "$FIX/audit_log_sessions.txt" >"$AUDIT"
touch -d '2026-07-30 09:00' -- "$AUDIT"

# --- the answer that means something -----------------------------------------

it "an empty answer is its own result, and it is a complete one"
# What this whole module exists for. Every file the window selected was opened and
# read from its first line, so nothing found means nothing was there — and the
# caller is told that with a code of its own rather than with an empty report.
assert_status "$ZRO_E_NO_RESULT" \
  zro_logsearch_text syslog 'yok-boyle-bir-sey-19283746' "$WIDE_S" "$WIDE_E"

it "a file that cannot be read makes the answer partial, and says which file"
: >"$ZRO_MOCK_LOG"
out=$(ZRO_MOCK_GREP_RC=2 ZRO_MOCK_GREP_ERR="grep: $SYS: Permission denied" \
      zro_logsearch_named rejected '' "$LIVE_S" "$LIVE_E" 2>/dev/null)
rc=0
ZRO_MOCK_GREP_RC=2 ZRO_MOCK_GREP_ERR="grep: $SYS: Permission denied" \
  zro_logsearch_named rejected '' "$WIDE_S" "$WIDE_E" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "$ZRO_E_NO_LOG"
assert_contains "$(zro_last_error)" "Permission denied"
assert_eq "$out" ""

it "and a scan that read some of its files reports a partial scan with the answer"
# One file readable and one not: the answer that could be found is worth having,
# so it is shown — under a banner naming what was missed, and with a code that
# tells the screen to mark its title.
unreadable="$TREE/zimbra/log/mailbox.log.2026-07-29.gz"
printf 'not gzip at all\n' >"$unreadable"
touch -d '2026-07-29 03:20' -- "$unreadable"
rc=0
out=$(zro_logsearch_text mailbox 'LmtpServer' "$WIDE_S" "$WIDE_E" 2>/dev/null) || rc=$?
assert_eq "$rc" "$ZRO_E_PARTIAL"
assert_contains "$out" "EKSIK TARAMA"
assert_contains "$out" "$unreadable"
assert_contains "$out" "KANITLAMAZ"
assert_contains "$out" "zmfixperms"
# The answer is still there, under the banner.
assert_contains "$out" "TcpServer/7025"
rm -f -- "$unreadable"

it "and the banner counts the whole selection, not the files it happens to know"
# A cap and a skipped file can both be true at once, and then read plus skipped is
# NOT the window: the files the cap left unopened are neither. A banner that added
# the two up would quietly report a smaller window than the operator chose.
#
# Four files, newest first: one read with nothing in it, one that cannot be
# decompressed, one that fills the cap, and one the cap therefore never opened.
: >"$MBOX"; pad 5 >"$MBOX"; touch -d '2026-07-30 09:00' -- "$MBOX"
printf 'not gzip at all\n' >"$unreadable"
touch -d '2026-07-29 03:20' -- "$unreadable"
third="$TREE/zimbra/log/mailbox.log.2026-07-28"
cat "$FIX/mailbox_log_errors.txt" >"$third"
touch -d '2026-07-28 03:20' -- "$third"
fourth="$TREE/zimbra/log/mailbox.log.2026-07-27"
cat "$FIX/mailbox_log_errors.txt" >"$fourth"
touch -d '2026-07-27 03:20' -- "$fourth"
rc=0
out=$(ZRO_LOGSEARCH_MATCHES=1 zro_logsearch_text mailbox 'LmtpServer' "$WIDE_S" "$WIDE_E" 2>/dev/null) || rc=$?
assert_eq "$rc" "$ZRO_E_PARTIAL"
assert_contains "$out" "Secilen 4 dosyadan 1 tanesi okunamadi"
assert_contains "$out" "SINIRA ULASILDI"
assert_contains "$out" "$fourth"
rm -f -- "$unreadable" "$third" "$fourth"
cat "$FIX/mailbox_log_errors.txt" >"$MBOX"; touch -d '2026-07-30 09:00' -- "$MBOX"

it "nothing found in a partial scan is reported as the partial scan it is"
# NOT as an empty result. An operator who reads "no records" from a scan that
# could not open half its files concludes the thing never happened, which is the
# exact wrong decision this screen exists to prevent.
printf 'not gzip at all\n' >"$unreadable"
touch -d '2026-07-29 03:20' -- "$unreadable"
rc=0
out=$(zro_logsearch_text mailbox 'yok-boyle-bir-sey-19283746' "$WIDE_S" "$WIDE_E" 2>/dev/null) || rc=$?
assert_eq "$rc" "$ZRO_E_PARTIAL"
assert_contains "$out" "EKSIK TARAMA"
rm -f -- "$unreadable"

# --- the cap ------------------------------------------------------------------

it "stops after the declared number of matches"
rc=0
out=$(ZRO_LOGSEARCH_MATCHES=3 zro_logsearch_text syslog 'padding' "$LIVE_S" "$LIVE_E" 2>/dev/null) || rc=$?
assert_eq "$(body "$out" | grep -c .)" "3"
assert_eq "$rc" "$ZRO_E_PARTIAL"

it "and says so, because a capped answer is not a complete one"
assert_contains "$out" "SINIRA ULASILDI"
assert_contains "$out" "Bulunan satir  : 3 (ust sinir: 3)"

it "and names the files it never reached because of the cap"
# The difference between "this did not happen" and "I stopped looking". A file the
# scan never opened is named, not silently absent from the list of what was read —
# and it is an OLDER file, because the scan starts at the newest.
rc=0
out=$(ZRO_LOGSEARCH_MATCHES=2 zro_logsearch_text syslog 'padding' "$WIDE_S" "$WIDE_E" 2>/dev/null) || rc=$?
assert_eq "$rc" "$ZRO_E_PARTIAL"
assert_contains "$out" "hic taranmadi"
assert_contains "$out" "$SYS.1.gz"
# The live file is what it did read, which is what an operator asking about now
# needed it to read.
assert_contains "$out" "----- $SYS -----"

it "and the cap is applied by the reader, not after the whole file arrived"
# Asserted on the argv: a search that let every match through and trimmed them
# here would hold a whole log's worth of lines in memory, on the server it is
# diagnosing.
: >"$ZRO_MOCK_LOG"
ZRO_LOGSEARCH_MATCHES=3 zro_logsearch_text syslog 'padding' "$LIVE_S" "$LIVE_E" >/dev/null 2>&1
assert_contains "$(ran)" "$(printf 'grep\t-a\t-F\t-m\t3\tpadding\t%s' "$SYS")"

it "a compressed file capped mid-scan is not reported as unreadable"
# The reader stops at the cap and closes the pipe, so the decompression upstream
# is killed by SIGPIPE and reports a failure it did not have. Read as an
# unreadable file, that would put a permissions banner and zmfixperms on a scan
# where nothing whatsoever was wrong.
#
# THE FILE HAS TO BE BIG ENOUGH FOR THE SIGNAL TO HAPPEN. A small one is
# decompressed into the pipe buffer before the reader stops, so nothing ever
# receives it — and a rotated mail log is not small. The token is in this file
# alone, so the newer file the scan starts with yields nothing and the whole cap
# falls here.
big="$TREE/var/log/zimbra.log.2.gz"
{ pad 40000 | sed 's/padding/onlyingz/'; } | gzip -c >"$big"
touch -d '2026-07-28 03:20' -- "$big"
rc=0
out=$(ZRO_LOGSEARCH_MATCHES=2 zro_logsearch_text syslog 'onlyingz' "$WIDE_S" "$WIDE_E" 2>/dev/null) || rc=$?
assert_eq "$rc" "$ZRO_E_PARTIAL"
assert_contains "$out" "SINIRA ULASILDI"
assert_not_contains "$out" "EKSIK TARAMA"
assert_not_contains "$out" "zmfixperms"
assert_eq "$(body "$out" | grep -c .)" "2"
rm -f -- "$big"

it "refuses a cap that is not a count, and runs nothing"
: >"$ZRO_MOCK_LOG"
ZRO_LOGSEARCH_MATCHES='200; id' assert_status "$ZRO_E_INPUT" zro_logsearch_named rejected '' "$LIVE_S" "$LIVE_E"
ZRO_LOGSEARCH_MATCHES='' assert_status "$ZRO_E_INPUT" zro_logsearch_named rejected '' "$LIVE_S" "$LIVE_E"
ZRO_LOGSEARCH_MATCHES='-5' assert_status "$ZRO_E_INPUT" zro_logsearch_named rejected '' "$LIVE_S" "$LIVE_E"
ZRO_LOGSEARCH_MATCHES='0' assert_status "$ZRO_E_INPUT" zro_logsearch_named rejected '' "$LIVE_S" "$LIVE_E"
assert_eq "$(ran)" ""

# --- what it will not do ------------------------------------------------------

it "opens only files the inventory listed for the log it was asked about"
: >"$ZRO_MOCK_LOG"
printf 'secret\n' >"$TREE/var/log/secret.txt"
printf 'neighbour\n' >"$SYS.bak"
zro_logsearch_text syslog 'secret' "$WIDE_S" "$WIDE_E" >/dev/null 2>&1
zro_logsearch_text syslog 'neighbour' "$WIDE_S" "$WIDE_E" >/dev/null 2>&1
outside=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  path=$(printf '%s' "$line" | awk -F'\t' '{print $NF}')
  case $path in
    "$SYS"|"$SYS".1.gz) ;;
    padding|secret|neighbour|-a|-F|-E) ;;   # the pattern, on the reader taking stdin
    *) outside="$outside [$path]" ;;
  esac
done <<EOF
$(ran)
EOF
assert_eq "$outside" ""
rm -f -- "$TREE/var/log/secret.txt" "$SYS.bak"

it "passes the gate's own refusals through instead of calling them unreadable logs"
# A host that cannot reduce priority is not a log that cannot be read, and an
# operator sent to zmfixperms over a missing ionice would repair nothing.
ZRO_IONICE_BIN='' assert_status "$ZRO_E_UNAVAILABLE" \
  zro_logsearch_named rejected '' "$LIVE_S" "$LIVE_E"
ZRO_SYSTEM_BIN=/nonexistent assert_status "$ZRO_E_NOCAP" \
  zro_logsearch_named rejected '' "$LIVE_S" "$LIVE_E"
ZRO_MOCK_ID_USER=nobody assert_status "$ZRO_E_BADUSER" \
  zro_logsearch_named rejected '' "$LIVE_S" "$LIVE_E"

it "refuses a match form nobody declared"
assert_status "$ZRO_E_DENIED" zro_logsearch_grep -P 'x'
assert_status "$ZRO_E_DENIED" zro_logsearch_grep '' 'x'
assert_status "$ZRO_E_DENIED" zro_logsearch_run syslog -P 'x' '' "$LIVE_S" "$LIVE_E" 'x'
assert_status "$ZRO_E_DENIED" zro_logsearch_named nosuchquestion '' "$LIVE_S" "$LIVE_E"

it "runs every scan at reduced processor and idle disk priority"
# The promise that diagnosing a loaded mail server does not deepen the load,
# asserted on the vector rather than on a comment. Both readers, including the
# decompression, which is what a rotated log really costs.
: >"$ZRO_MOCK_LOG"
zro_logsearch_named rejected '' "$WIDE_S" "$WIDE_E" >/dev/null 2>&1
unwrapped=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case $line in
    nice*|ionice*|timeout*|id*|runuser*) continue ;;
  esac
  bin=${line%%	*}
  # Every reader the scan ran must have a nice line naming it.
  grep -q "^nice.*$bin" "$ZRO_MOCK_LOG" || unwrapped="$unwrapped [$bin]"
done <<EOF
$(ran)
EOF
assert_eq "$unwrapped" ""

it "reaches no Zimbra binary and opens no mailbox"
: >"$ZRO_MOCK_LOG"
zro_logsearch_named sessions '' "$WIDE_S" "$WIDE_E" >/dev/null 2>&1
log=$(cat "$ZRO_MOCK_LOG")
assert_contains "$log" "grep"
assert_not_contains "$log" "zmprov"
assert_not_contains "$log" "zmmailbox"
assert_not_contains "$log" "zmmsgtrace"

# --- the verdict, as a pure function -----------------------------------------

it "tells a file that held nothing apart from one that could not be opened"
# The reader's own statuses, measured on the lab server: 0 matched, 1 read and
# matched nothing, 2 could not open. Getting this backwards is the whole failure
# this feature exists to prevent, so it is checked without a filesystem.
assert_out_eq "ok" zro_logsearch_scan_verdict '/var/log/zimbra.log' '0'
assert_out_eq "ok" zro_logsearch_scan_verdict '/var/log/zimbra.log' '1'
assert_out_eq "unreadable" zro_logsearch_scan_verdict '/var/log/zimbra.log' '2'
assert_out_eq "ok" zro_logsearch_scan_verdict '/var/log/zimbra.log' '0 1'
assert_out_eq "unreadable" zro_logsearch_scan_verdict '/var/log/zimbra.log' '2 1'

it "and treats a failed decompression as a file nobody read"
# Without this, the reader downstream succeeds on the empty input a failed
# decompression leaves it, and answers "nothing matched" about a file that was
# never opened.
assert_out_eq "ok" zro_logsearch_scan_verdict '/var/log/zimbra.log.1.gz' '0 0'
assert_out_eq "ok" zro_logsearch_scan_verdict '/var/log/zimbra.log.1.gz' '0 1'
assert_out_eq "unreadable" zro_logsearch_scan_verdict '/var/log/zimbra.log.1.gz' '1 1'
assert_out_eq "unreadable" zro_logsearch_scan_verdict '/var/log/zimbra.log.1.gz' '2 1'

it "and not knowing is never read as knowing nothing was there"
assert_out_eq "unreadable" zro_logsearch_scan_verdict '/var/log/zimbra.log' ''
assert_out_eq "unreadable" zro_logsearch_scan_verdict '/var/log/zimbra.log' 'x'

it "tells the gate's refusals apart from anything a reader said"
assert_out_eq "" zro_logsearch_gate_code '0 1'
assert_out_eq "" zro_logsearch_gate_code '141 0'
assert_out_eq "" zro_logsearch_gate_code '2'
assert_out_eq "$ZRO_E_DENIED" zro_logsearch_gate_code "0 $ZRO_E_DENIED"
assert_out_eq "$ZRO_E_UNAVAILABLE" zro_logsearch_gate_code "$ZRO_E_UNAVAILABLE"
assert_out_eq "$ZRO_E_TIMEOUT" zro_logsearch_gate_code "141 $ZRO_E_TIMEOUT"

rm -f -- "$ZRO_MOCK_LOG" "$ZRO_ERROR_FILE"
rm -rf -- "$TREE"
zro_t_report
