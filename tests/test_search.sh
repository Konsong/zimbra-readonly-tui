#!/usr/bin/env bash
# The message search and the conversation listing: the query this tool builds, the
# table it reads back, and the argument vector that proves neither of them can mark
# a message read.
#
# EVERY FIXTURE HERE CAME OFF THE LAB SERVER on 2026-08-03, with the names changed
# and the geometry kept. That geometry is the point: the search table's column
# widths are computed PER PAGE — a page of ten hits prints every column one
# character further right than a page of nine — so both were captured, and a reader
# built on fixed offsets fails against the wide one. See
# docs/research/2026-08-03-message-search-and-conversations.md.
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/table.sh
. "$ZRO_SRC/lib/table.sh"
# shellcheck source=../lib/validate.sh
. "$ZRO_SRC/lib/validate.sh"
# shellcheck source=../lib/window.sh
. "$ZRO_SRC/lib/window.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
export ZRO_MOCK_ID_USER=zimbra
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* 2>/dev/null || true

ZRO_MBOX_PROOF_FILE=$(mktemp); export ZRO_MBOX_PROOF_FILE

# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"
# shellcheck source=../lib/account.sh
. "$ZRO_SRC/lib/account.sh"
# shellcheck source=../lib/mailbox.sh
. "$ZRO_SRC/lib/mailbox.sh"
# shellcheck source=../lib/search.sh
. "$ZRO_SRC/lib/search.sh"

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG
FIX="$ZRO_TEST_ROOT/fixtures"

ACCT="ahmet.yilmaz@example.com"

HITS="$FIX/zmmailbox_s_message_hits.txt"
WIDE="$FIX/zmmailbox_s_message_wide.txt"
CAPPED="$FIX/zmmailbox_s_message_capped.txt"
NOHITS="$FIX/zmmailbox_s_no_hits.txt"
CONVS="$FIX/zmmailbox_s_conversations.txt"
SCMSG="$FIX/zmmailbox_sc_messages.txt"
PARSE_ERR="$FIX/zmmailbox_s_query_parse_error.err"
NOFOLDER_ERR="$FIX/zmmailbox_s_no_such_folder.err"
NOCONV_ERR="$FIX/zmmailbox_sc_no_such_conv.err"
BADID_ERR="$FIX/zmmailbox_sc_malformed_id.err"

ran() { cat "$ZRO_MOCK_LOG"; }
fresh() { : >"$ZRO_MOCK_LOG"; zro_mbox_forget; zro_clear_error; }

proven() {
  ZRO_MOCK_ZMPROV_GIS_OUT="$FIX/zmprov_gis_ok.txt" ZRO_MOCK_ZMPROV_GIS_RC=0 "$@"
}
no_mailbox() {
  ZRO_MOCK_ZMPROV_GIS_ERR="$FIX/zmprov_gis_no_mailbox.err" ZRO_MOCK_ZMPROV_GIS_RC=2 "$@"
}
outage() {
  ZRO_MOCK_ZMPROV_GIS_ERR="$FIX/zmprov_io_error_refused.err" ZRO_MOCK_ZMPROV_GIS_RC=1 "$@"
}

# The three answers a mailbox can give this module, keyed the way the mock keys
# them: the subcommand and the first flag behind it. The message search, the
# conversation search and the conversation listing are three different keys, which
# is what lets one case script one of them without answering for the others.
search_msg() { ZRO_MOCK_ZMMAILBOX_S__T_OUT="$1" ZRO_MOCK_ZMMAILBOX_S__T_RC="${2-0}" "${@:3}"; }
search_conv() { ZRO_MOCK_ZMMAILBOX_S__L_OUT="$1" ZRO_MOCK_ZMMAILBOX_S__L_RC="${2-0}" "${@:3}"; }
conv_msgs() { ZRO_MOCK_ZMMAILBOX_SC__L_OUT="$1" ZRO_MOCK_ZMMAILBOX_SC__L_RC="${2-0}" "${@:3}"; }
search_msg_err() { ZRO_MOCK_ZMMAILBOX_S__T_ERR="$1" ZRO_MOCK_ZMMAILBOX_S__T_RC="${2-2}" "${@:3}"; }
conv_msgs_err() { ZRO_MOCK_ZMMAILBOX_SC__L_ERR="$1" ZRO_MOCK_ZMMAILBOX_SC__L_RC="${2-2}" "${@:3}"; }

field() { printf '%s' "$1" | awk -F'\t' -v n="$2" '{print $n}'; }

# ------------------------------------------------------- the criteria table --

