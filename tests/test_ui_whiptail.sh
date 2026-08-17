#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/ui.sh
. "$ZRO_SRC/lib/ui.sh"

it "accepts a UTF-8 locale"
assert_ok zro_ui_locale_ok "tr_TR.UTF-8"
assert_ok zro_ui_locale_ok "en_US.utf8"
assert_ok zro_ui_locale_ok "C.UTF-8"

it "rejects a locale that cannot render Turkish labels"
assert_fail zro_ui_locale_ok "C"
assert_fail zro_ui_locale_ok "POSIX"
assert_fail zro_ui_locale_ok "en_US.ISO-8859-1"
assert_fail zro_ui_locale_ok ""

ZRO_WHIPTAIL_BIN=/nonexistent/whiptail

it "builds the menu argument vector the run path will execute"
argv=$(zro_ui_whiptail_argv menu "Ana Menu" "Secim" 1 "Hesap ve kota" 2 "Cikis")
assert_contains "$argv" "--menu"
assert_contains "$argv" "--notags"
assert_contains "$argv" "Ana Menu"
assert_contains "$argv" "Hesap ve kota"
assert_contains "$argv" "/nonexistent/whiptail"

it "keeps a label containing spaces as one argument"
argv=$(zro_ui_whiptail_argv menu "T" "S" 1 "Hesap ve kota kontrolleri")
assert_contains "$argv" "$(printf '\tHesap ve kota kontrolleri')"

it "keeps operator text out of the flag positions"
argv=$(zro_ui_whiptail_argv input "T" "S" '--yesno x')
assert_contains "$argv" "$(printf '\t--yesno x')"
assert_not_contains "$argv" "$(printf '\t--yesno\tx')"

it "builds each box kind with its own flag"
assert_contains "$(zro_ui_whiptail_argv input "T" "S" "")" "--inputbox"
assert_contains "$(zro_ui_whiptail_argv msgbox "T" "S")" "--msgbox"
assert_contains "$(zro_ui_whiptail_argv textbox "T" "/tmp/x")" "--textbox"
assert_contains "$(zro_ui_whiptail_argv yesno "T" "S")" "--yesno"

it "always carries a title and a backtitle"
argv=$(zro_ui_whiptail_argv msgbox "Hata" "Bir sey oldu")
assert_contains "$argv" "--title"
assert_contains "$argv" "--backtitle"

# ------------------------------------------------- the stop, on the real path --
#
# The stub answers a scripted stop, which is what the screen cases drive. What is
# checked HERE is the path that really runs: the byte it reads, and that reading
# it does not wait for a line. ZRO_UI_TTY is pointed at a file for the same reason
# the drawing cases point it at one — a terminal is what this program is given,
# not what a suite has.

it "a key already waiting stops the run, and it is ESC that does it"
tty_file=$(mktemp)
printf '\033' >"$tty_file"
ZRO_UI_TTY=$tty_file assert_ok zro_ui_tty_stop

it "and any other key is not a stop, however long it has been waiting"
printf 'q' >"$tty_file"
ZRO_UI_TTY=$tty_file assert_fail zro_ui_tty_stop

it "and a terminal with nothing on it is not a stop either"
: >"$tty_file"
ZRO_UI_TTY=$tty_file assert_fail zro_ui_tty_stop

it "and a terminal this program cannot read is not one, because nobody could ask"
ZRO_UI_TTY=/nonexistent/tty assert_fail zro_ui_tty_stop
rm -f -- "$tty_file"

zro_t_report
