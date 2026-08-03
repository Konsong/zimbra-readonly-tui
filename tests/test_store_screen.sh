#!/usr/bin/env bash
# The screens behind the existence gate, driven through the stub UI backend: the
# folder listing, one folder, one folder's grants, the mailbox size and quota
# usage — and what each of them does when the gate says there is no mailbox.
set -uo pipefail
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

# This file is about the mailbox screens, not about what this host ships.
export ZRO_CAP_FORCE_TRACE_BIN=yes
export ZRO_CAP_FORCE_TRACE_LOG=ok
# And the queue's, for the same reason: whether the machine running the suite
# ships a mail transfer agent has nothing to say about the cases below.
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
export ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt"

# The mailbox, as the lab server answered for it.
export ZRO_MOCK_ZMMAILBOX_GAF_OUT="$FIX/zmmailbox_gaf_ok.txt"
export ZRO_MOCK_ZMMAILBOX_GF_OUT="$FIX/zmmailbox_gf_inbox.txt"
export ZRO_MOCK_ZMMAILBOX_GFG_OUT="$FIX/zmmailbox_gfg_grants.txt"
export ZRO_MOCK_ZMMAILBOX_GMS__V_OUT="$FIX/zmmailbox_gms_bytes.txt"

ADDR="ahmet.yilmaz@example.com"