it "declares every criterion the ticket asks for, and each with a kind the builder implements"
# THE TWO SETS ARE HELD EQUAL IN BOTH DIRECTIONS, the way the allowlist and the
# table of binary roots are: a criterion whose kind nobody can build is a menu
# entry that refuses whatever is typed into it, and a kind nobody claims is a
# branch nobody reaches.
for id in sender sender-domain recipient env-sender env-recipient subject msgid \
          day day-from day-to attachment-name attachment-type state folder scope; do
  assert_ok zro_search_criterion "$id"
done
assert_status "$ZRO_E_INPUT" zro_search_criterion 'yokboyle'
assert_status "$ZRO_E_INPUT" zro_search_criterion ''

it "and every declared kind is one the term builder answers for"
kinds=$(while IFS= read -r id; do
          [ -n "$id" ] || continue
          zro_search_kind "$id"
          printf '\n'
        done <<EOF
$(zro_search_ids)
EOF
)
assert_eq "$(printf '%s\n' "$kinds" | sort -u | tr '\n' ' ')" \
          "address atype day dayend dayspan domain folder msgid scope state text "

it "and every kind can be asked for: it has a prompt, or it is a menu, or it takes no value"
# HELD EQUAL IN BOTH DIRECTIONS. A kind with neither a prompt nor a menu is a
# criterion an operator can select and nothing can ask them for; a prompt for a
# kind nobody claims is text nobody reads.
MENU_KINDS='state atype'
NOVALUE_KINDS='scope'
while IFS= read -r kind; do
  [ -n "$kind" ] || continue
  case " $MENU_KINDS $NOVALUE_KINDS " in
    *" $kind "*) zro_t_pass; continue ;;
  esac
  if prompt=$(zro_search_prompt "$kind") && [ -n "$prompt" ]; then
    zro_t_pass
  else
    zro_t_fail "criterion kind [$kind] has no prompt, no menu and no exemption"
  fi
done <<EOF
$(printf '%s\n' "$kinds" | sort -u)
EOF

it "and the prompt table declares nothing for a kind no criterion claims"
for kind in state atype scope yokboyle ''; do
  assert_status "$ZRO_E_INPUT" zro_search_prompt "$kind"
done

it "and a prompt that runs over several lines is read whole"
# The prompts say what the tool will do with what is typed, so most of them are a
# paragraph. An entry ends where the next DECLARED kind begins — the same rule the
# mail settings reader applies to a multi-line attribute — rather than at the first
# line that happens to carry a colon.
assert_contains "$(zro_search_prompt day)" 'milisaniye'
assert_contains "$(zro_search_prompt folder)" 'alt klasorleri kapsamaz'
assert_not_contains "$(zro_search_prompt folder)" 'Gun'
assert_contains "$(zro_search_prompt msgid)" 'koseli parantezler'
assert_not_contains "$(zro_search_prompt msgid)" 'Aranacak metin'

it "and each criterion carries the operator the query language really uses"
# Measured on the lab server, every one of them: research §7. The two envelope
# operators are here because they PARSE — what they matched on that server is a
# fact the screen discloses rather than a reason to leave them out.
assert_out_eq 'from' zro_search_operator sender
assert_out_eq 'from' zro_search_operator sender-domain
assert_out_eq 'to' zro_search_operator recipient
assert_out_eq 'envfrom' zro_search_operator env-sender
assert_out_eq 'envto' zro_search_operator env-recipient
assert_out_eq 'subject' zro_search_operator subject
assert_out_eq 'msgid' zro_search_operator msgid
# The single day names the first of the two operators it writes; `date:` is
# nowhere in this table, and the case below says why.
assert_out_eq 'after' zro_search_operator day
assert_eq "$ZRO_SEARCH_OP_DAY_END" 'before'
assert_out_eq 'after' zro_search_operator day-from
assert_out_eq 'before' zro_search_operator day-to
assert_out_eq 'filename' zro_search_operator attachment-name
assert_out_eq 'attachment' zro_search_operator attachment-type
assert_out_eq 'is' zro_search_operator state
assert_out_eq 'in' zro_search_operator folder
assert_out_eq 'is' zro_search_operator scope

# --------------------------------------------------------- building a term --

it "writes an address criterion as a quoted term"
assert_out_eq 'from:"ali@example.com"' zro_search_term sender 'ali@example.com'
assert_out_eq 'to:"ali@example.com"' zro_search_term recipient 'ali@example.com'
assert_out_eq 'envfrom:"ali@example.com"' zro_search_term env-sender 'ali@example.com'
assert_out_eq 'envto:"ali@example.com"' zro_search_term env-recipient 'ali@example.com'

it "and refuses anything that is not an address there"
assert_status "$ZRO_E_INPUT" zro_search_term sender 'example.com'
assert_status "$ZRO_E_INPUT" zro_search_term sender '-ali@example.com'
assert_status "$ZRO_E_INPUT" zro_search_term sender 'ali@example.com; id'
assert_status "$ZRO_E_INPUT" zro_search_term sender ''

