#!/usr/bin/env bash
set -uo pipefail
# The two mail settings screens driven through the menu and the stub UI: what the
# operator picks, what they are told before the wait, what the report is headed
# with, and what each one spends.
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

# This file is about the mail settings screens, not about what the host running
# the suite happens to ship.
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

EMPTY=$(mktemp); : >"$EMPTY"
ADDR="ahmet.yilmaz@example.com"

queue() { printf '%s\n' "$@" >"$ZRO_UI_QUEUE"; zro_ui_reset; }
transcript() { cat "$ZRO_UI_OUT"; }
entries() { grep -F 'MENU Ana menu' "$ZRO_UI_OUT" | tail -n 1 | sed 's/^.*| //'; }
ran() { cat "$ZRO_MOCK_LOG"; }
read_count() { ran | grep -c '^zmprov'; }
run() { : >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"; zro_menu_main; }

# The account carrying everything, as the lab server answered for it.
full_server() {
  export ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_mailset_full.txt"
  export ZRO_MOCK_ZMPROV_GSIG_OUT="$FIX/zmprov_gsig_bodies.txt"
  export ZRO_MOCK_ZMPROV_GID_OUT="$FIX/zmprov_gid_two.txt"
}

# ------------------------------------------------------------- the entries --

it "both screens are offered, and both are about the selected account"
zro_sel_clear
queue "__CANCEL__"
run
list=$(entries)
for id in account-mailsettings account-filters; do
  assert_contains "$list" "$id"
  assert_out_eq "account" zro_menu_scope "$id"
done

# Class 1, whose unit is an ENTRY. Neither screen opens a mailbox, so neither may
# claim the class that names one.
it "and both declare the class of a directory read about one entry"
for id in account-mailsettings account-filters; do
  assert_out_eq "1" zro_menu_cost "$id"
done

it "and the operator picks them by the label the report is then headed with"
assert_out_eq "Posta ayarlari (filtre, teslim, imza)" zro_menu_label account-mailsettings
assert_out_eq "Filtre kurallarinin tam metni" zro_menu_label account-filters

# ----------------------------------------------------------- the card --

it "the card renders the settings from the reads the screen declares"
full_server
zro_sel_set "$ADDR"
queue "account-mailsettings" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "Yerel teslim"
assert_contains "$out" "posta yerel kutuya birakilmiyor"
assert_contains "$out" "tanimli (17 satir)"
assert_contains "$out" "Kurumsal"
assert_contains "$out" "DEFAULT (hesabin kendi kimligi)"

# THREE READS OF ONE ENTRY, declared as a multiple rather than absorbed into a
# total: a screen that quietly stopped asking for the signatures would fail here,
# and so would one that reached for a second account.
it "and it costs three reads of the one entry it is about"
assert_cost account-mailsettings "$(read_count)" 1 3

it "and the operator is told what it will spend before the wait begins"
out=$(transcript)
assert_contains "$out" "Bu ekran hesabi UC KEZ okur"
notice_line=$(grep -n "UC KEZ" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
result_line=$(grep -n "Yerel teslim" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
assert_eq "$([ "$notice_line" -lt "$result_line" ] && printf yes || printf no)" "yes"

it "and the report is headed with the entry the operator picked"
assert_contains "$(transcript)" "Posta ayarlari (filtre, teslim, imza)"

# ------------------------------------------------------ the filters screen --

it "the filter screen renders both rule sets in full"
full_server
zro_sel_set "$ADDR"
queue "account-filters" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "Gelen posta kurallari"
assert_contains "$out" "# Faturalar"
assert_contains "$out" "# Duyurular"
assert_contains "$out" 'fileinto "Duyurular";'
assert_contains "$out" 'fileinto "Gonderilmis";'

it "and it costs one read of the one entry it is about"
assert_cost account-filters "$(read_count)" 1

# ------------------------------------------ an account with nothing at all --

it "an account with no filters, no signatures and no identity of its own renders"
export ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_mailset_bare.txt"
export ZRO_MOCK_ZMPROV_GSIG_OUT="$EMPTY"
export ZRO_MOCK_ZMPROV_GID_OUT="$FIX/zmprov_gid_default.txt"
zro_sel_set "sade@example.com"
queue "account-mailsettings" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "Gelen"
assert_contains "$out" "yok"
assert_not_contains "$out" "bilinmiyor"

# THE CLAIM THE SCREEN RESTS ON, asserted where an operator would meet it: an
# account with no mailbox is answered rather than refused, and neither screen so
# much as asks the existence oracle.
it "and neither screen touches a mailbox or the oracle that guards one"
assert_eq "$(ran | grep -c '^zmmailbox')" "0"
assert_eq "$(ran | grep -c "$(printf '^zmprov\tgis')")" "0"

zro_t_report
