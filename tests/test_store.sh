#!/usr/bin/env bash
# What is inside a mailbox: the folder listing, one folder, one folder's grants,
# the size, and the quota usage that is the size read against the limit.
#
# EVERY FIXTURE HERE WAS CAPTURED ON THE LAB SERVER, on 2026-08-02, with the
# addresses changed and nothing else. Two production bugs in this tool's history
# came from output written from memory, and the shapes below are exactly where a
# third would come from: a fixed-width table whose columns are a format string's,
# and a size that is a number in one form and a locale-formatted string in the
# other. See docs/research/2026-08-02-folders-size-and-quota.md.
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/validate.sh
. "$ZRO_SRC/lib/validate.sh"

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
# shellcheck source=../lib/store.sh
. "$ZRO_SRC/lib/store.sh"

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG
FIX="$ZRO_TEST_ROOT/fixtures"

ACCT="ahmet.yilmaz@example.com"
BARE="sade@example.com"
GONE="yok@example.com"

GAF="$FIX/zmmailbox_gaf_ok.txt"
GAF_EMPTY="$FIX/zmmailbox_gaf_empty_mailbox.txt"
GAF_DECORATED="$FIX/zmmailbox_gaf_synthetic_decorated.txt"
GFG="$FIX/zmmailbox_gfg_grants.txt"
GFG_NONE="$FIX/zmmailbox_gfg_none.txt"
GF="$FIX/zmmailbox_gf_inbox.txt"
GF_GRANTS="$FIX/zmmailbox_gf_inbox_grants.txt"
GF_ROOT="$FIX/zmmailbox_gf_root.txt"
GMS="$FIX/zmmailbox_gms_bytes.txt"
GMS_HUMAN="$FIX/zmmailbox_gms_human.txt"
GMS_LOCALE="$FIX/zmmailbox_gms_synthetic_locale.txt"
NO_FOLDER="$FIX/zmmailbox_unknown_folder.err"

ran() { cat "$ZRO_MOCK_LOG"; }
fresh() { : >"$ZRO_MOCK_LOG"; zro_mbox_forget; zro_clear_error; }

# The gate's own answer, as the three captured outcomes. Every case says which
# server it is talking to: a mailbox read is only ever made behind a gate that
# answered, so nothing here can be exercised without saying what the gate said.
proven() {
  ZRO_MOCK_ZMPROV_GIS_OUT="$FIX/zmprov_gis_ok.txt" ZRO_MOCK_ZMPROV_GIS_RC=0 "$@"
}
no_mailbox() {
  ZRO_MOCK_ZMPROV_GIS_ERR="$FIX/zmprov_gis_no_mailbox.err" ZRO_MOCK_ZMPROV_GIS_RC=2 "$@"
}
no_account() {
  ZRO_MOCK_ZMPROV_GIS_ERR="$FIX/zmprov_gis_no_such_account.err" ZRO_MOCK_ZMPROV_GIS_RC=2 "$@"
}
outage() {
  ZRO_MOCK_ZMPROV_GIS_ERR="$FIX/zmprov_io_error_refused.err" ZRO_MOCK_ZMPROV_GIS_RC=1 "$@"
}

rows_of() { zro_store_parse_folders <"$1"; }
field() { printf '%s' "$1" | awk -F'\t' -v n="$2" '{print $n}'; }

# ------------------------------------------------ the folder table, parsed --

it "reads every folder the listing prints, and nothing else"
# Thirteen folders and two header lines. The headers are refused by what is IN
# the columns rather than by being the first two lines: a reader that skipped two
# lines would take the first folder for a header the day a blank line appears
# above it.
assert_eq "$(rows_of "$GAF" | wc -l)" "13"

it "and keeps a folder path that contains a space"
# '/Emailed Contacts' ships with every mailbox Zimbra creates. A reader that split
# the row on whitespace would be wrong about a standard folder on the first
# account it was pointed at — which is why the path is cut at a column instead.
assert_contains "$(rows_of "$GAF")" "/Emailed Contacts"

it "and reads the columns of one row as the format string lays them out"
row=$(rows_of "$GAF" | grep '/Inbox$')
assert_eq "$(field "$row" 1)" "2"
assert_eq "$(field "$row" 2)" "mess"
assert_eq "$(field "$row" 3)" "1"
assert_eq "$(field "$row" 4)" "1"
assert_eq "$(field "$row" 5)" "/Inbox"

