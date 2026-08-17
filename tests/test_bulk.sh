#!/usr/bin/env bash
set -uo pipefail
# Bulk queries: the same directory read, made about a list the operator supplied.
#
# WHAT IS ASSERTED HERE. The list is taken apart, judged and capped by pure
# functions, so those are driven directly over a table of inputs — a validator and
# a parser are exactly the internal helpers this project tests on their own. The
# engine is driven against the mock directory, where what matters is the argument
# vector each account really cost and that one address the directory does not hold
# leaves the run still going.
#
# NO FIXTURE IS INVENTED HERE. Every reply below is a capture already in the tree,
# read back through a narrower attribute list than the one it was captured with.
# That is honest because zmprov answers the same 'name: value' stream whichever
# list it is given — the bare and entry-only captures beside these show it — and
# because what these cases parse is the same text the account and mail settings
# screens already parse in production.
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/validate.sh
. "$ZRO_SRC/lib/validate.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_SYSTEM_BIN="$ZRO_TEST_ROOT/mocks/system"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
export ZRO_MOCK_ID_USER=zimbra
export ZRO_UI_BACKEND=stub
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* "$ZRO_TEST_ROOT"/mocks/system/* 2>/dev/null || true

# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"
# shellcheck source=../lib/inventory.sh
. "$ZRO_SRC/lib/inventory.sh"
# shellcheck source=../lib/window.sh
. "$ZRO_SRC/lib/window.sh"
# shellcheck source=../lib/ui.sh
. "$ZRO_SRC/lib/ui.sh"
# shellcheck source=../lib/account.sh
. "$ZRO_SRC/lib/account.sh"
# shellcheck source=../lib/mailset.sh
. "$ZRO_SRC/lib/mailset.sh"
# shellcheck source=../lib/bulk.sh
. "$ZRO_SRC/lib/bulk.sh"

ZRO_MOCK_LOG=$(mktemp);  export ZRO_MOCK_LOG
ZRO_UI_QUEUE=$(mktemp);  export ZRO_UI_QUEUE
ZRO_UI_OUT=$(mktemp);    export ZRO_UI_OUT
FIX="$ZRO_TEST_ROOT/fixtures"

TAB=$ZRO_TAB
A1='ahmet.yilmaz@example.com'
A2='sade@example.com'
A3='kilitli@example.com'

# Only the directory command's own lines: the wrappers it runs behind record
# themselves too, and what these cases are about is what zmprov was asked.
ran() { grep '^zmprov' "$ZRO_MOCK_LOG"; }
reads() { grep -c '^zmprov' "$ZRO_MOCK_LOG"; }
mocked() { cat "$ZRO_MOCK_LOG"; }
fresh() { : >"$ZRO_MOCK_LOG"; : >"$ZRO_UI_OUT"; zro_ui_reset; }

# ------------------------------------------------------------ the entries --
#
# What an operator hands over is text, and the only thing that makes it a list is
# where one address ends and the next begins.

it "a comma-separated list is one address per entry, in the order it was written"
assert_eq "$(zro_bulk_split "$A1,$A2,$A3")" "$A1
$A2
$A3"

it "and so is a file, whose entries are separated by its lines"
assert_eq "$(zro_bulk_split "$A1
$A2")" "$A1
$A2"

it "and a list written on Windows does not carry the carriage return into the address"
# The one separator that is invisible on the screen it came from. Left on the
# address it would be validated, refused, and reported as an entry the operator
# can see nothing wrong with.
assert_eq "$(zro_bulk_split "$(printf '%s\r\n%s\r\n' "$A1" "$A2")")" "$A1
$A2"

it "and a semicolon, a space and a tab separate two addresses as a comma does"
assert_eq "$(zro_bulk_split "$A1;$A2 $A3")" "$A1
$A2
$A3"
assert_eq "$(zro_bulk_split "$(printf '%s\t%s' "$A1" "$A2")")" "$A1
$A2"

it "and nothing between two separators is not an entry"
assert_eq "$(zro_bulk_split ",,$A1,,,$A2,,")" "$A1
$A2"

it "and nothing at all is no entries rather than one empty one"
assert_eq "$(zro_bulk_split '')" ""
assert_eq "$(zro_bulk_split '   ')" ""

# --------------------------------------------------------------- the plan --
#
# Every address judged before anything runs, and each entry answered for by
# position — which is the only thing that lets an operator find the one the tool
# refused in the file they wrote.

it "every valid address is accepted, in the order it was given"
plan=$(zro_bulk_plan "$A1,$A2")
assert_eq "$(zro_bulk_plan_addresses "$plan")" "$A1
$A2"
assert_out_eq "2" zro_bulk_plan_count "$plan" ok

it "an entry that is not an address is refused with its position, and the run keeps the rest"
plan=$(zro_bulk_plan "$A1,ali@@example,$A2")
assert_eq "$(zro_bulk_plan_addresses "$plan")" "$A1
$A2"
assert_out_eq "1" zro_bulk_plan_count "$plan" bad
assert_contains "$plan" "bad${TAB}2${TAB}ali@@example"

it "and its position is the entry's own, not the line it was written on"
# Three addresses on one line and the third is wrong: the operator is told which
# ENTRY was refused, because a line number would name all three at once.
plan=$(zro_bulk_plan "$A1 $A2 -yok@example.com")
assert_out_eq "1" zro_bulk_plan_count "$plan" bad
assert_contains "$plan" "bad${TAB}3${TAB}-yok@example.com"

it "and a control character in an entry is not carried onto the screen that reports it"
plan=$(zro_bulk_plan "$(printf 'a\001b@example.com')")
assert_out_eq "0" zro_bulk_plan_count "$plan" ok
assert_out_eq "1" zro_bulk_plan_count "$plan" bad
assert_not_contains "$plan" "$(printf '\001')"

it "and an entry longer than an address can be is reported without filling the screen"
long=""
while [ "${#long}" -lt 400 ]; do long="${long}aaaaaaaaaa"; done
plan=$(zro_bulk_plan "$long")
assert_out_eq "1" zro_bulk_plan_count "$plan" bad
assert_eq "$(printf '%s' "$plan" | awk 'END { print (length($0) < 120) }')" "1"

it "an address given twice is read once, and the repeat is recorded"
# A repeated address costs a JVM start and answers the same thing twice. Dropping
# it is the same discipline as the cost classes: what an operation spends has to
# be what the question costs.
plan=$(zro_bulk_plan "$A1,$A2,$A1")
assert_eq "$(zro_bulk_plan_addresses "$plan")" "$A1
$A2"
assert_out_eq "1" zro_bulk_plan_count "$plan" dup
assert_contains "$plan" "dup${TAB}3${TAB}$A1"

it "and case is not what makes two addresses different"
# The DOMAIN is left in lower case: the suite's own compatibility scan reads an
# at sign followed by a capital as a bash 4.4 parameter transformation, and what
# this case is about is the folding rather than which half is shouted.
plan=$(zro_bulk_plan "$A1,AHMET.YILMAZ@example.com")
assert_out_eq "1" zro_bulk_plan_count "$plan" ok
assert_out_eq "1" zro_bulk_plan_count "$plan" dup

it "and the address that is read is the one the operator wrote first"
assert_eq "$(zro_bulk_plan_addresses "$plan")" "$A1"

it "the list is capped, and what the cap left out is recorded rather than dropped"
ZRO_BULK_MAX_REAL=$ZRO_BULK_MAX
ZRO_BULK_MAX=2
plan=$(zro_bulk_plan "$A1,$A2,$A3")
assert_eq "$(zro_bulk_plan_addresses "$plan")" "$A1
$A2"
assert_out_eq "1" zro_bulk_plan_count "$plan" cut
assert_contains "$plan" "cut${TAB}3${TAB}$A3"

it "and a cap of nothing is a defect rather than a run of nothing"
ZRO_BULK_MAX=0
assert_status "$ZRO_E_INPUT" zro_bulk_plan "$A1"
ZRO_BULK_MAX=x
assert_status "$ZRO_E_INPUT" zro_bulk_plan "$A1"
ZRO_BULK_MAX=$ZRO_BULK_MAX_REAL

it "a list of nothing but refusals accepts nothing, and says so rather than failing"
plan=$(zro_bulk_plan "ali@@example,-yok")
assert_eq "$(zro_bulk_plan_addresses "$plan")" ""
assert_out_eq "2" zro_bulk_plan_count "$plan" bad

it "what will not be read is rendered with its position and why"
plan=$(zro_bulk_plan "$A1,ali@@example,$A1")
out=$(zro_bulk_plan_rejects "$plan")
assert_contains "$out" "2."
assert_contains "$out" "ali@@example"
assert_contains "$out" "gecersiz"
assert_contains "$out" "3."
assert_contains "$out" "tekrar"

it "and the rejected entries are bounded, with the number not shown said out loud"
many=""
i=0
while [ "$i" -lt 40 ]; do i=$((i + 1)); many="$many,bad$i@@x"; done
plan=$(zro_bulk_plan "$many")
out=$(zro_bulk_plan_rejects "$plan")
assert_eq "$(printf '%s\n' "$out" | grep -c 'gecersiz')" "$ZRO_BULK_REJECT_SHOW"
assert_contains "$out" "$((40 - ZRO_BULK_REJECT_SHOW)) girdi daha"

# ------------------------------------------------------------- the file --
#
# The one path in this program an operator types. Judged before it is opened,
# because everything else this tool reads is a path the tool itself chose.

LIST=$(mktemp)
printf '%s\n%s\n' "$A1" "$A2" >"$LIST"

it "a readable file of addresses is admitted and read"
assert_out_eq "ok" zro_bulk_file_verdict "$LIST"
assert_eq "$(zro_bulk_read_file "$LIST")" "$A1
$A2"

it "a path that is not absolute is refused before anything is opened"
# A relative path means whatever directory the tool happens to have been started
# in, which is not something an operator can check from the screen they typed it
# on.
assert_out_eq "shape" zro_bulk_file_verdict "liste.txt"
assert_out_eq "shape" zro_bulk_file_verdict ""

it "and so is one that reaches out of itself or carries what a path may not"
assert_out_eq "shape" zro_bulk_file_verdict "/tmp/../etc/shadow"
assert_out_eq "shape" zro_bulk_file_verdict "/tmp/liste\$(id).txt"
assert_out_eq "shape" zro_bulk_file_verdict "/tmp/li ste.txt"
assert_out_eq "shape" zro_bulk_file_verdict "$(printf '/tmp/li\001ste.txt')"

it "and one this host does not have is told apart from one it will not open"
assert_out_eq "missing" zro_bulk_file_verdict "/tmp/zro-no-such-list-file"
assert_out_eq "notfile" zro_bulk_file_verdict "/tmp"

it "an empty file is an answer about the file, not a refusal of the path"
EMPTY=$(mktemp); : >"$EMPTY"
assert_out_eq "empty" zro_bulk_file_verdict "$EMPTY"

it "and a file too large to be a list of addresses is refused with a bound"
BIG=$(mktemp)
ZRO_BULK_FILE_BYTES_REAL=$ZRO_BULK_FILE_BYTES
ZRO_BULK_FILE_BYTES=16
printf '%s\n%s\n' "$A1" "$A2" >"$BIG"
assert_out_eq "toobig" zro_bulk_file_verdict "$BIG"
ZRO_BULK_FILE_BYTES=$ZRO_BULK_FILE_BYTES_REAL

it "a file that is not admitted is not read either"
assert_status "$ZRO_E_INPUT" zro_bulk_read_file "liste.txt"
assert_status "$ZRO_E_INPUT" zro_bulk_read_file "/tmp/zro-no-such-list-file"

it "and a file this account cannot open is refused rather than reported empty"
NOREAD=$(mktemp)
printf '%s\n' "$A1" >"$NOREAD"
chmod 000 "$NOREAD" 2>/dev/null || true
if [ -r "$NOREAD" ]; then
  # Running where file modes do not apply to this account — as root, or on a
  # mount that ignores them. The verdict would be 'ok' and it would be right:
  # this account really can open the file. There is nothing to assert.
  printf '  (skipped: this account can read a mode-000 file)\n' >&2
else
  assert_out_eq "unreadable" zro_bulk_file_verdict "$NOREAD"
fi
chmod 644 "$NOREAD" 2>/dev/null || true

# ------------------------------------------------------------ the estimate --

it "before anything has been read the estimate is what this tool declares an account costs"
assert_out_eq "$((3 * ZRO_BULK_SECONDS))" zro_bulk_eta 0 3 0

it "and afterwards it is what this run has actually been spending"
# Two accounts in ten seconds, eight to go: forty seconds, from the run rather
# than from the declaration.
assert_out_eq "40" zro_bulk_eta 2 10 10

it "and a part of a second still to spend is a second, never nothing"
assert_out_eq "2" zro_bulk_eta 2 3 3

it "and a run with nothing left has nothing left to estimate"
assert_out_eq "0" zro_bulk_eta 3 3 30

it "a number of seconds is read as an operator reads a clock"
assert_out_eq "45 sn" zro_bulk_duration 45
assert_out_eq "2 dk 30 sn" zro_bulk_duration 150
assert_out_eq "1 sa 5 dk" zro_bulk_duration 3900
assert_out_eq "0 sn" zro_bulk_duration 0

it "and something that is not a number of seconds is refused rather than rendered"
assert_status "$ZRO_E_INPUT" zro_bulk_duration "x"
assert_status "$ZRO_E_INPUT" zro_bulk_eta 1 x 1

# ------------------------------------------------------------ the questions --

it "the two questions are declared, each with what the report calls it"
assert_eq "$(zro_bulk_question_ids)" "status
mail"
assert_out_eq "Hesap durumu" zro_bulk_question_label status
assert_out_eq "Filtre ve yonlendirme" zro_bulk_question_label mail
assert_fail zro_bulk_question_label sweep

# --------------------------------------------------------------- the rows --
#
# Pure: what an account turned out to hold, rendered. Held apart from the read
# above them so that what an operator sees can be asserted without a directory.

STATUS_RAW='# name ahmet.yilmaz@example.com
zimbraAccountStatus: closed'

it "a status row carries the address and what the directory said about it"
out=$(zro_bulk_row status "$A1" 0 "$STATUS_RAW")
assert_contains "$out" "$A1"
assert_contains "$out" "closed"

it "and an account whose status nobody set is not reported as active"
out=$(zro_bulk_row status "$A1" 0 '# name ahmet.yilmaz@example.com')
assert_contains "$out" "$ZRO_TXT_UNSET"
assert_not_contains "$out" "active"

it "an address the directory does not hold is an answer on its own row"
out=$(zro_bulk_row status "$A1" "$ZRO_E_NO_ACCOUNT" '')
assert_contains "$out" "$A1"
assert_contains "$out" "HESAP YOK"

it "and a read that could not run says so, and never as a status"
out=$(zro_bulk_row status "$A1" "$ZRO_E_UNAVAILABLE" '')
assert_contains "$out" "OKUNAMADI"
assert_contains "$out" "$ZRO_E_UNAVAILABLE"

MAIL_RAW=$(cat "$FIX/zmprov_ga_mailset_full.txt")

it "a mail row names both kinds of forwarding separately"
out=$(zro_bulk_row mail "$A1" 0 "$MAIL_RAW")
assert_contains "$out" "denetim@example.net"
assert_contains "$out" "kisisel-yedek@example.net"
assert_contains "$out" "Yonetici"
assert_contains "$out" "Kullanici"

it "and says when local delivery is off, which is what empties a mailbox quietly"
assert_contains "$(zro_bulk_row mail "$A1" 0 "$MAIL_RAW")" "kapali"

it "and counts a rule set rather than printing it into a list of two hundred accounts"
out=$(zro_bulk_row mail "$A1" 0 "$MAIL_RAW")
assert_contains "$out" "17 satir"
assert_contains "$out" "8 satir"
assert_not_contains "$out" "fileinto"

it "an account with none of it is one line saying so, not four saying nothing"
out=$(zro_bulk_row mail "$A2" 0 '# name sade@example.com')
assert_contains "$out" "$A2"
assert_eq "$(printf '%s\n' "$out" | grep -c .)" "2"
assert_not_contains "$out" "Yonetici"

it "and a mail row for an address the directory does not hold says the same thing a status row does"
out=$(zro_bulk_row mail "$A1" "$ZRO_E_NO_ACCOUNT" '')
assert_contains "$out" "HESAP YOK"

it "a question this tool does not ask renders nothing and refuses"
assert_status "$ZRO_E_INPUT" zro_bulk_row sweep "$A1" 0 ''

# ------------------------------------------------------------- the tally --

it "what a row is counted as in the summary is the word the answer used"
assert_out_eq "closed" zro_bulk_tally status 0 "$STATUS_RAW"
assert_out_eq "hesap yok" zro_bulk_tally status "$ZRO_E_NO_ACCOUNT" ''
assert_out_eq "okunamadi" zro_bulk_tally status "$ZRO_E_TIMEOUT" ''

it "and an account can be counted in more than one of a mail run's columns"
out=$(zro_bulk_tally mail 0 "$MAIL_RAW")
assert_contains "$out" "yonlendirmesi olan"
assert_contains "$out" "yonetici tanimli yonlendirmesi olan"
assert_contains "$out" "filtresi olan"
assert_contains "$out" "yerel teslimi kapali"

it "and an account with nothing set is counted in none of them"
assert_out_eq "" zro_bulk_tally mail 0 '# name sade@example.com'

it "the summary counts what the tally said, and is the same list twice over"
out=$(zro_bulk_summary "active
active
closed")
assert_contains "$out" "active"
assert_contains "$out" "2"
assert_contains "$out" "closed"

# ---------------------------------------------------------------- the read --
#
# The one part of a bulk query that runs anything. One directory read per address
# and no mailbox at any point.

it "the status read asks for one account and the one attribute the row shows"
fresh
export ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt"
out=$(zro_bulk_read status "$A1")
assert_contains "$out" "zimbraAccountStatus: active"
assert_eq "$(ran)" "zmprov${TAB}ga${TAB}$A1${TAB}zimbraAccountStatus"
assert_eq "$(reads)" "1"

it "the mail read asks for one account and the attributes that decide its mail"
fresh
export ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_mailset_full.txt"
zro_bulk_read mail "$A1" >/dev/null
assert_contains "$(ran)" "zimbraMailForwardingAddress"
assert_contains "$(ran)" "zimbraPrefMailLocalDeliveryDisabled"
assert_eq "$(reads)" "1"

it "and every attribute it asks for is one the reader of a rule set knows"
# A rule set is a multi-line value, and what tells its continuation lines from the
# line that ends it is the set of attribute names the reader was given. An
# attribute asked for here and absent from that set would cut a filter off at its
# first line.
missing=""
for a in "${ZRO_BULK_MAIL_ATTRS[@]}"; do
  case " ${ZRO_MAILSET_ATTRS[*]} " in
    *" $a "*) ;;
    *) missing="$missing [$a]" ;;
  esac
done
assert_eq "$missing" ""

it "an address that is not one is refused before anything runs"
fresh
assert_status "$ZRO_E_INPUT" zro_bulk_read status "not-an-address"
assert_eq "$(reads)" "0"

it "and a question this tool does not ask reaches no directory at all"
fresh
assert_status "$ZRO_E_INPUT" zro_bulk_read sweep "$A1"
assert_eq "$(reads)" "0"

# ----------------------------------------------------------------- the run --

# Three addresses, each answering for itself. The mock is keyed on the account as
# well as the subcommand precisely so that a run of three can be told from one
# account read three times.
staged_three() {
  export ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt"
  export ZRO_MOCK_ZMPROV_GA_SADE_EXAMPLE_COM_OUT="$FIX/zmprov_ga_bare.txt"
  export ZRO_MOCK_ZMPROV_GA_KILITLI_EXAMPLE_COM_OUT="$FIX/zmprov_ga_locked.txt"
  unset ZRO_MOCK_ZMPROV_GA_ERR ZRO_MOCK_ZMPROV_GA_RC
}

it "one directory read per address on the list, in the order the operator wrote them"
fresh
staged_three
plan=$(zro_bulk_plan "$A1,$A2,$A3")
out=$(zro_bulk_run status "yazilan liste" "$plan")
assert_eq "$(reads)" "3"
assert_eq "$(ran | awk -F'\t' '{ print $3 }')" "$A1
$A2
$A3"

it "and the answer carries a row per address, with what each one said"
assert_contains "$out" "$A1"
assert_contains "$out" "active"
assert_contains "$out" "$A3"
assert_contains "$out" "locked"

it "and it says what was asked and where the list came from"
assert_contains "$out" "Hesap durumu"
assert_contains "$out" "yazilan liste"

it "and the summary counts the run rather than repeating it"
assert_contains "$out" "Ozet"
assert_contains "$out" "locked"

it "and no mailbox is opened, and the oracle that guards one is never asked"
assert_eq "$(mocked | grep -c '^zmmailbox')" "0"
assert_eq "$(mocked | grep -c "$(printf '^zmprov\tgis')")" "0"

it "an address the directory does not hold is a row, and the run carries on past it"
fresh
staged_three
export ZRO_MOCK_ZMPROV_GA_YOK_EXAMPLE_COM_ERR="$FIX/zmprov_ga_no_such_account.err"
export ZRO_MOCK_ZMPROV_GA_YOK_EXAMPLE_COM_RC=2
plan=$(zro_bulk_plan "$A1,yok@example.com,$A3")
rc=0
out=$(zro_bulk_run status "yazilan liste" "$plan") || rc=$?
assert_eq "$(reads)" "3"
assert_contains "$out" "HESAP YOK"
assert_contains "$out" "locked"

it "and a missing account is an answer, so the run is not reported as incomplete"
assert_eq "$rc" "0"

it "a read that could not run leaves the answer incomplete, and says so"
# A refusal rather than an unreachable mailbox service, because the second is
# retried against LDAP and would answer — which is the degraded read working, not
# a read that failed.
fresh
staged_three
export ZRO_MOCK_ZMPROV_GA_KILITLI_EXAMPLE_COM_ERR="$FIX/zmprov_auth_failed.err"
export ZRO_MOCK_ZMPROV_GA_KILITLI_EXAMPLE_COM_RC=2
unset ZRO_MOCK_ZMPROV_GA_KILITLI_EXAMPLE_COM_OUT
plan=$(zro_bulk_plan "$A1,$A3")
rc=0
out=$(zro_bulk_run status "yazilan liste" "$plan") || rc=$?
assert_eq "$rc" "$ZRO_E_PARTIAL"
assert_contains "$out" "EKSIK"
assert_contains "$out" "OKUNAMADI"
assert_contains "$out" "active"
unset ZRO_MOCK_ZMPROV_GA_KILITLI_EXAMPLE_COM_ERR ZRO_MOCK_ZMPROV_GA_KILITLI_EXAMPLE_COM_RC

it "the operator is shown where the run has got to, and what is left of the wait"
fresh
staged_three
plan=$(zro_bulk_plan "$A1,$A2,$A3")
zro_bulk_run status "yazilan liste" "$plan" >/dev/null
progress=$(cat "$ZRO_UI_OUT")
assert_contains "$progress" "1 / 3"
assert_contains "$progress" "3 / 3"
assert_contains "$progress" "Tahmini kalan sure"
assert_contains "$progress" "ESC"

it "ESC stops the run where it had got to, and every address after it is left unread"
fresh
staged_three
export ZRO_UI_STOP_AFTER=2
plan=$(zro_bulk_plan "$A1,$A2,$A3")
rc=0
out=$(zro_bulk_run status "yazilan liste" "$plan") || rc=$?
unset ZRO_UI_STOP_AFTER
assert_eq "$(reads)" "1"

it "and what it found until then is kept, and marked as the part of an answer it is"
assert_eq "$rc" "$ZRO_E_PARTIAL"
assert_contains "$out" "$A1"
assert_contains "$out" "active"
assert_contains "$out" "DURDURULDU"
assert_not_contains "$out" "$A3"

it "and the two addresses it never read are counted rather than left out"
assert_contains "$out" "kalan 2"

it "a plan with no address to read is refused rather than run as an empty report"
fresh
plan=$(zro_bulk_plan "ali@@example")
assert_status "$ZRO_E_INPUT" zro_bulk_run status "yazilan liste" "$plan"
assert_eq "$(reads)" "0"

it "and a question this tool does not ask runs nothing"
fresh
plan=$(zro_bulk_plan "$A1")
assert_status "$ZRO_E_INPUT" zro_bulk_run sweep "yazilan liste" "$plan"
assert_eq "$(reads)" "0"

it "the report says what was refused before the run as well as what the run found"
fresh
staged_three
plan=$(zro_bulk_plan "$A1,ali@@example,$A1")
out=$(zro_bulk_run status "yazilan liste" "$plan")
assert_contains "$out" "ali@@example"
assert_contains "$out" "gecersiz"
assert_contains "$out" "tekrar"
assert_eq "$(reads)" "1"

it "and the cap it was capped by, whenever it did any capping"
fresh
staged_three
ZRO_BULK_MAX_REAL=$ZRO_BULK_MAX
ZRO_BULK_MAX=1
plan=$(zro_bulk_plan "$A1,$A2")
out=$(zro_bulk_run status "yazilan liste" "$plan")
ZRO_BULK_MAX=$ZRO_BULK_MAX_REAL
assert_contains "$out" "en fazla 1"
assert_eq "$(reads)" "1"

rm -f -- "$ZRO_MOCK_LOG" "$ZRO_UI_QUEUE" "$ZRO_UI_OUT" "$LIST" "$EMPTY" "$BIG" "$NOREAD"
zro_t_report