it "writes a sending domain as the query language's own domain form, unquoted"
# The leading '@' is what makes this a whole-domain match rather than text, so it
# stands outside any quoting — and a validated domain holds no character quoting
# would protect. An '@' the operator typed is taken off first, because typing the
# marker is the likeliest thing to do on a prompt asking for a domain.
assert_out_eq 'from:@example.com' zro_search_term sender-domain 'example.com'
assert_out_eq 'from:@example.com' zro_search_term sender-domain '@example.com'
assert_status "$ZRO_E_INPUT" zro_search_term sender-domain 'ali@example.com'
assert_status "$ZRO_E_INPUT" zro_search_term sender-domain 'example'

it "writes free text as a quoted term, and escapes a quote inside it"
assert_out_eq 'subject:"temmuz faturasi"' zro_search_term subject 'temmuz faturasi'
assert_out_eq 'subject:"bir \"tirnakli\" konu"' zro_search_term subject 'bir "tirnakli" konu'
assert_out_eq 'filename:"rapor.pdf"' zro_search_term attachment-name 'rapor.pdf'

it "and refuses a value that would terminate its own quoting"
# THE ESCAPING DEBT, at the level a screen reaches it. The quoter refuses the
# value; what this asserts is that the refusal survives all the way out to the
# term, so nothing downstream can be handed a half-quoted query.
assert_status "$ZRO_E_INPUT" zro_search_term subject $'temmuz faturasi\\'
assert_status "$ZRO_E_INPUT" zro_search_term attachment-name $'rapor\\'
assert_status "$ZRO_E_INPUT" zro_search_term subject $'iki\nsatir'
assert_status "$ZRO_E_INPUT" zro_search_term subject ' bosluk'
assert_status "$ZRO_E_INPUT" zro_search_term subject 'bosluk '
assert_status "$ZRO_E_INPUT" zro_search_term subject ''

it "writes a message-id as the bare identifier the server matches"
# Measured: the bracketed form matches nothing, which is why the validator refuses
# a value still wearing them rather than searching for one that cannot be found.
assert_out_eq 'msgid:"CAabc123@example.com"' zro_search_term msgid 'CAabc123@example.com'
assert_status "$ZRO_E_INPUT" zro_search_term msgid '<CAabc123@example.com>'
assert_status "$ZRO_E_INPUT" zro_search_term msgid 'CAabc 123@example.com'

it "writes a folder as a quoted path"
assert_out_eq 'in:"/Inbox"' zro_search_term folder '/Inbox'
assert_out_eq 'in:"/Projeler/2026/Q3 Raporlar"' zro_search_term folder '/Projeler/2026/Q3 Raporlar'
assert_status "$ZRO_E_INPUT" zro_search_term folder 'Inbox'
assert_status "$ZRO_E_INPUT" zro_search_term folder '-v'

it "writes the read state and the attachment type as words this program owns"
assert_out_eq 'is:read' zro_search_term state read
assert_out_eq 'is:unread' zro_search_term state unread
assert_out_eq 'attachment:pdf' zro_search_term attachment-type pdf
assert_out_eq 'attachment:any' zro_search_term attachment-type any
assert_out_eq 'is:anywhere' zro_search_term scope anywhere

it "and refuses a word it does not offer, whatever the query language would accept"
# `is:flagged` and `attachment:ms-tnef` are real operators and are not offered.
# What may reach these two fields is what a menu in this program drew.
assert_status "$ZRO_E_INPUT" zro_search_term state flagged
assert_status "$ZRO_E_INPUT" zro_search_term state 'read is:anywhere'
assert_status "$ZRO_E_INPUT" zro_search_term attachment-type 'ms-tnef'
assert_status "$ZRO_E_INPUT" zro_search_term scope everything
assert_status "$ZRO_E_INPUT" zro_search_term scope ''

it "sends a day as epoch milliseconds, because the absolute form is locale-dependent"
# Measured: `date:2026-07-01` is a parse error, and the absolute form Zimbra does
# take is parsed with the request locale's short format. A count of milliseconds
# means the same thing everywhere.
#
# The expected value is computed with the same clock the tool uses rather than
# written down, so this case says what the rule is instead of what one machine's
# timezone makes of it.
day_ms=$(( $("$ZRO_DATE_BIN" -d '2026-07-28 00:00' '+%s') * 1000 ))
next_ms=$(( day_ms + 86400000 ))
assert_out_eq "after:$day_ms" zro_search_term day-from '2026-07-28'