queue() { printf '%s\n' "$@" >"$ZRO_UI_QUEUE"; zro_ui_reset; }
transcript() { cat "$ZRO_UI_OUT"; }
entries() { grep -F 'MENU Ana menu' "$ZRO_UI_OUT" | tail -n 1 | sed 's/^.*| //'; }
ran() { cat "$ZRO_MOCK_LOG"; }
opened() { ran | grep -c '^zmmailbox'; }
run() { : >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"; zro_mbox_forget; zro_menu_main; }

# The three answers the gate can give, as three servers.
exists_server() {
  export ZRO_MOCK_ZMPROV_GIS_OUT="$FIX/zmprov_gis_ok.txt"
  unset ZRO_MOCK_ZMPROV_GIS_ERR ZRO_MOCK_ZMPROV_GIS_RC
}
no_mailbox_server() {
  unset ZRO_MOCK_ZMPROV_GIS_OUT
  export ZRO_MOCK_ZMPROV_GIS_ERR="$FIX/zmprov_gis_no_mailbox.err"
  export ZRO_MOCK_ZMPROV_GIS_RC=2
}
outage_server() {
  unset ZRO_MOCK_ZMPROV_GIS_OUT
  export ZRO_MOCK_ZMPROV_GIS_ERR="$FIX/zmprov_io_error_refused.err"
  export ZRO_MOCK_ZMPROV_GIS_RC=1
}

# ------------------------------------------------------------- the entries --

it "all five screens are offered, and every one of them is about the account"
zro_sel_clear
queue "__CANCEL__"
run
list=$(entries)
for id in mailbox-quota mailbox-size mailbox-folders mailbox-folder mailbox-folder-grants; do
  assert_contains "$list" "$id"
  assert_out_eq "account" zro_menu_scope "$id"
done

it "and every one of them declares the class of a read inside one mailbox"
# Class 2, whose unit is a MAILBOX. The quota screen reads the directory as well,
# and is still class 2: what its work grows with is mailboxes, and one account is
# one mailbox however large the directory around it gets.
for id in mailbox-quota mailbox-size mailbox-folders mailbox-folder mailbox-folder-grants; do
  assert_out_eq "2" zro_menu_cost "$id"
done

# --------------------------------------------------------- the folder list --

it "the folder listing renders every folder with its counts"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-folders" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "/Inbox"
assert_contains "$out" "/Emailed Contacts"
assert_contains "$out" "Klasor sayisi        : 15"
assert_contains "$out" "/Projeler/2026/Q3 Raporlar"
assert_contains "$out" "Toplam oge           : 2"
assert_contains "$out" "Okunmamis            : 1"

it "and it costs one read of one mailbox"
assert_cost mailbox-folders "$(opened)" 1

it "and the operator is told a query is running before the wait begins"
notice_line=$(grep -n "bekleyin" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
result_line=$(grep -n "Klasor sayisi" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
assert_eq "$([ "$notice_line" -lt "$result_line" ] && printf yes || printf no)" "yes"

# ------------------------------------------------------- the mailbox size --

it "the size screen renders bytes and the human form together"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-size" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "700 B (700 bayt)"

it "and it asked the server for raw bytes rather than for a formatted string"
# The whole locale hazard in one assertion: what reaches the screen is formatted
# HERE, from a number, and never by a JVM whose decimal separator depends on the
# host's locale.
assert_contains "$(ran)" "$(printf 'gms\t-v')"
assert_cost mailbox-size "$(opened)" 1

it "and a size the server answered in the formatted form is a field, not a failure"
# If anything ever answers this read in the human shape, the field says the value
# could not be read and the screen explains why. Reporting 1,44 GB as 144 GB is
# what that prevents, and it would be invisible on the screen.
#
# 'bilinmiyor' rather than a failure box, because this is a fact about THIS
# PROGRAM — it refuses to guess at a decimal separator — and the screen it belongs
# to still has something to say.
exists_server
zro_sel_set "$ADDR"
queue "mailbox-size" "__CANCEL__"
ZRO_MOCK_ZMMAILBOX_GMS__V_OUT="$FIX/zmmailbox_gms_synthetic_locale.txt" run
out=$(transcript)
assert_contains "$out" "Boyut                : $ZRO_TXT_UNKNOWN"
assert_not_contains "$out" "MSG Sonuc yok"
assert_not_contains "$out" "144"
assert_not_contains "$out" "1,44"

it "and on the quota screen it does not take the limit down with it"
# Half an answer is still an answer: the limit was read and is worth showing, and
# the proportion is the one thing that cannot be computed from it alone.
exists_server
zro_sel_set "$ADDR"
queue "mailbox-quota" "__CANCEL__"
ZRO_MOCK_ZMMAILBOX_GMS__V_OUT="$FIX/zmmailbox_gms_synthetic_locale.txt" run
out=$(transcript)
assert_contains "$out" "Kota limiti          : 5.0 GB"
assert_contains "$out" "Kullanilan           : $ZRO_TXT_UNKNOWN"
assert_contains "$out" "kullanim okunamadi"
assert_not_contains "$out" "Doluluk              : %0"

# ----------------------------------------------------------- quota usage --

it "quota usage renders as a proportion of the limit the account card shows"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-quota" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "Kota limiti          : 5.0 GB"
assert_contains "$out" "Kullanilan           : 700 B (700 bayt)"
assert_contains "$out" "%1'den az"

it "and an unlimited limit is said in words rather than divided into"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-quota" "__CANCEL__"
ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_locked.txt" run
out=$(transcript)
assert_contains "$out" "sinirsiz"
assert_contains "$out" "oran yok"

it "and nothing here runs the whole-server quota command"
# It takes a server, not an account, and answers for every account on it: the
# class 4 sweep this tool does not have. Asserted against the transcript of a real
# run rather than against the source.
assert_not_contains "$(ran)" "$(printf '\tgqu')"
assert_not_contains "$(ran)" "getQuotaUsage"
assert_not_contains "$(ran)" "$(printf '\tgmi')"

# -------------------------------------------------- one folder, and its grants --

it "a folder is chosen from the listing this program read, by position"
exists_server
zro_sel_set "$ADDR"
# The listing is drawn, position 8 is /Inbox, then the menu is left.
queue "mailbox-folder" "8" "__CANCEL__" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "MENU Klasor detayi"
assert_contains "$out" "/Inbox (1 oge, 1 okunmamis)"
assert_contains "$out" "Boyut                : 353 B (353 bayt)"

it "and that costs the listing plus the folder: two reads of one mailbox"
# THE MULTIPLE IS DECLARED, NOT ABSORBED. One mailbox is the unit; a screen that
# offers a folder before it can read one pays twice for it, and says so before it
# runs.
assert_cost mailbox-folder "$(opened)" 1 2

it "and the path the operator picked is what was asked for, whole"
assert_contains "$(ran)" "$(printf 'gf\t/Inbox')"

it "a second folder in the same visit does not re-read the listing"
# The folders of a mailbox do not change while somebody is reading one of them.
exists_server
zro_sel_set "$ADDR"
queue "mailbox-folder" "8" "9" "__CANCEL__" "__CANCEL__"
run
# Counted off the lines the BINARY recorded, not off every line in the log: the
# timeout wrapper records the vector it is about to run as well, so a count taken
# over the whole file reports every invocation twice.
assert_eq "$(ran | grep '^zmmailbox' | grep -c "$(printf '\tgaf')")" "1"
assert_eq "$(ran | grep '^zmmailbox' | grep -c "$(printf '\tgf\t')")" "2"

it "the grants of a folder render, and every grant is shown"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-folder-grants" "8" "__CANCEL__" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "Paylasim sayisi      : 3"
assert_contains "$out" "yeni.kullanici@example.com"
assert_contains "$out" "tum-personel@example.com"
assert_contains "$out" "$ZRO_TXT_STORE_PUBLIC"
assert_contains "$(ran)" "$(printf 'gfg\t/Inbox')"

it "and a folder shared with nobody says so"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-folder-grants" "8" "__CANCEL__" "__CANCEL__"
ZRO_MOCK_ZMMAILBOX_GFG_OUT="$FIX/zmmailbox_gfg_none.txt" run
assert_contains "$(transcript)" "$ZRO_TXT_STORE_NO_GRANTS"

it "a path the server refuses is explained, and the listing is still there"
# The likeliest cause is not a mistake the operator made: a search folder, a
# mountpoint and a feed each carry a parenthesised decoration inside the path
# column, and none of it is part of the path.
exists_server
zro_sel_set "$ADDR"
queue "mailbox-folder" "8" "__CANCEL__" "__CANCEL__"
ZRO_MOCK_ZMMAILBOX_GF_ERR="$FIX/zmmailbox_unknown_folder.err" \
ZRO_MOCK_ZMMAILBOX_GF_RC=2 run
out=$(transcript)
assert_contains "$out" "MSG Klasor bulunamadi"
assert_contains "$out" "mountpoint"
# Returned to the folder list rather than to the main menu: the operator picked a
# folder, not an operation.
assert_contains "$out" "MENU Klasor detayi"

# ------------------------------------------ an account with no mailbox --

it "an account with no mailbox gets the result screen on every one of these"
# THE ACCEPTANCE CRITERION THE WHOLE GATE EXISTS FOR. The read never ran, and what
# the operator is shown is the answer — a mailbox is created on first login or
# first delivery — rather than a failure box saying 'Mailbox bulunamadi'.
for id in mailbox-quota mailbox-size mailbox-folders mailbox-folder mailbox-folder-grants; do
  no_mailbox_server
  zro_sel_set "$ADDR"
  queue "$id" "__CANCEL__"
  run
  out=$(transcript)
  assert_contains "$out" "$ZRO_TXT_MBOX_NONE"
  assert_contains "$out" "TEXT $(zro_menu_label "$id")"
  assert_not_contains "$out" "MSG Bulunamadi"
  assert_not_contains "$out" "MSG Hata"
  # And the binary that would have created one was never reached.
  assert_eq "$(opened)" "0"
done

it "and that screen still says this tool will not create one"
assert_contains "$(transcript)" "YARATMAZ"

it "an address that is no account is told apart from a mailbox that is missing"
unset ZRO_MOCK_ZMPROV_GIS_OUT
export ZRO_MOCK_ZMPROV_GIS_ERR="$FIX/zmprov_gis_no_such_account.err"
export ZRO_MOCK_ZMPROV_GIS_RC=2
zro_sel_set "yok@example.com"
queue "mailbox-folders" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "$ZRO_TXT_MBOX_NO_ACCOUNT"
assert_not_contains "$out" "$ZRO_TXT_MBOX_NONE"
assert_eq "$(opened)" "0"

it "a mailbox service that does not answer refuses every one of them by name"
for id in mailbox-quota mailbox-size mailbox-folders mailbox-folder; do
  outage_server
  zro_sel_set "$ADDR"
  queue "$id" "__CANCEL__"
  run
  out=$(transcript)
  assert_contains "$out" "MSG Mailbox sorusu yanitlanamiyor"
  assert_eq "$(opened)" "0"
done

# ------------------------------------------------------------ the guarantee --

it "no screen here runs a command that would change a mailbox"
# Asserted against the transcript of real runs rather than against the source: the
# four subcommands that reach the binary are the four the allowlist approves, and
# nothing else was even attempted.
exists_server
zro_sel_set "$ADDR"
queue "mailbox-folders" "mailbox-size" "mailbox-quota" "mailbox-folder" "8" \
      "__CANCEL__" "mailbox-folder-grants" "8" "__CANCEL__" "__CANCEL__"
run
log=$(ran | grep '^zmmailbox')
assert_eq "$(printf '%s\n' "$log" | grep -c "$(printf '\t-z\t-m\t')")" "$(opened)"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  sub=$(printf '%s' "$line" | cut -f5)
  case $sub in
    gaf|gf|gfg|gms) zro_t_pass ;;
    *) zro_t_fail "a screen ran an unapproved mailbox subcommand: $sub" ;;
  esac
done <<EOF
$log
EOF

it "and every one of those reads was preceded by the oracle in this session"
# Order asserted rather than assumed: a mailbox opened before the oracle answered
# would create the mailbox it was asked to describe.
assert_contains "$(ran | grep -E '^(zmprov|zmmailbox)' | head -n 1)" \
  "$(printf 'zmprov\tgis')"

it "and the proof is paid for once, however many screens are opened"
# The gate keeps a yes for the session, so five mailbox screens cost one oracle
# read between them.
assert_eq "$(ran | grep -c "$(printf '^zmprov\tgis')")" "1"

rm -f -- "$ZRO_MOCK_LOG" "$ZRO_UI_QUEUE" "$ZRO_UI_QUEUE.pos" "$ZRO_UI_OUT" \
         "$ZRO_MBOX_PROOF_FILE"
zro_t_report
