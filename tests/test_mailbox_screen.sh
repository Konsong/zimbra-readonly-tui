#!/usr/bin/env bash
# The existence gate as a screen, driven through the stub UI backend: three
# outcomes, three screens, and the fourth condition that is not an outcome at all.
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ZIMBRA_LIBEXEC="$ZRO_TEST_ROOT/mocks/libexec"
export ZRO_SYSTEM_BIN="$ZRO_TEST_ROOT/mocks/system"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
export ZRO_UI_BACKEND=stub
export ZRO_SOURCED_ONLY=1
export ZRO_MOCK_ID_USER=zimbra
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* "$ZRO_TEST_ROOT"/mocks/libexec/* \
         "$ZRO_TEST_ROOT"/mocks/system/* 2>/dev/null || true

# This file is about the mailbox screen, not about what this host ships. Both
# trace probes are pinned so that a mark on some other entry is never the machine
# running the suite deciding something.
export ZRO_CAP_FORCE_TRACE_BIN=yes
export ZRO_CAP_FORCE_TRACE_LOG=ok

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
export ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt"

ADDR="ahmet.yilmaz@example.com"

queue() { printf '%s\n' "$@" >"$ZRO_UI_QUEUE"; zro_ui_reset; }
transcript() { cat "$ZRO_UI_OUT"; }
entries() { grep -F 'MENU Ana menu' "$ZRO_UI_OUT" | tail -n 1 | sed 's/^.*| //'; }
ran() { cat "$ZRO_MOCK_LOG"; }
oracle_runs() { ran | grep -c "$(printf '^zmprov\tgis')"; }

# One run of the menu, with the session's memory of proofs cleared: each case
# says which server it is talking to and pays the gate itself, rather than
# inheriting a proof the case before it earned.
run() { : >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"; zro_mbox_forget; zro_menu_main; }

# The three captured outcomes, as three servers.
exists_server() {
  export ZRO_MOCK_ZMPROV_GIS_OUT="$FIX/zmprov_gis_ok.txt"
  unset ZRO_MOCK_ZMPROV_GIS_ERR ZRO_MOCK_ZMPROV_GIS_RC
}
no_mailbox_server() {
  unset ZRO_MOCK_ZMPROV_GIS_OUT
  export ZRO_MOCK_ZMPROV_GIS_ERR="$FIX/zmprov_gis_no_mailbox.err"
  export ZRO_MOCK_ZMPROV_GIS_RC=2
}
no_account_server() {
  unset ZRO_MOCK_ZMPROV_GIS_OUT
  export ZRO_MOCK_ZMPROV_GIS_ERR="$FIX/zmprov_gis_no_such_account.err"
  export ZRO_MOCK_ZMPROV_GIS_RC=2
}
outage_server() {
  unset ZRO_MOCK_ZMPROV_GIS_OUT
  export ZRO_MOCK_ZMPROV_GIS_ERR="$FIX/zmprov_io_error_refused.err"
  export ZRO_MOCK_ZMPROV_GIS_RC=1
}

# ----------------------------------------------------- three outcomes, three screens --

it "the entry is offered, and it is about the account"
zro_sel_clear
queue "__CANCEL__"
run
assert_contains "$(entries)" "mailbox-status Mailbox var mi"
assert_out_eq "account" zro_menu_scope mailbox-status

it "a mailbox that is there gets its own screen"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-status" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "$ZRO_TXT_MBOX_EXISTS"
assert_not_contains "$out" "$ZRO_TXT_MBOX_NONE"
assert_not_contains "$out" "$ZRO_TXT_MBOX_NO_ACCOUNT"

it "an account with no mailbox gets a RESULT screen, not an error dialog"
# The distinction the whole gate turns on. This account is provisioned and has
# never been used; being told so is an answer, and being shown a failure box would
# send an operator looking for something broken.
no_mailbox_server
zro_sel_set "$ADDR"
queue "mailbox-status" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "$ZRO_TXT_MBOX_NONE"
assert_contains "$out" "TEXT Mailbox var mi"
assert_not_contains "$out" "MSG Hata"
assert_not_contains "$out" "MSG Bulunamadi"

it "and it says what creates a mailbox, so never used is an answer rather than a puzzle"
assert_contains "$(transcript)" "ilk giriste veya ilk teslimde"

it "and it says out loud that this tool will not create one"
# THE GUARANTEE, MADE VISIBLE AT THE POINT WHERE BREAKING IT WOULD BE MOST
# TEMPTING. An operator reading "this account has no mailbox" is one keystroke
# away from wanting the tool to look inside it anyway.
assert_contains "$(transcript)" "YARATMAZ"

it "an account that is not there gets a third screen, not the second one"
no_account_server
zro_sel_set "yok@example.com"
queue "mailbox-status" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "$ZRO_TXT_MBOX_NO_ACCOUNT"
assert_not_contains "$out" "$ZRO_TXT_MBOX_NONE"

it "the three screens are told apart by the message, not by the exit status"
# All three failures exit 2 on the real server. The fixtures carry that status
# verbatim, so a classification that read the code would answer the same word to
# two of these cases and this file would have caught it.
assert_eq "$(grep -c 'mailbox not found' "$FIX/zmprov_gis_no_mailbox.err")" "1"
assert_eq "$(grep -c 'no such account' "$FIX/zmprov_gis_no_such_account.err")" "1"

# ------------------------------------------------------------- the silent gate --

it "a mailbox service that does not answer is its own screen, naming the cause"
outage_server
zro_sel_set "$ADDR"
queue "mailbox-status" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "MSG Mailbox sorusu yanitlanamiyor"
assert_contains "$out" "SOAP"
assert_contains "$out" "zmcontrol status"

it "and it is not reported as the account having no mailbox"
# THE ONE THING THIS SCREEN MAY NEVER SAY. An outage read as an absence is the
# most damaging sentence this program could produce.
assert_not_contains "$(transcript)" "$ZRO_TXT_MBOX_NONE"

it "and it says the mailbox screens lose nothing they could otherwise have had"
# Not reported as a failure: the commands behind the gate reach the same service,
# so refusing costs the operator nothing real. Saying so is what stops the screen
# reading as a broken tool during the incident the tool exists to diagnose.
assert_contains "$(transcript)" "Kaybedilen bir bilgi yok"

it "and it does not claim the directory screens are affected"
assert_contains "$(transcript)" "LDAP"

it "the menu is returned to, not left"
assert_contains "$(transcript)" "MENU Ana menu"

# ------------------------------------------------------------------- the cost --

it "the screen costs one read of one mailbox"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-status" "__CANCEL__"
run
# ONE MAILBOX NAMED BY THE ANSWER, one invocation spent on it. Counted through the
# declared class rather than against a number written here, so a screen that
# started reading per account fails against the unit it claimed.
assert_cost mailbox-status "$(oracle_runs)" 1

it "and a second visit in the same session costs nothing at all"
# The proof is kept; the gate is not re-run. This is the one screen whose exact
# cost is sometimes zero, which is why it says so before it runs.
exists_server
zro_sel_set "$ADDR"
queue "mailbox-status" "mailbox-status" "mailbox-status" "__CANCEL__"
run
assert_eq "$(oracle_runs)" "1"

it "but an absence is asked again every single time"
no_mailbox_server
zro_sel_set "$ADDR"
queue "mailbox-status" "mailbox-status" "__CANCEL__"
run
assert_eq "$(oracle_runs)" "2"

it "and it declares what it will spend before it spends it"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-status" "__CANCEL__"
run
assert_contains "$(transcript)" "BIR KEZ"
notice_line=$(grep -n "BIR KEZ" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
result_line=$(grep -n "$ZRO_TXT_MBOX_EXISTS" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
assert_eq "$([ "$notice_line" -lt "$result_line" ] && printf yes || printf no)" "yes"

it "and no other account screen borrows that sentence"
exists_server
zro_sel_set "$ADDR"
queue "account-card" "__CANCEL__"
run
assert_not_contains "$(transcript)" "BIR KEZ"

# --------------------------------------------------- what it may not run --

it "no screen here opens a mailbox"
# THE POINT OF THE WHOLE TICKET, asserted against the transcript of a real run
# rather than against the source. Whatever the gate answered, the binary that
# provisions is never reached.
for server in exists_server no_mailbox_server no_account_server outage_server; do
  $server
  zro_sel_set "$ADDR"
  queue "mailbox-status" "__CANCEL__"
  run
  assert_not_contains "$(ran)" "zmmailbox"
done

it "and it never runs the read-named command that creates one"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-status" "__CANCEL__"
run
assert_not_contains "$(ran)" "$(printf '\tgmi')"

it "and it asks the directory for nothing else"
# One invocation, and it is the oracle. A screen that also read the account card
# would be paying class 1 on top of class 2 for a question neither of them asks.
exists_server
zro_sel_set "$ADDR"
queue "mailbox-status" "__CANCEL__"
run
assert_eq "$(ran | grep -c '^zmprov')" "1"

# ------------------------------------------------------- about which address --

it "an alias is queried for the account behind it, and the screen says so"
# The card is about the account; the address the operator chose is on the frame.
# Without the note the two would disagree with nobody saying why.
exists_server
zro_sel_clear
zro_sel_set "alias-a@example.com"
zro_sel_set_identity "$(zro_identity_record alias 'alias-a@example.com' "$ADDR" 'Ahmet Yilmaz')"
queue "mailbox-status" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "alias-a@example.com adresi bir alias"
assert_contains "$out" "$ADDR hesabina aittir"
assert_contains "$(ran)" "$(printf 'zmprov\tgis\t%s' "$ADDR")"

it "an address that is not an account is marked before the entry is chosen"
zro_sel_clear
zro_sel_set "liste@example.com"
zro_sel_set_identity "$(zro_identity_record list 'liste@example.com')"
queue "__CANCEL__"
run
assert_contains "$(entries)" "Mailbox var mi - BU ADRES HESAP DEGIL"

it "and choosing it anyway asks Zimbra nothing"
zro_sel_clear
zro_sel_set "liste@example.com"
zro_sel_set_identity "$(zro_identity_record list 'liste@example.com')"
queue "mailbox-status" "__CANCEL__"
run
assert_eq "$(ran | grep -c '^zmprov')" "0"
assert_contains "$(transcript)" "dagitim listesi"

it "the screen reached with nothing selected is a defect, and runs nothing"
zro_sel_clear
: >"$ZRO_MOCK_LOG"
: >"$ZRO_UI_OUT"
said=$(zro_screen_mailbox mailbox-status 2>&1 >/dev/null)
assert_contains "$said" "menu defect"
assert_contains "$(transcript)" "Ic hata"
assert_eq "$(ran | grep -c '^zmprov')" "0"

it "an operation with no label is a defect before anything is queried"
zro_sel_set "$ADDR"
: >"$ZRO_UI_OUT"
: >"$ZRO_MOCK_LOG"
said=$(zro_screen_mailbox mailbox-nonesuch 2>&1 >/dev/null)
assert_contains "$said" "no label for mailbox operation"
assert_contains "$(transcript)" "Ic hata"
assert_eq "$(ran | grep -c '^zmprov')" "0"

it "and so is one this list declares and this file does not answer"
# The other half of the same equality, and the half a label cannot show. Without
# the branch that catches it, the report variable would still hold the PREVIOUS
# answer — an old proof of existence read as the answer to a question nobody asked.
exists_server
zro_sel_set "$ADDR"
: >"$ZRO_UI_OUT"
ZRO_MENU_OPS_REAL=$ZRO_MENU_OPS
ZRO_MENU_OPS="mailbox-nowhere:account:2:Mailbox: cevapsiz"
said=$(zro_screen_mailbox mailbox-nowhere 2>&1 >/dev/null)
ZRO_MENU_OPS=$ZRO_MENU_OPS_REAL
assert_contains "$said" "no mailbox operation for"
assert_contains "$(transcript)" "Ic hata"
assert_not_contains "$(transcript)" "$ZRO_TXT_MBOX_EXISTS"

rm -f -- "$ZRO_MOCK_LOG" "$ZRO_UI_QUEUE" "$ZRO_UI_QUEUE.pos" "$ZRO_UI_OUT" \
         "$ZRO_MBOX_PROOF_FILE"
zro_t_report