it "and the end of a range is the midnight that closes the day, so the range includes it"
# `after:` and `before:` are strict comparisons and the server compares the
# INSTANT — measured on a mailbox with messages on two known days: after the
# midnight opening a day answered with all of that day, before the same midnight
# with none of it. Both ends on a midnight is therefore a range that covers exactly
# the days the operator named.
assert_out_eq "before:$next_ms" zro_search_term day-to '2026-07-28'

it "and ONE day is that same bounded pair, never the query language's own date term"
# `date:` IS NOT USED AND THAT WAS MEASURED. It is documented as equality over the
# whole day, and the value this tool would send it is a count of milliseconds,
# which the server reads as one instant: on a mailbox holding eleven messages on
# the day asked about, `date:<that midnight>` answered with NOTHING and exit 0.
# A criterion that silently finds nothing is what this screen exists to avoid.
assert_out_eq "after:$day_ms before:$next_ms" zro_search_term day '2026-07-28'
assert_not_contains "$(zro_search_term day '2026-07-28')" 'date:'
assert_not_contains "$(zro_search_query day '2026-07-28' state unread)" 'date:'

it "and refuses a day the calendar does not have"
assert_status "$ZRO_E_INPUT" zro_search_term day '2026-02-30'
assert_status "$ZRO_E_INPUT" zro_search_term day '28-07-2026'
assert_status "$ZRO_E_INPUT" zro_search_term day '2026-07-28 09:00'
assert_status "$ZRO_E_INPUT" zro_search_term day 'dun'
assert_status "$ZRO_E_INPUT" zro_search_term day ''

# ---------------------------------------------------------- the whole query --

it "joins criteria into one query, in the order the operator built them"
assert_out_eq 'from:"ali@example.com" is:unread' \
  zro_search_query sender 'ali@example.com' state unread
assert_out_eq 'is:unread from:"ali@example.com"' \
  zro_search_query state unread sender 'ali@example.com'

it "and carries every criterion the ticket names, in one query"
# THE COMBINATION CASE. Twelve criteria are expressible individually; this is the
# assertion that they are expressible TOGETHER, which is the one that would fail if
# any of them wrote a term that cannot stand beside another.
day_ms=$(( $("$ZRO_DATE_BIN" -d '2026-07-01 00:00' '+%s') * 1000 ))
end_ms=$(( $("$ZRO_DATE_BIN" -d '2026-07-31 00:00' '+%s') * 1000 + 86400000 ))
assert_out_eq "from:\"ali@example.com\" from:@example.com to:\"veli@example.com\" envfrom:\"ali@example.com\" envto:\"veli@example.com\" subject:\"fatura\" msgid:\"CAabc@example.com\" after:$day_ms before:$end_ms filename:\"rapor.pdf\" attachment:pdf is:unread in:\"/Inbox\" is:anywhere" \
  zro_search_query sender 'ali@example.com' sender-domain 'example.com' \
    recipient 'veli@example.com' env-sender 'ali@example.com' env-recipient 'veli@example.com' \
    subject 'fatura' msgid 'CAabc@example.com' day-from '2026-07-01' day-to '2026-07-31' \
    attachment-name 'rapor.pdf' attachment-type pdf state unread folder '/Inbox' scope anywhere

it "and refuses to build a query out of nothing"
# The server answers an empty query with a parse error, which would reach the
# operator as the tool having failed at asking nothing.
assert_status "$ZRO_E_INPUT" zro_search_query
assert_status "$ZRO_E_INPUT" zro_search_query sender
assert_status "$ZRO_E_INPUT" zro_search_query sender 'ali@example.com' state

it "and one bad value refuses the whole query rather than dropping a criterion"
# A query missing a criterion is narrower than the operator asked for and looks
# exactly like an answer. Refusing is visible.
assert_status "$ZRO_E_INPUT" zro_search_query sender 'ali@example.com' subject $'fatura\\'
assert_status "$ZRO_E_INPUT" zro_search_query yokboyle 'x'

# --------------------------------------------------------- reading the table --

it "reads the count and the more flag the table opens with"
assert_out_eq "5${ZRO_TAB}false" zro_search_meta "$(cat "$HITS")"
assert_out_eq "5${ZRO_TAB}true" zro_search_meta "$(cat "$CAPPED")"
assert_out_eq "0${ZRO_TAB}false" zro_search_meta "$(cat "$NOHITS")"
assert_out_eq "13${ZRO_TAB}false" zro_search_meta "$(cat "$WIDE")"

it "and refuses output that carries no count line at all"
# That is what the usage banner looks like — `sc` prints it on STDOUT and exits 1
# when its query argument is missing — and it must never be read as an empty
# result, which would say the mailbox holds nothing matching.
assert_status "$ZRO_E_NO_RESULT" zro_search_meta 'usage:'
assert_status "$ZRO_E_NO_RESULT" zro_search_meta ''
assert_status "$ZRO_E_NO_RESULT" zro_search_meta 'num: cok, more: false'
assert_status "$ZRO_E_NO_RESULT" zro_search_meta 'num: 5, more: belki'

