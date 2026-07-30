#!/usr/bin/env bash
# The delivery trace screens, driven through the stub UI backend.
#
# The tracing fixtures are SYNTHETIC; see the header of tests/test_delivery.sh
# for why, and for what may not be asserted about them.
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ZIMBRA_LIBEXEC="$ZRO_TEST_ROOT/mocks/libexec"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
export ZRO_UI_BACKEND=stub
export ZRO_SOURCED_ONLY=1
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* "$ZRO_TEST_ROOT"/mocks/libexec/* 2>/dev/null || true

# Local wall clock is this tool's only time model, and these cases read the real
# clock rather than a fixed moment. The ZONE is pinned all the same, as it is in
# every other clock-dependent file here: a zone that observes daylight saving makes
# one local hour a year ambiguous, and a case that reads a timestamp back would
# fail in it once a year. Nothing is lost — the tool documents that it does no
# daylight-saving arithmetic, so there is no behaviour in that hour to assert.
export TZ=UTC

# The log tree the presets select from. Its timestamps are RELATIVE TO THE REAL
# CLOCK, unlike the fixed tree the pure cases use: these screens ask the clock
# what "the last hour" and "yesterday" mean, so the files have to sit where those
# answers land — at any hour of any day the suite is run.
NOW=$(date '+%s')
TODAY=$(date -d 'today 00:00:00' '+%s')
# 03:20, which is when cron.daily fires rotation. A file rotated then holds the
# lines of the day before it, which is the whole reason a window is compared
# against a coverage interval rather than against a date in a name.
R1=$((TODAY - 86400 + 12000))   # rotated yesterday at 03:20
R2=$((TODAY - 172800 + 12000))  # and the morning before that

TREE=$(mktemp -d)
mkdir -p "$TREE/var/log"
export ZRO_SYSLOG_FILE="$TREE/var/log/zimbra.log"
export ZRO_LOG_DIR="$TREE/zimbra/log"

SYS="$TREE/var/log/zimbra.log"
mk() {
  printf 'placeholder\n' >"$1"
  touch -d "@$2" -- "$1"
  # The MODE is set explicitly, not left to the umask of whoever runs the suite.
  # The readability probe reads it, and under a restrictive umask every case in
  # this file would otherwise find the trace unavailable — for a reason that is
  # about the machine running the tests rather than about the tool.
  chmod 644 -- "$1"
}
mk "$SYS"      "$((NOW - 300))"
mk "$SYS.1.gz" "$R1"
mk "$SYS.2.gz" "$R2"

# shellcheck source=../zimbra-ro-tui.sh
. "$ZRO_SRC/zimbra-ro-tui.sh"

it "this fixture host can trace, which every case below assumes"
# Asked HERE, before the mock log exists, and remembered for the rest of the file.
# The probes are asked once per session by design, and several cases below assert
# that NOTHING ran: a probe firing inside one of them would put an identity lookup
# in the very log they are reading. The cases that need a different answer force
# one rather than clearing this.
zro_cap_reset
assert_ok zro_cap_trace_available

ZRO_MOCK_LOG=$(mktemp);  export ZRO_MOCK_LOG
ZRO_UI_QUEUE=$(mktemp);  export ZRO_UI_QUEUE
ZRO_UI_OUT=$(mktemp);    export ZRO_UI_OUT
FIX="$ZRO_TEST_ROOT/fixtures"
ONE="$FIX/zmmsgtrace_synthetic_one_message.txt"
NONE="$FIX/zmmsgtrace_synthetic_no_match.txt"
export ZRO_MOCK_ZMCONTROL__V_OUT="$FIX/zmcontrol_v.txt"
export ZRO_MOCK_ID_USER=zimbra

queue() { printf '%s\n' "$@" >"$ZRO_UI_QUEUE"; zro_ui_reset; }

# The common path: trace by recipient, over the last hour.
HOUR=("1" "ahmet.yilmaz@example.com" "hour" "__CANCEL__" "__CANCEL__")

it "the delivery trace is reachable from the main menu"
queue "2" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
zro_menu_main
assert_contains "$(cat "$ZRO_UI_OUT")" "Teslim takibi"

it "a valid recipient and a preset window reach the report"
queue "${HOUR[@]}"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "ahmet.yilmaz@example.com"
assert_contains "$transcript" "$(cat "$ONE")"

it "the window screen names arrival, not delivery"
# A window compared against arrival time is not a window compared against
# delivery time. An operator who reads it as the latter concludes that a message
# which arrived at 23:59 and was delivered at 00:02 never arrived.
queue "${HOUR[@]}"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "MENU Varis araligi"
assert_contains "$transcript" "varis zamanina gore"
assert_not_contains "$transcript" "teslim zamanina gore"

# The window the tracer was actually given, back as two absolute timestamps. The
# stamp is the tracer's own format, so reading it here is how a case can ask what
# the operator's choice turned into rather than trusting the menu's labels.
bounds() {
  local stamp=$1
  printf '%s' "$("$ZRO_DATE_BIN" -d \
    "${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:8:2}:${stamp:10:2}:${stamp:12:2}" '+%s')"
}
searched() {
  local field
  field=$(grep '^zmmsgtrace' "$ZRO_MOCK_LOG" | head -n 1 | cut -f5)
  printf '%s %s' "$(bounds "${field%,*}")" "$(bounds "${field#*,}")"
}
run_preset() {
  queue "1" "ahmet.yilmaz@example.com" "$1" "__CANCEL__" "__CANCEL__"
  : >"$ZRO_MOCK_LOG"
  ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery
}

it "each rolling preset searches the span its label names"
# The menu's entries are checked by what they SEARCH, not by their text: an entry
# wired to the wrong preset would show the right label and answer another
# question, which is the one failure a label cannot reveal.
for pair in "hour 3600" "day 86400" "week 604800"; do
  run_preset "${pair%% *}"
  w=$(searched)
  assert_eq "$(( ${w##* } - ${w%% *} ))" "${pair##* }"
done

it "the yesterday entry searches the calendar day, midnight to its last second"
run_preset yesterday
today=$("$ZRO_DATE_BIN" -d 'today 00:00:00' '+%s')
w=$(searched)
assert_eq "${w%% *}" "$((today - 86400))"
assert_eq "${w##* }" "$((today - 1))"

it "the report says which window and which files the answer came from"
queue "${HOUR[@]}"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "Varis araligi"
assert_contains "$transcript" "Taranan log"
assert_contains "$transcript" "$SYS"

it "the last hour reads the file still being written and no rotated one"
queue "${HOUR[@]}"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery
traced=$(grep '^zmmsgtrace' "$ZRO_MOCK_LOG")
assert_eq "$(printf '%s\n' "$traced" | wc -l | tr -d ' ')" "1"
assert_contains "$traced" "$(printf '\t%s' "$SYS")"
assert_not_contains "$traced" "$SYS.1.gz"

it "yesterday reaches a rotated file, whatever hour it is asked at"
# Rotation runs in the early morning, so yesterday's lines are split between the
# file rotated yesterday morning and the one rotated this morning. The window has
# to reach the rotated file at every hour of the day, or an operator asking about
# yesterday is answered from today's log alone.
queue "1" "ahmet.yilmaz@example.com" "yesterday" "__CANCEL__" "__CANCEL__"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery
assert_contains "$(grep '^zmmsgtrace' "$ZRO_MOCK_LOG")" "$SYS.1.gz"

it "a wide window is one invocation per file, each with a year and a file of its own"
# Three files, three invocations, three distinct paths, each carrying a four-digit
# year. That the year is DERIVED FROM EACH FILE rather than guessed once cannot be
# shown here — every file in this tree falls in the same year, because no preset
# reaches back further than seven days. tests/test_delivery.sh proves it against a
# tree that straddles a new year, which is the only place it can be proved.
queue "1" "ahmet.yilmaz@example.com" "week" "__CANCEL__" "__CANCEL__"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery
traced=$(grep '^zmmsgtrace' "$ZRO_MOCK_LOG")
assert_eq "$(printf '%s\n' "$traced" | wc -l | tr -d ' ')" "3"
assert_eq "$(printf '%s\n' "$traced" | cut -f8 | sort -u | wc -l | tr -d ' ')" "3"
malformed=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case $(printf '%s' "$line" | cut -f7) in
    [0-9][0-9][0-9][0-9]) ;;
    *) malformed="$malformed [$line]" ;;
  esac
done <<EOF
$traced
EOF
assert_eq "$malformed" ""

it "the total is shown as the sum over the files it came from"
# The tracer re-initialises per file, so a message whose hops straddle a rotation
# is introduced once in each file and counted twice. Telling those apart would mean
# parsing the report further, against output nobody has captured — so the count is
# presented as what it is: per file, and summed.
queue "1" "ahmet.yilmaz@example.com" "week" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "Bulunan ileti  : 3"
assert_contains "$transcript" "3 dosya"
assert_contains "$transcript" "toplam, dosya basina bulunanlarin toplamidir"

it "and carries no such caveat when one file answered the question"
queue "${HOUR[@]}"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery
assert_not_contains "$(cat "$ZRO_UI_OUT")" "toplam, dosya basina"

it "an explicit range is accepted and reaches the tracer as the window it names"
queue "1" "ahmet.yilmaz@example.com" "explicit" "2026-07-28 08:00" "2026-07-28 09:30" \
      "__CANCEL__" "__CANCEL__"
: >"$ZRO_MOCK_LOG"; : >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery
assert_contains "$(cat "$ZRO_MOCK_LOG")" \
  "$(printf '\t--time\t20260728080000,20260728093000\t')"

it "a malformed explicit range is refused and nothing is run"
queue "1" "ahmet.yilmaz@example.com" "explicit" "dun" "bugun" "__CANCEL__" "__CANCEL__"
: >"$ZRO_MOCK_LOG"; : >"$ZRO_UI_OUT"
zro_menu_delivery
assert_contains "$(cat "$ZRO_UI_OUT")" "Gecersiz"
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "an explicit range that ends before it starts is refused, not swapped"
queue "1" "ahmet.yilmaz@example.com" "explicit" "2026-07-28 09:00" "2026-07-28 08:00" \
      "__CANCEL__" "__CANCEL__"
: >"$ZRO_MOCK_LOG"; : >"$ZRO_UI_OUT"
zro_menu_delivery
assert_contains "$(cat "$ZRO_UI_OUT")" "Gecersiz"
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "tells the operator the search is running before the wait begins"
queue "${HOUR[@]}"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery
assert_contains "$(cat "$ZRO_UI_OUT")" "bekleyin"
notice_line=$(grep -n "bekleyin" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
result_line=$(grep -n "Bulunan ileti" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
assert_eq "$([ "$notice_line" -lt "$result_line" ] && printf yes || printf no)" "yes"

it "the wait screen names the window being searched"
queue "${HOUR[@]}"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery
notice=$(grep -A 4 "NOTICE Calisiyor" "$ZRO_UI_OUT")
assert_contains "$notice" "Varis araligi"

it "nothing found says so, and says it is not proof nothing arrived"
queue "${HOUR[@]}"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$NONE" zro_menu_delivery
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "bulunamadi"
# The operator has to learn what the empty answer is an answer about, or it reads
# as a verdict it has not earned.
assert_contains "$transcript" "varis zamanina gore"
assert_contains "$transcript" "kanitlamaz"

it "an invalid address is reported and nothing is run"
queue "1" 'ahmet@example.com; id' "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
zro_menu_delivery
assert_contains "$(cat "$ZRO_UI_OUT")" "Gecersiz"
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

# ------------------------------------------------- the other two filters --
#
# Two more ways into the same trace. Sender answers whether a user's outbound
# message actually left; message-id answers the precise question an operator has
# while holding a bounce report, where an address alone is too broad.

it "the trace menu offers three ways in, each reaching a filter of its own"
# The stub backend records a menu's title and text, not its entries, so what an
# entry SAYS cannot be asserted here — what it DOES can, and an entry wired to
# the wrong filter is the failure a label could not have revealed anyway.
#
# One value serves all three: it is a valid address and a valid identifier.
seen=""
for entry in 1 2 3; do
  queue "$entry" "CAabc123@example.com" "hour" "__CANCEL__" "__CANCEL__"
  : >"$ZRO_MOCK_LOG"
  ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" \
  ZRO_MOCK_ZMMSGTRACE___SENDER_OUT="$ONE" \
  ZRO_MOCK_ZMMSGTRACE___ID_OUT="$ONE" \
    zro_menu_delivery
  seen="$seen $(grep '^zmmsgtrace' "$ZRO_MOCK_LOG" | head -n 1 | cut -f2)"
done
assert_eq "$seen" " --recipient --sender --id"

it "a menu entry this screen does not have runs nothing"
queue "9" "__CANCEL__"
: >"$ZRO_MOCK_LOG"
assert_ok zro_menu_delivery
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "a sender search reaches the tracer as the sender filter"
queue "2" "ahmet.yilmaz@example.com" "hour" "__CANCEL__" "__CANCEL__"
: >"$ZRO_MOCK_LOG"; : >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___SENDER_OUT="$ONE" zro_menu_delivery
traced=$(grep '^zmmsgtrace' "$ZRO_MOCK_LOG")
assert_contains "$traced" "$(printf 'zmmsgtrace\t--sender\tahmet\\.yilmaz@example\\.com\t')"
assert_not_contains "$traced" "--recipient"
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "Gonderen       : ahmet.yilmaz@example.com"
assert_contains "$transcript" "$(cat "$ONE")"

it "and the wait screen names the sender it is searching for"
notice=$(grep -A 4 "NOTICE Calisiyor" "$ZRO_UI_OUT")
assert_contains "$notice" "Gonderen: ahmet.yilmaz@example.com"

it "a message-id search reaches the tracer as the id filter"
queue "3" "CAabc123@example.com" "hour" "__CANCEL__" "__CANCEL__"
: >"$ZRO_MOCK_LOG"; : >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___ID_OUT="$ONE" zro_menu_delivery
traced=$(grep '^zmmsgtrace' "$ZRO_MOCK_LOG")
assert_contains "$traced" "$(printf 'zmmsgtrace\t--id\tCAabc123@example\\.com\t')"
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "Ileti kimligi  : CAabc123@example.com"
assert_contains "$transcript" "$(cat "$ONE")"

it "the message-id screen says the match is case-sensitive"
# THE POINT OF SAYING IT. The tracer matches this filter case-sensitively and
# the other two case-insensitively. An operator who retypes an identifier in the
# wrong case gets an empty result, and an empty result on this screen reads as
# proof the message never arrived.
assert_contains "$transcript" "INPUT Ileti kimligi"
assert_contains "$transcript" "BUYUK/kucuk harf"

it "an empty message-id answer repeats what an empty answer here can hide"
queue "3" "CAabc123@example.com" "hour" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___ID_OUT="$NONE" zro_menu_delivery
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "bulunamadi"
assert_contains "$transcript" "kanitlamaz"
# Said again where it matters most: this is the screen an operator reaches after
# typing an identifier by hand.
assert_contains "$transcript" "BUYUK/kucuk harf"

it "and the recipient screen carries no such note, having nothing to warn about"
queue "${HOUR[@]}"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$NONE" zro_menu_delivery
assert_not_contains "$(cat "$ZRO_UI_OUT")" "BUYUK/kucuk harf"

it "the identifier is searched for as a header carries it, brackets and all"
# The header line reads 'Message-ID: <CAabc123@example.com>' and that is what an
# operator pastes. The tracer stores the identifier without its delimiters, so
# they come off before the search rather than turning it into one that matches
# nothing.
queue "3" "<CAabc123@example.com>" "hour" "__CANCEL__" "__CANCEL__"
: >"$ZRO_MOCK_LOG"; : >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___ID_OUT="$ONE" zro_menu_delivery
assert_contains "$(grep '^zmmsgtrace' "$ZRO_MOCK_LOG")" \
  "$(printf '\t--id\tCAabc123@example\\.com\t')"
assert_contains "$(cat "$ZRO_UI_OUT")" "Ileti kimligi  : CAabc123@example.com"

it "an invalid sender is reported and nothing is run"
queue "2" 'ahmet@example.com; id' "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
zro_menu_delivery
assert_contains "$(cat "$ZRO_UI_OUT")" "Gecersiz"
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "an invalid message-id is reported and nothing is run"
# The whole header line, which is the paste that would otherwise match nothing.
queue "3" 'Message-ID: <CAabc123@example.com>' "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
zro_menu_delivery
assert_contains "$(cat "$ZRO_UI_OUT")" "Gecersiz"
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "cancelling either new prompt returns to the trace menu, not out of it"
for entry in 2 3; do
  queue "$entry" "__CANCEL__" "__CANCEL__"
  : >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
  assert_ok zro_menu_delivery
  assert_eq "$(grep -c 'MENU Teslim takibi' "$ZRO_UI_OUT")" "2"
  assert_eq "$(cat "$ZRO_MOCK_LOG")" ""
done

it "a partial scan is disclosed on every filter, not only the first one written"
queue "2" "ahmet.yilmaz@example.com" "week" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___SENDER_OUT="$ONE" \
ZRO_MOCK_ZMMSGTRACE_UNREADABLE="$SYS.1.gz" \
  zro_menu_delivery
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "TEXT Teslim izi - EKSIK TARAMA"
assert_contains "$transcript" "KANITLAMAZ"

it "cancelling the trace menu returns to the caller"
queue "__CANCEL__"
assert_ok zro_menu_delivery

it "cancelling the address prompt returns to the trace menu, not out of it"
queue "1" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
assert_ok zro_menu_delivery
# Drawn once before the prompt and once after it: the operator is back where
# they were, not one screen further out.
assert_eq "$(grep -c 'MENU Teslim takibi' "$ZRO_UI_OUT")" "2"

it "cancelling the window menu returns to the trace menu, not out of it"
queue "1" "ahmet.yilmaz@example.com" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
assert_ok zro_menu_delivery
assert_eq "$(grep -c 'MENU Teslim takibi' "$ZRO_UI_OUT")" "2"
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "cancelling either end of an explicit range returns to the trace menu"
queue "1" "ahmet.yilmaz@example.com" "explicit" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
assert_ok zro_menu_delivery
assert_eq "$(grep -c 'MENU Teslim takibi' "$ZRO_UI_OUT")" "2"
queue "1" "ahmet.yilmaz@example.com" "explicit" "2026-07-28 08:00" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
assert_ok zro_menu_delivery
assert_eq "$(grep -c 'MENU Teslim takibi' "$ZRO_UI_OUT")" "2"
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "a log that cannot be read names the cause and the repair, not a bare code"
queue "${HOUR[@]}"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_RC=13 \
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_ERR="$FIX/zmmsgtrace_synthetic_unreadable.err" \
  zro_menu_delivery
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "okunamadi"
# The usual cause is ownership on the syslog file, and it breaks Zimbra's own
# tooling too, so the screen names the tool that repairs it.
assert_contains "$transcript" "zmfixperms"
# And it must not be readable as an empty result, which is a different answer.
assert_contains "$transcript" "DEGILDIR"

it "one unreadable file among several is answered, with the gap disclosed"
# Three files, one of them unreadable: the operator gets what could be found AND an
# account of what was missed. Refusing outright would throw away a usable answer;
# showing it silently would let an empty one read as proof the message never came.
queue "1" "ahmet.yilmaz@example.com" "week" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" \
ZRO_MOCK_ZMMSGTRACE_UNREADABLE="$SYS.1.gz" \
  zro_menu_delivery
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "EKSIK TARAMA"
assert_contains "$transcript" "$SYS.1.gz"
assert_contains "$transcript" "$(cat "$ONE")"
assert_contains "$transcript" "Bulunan ileti"
# The repair, and the sentence the whole screen exists for.
assert_contains "$transcript" "zmfixperms"
assert_contains "$transcript" "KANITLAMAZ"

it "and the disclosure is on the frame as well as in the text"
# whiptail keeps the title on the box border while the report scrolls, so it is the
# one part of the screen a long trace cannot push out of view. The banner is where
# the detail is; the title is what makes the disclosure sticky.
assert_contains "$transcript" "TEXT Teslim izi - EKSIK TARAMA"

it "a complete scan is titled and worded as the whole answer it is"
queue "1" "ahmet.yilmaz@example.com" "week" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "TEXT Teslim izi:"
assert_not_contains "$transcript" "EKSIK"

it "no file readable at all draws the log screen, not a report"
# Nothing was scanned, so there is no partial answer to show — and the screen has
# to say that this is not the same thing as finding no record.
queue "1" "ahmet.yilmaz@example.com" "week" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" \
ZRO_MOCK_ZMMSGTRACE_UNREADABLE="$(printf '%s\n%s\n%s' "$SYS" "$SYS.1.gz" "$SYS.2.gz")" \
  zro_menu_delivery
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "Log okunamiyor"
assert_contains "$transcript" "DEGILDIR"
assert_not_contains "$transcript" "Bulunan ileti"

it "nothing found in a partial scan is never shown as a plain empty result"
# The dangerous case: an operator shown "kayit bulunamadi" from a scan missing a
# file concludes the message never arrived. The report is shown instead, banner and
# all, with the count it really found.
queue "1" "ahmet.yilmaz@example.com" "week" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$NONE" \
ZRO_MOCK_ZMMSGTRACE_UNREADABLE="$SYS.1.gz" \
  zro_menu_delivery
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "EKSIK TARAMA"
assert_contains "$transcript" "Bulunan ileti  : 0"

it "a refused search still names a file it had already skipped"
# The oldest file is skipped, the next fails with a status nobody recognises. The
# search is refused — and the screen still names the log that was never read, so no
# path through this screen leaves a skipped file unmentioned.
queue "1" "ahmet.yilmaz@example.com" "week" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" \
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_RC=2 \
ZRO_MOCK_ZMMSGTRACE_UNREADABLE="$SYS.2.gz" \
  zro_menu_delivery
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "$SYS.2.gz"
assert_not_contains "$transcript" "Bulunan ileti"

it "the shared error reporter names a partial scan rather than a bare code"
# Unreachable from this screen, which shows the report instead — and asserted all
# the same, because the one thing this milestone may not do is let a skipped file
# arrive as a number the operator has to look up.
: >"$ZRO_UI_OUT"
zro_report_error "$ZRO_E_PARTIAL"
assert_contains "$(cat "$ZRO_UI_OUT")" "eksik"
assert_not_contains "$(cat "$ZRO_UI_OUT")" "kod 30"

it "the window screen offers exactly the presets the window module implements"
# Two declarations, held equal here because neither can check the other at run
# time without reaching into its business: the screen owns the labels, the module
# owns the arithmetic. Same shape as the allowlist and the binary-root table.
offered=""
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  case ${entry%%:*} in
    explicit) ;;   # not a preset: it asks for a range instead of computing one
    *) offered="$offered ${entry%%:*}" ;;
  esac
done <<EOF
$ZRO_WINDOW_CHOICES
EOF
implemented=""
for preset in $ZRO_WIN_PRESETS; do
  implemented="$implemented $preset"
done
assert_eq "$offered" "$implemented"

it "and offers a way to type a range that is not one of them"
assert_contains "$ZRO_WINDOW_CHOICES" "explicit:"

it "a clock this host cannot run is reported, not answered with a shrug"
# The preset path asks the clock for two readings. Without them there is no window
# at all, and returning quietly to the menu would read as the tool ignoring the
# operator. Refused at startup as well, which is where a host like this stops.
queue "${HOUR[@]}"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
( ZRO_DATE_BIN=/nonexistent/date
  ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery )
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "Saat okunamadi"
# And the cause is named, not dressed up as the mailbox service being down.
assert_not_contains "$transcript" "mailboxd"
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "a tracing binary this host does not have marks the entry, not the search"
# Learned BEFORE a search is invested in it: the main menu entry says so, and
# selecting it explains why rather than failing from inside a screen.
queue "2" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
ZRO_CAP_FORCE_TRACE_BIN=no zro_menu_main
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "KULLANILAMAZ"
assert_contains "$transcript" "Kullanilamaz"
# A version difference is not a permission, so this message may not send the
# operator to the permission repair tool.
assert_not_contains "$transcript" "zmfixperms"
# The screen was never drawn and nothing was asked for or run.
assert_not_contains "$transcript" "MENU Teslim takibi"
# The main menu reads the version on every redraw, so the log is not empty here;
# what matters is that no trace was run.
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "zmmsgtrace"

it "an unreadable primary log marks the entry and names the cause and the repair"
queue "2" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
ZRO_CAP_FORCE_TRACE_LOG=unreadable zro_menu_main
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "KULLANILAMAZ"
# The cause: the account every command runs as cannot read it. Not that the tool is
# running as the wrong user, and not that a search found nothing.
assert_contains "$transcript" "zimbra"
assert_contains "$transcript" "okunamiyor"
# The repair, by name, and the file it is about.
assert_contains "$transcript" "zmfixperms"
assert_contains "$transcript" "$SYS"
assert_not_contains "$transcript" "MENU Teslim takibi"
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "zmmsgtrace"

it "a log that is not there is not reported as a permission to repair"
# Different cause, different repair: naming the permission tool for a file that
# does not exist sends the operator looking for a mode that is not the problem.
queue "2" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_CAP_FORCE_TRACE_LOG=missing zro_menu_main
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "bulunamadi"
assert_contains "$transcript" "$SYS"
assert_not_contains "$transcript" "zmfixperms"

it "the entry carries no such mark when both probes are satisfied"
queue "__CANCEL__"
: >"$ZRO_UI_OUT"
zro_menu_main
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "Teslim takibi"
assert_not_contains "$transcript" "KULLANILAMAZ"

it "and the screen refuses on its own, not only through the entry that marks it"
# The mark is what an operator sees first; this is what makes it more than a label.
# Both read the same probe, asked once.
queue "${HOUR[@]}"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
ZRO_CAP_FORCE_TRACE_LOG=unreadable assert_ok zro_menu_delivery
assert_contains "$(cat "$ZRO_UI_OUT")" "Kullanilamaz"
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "a tracing binary that vanishes mid-session is still refused by the gate"
# The probe answers once per session, so a binary removed after the menu was drawn
# from it is not caught by it. The gate refuses independently, which is what makes
# it safe for the probe to be an answer about a moment rather than a guarantee.
queue "${HOUR[@]}"
: >"$ZRO_UI_OUT"
ZRO_ZIMBRA_LIBEXEC=/nonexistent zro_menu_delivery
assert_contains "$(cat "$ZRO_UI_OUT")" "Kullanilamaz"

it "no delivery screen touches a mailbox or the directory"
queue "${HOUR[@]}"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery
log=$(cat "$ZRO_MOCK_LOG")
assert_contains "$log" "zmmsgtrace"
assert_not_contains "$log" "zmmailbox"
assert_not_contains "$log" "zmprov"

it "no screen ever hands the tracer a path an operator typed"
# The file list comes from the inventory. Whatever an operator types is an
# address or a date, and every path in the vector is under the declared root.
queue "1" "ahmet.yilmaz@example.com" "week" "__CANCEL__" "__CANCEL__"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery
outside=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  path=$(printf '%s' "$line" | cut -f8)
  case $path in
    "$SYS"*) ;;
    *) outside="$outside [$path]" ;;
  esac
done <<EOF
$(grep '^zmmsgtrace' "$ZRO_MOCK_LOG")
EOF
assert_eq "$outside" ""

rm -f -- "$ZRO_MOCK_LOG" "$ZRO_UI_QUEUE" "$ZRO_UI_QUEUE.pos" "$ZRO_UI_OUT"
rm -rf -- "$TREE"
zro_t_report
