#!/usr/bin/env bash
# The search screens, driven through the stub UI backend: the criteria an operator
# builds a query out of, the answer, and the conversation they open from it.
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

# This file is about the search screens, not about what this host ships.
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
export ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt"

# The three answers a mailbox gives these screens, keyed as the mock keys them:
# the message search, the conversation search and the conversation listing.
export ZRO_MOCK_ZMMAILBOX_S__T_OUT="$FIX/zmmailbox_s_message_hits.txt"
export ZRO_MOCK_ZMMAILBOX_S__L_OUT="$FIX/zmmailbox_s_conversations.txt"
export ZRO_MOCK_ZMMAILBOX_SC__L_OUT="$FIX/zmmailbox_sc_messages.txt"

ADDR="ahmet.yilmaz@example.com"

queue() { printf '%s\n' "$@" >"$ZRO_UI_QUEUE"; zro_ui_reset; }
transcript() { cat "$ZRO_UI_OUT"; }
entries() { grep -F 'MENU Ana menu' "$ZRO_UI_OUT" | tail -n 1 | sed 's/^.*| //'; }
ran() { cat "$ZRO_MOCK_LOG"; }
opened() { ran | grep -c '^zmmailbox'; }
run() { : >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"; zro_mbox_forget; zro_menu_main; }

exists_server() {
  export ZRO_MOCK_ZMPROV_GIS_OUT="$FIX/zmprov_gis_ok.txt"
  unset ZRO_MOCK_ZMPROV_GIS_ERR ZRO_MOCK_ZMPROV_GIS_RC
}
no_mailbox_server() {
  unset ZRO_MOCK_ZMPROV_GIS_OUT
  export ZRO_MOCK_ZMPROV_GIS_ERR="$FIX/zmprov_gis_no_mailbox.err"
  export ZRO_MOCK_ZMPROV_GIS_RC=2
}

# ------------------------------------------------------------- the entries --

it "both screens are offered, about the account, at the cost of a read inside one mailbox"
zro_sel_clear
queue "__CANCEL__"
run
list=$(entries)
for id in mailbox-search mailbox-conversation; do
  assert_contains "$list" "$id"
  assert_out_eq "account" zro_menu_scope "$id"
  assert_out_eq "2" zro_menu_cost "$id"
done

it "and each says what it will spend before it spends it"
assert_contains "$(zro_mailbox_cost_note mailbox-search)" "BIR arama"
assert_contains "$(zro_mailbox_cost_note mailbox-conversation)" "her konusma icin"
# The gate's own sentence is on both, because both pay it.
assert_contains "$(zro_mailbox_cost_note mailbox-search)" "kapi bir sorgu daha ekler"

# --------------------------------------------------------- building a query --

it "offers every declared criterion on the criteria screen"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-search" "__CANCEL__" "__CANCEL__"
run
out=$(transcript)
for id in sender sender-domain recipient env-sender env-recipient subject msgid \
          day day-from day-to attachment-name attachment-type state folder scope; do
  assert_contains "$out" "$id"
done
assert_contains "$out" "ARAMAYI CALISTIR"

it "and runs nothing until the operator asks it to"
assert_eq "$(opened)" "0"

it "builds a query out of the criteria and searches once"
exists_server
zro_sel_set "$ADDR"
# subject → a value → run → leave the result → leave the criteria screen.
queue "mailbox-search" "subject" "temmuz faturasi" "__run__" "__CANCEL__" "__CANCEL__"
run
out=$(transcript)
assert_contains "$(ran)" "$(printf 's\t-t\tmessage\t-l\t%s\tsubject:"temmuz faturasi"' "$ZRO_SEARCH_LIMIT")"
assert_contains "$out" 'Sorgu                : subject:"temmuz faturasi"'
assert_cost mailbox-search "$(opened)" 1

it "and renders each hit with its identifier"
assert_contains "$out" "264"
assert_contains "$out" "Ynt: Temmuz faturasi"
assert_contains "$out" "ADRES DEGILDIR"

it "and the criteria stay on the screen so a second search is an edit"
# The value the operator gave is offered back as the criterion's label, which is
# what makes adding one more criterion an edit rather than a retyping.
assert_contains "$out" "Konu = temmuz faturasi"

it "combines several criteria into one query, and still runs once"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-search" "sender" "ali@example.com" "state" "unread" "folder" "/Inbox" \
      "__run__" "__CANCEL__" "__CANCEL__"
run
assert_contains "$(ran)" 'from:"ali@example.com" is:unread in:"/Inbox"'
assert_cost mailbox-search "$(opened)" 1

it "and a criterion chosen twice replaces its own value rather than asking twice"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-search" "sender" "ali@example.com" "sender" "veli@example.com" \
      "__run__" "__CANCEL__" "__CANCEL__"
run
assert_contains "$(ran)" 'from:"veli@example.com"'
assert_not_contains "$(ran)" 'ali@example.com'

it "and the criteria can be cleared"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-search" "sender" "ali@example.com" "__clear__" "__run__" "__CANCEL__"
run
out=$(transcript)
assert_eq "$(opened)" "0"
assert_contains "$out" "Olcut yok"

it "refuses to search with no criterion at all rather than sending an empty query"
# The server answers an empty query with a parse error, which would reach the
# operator as this tool having failed at asking nothing.
exists_server
zro_sel_set "$ADDR"
queue "mailbox-search" "__run__" "__CANCEL__"
run
assert_contains "$(transcript)" "Arama en az bir olcutle calisir"
assert_eq "$(opened)" "0"

it "refuses a value that would terminate its own quoting, and says why"
# THE ESCAPING DEBT AS THE OPERATOR MEETS IT. Nothing runs, and the screen names
# the backslash rather than reporting an invalid input in general terms.
exists_server
zro_sel_set "$ADDR"
# $'…' rather than '…': in single quotes a trailing backslash reads like an
# attempt to escape the quote, to a reader and to ShellCheck alike.
queue "mailbox-search" "subject" $'temmuz faturasi\\' "__CANCEL__" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "Gecersiz girdi"
assert_contains "$out" "TERS BOLU ILE BITEMEZ"
assert_eq "$(opened)" "0"

it "and a rejected value leaves the criterion unset rather than half set"
assert_not_contains "$(transcript)" "Konu = temmuz"

it "warns about the envelope criteria before the value is asked for"
# Their empty answer is not evidence: on the laboratory server they matched
# nothing even for messages whose envelope was exactly the address searched for.
exists_server
zro_sel_set "$ADDR"
queue "mailbox-conversation" "env-sender" "__CANCEL__" "__CANCEL__"
run
assert_contains "$(transcript)" "Zarf alanlari"
assert_contains "$(transcript)" "bu sunucuda aranamiyor"

it "and warns about the attachment criteria too, in the other direction"
# The research doc claims this screen says it, so the claim is held to a case. The
# two warnings must not read alike: the envelope pair was MEASURED answering
# nothing, while the attachment pair was never run against a message carrying an
# attachment at all. An unmeasured gap presented as a measured one is a finding
# nobody made.
exists_server
zro_sel_set "$ADDR"
queue "mailbox-search" "attachment-type" "__CANCEL__" "__CANCEL__" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "Ek olcutleri"
assert_contains "$out" "OLCULMEDI"
assert_not_contains "$out" "bu sunucuda aranamiyor"

it "and the attachment name carries the same warning as the type"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-search" "attachment-name" "__CANCEL__" "__CANCEL__" "__CANCEL__"
run
assert_contains "$(transcript)" "Ek olcutleri"

it "offers the read state and the attachment type as menus rather than as prompts"
# Nothing an operator types reaches `is:` or `attachment:`: what comes back is one
# of the words in a table this program drew.
exists_server
zro_sel_set "$ADDR"
queue "mailbox-search" "state" "unread" "attachment-type" "pdf" "__run__" "__CANCEL__" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "Okunmamis"
assert_contains "$out" "PDF"
assert_contains "$(ran)" 'is:unread attachment:pdf'

# ----------------------------------------------------------- the answers --

it "renders a search with no hits as a result rather than as a failure"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-search" "subject" "yokboyle" "__run__" "__CANCEL__" "__CANCEL__"
ZRO_MOCK_ZMMAILBOX_S__T_OUT="$FIX/zmmailbox_s_no_hits.txt" run
out=$(transcript)
assert_contains "$out" "Bu sorguya uyan ileti bulunamadi"
assert_contains "$out" "bir sonuc"
assert_not_contains "$out" "MSG Islem basarisiz"

it "reports a folder criterion the mailbox does not have as its own screen"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-search" "folder" "/YokBoyleKlasor" "__run__" "__CANCEL__" "__CANCEL__"
ZRO_MOCK_ZMMAILBOX_S__T_OUT="" ZRO_MOCK_ZMMAILBOX_S__T_ERR="$FIX/zmmailbox_s_no_such_folder.err" \
  ZRO_MOCK_ZMMAILBOX_S__T_RC=2 run
out=$(transcript)
assert_contains "$out" "Klasor bulunamadi"
assert_contains "$out" "no such folder path"

it "reports a query the server refuses as a defect in this tool, with the query in it"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-search" "subject" "fatura" "__run__" "__CANCEL__" "__CANCEL__"
ZRO_MOCK_ZMMAILBOX_S__T_OUT="" ZRO_MOCK_ZMMAILBOX_S__T_ERR="$FIX/zmmailbox_s_query_parse_error.err" \
  ZRO_MOCK_ZMMAILBOX_S__T_RC=2 run
out=$(transcript)
assert_contains "$out" "Sorgu reddedildi"
assert_contains "$out" 'subject:"fatura"'

it "and an account with no mailbox is answered by the gate, not by a failure box"
no_mailbox_server
zro_sel_set "$ADDR"
queue "mailbox-search" "subject" "fatura" "__run__" "__CANCEL__" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "$ZRO_TXT_MBOX_NONE"
assert_contains "$out" "BU ARAC MAILBOXU"
assert_eq "$(opened)" "0"

# ------------------------------------------------------ the conversations --

it "the conversation search offers the conversations it found"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-conversation" "subject" "fatura" "__run__" "__CANCEL__" "__CANCEL__" "__CANCEL__"
run
out=$(transcript)
assert_contains "$(ran)" "$(printf 's\t-l\t%s\tsubject:"fatura"' "$ZRO_SEARCH_LIMIT")"
assert_not_contains "$(ran)" "$(printf 's\t-t\tmessage')"
assert_contains "$out" "265"
assert_contains "$out" "Konusma secin"

it "and opening one lists the messages in it, for one query more"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-conversation" "subject" "fatura" "__run__" "1" "__CANCEL__" "__CANCEL__" "__CANCEL__"
run
out=$(transcript)
assert_contains "$(ran)" "$(printf 'sc\t-l\t%s\t265\tis:anywhere' "$ZRO_SEARCH_LIMIT")"
assert_contains "$out" "Konusma id           : 265"
assert_contains "$out" "264"
assert_contains "$out" "262"
# One search and one listing: the multiple this screen declares.
assert_cost mailbox-conversation "$(opened)" 1 2

it "and a one-message conversation is answered without asking the server anything"
# Its id is the negation of the message's id, and this tool will not put a value
# beginning with a minus on a command line. The second row of the fixture is one.
exists_server
zro_sel_set "$ADDR"
queue "mailbox-conversation" "subject" "fatura" "__run__" "2" "__CANCEL__" "__CANCEL__" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "tek ileti"
assert_contains "$out" "Ileti id             : 263"
assert_not_contains "$(ran)" "$(printf 'sc\t')"
assert_cost mailbox-conversation "$(opened)" 1

it "and a position that is not on the list names nothing"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-conversation" "subject" "fatura" "__run__" "99" "__CANCEL__" "__CANCEL__" "__CANCEL__"
run
assert_not_contains "$(ran)" "$(printf 'sc\t')"

it "and a conversation the server no longer has is an answer rather than a failure"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-conversation" "subject" "fatura" "__run__" "1" "__CANCEL__" "__CANCEL__" "__CANCEL__"
ZRO_MOCK_ZMMAILBOX_SC__L_OUT="" ZRO_MOCK_ZMMAILBOX_SC__L_ERR="$FIX/zmmailbox_sc_no_such_conv.err" \
  ZRO_MOCK_ZMMAILBOX_SC__L_RC=2 run
out=$(transcript)
assert_contains "$out" "$ZRO_TXT_SEARCH_NO_CONV"
assert_not_contains "$out" "MSG Islem basarisiz"

it "the operator is told a query is running before the wait begins"
exists_server
zro_sel_set "$ADDR"
queue "mailbox-search" "subject" "fatura" "__run__" "__CANCEL__" "__CANCEL__"
run
notice_line=$(grep -n "bekleyin" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
result_line=$(grep -n "Sunucunun bildirdigi" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
assert_eq "$([ "$notice_line" -lt "$result_line" ] && printf yes || printf no)" "yes"

it "and leaving the screen leaves no criterion behind for the next one"
# The criteria belong to the screen, not to the session: an operator who comes
# back and starts again is starting again, and a query carrying a criterion they
# cannot see is the one thing a query builder must never do.
exists_server
zro_sel_set "$ADDR"
queue "mailbox-search" "sender" "ali@example.com" "__CANCEL__" \
      "mailbox-search" "subject" "fatura" "__run__" "__CANCEL__" "__CANCEL__"
run
assert_contains "$(ran)" 'subject:"fatura"'
assert_not_contains "$(ran)" 'from:"ali@example.com"'

zro_t_report
