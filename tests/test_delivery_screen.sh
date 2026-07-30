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
}
mk "$SYS"      "$((NOW - 300))"
mk "$SYS.1.gz" "$R1"
mk "$SYS.2.gz" "$R2"

# shellcheck source=../zimbra-ro-tui.sh
. "$ZRO_SRC/zimbra-ro-tui.sh"

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
HOUR=("1" "ahmet.yilmaz@example.com" "1" "__CANCEL__" "__CANCEL__")

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
for pair in "1 3600" "2 86400" "4 604800"; do
  run_preset "${pair%% *}"
  w=$(searched)
  assert_eq "$(( ${w##* } - ${w%% *} ))" "${pair##* }"
done

it "the yesterday entry searches the calendar day, midnight to its last second"
run_preset 3
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
queue "1" "ahmet.yilmaz@example.com" "3" "__CANCEL__" "__CANCEL__"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery
assert_contains "$(grep '^zmmsgtrace' "$ZRO_MOCK_LOG")" "$SYS.1.gz"

it "each file is traced once, with the year of its own modification time"
# The defect this removes: the tracer guesses one year from the local clock, so a
# time-bounded search of a log rotated in another year silently finds nothing.
# The year is compared against each file's own timestamp rather than against
# today's, so this case still holds on the first of January.
queue "1" "ahmet.yilmaz@example.com" "4" "__CANCEL__" "__CANCEL__"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery
traced=$(grep '^zmmsgtrace' "$ZRO_MOCK_LOG")
assert_eq "$(printf '%s\n' "$traced" | wc -l | tr -d ' ')" "3"
assert_eq "$(printf '%s\n' "$traced" | cut -f8 | sort -u | wc -l | tr -d ' ')" "3"
wrong=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  year=$(printf '%s' "$line" | cut -f7)
  path=$(printf '%s' "$line" | cut -f8)
  want=$(date -d "@$(stat -c '%Y' -- "$path")" '+%Y')
  [ "$year" = "$want" ] || wrong="$wrong [$path: $year, not $want]"
done <<EOF
$traced
EOF
assert_eq "$wrong" ""

it "an explicit range is accepted and reaches the tracer as the window it names"
queue "1" "ahmet.yilmaz@example.com" "5" "2026-07-28 08:00" "2026-07-28 09:30" \
      "__CANCEL__" "__CANCEL__"
: >"$ZRO_MOCK_LOG"; : >"$ZRO_UI_OUT"
# The zone is pinned inside a subshell: a temporary assignment in front of a
# function call persists after it returns in bash, and every case below reads the
# clock.
( export TZ=UTC; ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery )
assert_contains "$(cat "$ZRO_MOCK_LOG")" \
  "$(printf '\t--time\t20260728080000,20260728093000\t')"

it "a malformed explicit range is refused and nothing is run"
queue "1" "ahmet.yilmaz@example.com" "5" "dun" "bugun" "__CANCEL__" "__CANCEL__"
: >"$ZRO_MOCK_LOG"; : >"$ZRO_UI_OUT"
zro_menu_delivery
assert_contains "$(cat "$ZRO_UI_OUT")" "Gecersiz"
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "an explicit range that ends before it starts is refused, not swapped"
queue "1" "ahmet.yilmaz@example.com" "5" "2026-07-28 09:00" "2026-07-28 08:00" \
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
queue "1" "ahmet.yilmaz@example.com" "5" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
assert_ok zro_menu_delivery
assert_eq "$(grep -c 'MENU Teslim takibi' "$ZRO_UI_OUT")" "2"
queue "1" "ahmet.yilmaz@example.com" "5" "2026-07-28 08:00" "__CANCEL__" "__CANCEL__"
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

it "one unreadable file among several refuses the whole search"
# Two files, one of them unreadable: no half-answer is shown. A report assembled
# from one of two files reads exactly like a complete one.
queue "1" "ahmet.yilmaz@example.com" "4" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" \
ZRO_MOCK_ZMMSGTRACE_UNREADABLE="$SYS" \
  zro_menu_delivery
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "okunamadi"
assert_not_contains "$transcript" "Bulunan ileti"

it "a tracing binary this host does not have is reported, not crashed into"
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
queue "1" "ahmet.yilmaz@example.com" "4" "__CANCEL__" "__CANCEL__"
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
