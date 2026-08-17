#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/ui.sh
. "$ZRO_SRC/lib/ui.sh"

export ZRO_UI_BACKEND=stub
ZRO_UI_QUEUE=$(mktemp); export ZRO_UI_QUEUE
ZRO_UI_OUT=$(mktemp);   export ZRO_UI_OUT

queue() { printf '%s\n' "$@" >"$ZRO_UI_QUEUE"; zro_ui_reset; }

it "returns the tag the operator selected"
queue "2"
assert_out_eq "2" zro_ui_menu "Ana Menu" "Secim" 1 "Hesap" 2 "Kota"

it "consumes one queue line per prompt, in order"
queue "1" "ahmet@example.com"
assert_out_eq "1" zro_ui_menu "Ana Menu" "Secim" 1 "Hesap"
assert_out_eq "ahmet@example.com" zro_ui_input "Hesap" "Adres"

it "reports cancel distinctly from an error"
queue "__CANCEL__"
assert_status "$ZRO_E_CANCEL" zro_ui_menu "Ana Menu" "Secim" 1 "Hesap"

it "reports cancel on an input prompt"
queue "__CANCEL__"
assert_status "$ZRO_E_CANCEL" zro_ui_input "Hesap" "Adres"

it "prints nothing when cancelled"
queue "__CANCEL__"
assert_out_eq "" zro_ui_input "Hesap" "Adres"

it "treats an exhausted queue as cancel rather than hanging"
queue
assert_status "$ZRO_E_CANCEL" zro_ui_menu "Ana Menu" "Secim" 1 "Hesap"

it "captures displayed messages"
queue
: >"$ZRO_UI_OUT"
zro_ui_msgbox "Hata" "Hesap bulunamadi"
assert_contains "$(cat "$ZRO_UI_OUT")" "Hesap bulunamadi"

it "captures displayed files"
queue
: >"$ZRO_UI_OUT"
body=$(mktemp); printf 'zimbraAccountStatus: active\n' >"$body"
zro_ui_textbox "Ozet" "$body"
assert_contains "$(cat "$ZRO_UI_OUT")" "zimbraAccountStatus: active"
rm -f -- "$body"

it "answers yes/no from the queue"
queue "yes"
assert_status 0 zro_ui_yesno "Onay" "Devam?"
queue "no"
assert_status 1 zro_ui_yesno "Onay" "Devam?"

it "a cancelled yes/no counts as no"
queue "__CANCEL__"
assert_status 1 zro_ui_yesno "Onay" "Devam?"

it "prompt text goes to the transcript, never to stdout"
queue "1"
: >"$ZRO_UI_OUT"
selected=$(zro_ui_menu "Ana Menu" "Bu metin stdout'a gitmemeli" 1 "Hesap")
assert_eq "$selected" "1"
assert_not_contains "$selected" "gitmemeli"
assert_contains "$(cat "$ZRO_UI_OUT")" "gitmemeli"

it "keeps a selection value containing spaces intact"
queue "hesap ve kota"
assert_out_eq "hesap ve kota" zro_ui_input "Hesap" "Adres"

it "a notice is recorded and consumes no queued answer"
queue "1"
: >"$ZRO_UI_OUT"
zro_ui_notice "Calisiyor" "Sorgulaniyor"
assert_contains "$(cat "$ZRO_UI_OUT")" "Sorgulaniyor"
# The queue must be untouched: a notice asks the operator for nothing.
assert_out_eq "1" zro_ui_menu "Ana Menu" "Secim" 1 "Hesap"

# --------------------------------------------------------- stopping a run --
#
# The one place this program reads the keyboard while nothing is being drawn. It
# is here for the reason every other drawing is: this module is the only path
# between the program and the terminal, so a long run cannot reach the keyboard by
# a route with no stub behind it.

it "nothing is asking to stop unless a case says so"
queue "1"
assert_fail zro_ui_stop_requested
assert_fail zro_ui_stop_requested

it "and a poll asks the operator for nothing, so it consumes no queued answer"
assert_out_eq "1" zro_ui_menu "Ana Menu" "Secim" 1 "Hesap"

it "a scripted stop answers on the poll it was scripted for, and not before"
queue "1"
ZRO_UI_STOP_AFTER=3
assert_fail zro_ui_stop_requested
assert_fail zro_ui_stop_requested
assert_ok zro_ui_stop_requested

it "and the count is kept in a file, so a run driven in a subshell still advances it"
# A bulk query runs inside command substitution: a counter incremented there would
# die with the subshell and every poll would be the first, which is a run that can
# never be stopped.
queue "1"
ZRO_UI_STOP_AFTER=2
if ( zro_ui_stop_requested ); then
  zro_t_fail "the first poll, made in a subshell, reported a stop"
else
  zro_t_pass
fi
assert_ok zro_ui_stop_requested
ZRO_UI_STOP_AFTER=

it "a stop nobody scripted is not a stop, whatever the queue holds"
queue "__CANCEL__"
assert_fail zro_ui_stop_requested

rm -f -- "$ZRO_UI_QUEUE" "$ZRO_UI_OUT" "$ZRO_UI_QUEUE.pos" "$ZRO_UI_QUEUE.stops"
zro_t_report
