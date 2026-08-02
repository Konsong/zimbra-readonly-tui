#!/usr/bin/env bash
# The selected address, and the frame it is carried on.
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/validate.sh
. "$ZRO_SRC/lib/validate.sh"
# shellcheck source=../lib/selection.sh
. "$ZRO_SRC/lib/selection.sh"
# shellcheck source=../lib/ui.sh
. "$ZRO_SRC/lib/ui.sh"

it "starts with nothing selected"
zro_sel_clear
assert_fail zro_sel_have
assert_out_eq "" zro_sel_address

it "carries an address once it is chosen"
assert_ok zro_sel_set "ahmet.yilmaz@example.com"
assert_ok zro_sel_have
assert_out_eq "ahmet.yilmaz@example.com" zro_sel_address

it "replaces the previous choice rather than adding to it"
assert_ok zro_sel_set "ayse.demir@example.com"
assert_out_eq "ayse.demir@example.com" zro_sel_address

it "refuses anything that is not an address, and keeps what it had"
# The prompt validates what it collects, so a refusal here is a defect in a
# caller. It matters all the same: an unvalidated value would be carried into
# every command of the session rather than into one.
for bad in "" "ahmet" "ahmet@example.com; id" "-x@example.com" "a b@example.com"; do
  assert_status "$ZRO_E_INPUT" zro_sel_set "$bad"
done
assert_out_eq "ayse.demir@example.com" zro_sel_address

it "can be given up again"
zro_sel_clear
assert_fail zro_sel_have
assert_out_eq "" zro_sel_address

# ------------------------------------------------------------- the frame --
#
# whiptail keeps a title on the box border while the text inside scrolls, so the
# title is the one part of a screen a long report cannot push out of view. That
# is why the selected address is put there, and why it is put there once for
# every screen rather than screen by screen.

it "a title says only what the screen is when nothing is selected"
zro_sel_clear
assert_out_eq "Hesap ozeti" zro_ui_title "Hesap ozeti"

it "and carries the selected address when there is one"
zro_sel_set "ahmet.yilmaz@example.com"
assert_out_eq "Hesap ozeti - ahmet.yilmaz@example.com" zro_ui_title "Hesap ozeti"

it "every box kind is drawn with it, not only the ones that report"
ZRO_UI_QUEUE=$(mktemp); export ZRO_UI_QUEUE
ZRO_UI_OUT=$(mktemp);   export ZRO_UI_OUT
export ZRO_UI_BACKEND=stub
printf '%s\n' "1" "yes" >"$ZRO_UI_QUEUE"; zro_ui_reset
body=$(mktemp); printf 'sonuc\n' >"$body"
zro_ui_menu "Ana menu" "Islem secin:" 1 "Hesap ozeti" >/dev/null
zro_ui_msgbox "Bulunamadi" "Hesap bulunamadi."
zro_ui_notice "Calisiyor" "Zimbra sorgulaniyor."
zro_ui_textbox "Hesap ozeti" "$body"
zro_ui_yesno "Onay" "Devam?" >/dev/null
missing=""
while IFS= read -r line; do
  case $line in
    MENU*|MSG*|NOTICE*|TEXT*|YESNO*)
      case $line in
        *"ahmet.yilmaz@example.com"*) ;;
        *) missing="$missing [$line]" ;;
      esac ;;
  esac
done <"$ZRO_UI_OUT"
assert_eq "$missing" ""
rm -f -- "$body"

it "an input prompt carries it too, so the answer is given about a known address"
printf '%s\n' "x" >"$ZRO_UI_QUEUE"; zro_ui_reset
: >"$ZRO_UI_OUT"
zro_ui_input "Ileti kimligi" "Kimlik:" >/dev/null
assert_contains "$(cat "$ZRO_UI_OUT")" "ahmet.yilmaz@example.com"

it "an address too long for the border is shortened, and marked as shortened"
# whiptail clips a title that does not fit, and what it clips is the end — which
# on this title is the address. Shortening it here keeps the screen's own name
# and says that the address is not shown whole. Nothing decides anything from
# this string: every screen that acts on the address reads the variable.
zro_sel_set "a.very.long.local.part.indeed@subdomain.example.com"
long=$(zro_ui_title "Teslim izi - EKSIK TARAMA")
assert_contains "$long" "Teslim izi - EKSIK TARAMA"
assert_contains "$long" ".."
assert_eq "$([ "${#long}" -le "$ZRO_UI_TITLE_MAX" ] && printf yes || printf no)" "yes"

it "and an address that fits is never shortened"
zro_sel_set "ali@example.com"
assert_out_eq "Hesap ozeti - ali@example.com" zro_ui_title "Hesap ozeti"

it "a screen name long enough to fill the border is shortened rather than the address"
# The one outcome this function exists to prevent is whiptail clipping the end of
# the title, because the end of the title is the address. A long screen name must
# therefore give way to it, not push it off.
zro_sel_set "a.very.long.local.part.indeed@subdomain.example.com"
long=$(zro_ui_title "Log: zimbra-mailbox-audit-2026-07-30-rotated.log.12.gz")
assert_eq "$([ "${#long}" -le "$ZRO_UI_TITLE_MAX" ] && printf yes || printf no)" "yes"
assert_contains "$long" "Log: zimbra"
# Twelve characters of address survive, which is what still names an account.
assert_eq "${long##* - }" "a.very.lon.."

it "and neither is shortened when both fit"
zro_sel_set "ali@example.com"
assert_out_eq "Log: zimbra.log - ali@example.com" zro_ui_title "Log: zimbra.log"

rm -f -- "$ZRO_UI_QUEUE" "$ZRO_UI_QUEUE.pos" "$ZRO_UI_OUT"
zro_t_report
