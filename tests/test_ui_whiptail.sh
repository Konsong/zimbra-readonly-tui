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

# ------------------------------------------------------- the notice's height --
#
# MEASURED AGAINST A REAL WHIPTAIL, not derived: an infobox keeps `height - 7`
# rows of the text it was given. Drawn at the fixed height this program used
# before, that is one row — so every notice in the tool showed its first line and
# dropped the rest, and no case could see it because the stub has no geometry.

it "a notice is drawn tall enough for the lines it was given"
argv=$(zro_ui_whiptail_argv infobox "Calisiyor" "bir
iki
uc
dort
bes")
assert_contains "$argv" "--infobox"
assert_contains "$argv" "$(printf '\t%s\t' "$((5 + ZRO_UI_NOTICE_CHROME))")"

it "and the height the box is built with is the one this rule computes"
# The run path and this test-facing printer go through one builder, so what is
# asserted here is what is really drawn.
assert_out_eq "$((5 + ZRO_UI_NOTICE_CHROME))" zro_ui_notice_height "bir
iki
uc
dort
bes"

it "and a short notice is not a box with no shape, nor a long one taller than the screen"
assert_out_eq "$ZRO_UI_NOTICE_HEIGHT" zro_ui_notice_height "tek satir"
assert_out_eq "$ZRO_UI_NOTICE_HEIGHT" zro_ui_notice_height ""
long=""
i=0
while [ "$i" -lt 40 ]; do i=$((i + 1)); long="$long
satir $i"; done
assert_out_eq "$ZRO_UI_HEIGHT" zro_ui_notice_height "$long"

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