it "reads a hit's id, its type and the rest of the row"
rows=$(zro_search_parse_rows <"$HITS")
assert_eq "$(printf '%s\n' "$rows" | wc -l)" "5"
assert_eq "$(field "$(printf '%s\n' "$rows" | sed -n 1p)" 1)" "264"
assert_eq "$(field "$(printf '%s\n' "$rows" | sed -n 1p)" 2)" "mess"
assert_contains "$(printf '%s\n' "$rows" | sed -n 1p)" "Ynt: Temmuz faturasi"
assert_eq "$(printf '%s\n' "$rows" | awk -F'\t' '{print $1}' | tr '\n' ' ')" "264 263 262 259 258 "

it "and drops the count line, the blank line and both header rows, by what they are"
# NOT BY COUNTING. A reader that skipped four lines would take the first hit for a
# header the day the server prints one line more.
assert_not_contains "$rows" "num:"
assert_not_contains "$rows" "Subject"
assert_not_contains "$rows" "----"

it "and reads a page whose columns have all moved, because the widths are per page"
# THE CASE THE FOLDER READER'S FIXED OFFSETS WOULD FAIL. Thirteen hits make the
# index column two characters wide, and every column behind it moves one to the
# right. Captured from the server both ways.
wide=$(zro_search_parse_rows <"$WIDE")
assert_eq "$(printf '%s\n' "$wide" | wc -l)" "13"
assert_eq "$(printf '%s\n' "$wide" | sed -n 1p | awk -F'\t' '{print $1}')" "273"
assert_eq "$(printf '%s\n' "$wide" | sed -n 10p | awk -F'\t' '{print $1}')" "263"
assert_eq "$(printf '%s\n' "$wide" | sed -n 13p | awk -F'\t' '{print $1}')" "258"
# The row whose index needed the second digit still starts its display text at the
# sender, with nothing of the id or the type left in front of it.
assert_eq "$(printf '%s\n' "$wide" | sed -n 10p | awk -F'\t' '{print substr($3, 1, 8)}')" "Ali Veli"

it "and keeps a subject that carries a double quote exactly as the server printed it"
assert_contains "$wide" 'Bir "tirnakli" konu'

it "reads a conversation search, whose ids may carry a sign"
convs=$(zro_search_parse_rows <"$CONVS")
assert_eq "$(printf '%s\n' "$convs" | awk -F'\t' '{print $1}' | tr '\n' ' ')" "265 -263 -259 -258 "
assert_eq "$(printf '%s\n' "$convs" | sed -n 1p | awk -F'\t' '{print $2}')" "conv"
# The message count Zimbra appends to the sender of a conversation row is kept: it
# is part of what the server printed there, and it is the one field that says a
# conversation holds more than one message.
assert_contains "$(printf '%s\n' "$convs" | sed -n 1p)" "Ali Veli (2)"

it "reads the conversation listing, which is the same table minus the type column"
# Two tables, two readers, declared apart — the day one of them grows a column the
# other must not silently read it as something else.
msgs=$(zro_search_parse_conv_rows <"$SCMSG")
assert_eq "$(printf '%s\n' "$msgs" | wc -l)" "2"
assert_eq "$(printf '%s\n' "$msgs" | awk -F'\t' '{print $1}' | tr '\n' ' ')" "264 262 "
assert_eq "$(printf '%s\n' "$msgs" | sed -n 1p | awk -F'\t' '{print substr($2, 1, 8)}')" "Ali Veli"

it "and the message reader would not read the conversation table as if it had a type"
# Fed the five-column table, the six-column reader takes the sender for a type.
# Asserted so that the two readers are visibly not interchangeable: this is what
# would go wrong silently if one of them were used for both.
crossed=$(zro_search_parse_conv_rows <"$HITS")
assert_eq "$(printf '%s\n' "$crossed" | sed -n 1p | awk -F'\t' '{print $2}')" "mess   Ali Veli              Ynt: Temmuz faturasi                                08/03/26 17:38"

it "answers nothing at all for a page with no hits"
assert_eq "$(zro_search_parse_rows <"$NOHITS")" ""

it "tells a virtual conversation from a real one"
assert_ok zro_search_conv_virtual '-263'
assert_ok zro_search_conv_virtual '-1'
assert_fail zro_search_conv_virtual '265'
assert_fail zro_search_conv_virtual ''
assert_out_eq '263' zro_search_conv_message '-263'

# ------------------------------------------------- the vector that is run --

