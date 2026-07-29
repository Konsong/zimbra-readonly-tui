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

rm -f -- "$ZRO_UI_QUEUE" "$ZRO_UI_OUT"
zro_t_report