it "and the root folder is a row like any other"
row=$(rows_of "$GAF" | head -n 1)
assert_eq "$(field "$row" 1)" "1"
assert_eq "$(field "$row" 5)" "/"

it "a mailbox that has never received anything still lists its folders"
# The empty case is not an error and not an empty answer: Zimbra creates twelve
# folders with the mailbox, and all of them read zero.
assert_eq "$(rows_of "$GAF_EMPTY" | wc -l)" "12"
assert_contains "$(rows_of "$GAF_EMPTY")" "/Inbox"

it "the header and the rule under it are never read as folders"
assert_not_contains "$(rows_of "$GAF")" "Msg Count"
assert_not_contains "$(rows_of "$GAF")" "----"

it "and nothing that is not a row becomes one"
assert_eq "$(printf 'ERROR: something went wrong entirely\n' | zro_store_parse_folders)" ""
assert_eq "$(printf '\n\n' | zro_store_parse_folders)" ""
assert_eq "$(printf 'short\n' | zro_store_parse_folders)" ""

it "a decorated path is kept exactly as the listing printed it"
# A search folder, a mountpoint and a feed each get a parenthesised suffix INSIDE
# the path column — the query, the owner and remote id, the URL. This tool cannot
# tell one from a folder whose name really ends in brackets, so it invents no rule
# for stripping either: the row is shown as it came, and the folder screen says so
# when the server refuses such a path.
rows=$(rows_of "$GAF_DECORATED")
assert_contains "$rows" "/Ortak Klasor (ahmet.yilmaz@example.com:2)"
assert_contains "$rows" "/Faturalar (subject:fatura)"
assert_contains "$rows" "/Rapor (2026)"

# ------------------------------------------------- the grant table, parsed --

it "reads every grant the listing prints"
assert_eq "$(zro_store_parse_grants <"$GFG" | wc -l)" "3"

it "and reads the three columns of one grant"
row=$(zro_store_parse_grants <"$GFG" | head -n 1)
assert_eq "$(field "$row" 1)" "r"
assert_eq "$(field "$row" 2)" "account"
assert_eq "$(field "$row" 3)" "yeni.kullanici@example.com"

it "and a public grant, which names nobody, keeps its empty grantee"
row=$(zro_store_parse_grants <"$GFG" | tail -n 1)
assert_eq "$(field "$row" 1)" "r"
assert_eq "$(field "$row" 2)" "public"
assert_eq "$(field "$row" 3)" ""

it "a folder shared with nobody parses to no rows at all"
assert_eq "$(zro_store_parse_grants <"$GFG_NONE")" ""

it "and no grant is dropped for naming a grantee kind this tool has not seen"
# THE RULE THE LIST CARD ALREADY LIVES BY. A card that showed only the kinds it
# recognises would report a folder shared with a whole domain as a folder shared
# with nobody, which is the one error a sharing screen may not make.
rows=$(printf '%s\n%s\n%s\n' \
  'Permissions      Type  Display' \
  '-----------  --------  -------' \
  '          r    domain  example.com' | zro_store_parse_grants)
assert_eq "$(field "$rows" 2)" "domain"
assert_eq "$(field "$rows" 3)" "example.com"

# ------------------------------------------------- one folder's own record --

it "reads a field of the folder that was asked about"
json=$(cat "$GF")
assert_out_eq "2" zro_store_json_field id "$json"
assert_out_eq "/Inbox" zro_store_json_field path "$json"
assert_out_eq "message" zro_store_json_field defaultView "$json"
assert_out_eq "1" zro_store_json_field itemCount "$json"
assert_out_eq "1" zro_store_json_field unreadCount "$json"
assert_out_eq "353" zro_store_json_field size "$json"
assert_out_eq "true" zro_store_json_field isSystemFolder "$json"

it "and never a field of a folder nested inside it"
# THE READER'S WHOLE RULE. Asking about the root folder answers with the entire
# tree nested under 'subFolders', so a reader that matched a key anywhere would
# report a child's name, path and size as the parent's — silently, and only for
# folders that have children.
json=$(cat "$GF_ROOT")
assert_out_eq "/" zro_store_json_field path "$json"
assert_out_eq "USER_ROOT" zro_store_json_field name "$json"
assert_out_eq "0" zro_store_json_field size "$json"
assert_out_eq "1" zro_store_json_field id "$json"

