#!/usr/bin/env bash
# The message detail screen, driven through the stub UI backend: the identifier an
# operator types, the record and headers they get back, and the four endings that are
# not a failure box.
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

# This file is about one screen, not about what this host ships.
export ZRO_CAP_FORCE_TRACE_BIN=yes
export ZRO_CAP_FORCE_TRACE_LOG=ok
export ZRO_CAP_FORCE_QUEUE_BIN=yes

ZRO_MBOX_PROOF_FILE=$(mktemp); export ZRO_MBOX_PROOF_FILE

# THE STORE ROOT IS DECLARED BEFORE THE PROGRAM IS SOURCED, because the module reads
# the override at load time exactly as every other root does. The blob path the dump
# fixture carries is the production one, so it is rewritten into this tree below.
STORE=$(mktemp -d)
export ZRO_STORE_ROOT="$STORE"

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

BLOB_DIR="$STORE/0/9/msg/0"
mkdir -p "$BLOB_DIR"
BLOB="$BLOB_DIR/274-778.msg"
cp -- "$FIX/store_blob_multipart.msg" "$BLOB"
DUMP="$STORE/dump-274.txt"
sed "s|^/opt/zimbra/store/.*|$BLOB|" "$FIX/zmmetadump_message.txt" >"$DUMP"
export ZRO_MOCK_ZMMETADUMP_274_OUT="$DUMP"

ADDR="ahmet.yilmaz@example.com"

