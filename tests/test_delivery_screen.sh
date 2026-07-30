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

it "the delivery trace is reachable from the main menu"
queue "2" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
zro_menu_main
assert_contains "$(cat "$ZRO_UI_OUT")" "Teslim takibi"

it "a valid recipient reaches the report"
queue "1" "ahmet.yilmaz@example.com" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "ahmet.yilmaz@example.com"
assert_contains "$transcript" "$(cat "$ONE")"

it "tells the operator the search is running before the wait begins"
queue "1" "ahmet.yilmaz@example.com" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery
assert_contains "$(cat "$ZRO_UI_OUT")" "bekleyin"
notice_line=$(grep -n "bekleyin" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
result_line=$(grep -n "Bulunan ileti" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
assert_eq "$([ "$notice_line" -lt "$result_line" ] && printf yes || printf no)" "yes"

it "nothing found says so, and says it is not proof nothing arrived"
queue "1" "ahmet.yilmaz@example.com" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$NONE" zro_menu_delivery
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "bulunamadi"
# The operator has to learn which logs were left out, or an empty answer reads
# as a verdict it has not earned.
assert_contains "$transcript" "rotasyon"

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

it "a log that cannot be read names the cause and the repair, not a bare code"
queue "1" "ahmet.yilmaz@example.com" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_RC=13 \
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_ERR="$FIX/zmmsgtrace_synthetic_unreadable.err" \
  zro_menu_delivery
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "okunamadi"
# The usual cause is ownership on the syslog file, and it breaks Zimbra's own
# tooling too, so the screen names the tool that repairs it.
assert_contains "$transcript" "zmfixperms"

it "a tracing binary this host does not have is reported, not crashed into"
queue "1" "ahmet.yilmaz@example.com" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_ZIMBRA_LIBEXEC=/nonexistent zro_menu_delivery
assert_contains "$(cat "$ZRO_UI_OUT")" "Kullanilamaz"

it "no delivery screen touches a mailbox or the directory"
queue "1" "ahmet.yilmaz@example.com" "__CANCEL__" "__CANCEL__"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ZMMSGTRACE___RECIPIENT_OUT="$ONE" zro_menu_delivery
log=$(cat "$ZRO_MOCK_LOG")
assert_contains "$log" "zmmsgtrace"
assert_not_contains "$log" "zmmailbox"
assert_not_contains "$log" "zmprov"

rm -f -- "$ZRO_MOCK_LOG" "$ZRO_UI_QUEUE" "$ZRO_UI_QUEUE.pos" "$ZRO_UI_OUT"
zro_t_report