it "a key the record does not carry is refused, never answered with something else"
assert_status "$ZRO_E_NO_RESULT" zro_store_json_field zimbraNoSuchThing "$(cat "$GF")"
assert_status "$ZRO_E_INPUT" zro_store_json_field "" "$(cat "$GF")"

it "an unshared folder and a shared one are told apart on the record itself"
assert_out_eq "[]" zro_store_json_field grants "$(cat "$GF")"
assert_out_eq "[" zro_store_json_field grants "$(cat "$GF_GRANTS")"

# ------------------------------------------------------------ the size --

it "reads the raw byte count"
assert_out_eq "700" zro_store_parse_size "$(cat "$GMS")"
assert_out_eq "0" zro_store_parse_size "0"

it "and REFUSES the formatted form rather than reading a number out of it"
# THE LOCALE HAZARD, AND THE WHOLE REASON THE RAW FORM IS ASKED FOR. The default
# output is built with the JVM's default locale: '1.44 GB' on one host and
# '1,44 GB' on the next. A reader that took the digits it found would report a
# mailbox holding 1.44 GB as one holding 144 GB on every Turkish, German or French
# server — a factor nobody can see on the screen. Refusing is visible; guessing is
# not.
assert_status "$ZRO_E_NO_RESULT" zro_store_parse_size "$(cat "$GMS_HUMAN")"
assert_status "$ZRO_E_NO_RESULT" zro_store_parse_size "$(cat "$GMS_LOCALE")"
assert_status "$ZRO_E_NO_RESULT" zro_store_parse_size "1.44 GB"
assert_status "$ZRO_E_NO_RESULT" zro_store_parse_size ""
assert_status "$ZRO_E_NO_RESULT" zro_store_parse_size "ERROR: service.FAILURE"

it "and renders a size in both forms, always"
# The human form is what an operator reads; the byte count is what they can check
# against a quota, a previous reading or a colleague's number.
assert_out_eq "700 B (700 bayt)" zro_store_size_field 700
assert_out_eq "1.0 KB (1024 bayt)" zro_store_size_field 1024
assert_out_eq "$ZRO_TXT_UNKNOWN" zro_store_size_field ""
assert_out_eq "$ZRO_TXT_UNKNOWN" zro_store_size_field "1,44 GB"

# ------------------------------------------- the reads, and what they run --

it "the folder listing runs one command, and it is the approved one"
fresh
rows=$(ZRO_MOCK_ZMMAILBOX_GAF_OUT="$GAF" proven zro_store_folders_fetch "$ACCT")
assert_eq "$(rows_of "$GAF")" "$rows"
assert_contains "$(ran)" "$(printf 'zmmailbox\t-z\t-m\t%s\tgaf' "$ACCT")"
assert_eq "$(ran | grep -c '^zmmailbox')" "1"

it "the size read asks for raw bytes, in the position that produces them"
# Measured on the lab server: `gms -v` answers 700, and the same flag written in
# FRONT of the subcommand answers '700 B' — it is a different option there. The
# vector is asserted whole, because the difference between the two is the
# difference between a number and a locale-formatted string.
fresh
ZRO_MOCK_ZMMAILBOX_GMS__V_OUT="$GMS" \
  assert_out_eq "700" proven zro_store_size_fetch "$ACCT"
assert_contains "$(ran)" "$(printf 'zmmailbox\t-z\t-m\t%s\tgms\t-v' "$ACCT")"

it "one folder is read by the path the listing gave, and the path travels whole"
fresh
json=$(ZRO_MOCK_ZMMAILBOX_GF_OUT="$GF" proven \
       zro_store_folder_fetch "$ACCT" '/Emailed Contacts')
assert_contains "$json" '"path": "/Inbox"'
assert_contains "$(ran)" "$(printf 'zmmailbox\t-z\t-m\t%s\tgf\t/Emailed Contacts' "$ACCT")"

it "and one folder's grants the same way"
fresh
rows=$(ZRO_MOCK_ZMMAILBOX_GFG_OUT="$GFG" proven \
       zro_store_grants_fetch "$ACCT" '/Inbox')
assert_eq "$(zro_store_parse_grants <"$GFG")" "$rows"
assert_contains "$(ran)" "$(printf 'zmmailbox\t-z\t-m\t%s\tgfg\t/Inbox' "$ACCT")"