queue() { printf '%s\n' "$@" >"$ZRO_UI_QUEUE"; zro_ui_reset; }
transcript() { cat "$ZRO_UI_OUT"; }
entries() { grep -F 'MENU Ana menu' "$ZRO_UI_OUT" | tail -n 1 | sed 's/^.*| //'; }
ran() { cat "$ZRO_MOCK_LOG"; }
# What this screen spends: the dump, and the two reads of the blob. The version read
# on the main menu is not this screen's.
spent() { ran | grep -cE '^(zmmetadump|head|gzip)'; }
run() { : >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"; zro_mbox_forget; zro_menu_main; }

# ------------------------------------------------------------- the entry --

it "the screen is offered, about the account, at the cost of a read inside one mailbox"
zro_sel_clear
queue "__CANCEL__"
run
assert_contains "$(entries)" "mailbox-message"
assert_out_eq "account" zro_menu_scope mailbox-message
assert_out_eq "2" zro_menu_cost mailbox-message

it "and it says what it will spend, and that the gate is not part of it"
note=$(zro_mailbox_cost_note mailbox-message)
assert_contains "$note" "UC calistirma"
assert_contains "$note" "MAILBOX OTURUMU ACILMAZ"
assert_not_contains "$note" "kapi bir sorgu daha ekler"

# ------------------------------------------------------- asking for an id --

it "asks for an identifier and runs nothing until it has one"
zro_sel_set "$ADDR"
queue "mailbox-message" "__CANCEL__"
run
assert_contains "$(transcript)" "INPUT Ileti detayi"
assert_contains "$(transcript)" "Ileti id"
assert_eq "$(spent)" "0"

it "refuses a value that is not an item id, and still runs nothing"
# Digits and nothing else: a negative value is the id of a single-message
# CONVERSATION, and a token beginning with a dash may not reach a command line.
zro_sel_set "$ADDR"
for bad in "abc" "-274" "0" "27 4"; do
  queue "mailbox-message" "$bad" "__CANCEL__" "__CANCEL__"
  run
  assert_contains "$(transcript)" "Gecersiz girdi"
  assert_eq "$(spent)" "0"
done

it "and the refusal says what a negative value really is"
assert_contains "$(transcript)" "tek iletilik bir konusmanin kimligidir"

# --------------------------------------------------------------- the answer --

it "renders the record and the headers of the message it was asked for"
zro_sel_set "$ADDR"
queue "mailbox-message" "274" "__CANCEL__" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "Ileti id             : 274"
assert_contains "$out" "Konu                 : Ekli ileti: temmuz faturasi"
assert_contains "$out" "From                 : Ali Veli <ali.veli@example.org>"
assert_contains "$out" "Cc                   : bilgi-islem@example.com, Ayse Demir <ayse.demir@example.com>"
assert_contains "$out" "fatura.pdf"
assert_contains "$out" "HAM BASLIKLAR"

it "and asks the dump for that item by address, and the blob head for that path"
assert_contains "$(ran)" "$(printf 'zmmetadump\t-m\t%s\t-i\t274' "$ADDR")"
assert_contains "$(ran)" "$(printf 'head\t-c\t2\t%s' "$BLOB")"
assert_contains "$(ran)" "$(printf 'head\t-c\t%s\t%s' "$ZRO_MSG_HEAD_BYTES" "$BLOB")"

it "and spends exactly what its cost note declared"
assert_cost mailbox-message "$(spent)" 1 3

it "and opens no mailbox session and pays no existence gate"
# THE REASON THIS SCREEN NEEDS NO GATE, asserted rather than described: the dump
# reads the database directly, so nothing here can create a mailbox for an account
# that has none — and the oracle has nothing to add.
assert_eq "$(ran | grep -c '^zmmailbox')" "0"
assert_eq "$(ran | grep -c 'gis')" "0"

it "and displays no part of the message body"
assert_not_contains "$out" "Govde metni"
assert_not_contains "$out" "JVBERi0xLjQK"
assert_contains "$out" "ILETI GOVDESI GOSTERILMEZ"

it "and the operator is told a read is running before the wait begins"
notice_line=$(grep -n "bekleyin" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
result_line=$(grep -n "HAM BASLIKLAR" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
assert_eq "$([ "$notice_line" -lt "$result_line" ] && printf yes || printf no)" "yes"

it "and the id just read is offered back, so the next one is an edit"
zro_sel_set "$ADDR"
queue "mailbox-message" "274" "__CANCEL__" "__CANCEL__"
run
# Two prompts: the one that was answered and the one after the answer. The stub
# records a default at the END of the prompt it belongs to, and this prompt's text
# runs over several lines — so the second one is the line the default hangs off.
assert_eq "$(grep -c '^INPUT' "$ZRO_UI_OUT")" "2"
assert_eq "$(grep -c ' | 274$' "$ZRO_UI_OUT")" "1"

it "reads a compressed blob through the decompress-to-stdout form, for one read more"
zro_sel_set "$ADDR"
GZ_DUMP="$STORE/dump-gz.txt"
GZBLOB="$BLOB_DIR/280-800.msg"
gzip -c "$FIX/store_blob_multipart.msg" >"$GZBLOB"
before=$(cksum <"$GZBLOB")
sed "s|^/opt/zimbra/store/.*|$GZBLOB|" "$FIX/zmmetadump_message.txt" >"$GZ_DUMP"
queue "mailbox-message" "274" "__CANCEL__" "__CANCEL__"
ZRO_MOCK_ZMMETADUMP_274_OUT="$GZ_DUMP" run
out=$(transcript)
assert_contains "$out" "From                 : Ali Veli <ali.veli@example.org>"
assert_contains "$(ran)" "$(printf 'gzip\t-dc\t%s' "$GZBLOB")"
# Nothing was written: the file is byte-identical and still there.
assert_eq "$(cksum <"$GZBLOB")" "$before"
assert_cost mailbox-message "$(spent)" 1 4

# ------------------------------------------------------ the other endings --

it "reports an id this mailbox does not hold as its own result screen"
zro_sel_set "$ADDR"
queue "mailbox-message" "274" "__CANCEL__" "__CANCEL__"
ZRO_MOCK_ZMMETADUMP_274_OUT="" ZRO_MOCK_ZMMETADUMP_274_ERR="$FIX/zmmetadump_no_such_item.err" \
  ZRO_MOCK_ZMMETADUMP_274_RC=1 run
out=$(transcript)
assert_contains "$out" "Ileti bulunamadi"
assert_contains "$out" "bir sonuc"
assert_contains "$out" "HER MAILBOXA OZELDIR"
assert_not_contains "$out" "MSG Islem basarisiz"

it "reports a mailbox this host does not carry as the two answers it really is"
zro_sel_set "$ADDR"
queue "mailbox-message" "274" "__CANCEL__" "__CANCEL__"
ZRO_MOCK_ZMMETADUMP_274_OUT="" ZRO_MOCK_ZMMETADUMP_274_ERR="$FIX/zmmetadump_not_on_host.err" \
  ZRO_MOCK_ZMMETADUMP_274_RC=1 run
out=$(transcript)
assert_contains "$out" "Mailbox bu sunucuda yok"
assert_contains "$out" "IKI ANLAMA GELIR"
assert_contains "$out" "not found on this host"

it "reports the clock running out with the reason the dump needs one"
zro_sel_set "$ADDR"
queue "mailbox-message" "274" "__CANCEL__" "__CANCEL__"
ZRO_MOCK_TIMEOUT_FIRE=1 run
out=$(transcript)
assert_contains "$out" "Zaman asimi"
# The measured cadence, which is what makes the sentence more than a guess: one retry
# every five seconds, for as long as it is left alone.
assert_contains "$out" "bes saniyede bir"
assert_contains "$out" "mysql (mailbox veritabani) servisi"

it "and a database outage reaches that screen with the server's own words in it"
# THE SHAPE MEASURED ON THE LAB SERVER with mysqld stopped: the retries go to STDOUT,
# stderr stays empty, and the clock ends it. What the operator must NOT be given is
# the shared box about mailboxd and an admin certificate — this read talks to neither.
zro_sel_set "$ADDR"
queue "mailbox-message" "274" "__CANCEL__" "__CANCEL__"
ZRO_MOCK_ZMMETADUMP_274_OUT="$FIX/zmmetadump_db_down.txt" ZRO_MOCK_ZMMETADUMP_274_RC=124 run
out=$(transcript)
assert_contains "$out" "Zaman asimi"
assert_contains "$out" "Could not establish a connection to the database"
assert_not_contains "$out" "zmcertmgr"

it "and a failure it does not recognise names the database rather than mailboxd"
zro_sel_set "$ADDR"
queue "mailbox-message" "274" "__CANCEL__" "__CANCEL__"
ZRO_MOCK_ZMMETADUMP_274_OUT="$FIX/zmmetadump_db_down.txt" ZRO_MOCK_ZMMETADUMP_274_RC=1 run
out=$(transcript)
assert_contains "$out" "Mailbox veritabani okunamadi"
assert_contains "$out" "getting database connection"
assert_not_contains "$out" "zmcertmgr"
assert_not_contains "$out" "admin sertifikasi gecersiz"

it "draws the record of an item with no blob, and says the path is absent"
zro_sel_set "$ADDR"
queue "mailbox-message" "2" "__CANCEL__" "__CANCEL__"
ZRO_MOCK_ZMMETADUMP_2_OUT="$FIX/zmmetadump_folder.txt" run
out=$(transcript)
assert_contains "$out" "Konu                 : Inbox"
assert_contains "$out" "blob_digest degeri bos"
# The blob was not opened, so the head read never happened.
assert_eq "$(ran | grep -cE '^(head|gzip)')" "0"

it "refuses a blob path the dump reported outside the declared store root"
zro_sel_set "$ADDR"
OUT_DUMP="$STORE/dump-outside.txt"
sed "s|^/opt/zimbra/store/.*|/etc/shadow|" "$FIX/zmmetadump_message.txt" >"$OUT_DUMP"
queue "mailbox-message" "274" "__CANCEL__" "__CANCEL__"
ZRO_MOCK_ZMMETADUMP_274_OUT="$OUT_DUMP" run
out=$(transcript)
assert_contains "$out" "BLOB DOSYASI ACILMADI"
assert_contains "$out" "Tanimli blob koku    : $ZRO_STORE_ROOT"
assert_eq "$(ran | grep -cE '^(head|gzip)')" "0"

it "and cancelling the identifier prompt returns to the menu rather than leaving"
zro_sel_set "$ADDR"
queue "mailbox-message" "__CANCEL__" "account-card" "__CANCEL__"
run
assert_contains "$(transcript)" "Ahmet Yilmaz"

rm -rf -- "$STORE"
zro_t_report
