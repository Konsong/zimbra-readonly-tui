#!/usr/bin/env bash
set -uo pipefail
# Regression suite for the invisible-dialog bug found on the production server
# on 2026-07-29.
#
# whiptail draws its dialog on stdout and returns the answer on stderr. Callers
# read prompts inside command substitution, so their stdout is a pipe, and the
# msgbox wrapper additionally discarded stdout. The dialog was drawn into
# /dev/null while whiptail still waited on stdin: the terminal looked frozen.
#
# The stub backend cannot catch this — it writes to a file and returns at once,
# so it models neither drawing nor blocking. These tests drive the real whiptail
# path against a mock that reports where its drawing landed.
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_UI_BACKEND=whiptail
export ZRO_WHIPTAIL_BIN="$ZRO_TEST_ROOT/mocks/bin/whiptail"
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* 2>/dev/null || true

# shellcheck source=../lib/ui.sh
. "$ZRO_SRC/lib/ui.sh"

TTY_FILE=$(mktemp); export ZRO_UI_TTY="$TTY_FILE"
ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG

drew() { grep -c 'WHIPTAIL_DREW' "$TTY_FILE"; }

it "a message box reaches the terminal even when the caller discards stdout"
: >"$TTY_FILE"
zro_ui_msgbox "Gecersiz girdi" "Gecersiz hesap adresi." >/dev/null 2>&1
assert_eq "$(drew)" "1"

it "a text box reaches the terminal even when the caller discards stdout"
: >"$TTY_FILE"
body=$(mktemp); printf 'sonuc\n' >"$body"
zro_ui_textbox "Sonuc" "$body" >/dev/null 2>&1
assert_eq "$(drew)" "1"
rm -f -- "$body"

it "a confirmation reaches the terminal even when the caller discards stdout"
: >"$TTY_FILE"
zro_ui_yesno "Onay" "Devam?" >/dev/null 2>&1
assert_eq "$(drew)" "1"

it "a prompt read inside command substitution still draws to the terminal"
: >"$TTY_FILE"
answer=$(ZRO_MOCK_WHIPTAIL_ANSWER='ahmet@example.com' zro_ui_input "Hesap" "Adres:")
assert_eq "$(drew)" "1"
assert_eq "$answer" "ahmet@example.com"

it "the drawing never leaks into a captured answer"
: >"$TTY_FILE"
answer=$(ZRO_MOCK_WHIPTAIL_ANSWER='2' zro_ui_menu "Ana menu" "Secim" 1 "Hesap" 2 "Kota")
assert_eq "$answer" "2"
assert_not_contains "$answer" "WHIPTAIL_DREW"

it "a message box nested two levels deep in command substitution still draws"
: >"$TTY_FILE"
outer=$( inner=$( zro_ui_msgbox "Hata" "bir sey oldu" >/dev/null 2>&1; printf 'done' ); printf '%s' "$inner" )
assert_eq "$outer" "done"
assert_eq "$(drew)" "1"

it "a non-zero whiptail status is reported as cancel, not as an answer"
: >"$TTY_FILE"
ZRO_MOCK_WHIPTAIL_RC=1 assert_status "$ZRO_E_CANCEL" zro_ui_input "Hesap" "Adres:"
ZRO_MOCK_WHIPTAIL_RC=1 assert_status "$ZRO_E_CANCEL" zro_ui_menu "Ana menu" "Secim" 1 "Hesap"

# ESC is whiptail's 255, and it has to leave a screen the same way the Cancel
# button does. Asserted here, at the one place where a status becomes navigation,
# so it holds for every screen in the program rather than screen by screen — the
# stub backend has no ESC to queue.
it "ESC leaves a screen exactly as Cancel does"
ZRO_MOCK_WHIPTAIL_RC=255 assert_status "$ZRO_E_CANCEL" zro_ui_input "Alici" "Alici adresi:"
ZRO_MOCK_WHIPTAIL_RC=255 assert_status "$ZRO_E_CANCEL" \
  zro_ui_menu "Teslim takibi" "Islem secin:" 1 "Alici adresine gore izle"

it "a refused confirmation is a no"
ZRO_MOCK_WHIPTAIL_RC=1 assert_status 1 zro_ui_yesno "Onay" "Devam?"

it "a notice reaches the terminal and asks whiptail not to wait"
: >"$TTY_FILE"; : >"$ZRO_MOCK_LOG"
zro_ui_notice "Calisiyor" "Zimbra sorgulaniyor" >/dev/null 2>&1
assert_eq "$(drew)" "1"
# --infobox is the flag that draws and returns immediately. Any of the waiting
# box kinds here would reproduce the freeze this suite exists to prevent.
line=$(cat "$ZRO_MOCK_LOG")
assert_contains "$line" "--infobox"
assert_not_contains "$line" "--msgbox"

rm -f -- "$TTY_FILE" "$ZRO_MOCK_LOG"
zro_t_report