it "a folder with no grants answers successfully with no rows"
# Success, not a failure and not an empty read: the listing printed its headers
# and stopped, which is what a folder shared with nobody looks like.
fresh
ZRO_MOCK_ZMMAILBOX_GFG_OUT="$GFG_NONE" \
  assert_ok proven zro_store_grants_fetch "$ACCT" '/Inbox'
ZRO_MOCK_ZMMAILBOX_GFG_OUT="$GFG_NONE" \
  assert_out_eq "" proven zro_store_grants_fetch "$ACCT" '/Inbox'

it "a path the server does not know is a folder answer, not a bare failure"
# Classified on the message, never on the status: this binary exits 2 for a folder
# that is not there and for everything else it fails at.
fresh
ZRO_MOCK_ZMMAILBOX_GF_ERR="$NO_FOLDER" ZRO_MOCK_ZMMAILBOX_GF_RC=2 \
  assert_status "$ZRO_E_NO_FOLDER" proven zro_store_folder_fetch "$ACCT" '/Yok'
assert_contains "$(zro_last_error)" "unknown folder"

it "and the same for a grant listing"
fresh
ZRO_MOCK_ZMMAILBOX_GFG_ERR="$NO_FOLDER" ZRO_MOCK_ZMMAILBOX_GFG_RC=2 \
  assert_status "$ZRO_E_NO_FOLDER" proven zro_store_grants_fetch "$ACCT" '/Yok'

it "a listing that answered with nothing at all is no result, not an empty mailbox"
# Every mailbox has a root folder. Nothing to parse means the answer was not a
# folder table, and drawing it as an empty list would say this mailbox has no
# folders — which is not a state Zimbra can be in.
fresh
empty=$(mktemp); : >"$empty"
ZRO_MOCK_ZMMAILBOX_GAF_OUT="$empty" \
  assert_status "$ZRO_E_NO_RESULT" proven zro_store_folders_fetch "$ACCT"
rm -f -- "$empty"

# ------------------------------------------------------ what the gate does --

it "an account with no mailbox never reaches the binary, on any of these reads"
# THE POINT OF THE WHOLE MILESTONE. Each read is refused by the gate before a
# vector is built, and the refusal is the documented code a screen turns into the
# result screen — not a failure of its own.
for read_call in \
  "zro_store_folders_fetch $BARE" \
  "zro_store_size_fetch $BARE" \
  "zro_store_folder_fetch $BARE /Inbox" \
  "zro_store_grants_fetch $BARE /Inbox"; do
  fresh
  # shellcheck disable=SC2086
  assert_status "$ZRO_E_NO_MAILBOX" no_mailbox $read_call
  assert_not_contains "$(ran)" "zmmailbox"
done

it "nor does an address that is no account"
fresh
assert_status "$ZRO_E_NO_ACCOUNT" no_account zro_store_folders_fetch "$GONE"
assert_not_contains "$(ran)" "zmmailbox"

it "nor does anything while the mailbox service is unreachable"
fresh
assert_status "$ZRO_E_UNAVAILABLE" outage zro_store_size_fetch "$ACCT"
assert_not_contains "$(ran)" "zmmailbox"

it "and the oracle's own sentence survives the read that never ran"
# The gate's message is the one an operator needs; the refused read wrote nothing,
# and overwriting the file with nothing would leave the screen showing a bare code.
fresh
no_mailbox zro_store_size_fetch "$BARE" >/dev/null 2>&1
assert_contains "$(zro_last_error)" "mailbox not found"

it "the oracle runs before any of it, every time"
fresh
ZRO_MOCK_ZMMAILBOX_GAF_OUT="$GAF" proven zro_store_folders_fetch "$ACCT" >/dev/null
first=$(ran | grep -nE '^(zmprov|zmmailbox)' | head -n 1)
assert_contains "$first" "zmprov	gis"

# ------------------------------------------------------- what is refused --

it "an address that is not one runs nothing at all"
fresh
assert_status "$ZRO_E_INPUT" zro_store_folders_fetch 'a@b.com; id'
assert_status "$ZRO_E_INPUT" zro_store_size_fetch ''
assert_status "$ZRO_E_INPUT" zro_store_folder_fetch 'a@b.com; id' '/Inbox'
assert_eq "$(ran)" ""