it "runs one search, with the type and the bound this program declares"
# THE ARGUMENT VECTOR IS THE PROOF. `-t message` is what makes the ids message
# ids; the query is ONE element, which is what keeps the query language's quoting
# the only quoting a value has to survive; and nothing in this vector marks
# anything read.
fresh
proven search_msg "$HITS" 0 zro_search_fetch "$ACCT" 'in:"/Inbox" is:unread' >/dev/null
assert_contains "$(ran)" \
"zmmailbox	-z	-m	$ACCT	s	-t	message	-l	$ZRO_SEARCH_LIMIT	in:\"/Inbox\" is:unread"

it "and asks for conversations by leaving that one flag out"
fresh
proven search_conv "$CONVS" 0 zro_search_conv_fetch "$ACCT" 'in:"/Inbox"' >/dev/null
assert_contains "$(ran)" \
"zmmailbox	-z	-m	$ACCT	s	-l	$ZRO_SEARCH_LIMIT	in:\"/Inbox\""

it "and lists a conversation by id, with a query this program owns"
fresh
proven conv_msgs "$SCMSG" 0 zro_search_conv_messages "$ACCT" '265' >/dev/null
assert_contains "$(ran)" \
"zmmailbox	-z	-m	$ACCT	sc	-l	$ZRO_SEARCH_LIMIT	265	is:anywhere"

it "and no command it runs is one that marks a message read"
# THE ASSERTION THE TICKET ASKS FOR, made against the argv rather than against the
# output. `gm` clears the unread flag on the message it reports and `mm`/`mmr`
# mark read outright: none of them may appear in anything this module ran.
log=$(ran)
for writer in "	gm	" "	mm	" "	mmr	" "	tm	" "	dm	" "	gru	"; do
  assert_not_contains "$log" "$writer"
done
assert_not_contains "$log" "markRead"
assert_not_contains "$log" "getMessage"

it "and a value that looks like a flag never reaches the vector"
# The conversation id is validated as digits, so the virtual conversation's
# negative id cannot be sent at all — the gate would refuse it as an allowlist
# denial, which in this program means a defect.
fresh
assert_status "$ZRO_E_INPUT" zro_search_conv_messages "$ACCT" '-263'
assert_eq "$(ran)" ""
assert_status "$ZRO_E_INPUT" zro_search_conv_messages "$ACCT" 'abc'
assert_status "$ZRO_E_INPUT" zro_search_fetch "$ACCT" '-t'
assert_eq "$(ran)" ""

it "and the output bound is judged before it can reach the vector either"
# The bound travels in the argument vector too, and three readers spend it, so it
# is held to the rule lib/logview.sh and lib/logsearch.sh state for their own:
# judged before it is used, because it reaches a command line. Unjudged, '-t'
# would sit where a count belongs in `zmmailbox s -t message -l <bound>` — a flag
# this program did not choose, in the one command an operator cannot see. A bound
# that is not a count is a defect in whatever set it, not a reason to fall back to
# a default nobody chose.
fresh
ZRO_SEARCH_LIMIT='50; id' assert_status "$ZRO_E_INPUT" zro_search_fetch "$ACCT" 'in:"/Inbox"'
ZRO_SEARCH_LIMIT='' assert_status "$ZRO_E_INPUT" zro_search_fetch "$ACCT" 'in:"/Inbox"'
ZRO_SEARCH_LIMIT='-t' assert_status "$ZRO_E_INPUT" zro_search_fetch "$ACCT" 'in:"/Inbox"'
ZRO_SEARCH_LIMIT='-5' assert_status "$ZRO_E_INPUT" zro_search_fetch "$ACCT" 'in:"/Inbox"'
ZRO_SEARCH_LIMIT='0' assert_status "$ZRO_E_INPUT" zro_search_fetch "$ACCT" 'in:"/Inbox"'
ZRO_SEARCH_LIMIT='-t' assert_status "$ZRO_E_INPUT" zro_search_conv_fetch "$ACCT" 'in:"/Inbox"'
ZRO_SEARCH_LIMIT='-t' assert_status "$ZRO_E_INPUT" zro_search_conv_messages "$ACCT" '265'
# Nothing ran: the bound is judged ahead of the gate, so a defect in whatever set
# it never becomes an allowlist denial on a production server.
assert_eq "$(ran)" ""

it "and every read is refused until the gate has proven the mailbox exists"
# EVERY OPERATION HERE RUNS ONLY BEHIND THE GATE. The oracle answers first, and an
# account with no mailbox never reaches the searching binary at all.
fresh
assert_status "$ZRO_E_NO_MAILBOX" no_mailbox search_msg "$HITS" 0 \
  zro_search_fetch "$ACCT" 'in:"/Inbox"'
assert_not_contains "$(ran)" "zmmailbox"
assert_contains "$(ran)" "zmprov	gis"

