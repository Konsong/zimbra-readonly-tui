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

# Pointed somewhere of its own before the program is sourced, so a case here that
# plants a proof cannot reach a session running beside it.
ZRO_MBOX_PROOF_FILE=$(mktemp); export ZRO_MBOX_PROOF_FILE

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

it "starts with no proof of any mailbox in hand"
# The capability cache lives in variables and a new process starts with it empty.
# The existence gate's proofs live in a FILE whose name carries a process id, and
# process ids are reused — so a session could otherwise inherit a proof nobody in
# it obtained, and go on to open a mailbox on that evidence. Emptied at startup
# rather than trusted to be absent, because this is the one direction the gate may
# never fail in.
printf '%s\n' 'ahmet.yilmaz@example.com' >"$ZRO_MBOX_PROOF_FILE"
assert_ok zro_mbox_proven 'ahmet.yilmaz@example.com'
ZRO_MOCK_ID_USER=zimbra assert_ok zro_startup_check
assert_fail zro_mbox_proven 'ahmet.yilmaz@example.com'

it "warns but does not fail on a non-UTF-8 locale"
captured=$(ZRO_MOCK_ID_USER=zimbra LC_ALL=C LANG=C zro_startup_check 2>&1)
assert_contains "$captured" "locale"
ZRO_MOCK_ID_USER=zimbra LC_ALL=C LANG=C assert_ok zro_startup_check

export ZRO_MOCK_ID_USER=zimbra

# What the menus do with a started tool is tests/test_main_menu.sh. These two are
# here because they are about the program ending, which is where startup ends.

it "cancelling the main menu exits the loop cleanly"
queue "__CANCEL__"
assert_ok zro_menu_main

it "the exit entry leaves the main menu"
queue "quit"
assert_ok zro_menu_main

rm -f -- "$ZRO_MOCK_LOG" "$ZRO_UI_QUEUE" "$ZRO_UI_QUEUE.pos" "$ZRO_UI_OUT"
zro_t_report
