#!/usr/bin/env bash
set -uo pipefail
# The two bulk query screens driven through the menu and the stub UI: where the
# list comes from, what the operator is told before the run starts, what the run
# spends, and what a stopped run leaves behind.
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ZIMBRA_LIBEXEC="$ZRO_TEST_ROOT/mocks/libexec"
export ZRO_POSTFIX_SBIN="$ZRO_TEST_ROOT/mocks/sbin"
export ZRO_SYSTEM_BIN="$ZRO_TEST_ROOT/mocks/system"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
export ZRO_NICE_BIN="$ZRO_TEST_ROOT/mocks/bin/nice"
export ZRO_IONICE_BIN="$ZRO_TEST_ROOT/mocks/bin/ionice"
export ZRO_UI_BACKEND=stub
export ZRO_SOURCED_ONLY=1
export ZRO_MOCK_ID_USER=zimbra
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* "$ZRO_TEST_ROOT"/mocks/libexec/* \
         "$ZRO_TEST_ROOT"/mocks/system/* "$ZRO_TEST_ROOT"/mocks/sbin/* 2>/dev/null || true

# This file is about the bulk screens, not about what the host running the suite
# happens to ship.
export ZRO_CAP_FORCE_TRACE_BIN=yes
export ZRO_CAP_FORCE_TRACE_LOG=ok
export ZRO_CAP_FORCE_QUEUE_BIN=yes

ZRO_MBOX_PROOF_FILE=$(mktemp); export ZRO_MBOX_PROOF_FILE

# shellcheck source=../zimbra-ro-tui.sh
. "$ZRO_SRC/zimbra-ro-tui.sh"
# Sourced after the program, because it reads the program's own declarations.
# shellcheck source=lib/cost.sh
. "$ZRO_TEST_ROOT/lib/cost.sh"

ZRO_MOCK_LOG=$(mktemp);  export ZRO_MOCK_LOG
ZRO_UI_QUEUE=$(mktemp);  export ZRO_UI_QUEUE
ZRO_UI_OUT=$(mktemp);    export ZRO_UI_OUT
FIX="$ZRO_TEST_ROOT/fixtures"
export ZRO_MOCK_ZMCONTROL__V_OUT="$FIX/zmcontrol_v.txt"

A1='ahmet.yilmaz@example.com'
A2='sade@example.com'
A3='kilitli@example.com'

queue() { printf '%s\n' "$@" >"$ZRO_UI_QUEUE"; zro_ui_reset; }
transcript() { cat "$ZRO_UI_OUT"; }
entries() { grep -F 'MENU Ana menu' "$ZRO_UI_OUT" | tail -n 1 | sed 's/^.*| //'; }
ran() { cat "$ZRO_MOCK_LOG"; }
read_count() { grep -c '^zmprov' "$ZRO_MOCK_LOG"; }
run() { : >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"; zro_menu_main; }

# Three accounts, each answering for itself.
staged() {
  export ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt"
  export ZRO_MOCK_ZMPROV_GA_SADE_EXAMPLE_COM_OUT="$FIX/zmprov_ga_bare.txt"
  export ZRO_MOCK_ZMPROV_GA_KILITLI_EXAMPLE_COM_OUT="$FIX/zmprov_ga_locked.txt"
}
staged

# ------------------------------------------------------------- the entries --

it "both bulk queries are offered, and neither asks for a selected address"
zro_sel_clear
queue "__CANCEL__"
run
list=$(entries)
for id in bulk-status bulk-mail; do
  assert_contains "$list" "$id"
  assert_out_eq "server" zro_menu_scope "$id"
done

# Class 1, whose unit is an ENTRY — the same class the account card claims, and
# the point of the whole screen: a run of two hundred accounts costs two hundred
# entries and nothing that grows with the directory around them.
it "and both declare the class of a directory read about one entry"
for id in bulk-status bulk-mail; do
  assert_out_eq "1" zro_menu_cost "$id"
done

it "and the operator picks them by the label the report is then headed with"
assert_out_eq "Toplu sorgu: listedeki hesaplarin durumu" zro_menu_label bulk-status
assert_out_eq "Toplu sorgu: listedeki filtre ve yonlendirmeler" zro_menu_label bulk-mail

# Two declarations held equal, the way the window presets and the operations that
# offer them already are. A question the module can answer and the menu does not
# offer is unreachable; an entry the menu offers and the module cannot answer is a
# defect that would only show up when somebody picked it.
it "every question the module declares is an operation the menu offers"
missing=""
while IFS= read -r q; do
  [ -n "$q" ] || continue
  zro_menu_label "bulk-$q" >/dev/null 2>&1 || missing="$missing [$q]"
done <<EOF
$(zro_bulk_question_ids)
EOF
assert_eq "$missing" ""

it "and every bulk operation the menu offers is a question the module declares"
unanswered=""
while IFS= read -r id; do
  case $id in bulk-*) ;; *) continue ;; esac
  zro_bulk_question_label "${id#bulk-}" >/dev/null 2>&1 || unanswered="$unanswered [$id]"
done <<EOF
$(zro_menu_ids)
EOF
assert_eq "$unanswered" ""

# ------------------------------------------------------- the list an operator types --

it "the first thing asked is where the list comes from"
queue "bulk-status" "__CANCEL__" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "MENU Liste kaynagi"
assert_contains "$out" "dosya"
assert_eq "$(read_count)" "0"

it "a typed list is read one address at a time, in the order it was typed"
queue "bulk-status" "text" "$A1,$A2,$A3" "yes" "__CANCEL__"
run
assert_eq "$(read_count)" "3"
assert_eq "$(ran | grep '^zmprov' | awk -F'\t' '{ print $3 }')" "$A1
$A2
$A3"

it "and the answer is one row per address, under the entry the operator picked"
out=$(transcript)
assert_contains "$out" "TEXT Toplu sorgu: listedeki hesaplarin durumu"
assert_contains "$out" "$A1"
assert_contains "$out" "active"
assert_contains "$out" "locked"

# The unit is the ENTRY and the list named three of them. A screen that reached
# for a fourth read, or that stopped making one per address, fails here against
# the class it claims rather than against a number somebody would have updated.
it "and it spends one directory read per address on the list"
assert_cost bulk-status "$(read_count)" 3

it "and it opens no mailbox, and never asks the oracle that guards one"
assert_eq "$(ran | grep -c '^zmmailbox')" "0"
assert_eq "$(ran | grep -c "$(printf '^zmprov\tgis')")" "0"

it "the operator is told what the run will cost before a single account is read"
queue "bulk-status" "text" "$A1,$A2" "__CANCEL__" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "YESNO"
assert_contains "$out" "2 adres"
assert_contains "$out" "Tahmini sure"

it "and declining it reads nothing at all"
assert_eq "$(read_count)" "0"

it "and the cap is stated there whether or not it applied"
assert_contains "$(transcript)" "$ZRO_BULK_MAX"

it "the progress is drawn as the run advances, and says how to stop it"
queue "bulk-status" "text" "$A1,$A2" "yes" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "NOTICE Toplu sorgu"
assert_contains "$out" "1 / 2"
assert_contains "$out" "2 / 2"
assert_contains "$out" "ESC"

# ---------------------------------------------------------- the list in a file --

LIST=$(mktemp)
printf '%s\n%s\n' "$A1" "$A3" >"$LIST"

it "a list in a file is read from it, and the file is named on the report"
queue "bulk-status" "file" "$LIST" "yes" "__CANCEL__"
run
out=$(transcript)
assert_eq "$(read_count)" "2"
assert_contains "$out" "$LIST"
assert_contains "$out" "locked"

it "a path this tool will not open is its own screen, and nothing is read"
queue "bulk-status" "file" "liste.txt" "__CANCEL__"
run
assert_contains "$(transcript)" "Gecersiz dosya yolu"
assert_eq "$(read_count)" "0"

it "and a file that is not there is told apart from one that is not a list"
queue "bulk-status" "file" "/tmp/zro-no-such-list-file" "__CANCEL__"
run
assert_contains "$(transcript)" "Dosya bulunamadi"
queue "bulk-status" "file" "/tmp" "__CANCEL__"
run
assert_contains "$(transcript)" "MSG Dosya degil"

it "and an empty file is answered as empty rather than as a broken read"
EMPTY_LIST=$(mktemp); : >"$EMPTY_LIST"
queue "bulk-status" "file" "$EMPTY_LIST" "__CANCEL__"
run
assert_contains "$(transcript)" "Dosya bos"
assert_eq "$(read_count)" "0"

it "and a file too large to be a list of addresses says so and says how large"
BIG_LIST=$(mktemp)
printf '%s\n%s\n' "$A1" "$A2" >"$BIG_LIST"
ZRO_BULK_FILE_BYTES_REAL=$ZRO_BULK_FILE_BYTES
ZRO_BULK_FILE_BYTES=16
queue "bulk-status" "file" "$BIG_LIST" "__CANCEL__"
run
ZRO_BULK_FILE_BYTES=$ZRO_BULK_FILE_BYTES_REAL
assert_contains "$(transcript)" "Dosya cok buyuk"
assert_eq "$(read_count)" "0"

# ------------------------------------------------------- what is refused --

it "a list with nothing readable on it says so and runs nothing"
queue "bulk-status" "text" "ali@@example,-yok" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "Sorgulanacak adres yok"
assert_contains "$out" "1. oge"
assert_eq "$(read_count)" "0"

it "and a list with nothing in it at all is a different screen, because it is a different mistake"
# Separators and nothing between them, which is what a stray paste leaves behind.
# An empty answer cannot be scripted here: the stub reads a blank queue line as a
# cancelled prompt, which is a different thing entirely.
queue "bulk-status" "text" " , , " "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "Liste bos"
assert_not_contains "$out" "Sorgulanacak adres yok"
assert_eq "$(read_count)" "0"

it "an entry that is not an address is reported with its position and the rest still run"
queue "bulk-status" "text" "$A1,ali@@example,$A3" "yes" "__CANCEL__"
run
out=$(transcript)
assert_eq "$(read_count)" "2"
assert_contains "$out" "2. oge"
assert_contains "$out" "ali@@example"
assert_contains "$out" "active"
assert_contains "$out" "locked"

it "and the confirmation says how many entries were refused before it is accepted"
assert_contains "$(transcript)" "1 gecersiz"

# ------------------------------------------------------------ stopping --

it "ESC stops the run, and what it found is still shown"
export ZRO_UI_STOP_AFTER=2
queue "bulk-status" "text" "$A1,$A2,$A3" "yes" "__CANCEL__"
run
unset ZRO_UI_STOP_AFTER
out=$(transcript)
assert_eq "$(read_count)" "1"
assert_contains "$out" "active"

it "and the answer is marked partial on the frame as well as in the text"
assert_contains "$out" "TEXT Toplu sorgu: listedeki hesaplarin durumu - EKSIK SONUC"
assert_contains "$out" "DURDURULDU"

# ------------------------------------------------------ the mail question --

it "the mail question answers with what is happening to each account's mail"
export ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_mailset_full.txt"
export ZRO_MOCK_ZMPROV_GA_SADE_EXAMPLE_COM_OUT="$FIX/zmprov_ga_mailset_bare.txt"
queue "bulk-mail" "text" "$A1,$A2" "yes" "__CANCEL__"
run
out=$(transcript)
assert_eq "$(read_count)" "2"
assert_contains "$out" "Yonetici tanimli yonlendirme: arsiv@example.net"
assert_contains "$out" "Kullanici tanimli yonlendirme: kisisel-yedek@example.net"
assert_contains "$out" "Yerel teslim"
assert_contains "$out" "yonlendirme yok, filtre yok"

it "and it spends one directory read per address, exactly as the status run does"
assert_cost bulk-mail "$(read_count)" 2
staged

rm -f -- "$ZRO_MOCK_LOG" "$ZRO_UI_QUEUE" "$ZRO_UI_OUT" "$ZRO_MBOX_PROOF_FILE" \
         "$LIST" "$EMPTY_LIST" "$BIG_LIST"
zro_t_report