fresh
assert_status "$ZRO_E_NO_MAILBOX" no_mailbox conv_msgs "$SCMSG" 0 \
  zro_search_conv_messages "$ACCT" '265'
assert_not_contains "$(ran)" "zmmailbox"

it "and a gate that cannot answer refuses rather than searching anyway"
fresh
assert_status "$ZRO_E_UNAVAILABLE" outage search_msg "$HITS" 0 \
  zro_search_fetch "$ACCT" 'in:"/Inbox"'
assert_not_contains "$(ran)" "zmmailbox"

it "and one search costs one invocation of the mailbox, however many criteria it carries"
fresh
query=$(zro_search_query sender 'ali@example.com' subject 'fatura' state unread \
        folder '/Inbox' scope anywhere)
proven search_msg "$HITS" 0 zro_search_fetch "$ACCT" "$query" >/dev/null
assert_eq "$(ran | grep -c '^zmmailbox')" "1"

# ------------------------------------------------------------ the failures --

it "reports a folder the mailbox does not have as its own answer"
fresh
assert_status "$ZRO_E_NO_FOLDER" proven search_msg_err "$NOFOLDER_ERR" 2 \
  zro_search_fetch "$ACCT" 'in:"/YokBoyleKlasor"'
assert_contains "$(zro_last_error)" "no such folder path"

it "reports a query the server would not parse as an input failure, with what it said"
# This program builds every query it sends, so this is a defect in the builder —
# and the screen behind it shows the query, which is what makes it reportable.
fresh
assert_status "$ZRO_E_INPUT" proven search_msg_err "$PARSE_ERR" 2 \
  zro_search_fetch "$ACCT" 'is:sarmasik'
assert_contains "$(zro_last_error)" "QUERY_PARSE_ERROR"

it "reports a conversation the server no longer has as a result rather than a failure"
fresh
assert_status "$ZRO_E_NO_RESULT" proven conv_msgs_err "$NOCONV_ERR" 2 \
  zro_search_conv_messages "$ACCT" '999999'
assert_contains "$(zro_last_error)" "no such conversation"

it "and an id the server itself refuses is an input failure"
fresh
assert_status "$ZRO_E_INPUT" proven conv_msgs_err "$BADID_ERR" 2 \
  zro_search_conv_messages "$ACCT" '4294967295'

it "and output with no table in it is never drawn as an empty result"
fresh
assert_status "$ZRO_E_NO_RESULT" proven conv_msgs "$FIX/zmcontrol_v.txt" 0 \
  zro_search_conv_messages "$ACCT" '265'

it "and a stopped service reports the outage rather than an empty mailbox"
fresh
assert_status "$ZRO_E_UNAVAILABLE" proven search_msg_err "$FIX/zmprov_io_error_refused.err" 1 \
  zro_search_fetch "$ACCT" 'in:"/Inbox"'

# ------------------------------------------------------------- the screens --

it "renders every hit with the identifier a later screen would be reached with"
fresh
raw=$(proven search_msg "$HITS" 0 zro_search_fetch "$ACCT" 'in:"/Inbox"')
body=$(zro_search_body "$ACCT" 'in:"/Inbox"' "$raw" folder '/Inbox')
for id in 264 263 262 259 258; do
  assert_contains "$body" "$id"
done
assert_contains "$body" "Hesap"
assert_contains "$body" "$ACCT"

it "and shows the query it really sent, so the answer can be read against the question"
assert_contains "$body" 'Sorgu'
assert_contains "$body" 'in:"/Inbox"'

it "and names the criteria in the operator's own words rather than the query's"
body2=$(zro_search_body "$ACCT" 'is:unread attachment:pdf' "$raw" state unread attachment-type pdf)
assert_contains "$body2" 'Okunmamis'
assert_contains "$body2" 'PDF'

# ------------------------------------- two criteria narrowing one field (#57) --
#
# THE DECISION THAT TICKET ASKED FOR, held to a case. Two criteria can write terms
# against the SAME field — the single day and a range start both write `after:`, and the
# two sender criteria both write `from:` — and the answer is then the intersection. It is
# not a wrong answer and it is not refused; what would be wrong is an empty intersection
# read as a fact about the mailbox, so the screen says which field was narrowed twice.

it "names the field two criteria narrowed, and stays quiet when none did"
assert_out_eq "after" zro_search_narrowed_twice day 2026-08-03 day-from 2026-08-05
assert_out_eq "before" zro_search_narrowed_twice day 2026-08-03 day-to 2026-08-05
assert_out_eq "from" zro_search_narrowed_twice sender 'ali@example.com' sender-domain example.org
assert_fail zro_search_narrowed_twice day-from 2026-08-03 day-to 2026-08-05
assert_fail zro_search_narrowed_twice sender 'ali@example.com' recipient 'veli@example.com'
assert_fail zro_search_narrowed_twice folder /Inbox
assert_fail zro_search_narrowed_twice