it "and a folder path that is not one is refused before the gate is even asked"
# The path comes from this program's own reading of the server's answer, so this
# is the structure refusing rather than the author remembering. A value that does
# not begin with '/' is a folder id, a decoration or something that was never a
# path.
fresh
assert_status "$ZRO_E_INPUT" proven zro_store_folder_fetch "$ACCT" ''
assert_status "$ZRO_E_INPUT" proven zro_store_folder_fetch "$ACCT" 'Inbox'
assert_status "$ZRO_E_INPUT" proven zro_store_folder_fetch "$ACCT" '-v'
assert_status "$ZRO_E_INPUT" proven zro_store_grants_fetch "$ACCT" '../etc'
assert_status "$ZRO_E_INPUT" proven zro_store_grants_fetch "$ACCT" "$(printf '/In\nbox')"
assert_eq "$(ran)" ""

it "and a folder name an account holder really typed is not refused with them"
# Permissive about the NAME on purpose: a folder is named by its owner, in their
# own language, with whatever punctuation they typed. The value travels as one
# element of an argument vector and never becomes a command name.
assert_ok zro_validate_folder_path '/Emailed Contacts'
assert_ok zro_validate_folder_path '/Rapor (2026)'
assert_ok zro_validate_folder_path '/Musteri & Tedarikci'
assert_ok zro_validate_folder_path '/Proje/2026/Q3'
assert_ok zro_validate_folder_path '/'

# --------------------------------------------------------------- the cards --

it "the folder card counts what the listing named, and says what it counted"
out=$(zro_store_folders_body "$ACCT" "$(rows_of "$GAF")")
assert_contains "$out" "Klasor sayisi        : 13"
assert_contains "$out" "Toplam oge           : 2"
assert_contains "$out" "Okunmamis            : 1"
assert_contains "$out" "/Emailed Contacts"

it "and it says out loud that the count is items and not messages"
# 'Msg Count' counts the folder's ITEMS: contacts in a contacts folder,
# appointments in a calendar. A column headed 'messages' would be a wrong answer
# on five of the folders every mailbox is created with.
assert_contains "$(zro_store_folders_body "$ACCT" "$(rows_of "$GAF")")" \
  "ILETI SAYISI DEGILDIR"

it "the folder detail card shows the one thing the listing cannot: bytes"
out=$(zro_store_folder_body "$ACCT" '/Inbox' "$(cat "$GF")")
assert_contains "$out" "Klasor               : /Inbox"
assert_contains "$out" "Boyut                : 353 B (353 bayt)"
assert_contains "$out" "Oge sayisi           : 1"
assert_contains "$out" "Sistem klasoru       : evet"

it "and reports sharing as whether, never as who"
# The folder record names a grantee by identifier and nothing else, so answering
# 'who' from here would print a UUID at an operator.
assert_contains "$(zro_store_folder_body "$ACCT" '/Inbox' "$(cat "$GF")")" \
  "Paylasim             : $ZRO_TXT_NONE"
out=$(zro_store_folder_body "$ACCT" '/Inbox' "$(cat "$GF_GRANTS")")
assert_contains "$out" "Paylasim             : var"
assert_not_contains "$out" "344c2c64"

it "a record this program cannot read reaches the operator as unreadable"
# Never as a value, and never as zero. If the serializer's shape ever changes,
# every field says so instead of one field being quietly wrong.
out=$(zro_store_folder_body "$ACCT" '/Inbox' 'not json at all')
assert_contains "$out" "Oge sayisi           : $ZRO_TXT_UNKNOWN"
assert_contains "$out" "Boyut                : $ZRO_TXT_UNKNOWN"
assert_contains "$out" "Sistem klasoru       : $ZRO_TXT_UNKNOWN"
# The path is the one field that answers anyway: it is what the operator asked
# about, and it came from this program rather than from the record.
assert_contains "$out" "Klasor               : /Inbox"

it "the grant card shows every grant, and names the public one as everyone"
out=$(zro_store_grants_body "$ACCT" '/Inbox' "$(zro_store_parse_grants <"$GFG")")
assert_contains "$out" "Paylasim sayisi      : 3"
assert_contains "$out" "yeni.kullanici@example.com"
assert_contains "$out" "tum-personel@example.com"
assert_contains "$out" "$ZRO_TXT_STORE_PUBLIC"

