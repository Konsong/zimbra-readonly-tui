#!/usr/bin/env bash
# The mail queue: what reaches the queue tool, what its listing is read as, and
# what a refusal by the host is told apart from.
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ZIMBRA_LIBEXEC="$ZRO_TEST_ROOT/mocks/libexec"
export ZRO_SYSTEM_BIN="$ZRO_TEST_ROOT/mocks/system"
export ZRO_POSTFIX_SBIN="$ZRO_TEST_ROOT/mocks/sbin"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
export ZRO_UI_BACKEND=stub
export ZRO_SOURCED_ONLY=1
export ZRO_MOCK_ID_USER=zimbra
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* "$ZRO_TEST_ROOT"/mocks/libexec/* \
         "$ZRO_TEST_ROOT"/mocks/system/* "$ZRO_TEST_ROOT"/mocks/sbin/* 2>/dev/null || true

# shellcheck source=../zimbra-ro-tui.sh
. "$ZRO_SRC/zimbra-ro-tui.sh"

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG
FIX="$ZRO_TEST_ROOT/fixtures"

# Captured on the lab server: two deferred messages and one placed on hold, so
# one listing carries more than one status. See
# docs/research/2026-08-02-mta-queue-and-log.md.
MIXED=$(cat "$FIX/postqueue_p_deferred_hold.txt")
EMPTY=$(cat "$FIX/postqueue_p_empty.txt")

listing() { export ZRO_MOCK_POSTQUEUE__P_OUT="$1"; unset ZRO_MOCK_POSTQUEUE__P_ERR ZRO_MOCK_POSTQUEUE__P_RC; }
ran() { cat "$ZRO_MOCK_LOG"; }
reset() { : >"$ZRO_MOCK_LOG"; zro_cap_reset; }

# ------------------------------------------------- what reaches the binary --

it "the listing form is what runs, and nothing rides behind it"
# The vector is the assertion this file exists for: the flushing and requeueing
# forms of this tool live one letter from the listing one, so what matters is
# the exact argv that reached the binary.
reset
listing "$FIX/postqueue_p_deferred_hold.txt"
assert_ok zro_queue_fetch
assert_eq "$(ran | grep -c '^postqueue')" "1"
assert_eq "$(ran | grep '^postqueue')" "postqueue	-p"

it "and it runs under the wall-clock timeout every command here runs under"
assert_contains "$(ran | grep '^timeout')" "$ZRO_TEST_ROOT/mocks/sbin/postqueue"

it "and it resolves under its own declared root, never under the Zimbra bin one"
assert_out_eq "$ZRO_TEST_ROOT/mocks/sbin/postqueue" zro_bin_path postqueue

it "and a root that is not there is reported as this host lacking the tool"
# NOT as a queue that could not be read: a build without the mail transfer agent
# has no queue tool at all, and the repair is a package rather than a setting.
reset
ZRO_POSTFIX_SBIN_REAL=$ZRO_POSTFIX_SBIN
export ZRO_POSTFIX_SBIN="$ZRO_TEST_ROOT/mocks/nowhere"
assert_status "$ZRO_E_NOCAP" zro_queue_fetch
assert_eq "$(ran | grep -c '^postqueue')" "0"
export ZRO_POSTFIX_SBIN=$ZRO_POSTFIX_SBIN_REAL

# ------------------------------------------------------ reading the status --

it "the marker on the queue id is what says which queue an entry is in"
# Postfix writes the status as a character appended to the id: '*' active, '!'
# hold, and nothing at all for everything else. Read from the captured listing
# rather than from the manual page.
assert_out_eq "active"  zro_queue_status '26D3F102FBF*'
assert_out_eq "hold"    zro_queue_status '26D3F102FBF!'
assert_out_eq "waiting" zro_queue_status '26D3F102FBF'

it "and an id this reader cannot make sense of is refused rather than guessed"
assert_fail zro_queue_status ''
assert_fail zro_queue_status '26D3F102FBF?'

# ------------------------------------------------------- reading the entries --

it "every entry in the captured listing is read, and only the entries"
# The header line, the blank separators and the closing summary are not entries,
# and a reader that counted them would report a queue larger than it is.
rows=$(zro_queue_rows "$MIXED")
assert_eq "$(printf '%s\n' "$rows" | grep -c .)" "3"

it "and each one carries the status its marker declared"
assert_eq "$(printf '%s\n' "$rows" | cut -f1 | sort | tr '\n' ' ')" "hold waiting waiting "

it "and the id it was listed under, with the marker taken off"
assert_eq "$(printf '%s\n' "$rows" | cut -f2 | sort | tr '\n' ' ')" "21E9B104C1C 26D3F102FBF 29AF4104C1D "

it "and the size, the arrival time and the sender the tool listed it with"
# The arrival time arrives as its four words with the listing's column padding
# gone: the tool pads the day to two characters so its columns line up, and a
# card has no columns to line up with. The words themselves are untouched —
# there is no year on that line, so nothing here parses a date.
held=$(printf '%s\n' "$rows" | grep '^hold')
assert_eq "$(printf '%s' "$held" | cut -f3)" "316"
assert_eq "$(printf '%s' "$held" | cut -f4)" "Sun Aug 2 23:26:43"
assert_eq "$(printf '%s' "$held" | cut -f5)" "ahmet.yilmaz@example.com"

it "and the recipient, which stands on a line of its own below the sender"
assert_eq "$(printf '%s' "$held" | cut -f6)" "kuyruk-test@dc01.example.com"

it "and the reason, whichever column the tool happened to indent it to"
# THE INDENTATION IS NOT STABLE, and this is the fixture that proves it: a long
# reason wraps the field and starts at column 1, a short one is indented twelve
# spaces. A reader keyed on the indent would find one of the two and miss the
# other.
assert_contains "$(printf '%s' "$held" | cut -f7)" "Connection refused"
deferred=$(printf '%s\n' "$rows" | grep '^waiting' | head -n 1)
assert_contains "$(printf '%s' "$deferred" | cut -f7)" "Host or domain name not found"
assert_not_contains "$(printf '%s' "$deferred" | cut -f7)" "("

it "a reason line is never read as a recipient"
# Both stand below the entry line and neither is indented predictably. What tells
# them apart is that a recipient is an address and a reason is a sentence.
assert_not_contains "$(printf '%s\n' "$rows" | cut -f6)" "Host or domain"

it "an empty queue is an answer with no entries in it, not a failure"
assert_eq "$(zro_queue_rows "$EMPTY")" ""
assert_ok zro_queue_rows "$EMPTY"

# ------------------------------------------------------------ the counts --

it "the counts are per status, and they are what the entries said"
assert_out_eq "2" zro_queue_count "$(zro_queue_rows "$MIXED")" waiting
assert_out_eq "1" zro_queue_count "$(zro_queue_rows "$MIXED")" hold
assert_out_eq "0" zro_queue_count "$(zro_queue_rows "$MIXED")" active

it "and a status this tool does not declare counts nothing"
assert_fail zro_queue_count "$(zro_queue_rows "$MIXED")" flushed

# ------------------------------------------------------ the summary screen --

it "the summary answers with counts before it answers with anything else"
reset
listing "$FIX/postqueue_p_deferred_hold.txt"
out=$(zro_queue_summary_card "$MIXED")
assert_contains "$out" "Kuyruktaki kayit     : 3"
assert_contains "$out" "Bekleyen (ertelenmis): 2"
assert_contains "$out" "Tutulan (hold)       : 1"
assert_contains "$out" "Gonderilen (active)  : 0"

it "and it says what the marker it read means"
assert_contains "$out" "'!'"
assert_contains "$out" "'*'"

it "and it says that this screen only lists the queue"
# The forms that flush, requeue and delete live in the same binary. An operator
# reading a queue of thousands has to know that this tool cannot act on it.
assert_contains "$out" "LISTELER"

it "and no entry's detail is on it"
assert_not_contains "$out" "21E9B104C1C"

it "an empty queue says so, and says it as a result"
out=$(zro_queue_summary_card "$EMPTY")
assert_contains "$out" "Kuyruktaki kayit     : 0"
assert_contains "$out" "Kuyruk bos"

# ------------------------------------------------------- the bounded detail --

it "the detail screen renders each entry with everything the listing gave"
out=$(zro_queue_detail_card "$MIXED")
assert_contains "$out" "21E9B104C1C"
assert_contains "$out" "26D3F102FBF"
assert_contains "$out" "29AF4104C1D"
assert_contains "$out" "Tutulan (hold)"
assert_contains "$out" "kuyruk-test@dc01.example.com"
assert_contains "$out" "Connection refused"
assert_contains "$out" "316 B"

it "and it is bounded, and says both the bound and what was left out"
# A queue on a busy server holds thousands. The bound is the point of the screen
# behind the counts, and a bound nobody is told about is a truncation.
ZRO_QUEUE_DETAIL_MAX_REAL=$ZRO_QUEUE_DETAIL_MAX
ZRO_QUEUE_DETAIL_MAX=2
out=$(zro_queue_detail_card "$MIXED")
assert_contains "$out" "ilk 2"
assert_contains "$out" "3"
assert_eq "$(printf '%s\n' "$out" | grep -c '^Kuyruk kimligi')" "2"
ZRO_QUEUE_DETAIL_MAX=$ZRO_QUEUE_DETAIL_MAX_REAL

it "and a bound that is not a count is a defect, not a reason to pick one"
ZRO_QUEUE_DETAIL_MAX_REAL=$ZRO_QUEUE_DETAIL_MAX
ZRO_QUEUE_DETAIL_MAX=hepsi
assert_status "$ZRO_E_INPUT" zro_queue_detail_card "$MIXED"
ZRO_QUEUE_DETAIL_MAX=0
assert_status "$ZRO_E_INPUT" zro_queue_detail_card "$MIXED"
ZRO_QUEUE_DETAIL_MAX=$ZRO_QUEUE_DETAIL_MAX_REAL

it "an empty queue has no detail to bound"
assert_status "$ZRO_E_NO_RESULT" zro_queue_detail_card "$EMPTY"

# --------------------------------------------- refused by the host, not by us --

it "a queue the host refuses to show is a permission answer, never a denial"
# AN ALLOWLIST DENIAL MEANS A DEFECT IN THIS PROGRAM. This is not one: the tool
# is present, it is executable, the operation is approved, and Postfix's own
# access-control setting refused the account every command runs as. The two must
# not arrive as the same code, because they send an operator to different files.
reset
unset ZRO_MOCK_POSTQUEUE__P_OUT
export ZRO_MOCK_POSTQUEUE__P_ERR="$FIX/postqueue_p_denied.err"
export ZRO_MOCK_POSTQUEUE__P_RC=69
assert_status "$ZRO_E_PERM" zro_queue_fetch

it "and what the tool said is kept, so the screen can quote it"
zro_queue_fetch >/dev/null 2>&1
assert_contains "$(zro_last_error)" "not allowed to view the mail queue"

it "and the session remembers that this host refuses, so the menu can say so"
assert_out_eq "denied" zro_cap_queue_reason

it "the refusal is read from what the tool said, not only from its status"
# Postfix exits 69 for this and this alone, and the message names the account it
# refused. Either is enough on its own: a release that changed the status must
# not turn a refusal into an unexplained failure, and one that reworded the
# message must not either.
reset
export ZRO_MOCK_POSTQUEUE__P_RC=1
assert_status "$ZRO_E_PERM" zro_queue_fetch
reset
unset ZRO_MOCK_POSTQUEUE__P_ERR
export ZRO_MOCK_POSTQUEUE__P_RC=69
assert_status "$ZRO_E_PERM" zro_queue_fetch

it "and an ordinary failure is not read as a refusal"
reset
unset ZRO_MOCK_POSTQUEUE__P_ERR
export ZRO_MOCK_POSTQUEUE__P_RC=1
assert_status "$ZRO_E_UNAVAILABLE" zro_queue_fetch
assert_out_eq "ok" zro_cap_queue_reason

it "a queue tool that never answered is reported as the timeout it was"
# The gate's timeout is what bounds every command here. It arrives as this
# program's own code rather than as the 124 the wrapper exits with.
reset
unset ZRO_MOCK_POSTQUEUE__P_ERR
export ZRO_MOCK_POSTQUEUE__P_RC=124
assert_status "$ZRO_E_TIMEOUT" zro_queue_fetch

zro_t_report
