#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
export ZRO_UI_BACKEND=stub
export ZRO_SOURCED_ONLY=1
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* 2>/dev/null || true

# shellcheck source=../zimbra-ro-tui.sh
. "$ZRO_SRC/zimbra-ro-tui.sh"

ZRO_MOCK_LOG=$(mktemp);  export ZRO_MOCK_LOG
ZRO_UI_QUEUE=$(mktemp);  export ZRO_UI_QUEUE
ZRO_UI_OUT=$(mktemp);    export ZRO_UI_OUT
FIX="$ZRO_TEST_ROOT/fixtures"
export ZRO_MOCK_ZMCONTROL__V_OUT="$FIX/zmcontrol_v.txt"

queue() { printf '%s\n' "$@" >"$ZRO_UI_QUEUE"; zro_ui_reset; }

it "starts as zimbra"
ZRO_MOCK_ID_USER=zimbra assert_ok zro_startup_check

it "starts as root"
ZRO_MOCK_ID_USER=root assert_ok zro_startup_check

it "refuses every other user"
ZRO_MOCK_ID_USER=nobody assert_status "$ZRO_E_BADUSER" zro_startup_check
ZRO_MOCK_ID_USER=postfix assert_status "$ZRO_E_BADUSER" zro_startup_check

it "says which user it found when refusing"
captured=$(ZRO_MOCK_ID_USER=postfix zro_startup_check 2>&1)
assert_contains "$captured" "postfix"

it "fails when the Zimbra binaries are absent"
ZRO_MOCK_ID_USER=zimbra ZRO_ZIMBRA_BIN=/nonexistent \
  assert_status "$ZRO_E_UNAVAILABLE" zro_startup_check

it "fails when a required system binary is missing"
ZRO_MOCK_ID_USER=zimbra ZRO_TIMEOUT_BIN="" \
  assert_status "$ZRO_E_UNAVAILABLE" zro_startup_check
# Without a clock there is no arrival window and no year for a rotated log, and
# without stat there is no log inventory. Both are refused here rather than from
# inside a screen, where they would arrive as a failure to work backwards from.
ZRO_MOCK_ID_USER=zimbra ZRO_DATE_BIN="" \
  assert_status "$ZRO_E_UNAVAILABLE" zro_startup_check
ZRO_MOCK_ID_USER=zimbra ZRO_STAT_BIN="" \
  assert_status "$ZRO_E_UNAVAILABLE" zro_startup_check
captured=$(ZRO_MOCK_ID_USER=zimbra ZRO_DATE_BIN="" zro_startup_check 2>&1)
assert_contains "$captured" "date"

it "runs the smoke check through the full wrapper when root"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=root zro_startup_check >/dev/null 2>&1
log=$(cat "$ZRO_MOCK_LOG")
assert_contains "$log" "runuser"
assert_contains "$log" "zmcontrol"

it "refuses to start when the terminal cannot be written to"
ZRO_MOCK_ID_USER=zimbra ZRO_UI_BACKEND=whiptail ZRO_UI_TTY=/nonexistent/dir/tty \
  assert_status "$ZRO_E_UNAVAILABLE" zro_startup_check

it "warns but does not fail on a non-UTF-8 locale"
captured=$(ZRO_MOCK_ID_USER=zimbra LC_ALL=C LANG=C zro_startup_check 2>&1)
assert_contains "$captured" "locale"
ZRO_MOCK_ID_USER=zimbra LC_ALL=C LANG=C assert_ok zro_startup_check

export ZRO_MOCK_ID_USER=zimbra

it "cancelling the account prompt returns to the menu instead of exiting"
queue "1" "__CANCEL__" "__CANCEL__"
assert_ok zro_menu_account

it "an invalid address is reported and the menu continues"
queue "1" 'a@b.com; id' "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
zro_menu_account
assert_contains "$(cat "$ZRO_UI_OUT")" "Gecersiz"
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "zmprov"

it "a valid address reaches the summary view"
queue "1" "ahmet.yilmaz@example.com" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" zro_menu_account
assert_contains "$(cat "$ZRO_UI_OUT")" "Ahmet Yilmaz"

it "tells the operator a query is running before the wait begins"
queue "1" "ahmet.yilmaz@example.com" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" zro_menu_account
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "bekleyin"
# The notice has to come before the result, or it is not a notice.
notice_line=$(grep -n "bekleyin" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
result_line=$(grep -n "Ahmet Yilmaz" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
assert_eq "$([ "$notice_line" -lt "$result_line" ] && printf yes || printf no)" "yes"

it "the quota screen is reachable and rendered"
queue "2" "ahmet.yilmaz@example.com" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" zro_menu_account
transcript=$(cat "$ZRO_UI_OUT")
assert_contains "$transcript" "5.0 GB"
assert_contains "$transcript" "gosterilmiyor"
# Reaching this screen must not run the command that creates mailboxes.
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf '\tgmi')"

it "the membership screen is reachable and rendered"
queue "3" "ahmet.yilmaz@example.com" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMPROV_GAM_OUT="$FIX/zmprov_gam_ok.txt" zro_menu_account
assert_contains "$(cat "$ZRO_UI_OUT")" "bilgi-islem@example.com"

it "a missing account is reported without leaving the menu"
queue "1" "yok@example.com" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_ga_no_such_account.err" \
ZRO_MOCK_ZMPROV_GA_RC=1 zro_menu_account
assert_contains "$(cat "$ZRO_UI_OUT")" "bulunamadi"

it "an empty membership list is reported as no result, not an error"
empty=$(mktemp); : >"$empty"
queue "3" "yalniz@example.com" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMPROV_GAM_OUT="$empty" zro_menu_account
assert_contains "$(cat "$ZRO_UI_OUT")" "Kayit bulunamadi"
rm -f -- "$empty"

it "cancelling the main menu exits the loop cleanly"
queue "__CANCEL__"
assert_ok zro_menu_main

it "the exit entry leaves the main menu"
queue "9"
assert_ok zro_menu_main

rm -f -- "$ZRO_MOCK_LOG" "$ZRO_UI_QUEUE" "$ZRO_UI_QUEUE.pos" "$ZRO_UI_OUT"
zro_t_report