it "and an unshared folder says so rather than showing an empty table"
out=$(zro_store_grants_body "$ACCT" '/Inbox' "")
assert_contains "$out" "$ZRO_TXT_STORE_NO_GRANTS"
assert_contains "$out" "Paylasim sayisi      : 0"
assert_not_contains "$out" "Izin"

it "the size card gives both forms and names the option it asked for"
out=$(zro_store_size_body "$ACCT" 700)
assert_contains "$out" "Boyut                : 700 B (700 bayt)"
assert_contains "$out" "HAM BAYT"

# ---------------------------------------------------------- quota usage --

it "quota usage is a proportion of the limit"
out=$(zro_store_quota_body "$ACCT" 'mail01.example.com' \
      "$(printf '1000%saccount' "$ZRO_TAB")" 120)
assert_contains "$out" "Doluluk              : %12"

it "and a usage too small to round to one per cent says so rather than zero"
# '%0' on a mailbox holding something reads as empty, which is a different answer
# from the one the numbers support.
out=$(zro_store_quota_body "$ACCT" 'mail01.example.com' \
      "$(printf '5368709120%saccount' "$ZRO_TAB")" 700)
assert_contains "$out" "%1'den az"

it "and an empty mailbox under a limit is exactly zero"
out=$(zro_store_quota_body "$ACCT" 'mail01.example.com' \
      "$(printf '5368709120%saccount' "$ZRO_TAB")" 0)
assert_contains "$out" "Doluluk              : %0"

it "an unlimited quota has no proportion, and says which of the two it is"
# Zimbra writes zimbraMailQuota: 0 to mean unlimited. Dividing by it is not the
# hazard; reporting it as a full mailbox would be.
out=$(zro_store_quota_body "$ACCT" 'mail01.example.com' \
      "$(printf '0%saccount' "$ZRO_TAB")" 700)
assert_contains "$out" "sinirsiz"
assert_contains "$out" "oran yok"

it "and a limit nobody could read is neither unlimited nor a proportion"
out=$(zro_store_quota_body "$ACCT" 'mail01.example.com' "" 700)
assert_contains "$out" "Kota limiti          : $ZRO_TXT_UNKNOWN"
assert_contains "$out" "limit okunamadi"
# READ OFF THE FIELDS, not off the whole screen: the closing paragraph explains
# what an unlimited quota is, so a search of the card would find that word on the
# one screen that must not be reporting it.
assert_not_contains "$(printf '%s\n' "$out" | grep '^Doluluk')" "sinirsiz"
assert_not_contains "$(printf '%s\n' "$out" | grep '^Kota limiti')" "sinirsiz"

it "the usage figure is the mailbox's own, and the limit the directory's"
out=$(zro_store_quota_body "$ACCT" 'mail01.example.com' \
      "$(printf '5368709120%scos' "$ZRO_TAB")" 700)
assert_contains "$out" "Kullanilan           : 700 B (700 bayt)"
assert_contains "$out" "Kota limiti          : 5.0 GB (COS kaydindan)"

it "and the whole-server quota command is named nowhere but in the sentence refusing it"
# It takes a server, not an account, and answers for every account on it: the
# class 4 sweep this tool does not have.
out=$(zro_store_quota_body "$ACCT" 'mail01.example.com' \
      "$(printf '0%saccount' "$ZRO_TAB")" 700)
assert_contains "$out" "bu araca alinmadi"

it "the quota screen reads the mailbox first and the directory second"
# An account with no mailbox is answered by the gate for the price of the gate,
# and never by a card showing a limit above a usage figure that does not exist.
fresh
assert_status "$ZRO_E_NO_MAILBOX" no_mailbox zro_store_quota_card "$BARE"
assert_eq "$(ran | grep -c '^zmprov')" "1"
assert_not_contains "$(ran)" "$(printf '\tga\t')"

it "and with a mailbox it spends one read on each"
fresh
out=$(ZRO_MOCK_ZMMAILBOX_GMS__V_OUT="$GMS" ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
      proven zro_store_quota_card "$ACCT")
assert_contains "$out" "5.0 GB"
assert_contains "$out" "700 B"
assert_eq "$(ran | grep -c '^zmmailbox')" "1"
assert_eq "$(ran | grep -c "$(printf '^zmprov\tga')")" "1"

rm -f -- "$ZRO_MOCK_LOG" "$ZRO_MBOX_PROOF_FILE"
zro_t_report