it "and the composing operator is not one of them, because two states are one question"
# `is:unread is:anywhere` is unread AND anywhere — the query an operator who picked both
# actually meant. A rule that read a repeated operator as a clash would warn about it.
assert_fail zro_search_narrowed_twice state unread scope anywhere

it "and the single day counts for both ends, because that is what it writes"
# `day` becomes `after:<midnight> before:<next midnight>` on its own, so combined with a
# range start it narrows one end twice and with a range end the other.
assert_out_eq "after" zro_search_narrowed_twice day-from 2026-08-05 day 2026-08-03
assert_eq "$(zro_search_narrowed_twice day 2026-08-03 day-from 2026-08-05 day-to 2026-08-09)" \
          "$(printf 'after\nbefore')"

it "and the result screen says so, next to the query it is about"
fresh
raw=$(proven search_msg "$HITS" 0 zro_search_fetch "$ACCT" 'in:"/Inbox"')
overlap=$(zro_search_body "$ACCT" 'after:1785628800000 before:1785715200000 after:1786233600000' \
  "$raw" day 2026-08-03 day-from 2026-08-08)
assert_contains "$overlap" 'AYNI ALAN IKI OLCUTLE DARALTILDI'
assert_contains "$overlap" 'KESISIMIDIR'
assert_contains "$overlap" '  after:'

it "and says nothing of the sort when the criteria narrow different fields"
quiet=$(zro_search_body "$ACCT" 'is:unread in:"/Inbox"' "$raw" state unread folder /Inbox)
assert_not_contains "$quiet" 'AYNI ALAN'

it "and says that the sender column is truncated and cannot be turned into an address"
# THE DISCLOSURE THE TICKET ASKS FOR. The server prints a display name there and
# cuts it at twenty characters without saying so.
assert_contains "$body" 'ADRES DEGILDIR'
assert_contains "$body" '20 karakterde'

it "and says that nothing it ran marked a message read"
assert_contains "$body" 'okundu isaretlemez'

it "renders a search with no hits as no results, not as a failure"
# A RESULT AND NOT A FAILURE, which is the whole distinction: the query ran, the
# server answered, and the answer is that there is nothing. The screen also names
# the one thing that makes an empty answer mean less than it looks like.
fresh
empty=$(proven search_msg "$NOHITS" 0 zro_search_fetch "$ACCT" 'subject:"yok"')
assert_eq "$?" "0"
none=$(zro_search_body "$ACCT" 'subject:"yok"' "$empty" subject 'yok')
assert_contains "$none" "$ZRO_TXT_SEARCH_NO_HITS"
assert_contains "$none" 'bir sonuc'
assert_contains "$none" 'COP KUTUSUNU VE SPAMI DISARIDA BIRAKIR'
assert_not_contains "$none" 'Kimden / Konu'

it "and says so when the server had more than the bound allowed"
fresh
capped=$(proven search_msg "$CAPPED" 0 zro_search_fetch "$ACCT" 'is:anywhere')
more=$(zro_search_body "$ACCT" 'is:anywhere' "$capped" scope anywhere)
assert_contains "$more" 'SUNUCUDA DAHA FAZLASI VAR'
assert_contains "$more" "$ZRO_SEARCH_LIMIT"

it "and says nothing of the sort when the answer was complete"
assert_not_contains "$body" 'SUNUCUDA DAHA FAZLASI VAR'

it "renders the messages of a conversation"
fresh
conv=$(proven conv_msgs "$SCMSG" 0 zro_search_conv_messages "$ACCT" '265')
cbody=$(zro_search_conv_body "$ACCT" '265' "$conv")
assert_contains "$cbody" '265'
assert_contains "$cbody" '264'
assert_contains "$cbody" '262'
assert_contains "$cbody" 'Temmuz faturasi'
assert_contains "$cbody" 'ADRES DEGILDIR'
assert_contains "$cbody" 'okundu isaretlemez'

it "and says that the listing covers Trash and Junk as well"
assert_contains "$cbody" 'is:anywhere'
assert_contains "$cbody" 'cop kutusuna'

it "and renders a conversation the server no longer has as an answer"
gone=$(zro_search_conv_body "$ACCT" '999999' '')
assert_contains "$gone" "$ZRO_TXT_SEARCH_NO_CONV"

it "answers a one-message conversation without running anything at all"
# The id is the negation of the message's id, and it may not reach a command line.
# What the operator needed was on the previous screen already.
virt=$(zro_search_virtual_body '-263')
assert_contains "$virt" 'tek ileti'
assert_contains "$virt" '-263'
assert_contains "$virt" '263'

zro_t_report
