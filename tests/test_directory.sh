#!/usr/bin/env bash
set -uo pipefail
# The two screens an address routes to that are not an account: the domain it
# belongs to, and the distribution list it may turn out to be.
#
# EVERY FIXTURE HERE WAS CAPTURED on TEST-C on 2026-08-02, with only names and
# addresses replaced; see docs/research/2026-08-02-domain-and-list.md for the
# session. That includes the two shapes this ticket had to create state for: a
# list carrying grants (`zmprov grr dl ... sendToDistList` / `ownDistList`) and a
# list with no members at all. Nothing below was written from memory — this
# repository has already shipped two production bugs that way.
#
# What is exercised against a function directly rather than through a fixture is
# said out loud where it happens, and is always a fact about THIS program: a
# bound on how many grantees are resolved, a grantee type the lab server has no
# instance of.
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

# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"
# shellcheck source=../lib/account.sh
. "$ZRO_SRC/lib/account.sh"
# shellcheck source=../lib/identity.sh
. "$ZRO_SRC/lib/identity.sh"
# shellcheck source=../lib/directory.sh
. "$ZRO_SRC/lib/directory.sh"

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG
FIX="$ZRO_TEST_ROOT/fixtures"

DOMAIN="example.com"
LIST="tum-personel@example.com"
EMPTY_LIST="bos-liste@example.com"
ACCT="ahmet.yilmaz@example.com"

invocations() { grep -c '^zmprov' "$ZRO_MOCK_LOG"; }

# The domain as the lab server answered it: a catch-all and a default class of
# service both set, the second of which costs the COS lookup below.
domain_card() {
  : >"$ZRO_MOCK_LOG"
  ZRO_MOCK_ZMPROV_GD_OUT="$FIX/zmprov_gd_ok.txt" \
  ZRO_MOCK_ZMPROV_GC_OUT="$FIX/zmprov_gc_ok.txt" \
    zro_domain_card "$DOMAIN"
}

# The same domain before either was set, which is what an ordinary domain looks
# like: zmprov omits an attribute nobody wrote.
domain_card_bare() {
  : >"$ZRO_MOCK_LOG"
  ZRO_MOCK_ZMPROV_GD_OUT="$FIX/zmprov_gd_bare.txt" \
    zro_domain_card "$DOMAIN"
}

# The list with its grants, and an account read standing in for every grantee
# lookup the card makes.
dl_card() {
  : >"$ZRO_MOCK_LOG"
  ZRO_MOCK_ZMPROV_GDL_OUT="$FIX/zmprov_gdl_grants.txt" \
  ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_identity_account.txt" \
    zro_dl_card "$LIST"
}

dl_card_empty() {
  : >"$ZRO_MOCK_LOG"
  ZRO_MOCK_ZMPROV_GDL_OUT="$FIX/zmprov_gdl_empty.txt" \
    zro_dl_card "$EMPTY_LIST"
}

# ------------------------------------------------ the domain of an address --

it "the domain of an address is the part after the separator"
assert_out_eq "$DOMAIN" zro_domain_of "$ACCT"
assert_out_eq "$DOMAIN" zro_domain_of "$LIST"

it "and an address that is not one has no domain to read"
# The selected address has been validated, so this is a defect rather than
# something an operator typed — and answering with a guess would send a
# directory read after a name nobody has.
assert_fail zro_domain_of "not-an-address"
assert_fail zro_domain_of ""
assert_fail zro_domain_of "$DOMAIN"

# ------------------------------------------------------------ the domain --

it "the domain card is one directory read when nothing has to be resolved"
domain_card_bare >/dev/null
assert_eq "$(invocations)" "1"

it "and two when a default class of service has to be named"
# Cost class 1 either way: both are reads about one entry, and neither does any
# work that grows with the number of accounts on the server.
domain_card >/dev/null
assert_eq "$(invocations)" "2"

it "it carries the four facts the operator came for"
out=$(domain_card)
assert_contains "$out" "$DOMAIN"
assert_contains "$out" "active"
assert_contains "$out" "local"
assert_contains "$out" "@example.com"
assert_contains "$out" "default"

it "a domain with no catch-all says so, and never leaves the field blank"
# 'yok' rather than 'tanimsiz': a domain does not inherit a catch-all from
# anywhere, so an absent attribute is a fact about the domain and answers the
# question the operator asked — where does unrouted mail go.
out=$(domain_card_bare)
assert_contains "$out" "Catch-all"
assert_contains "$out" "yok"

it "and a domain with no default class of service says that differently"
# Unset, not empty: accounts created here take the server-wide default instead,
# which is a different sentence from 'there is no catch-all'.
assert_contains "$(domain_card_bare)" "$ZRO_TXT_UNSET"

it "the card never counts the accounts in the domain"
# The one operation this screen may not perform. It is refused by design rather
# than bounded and offered, and the screen says so where an operator who came
# looking for the number will read it.
out=$(domain_card)
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "gaa"
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "gqu"
assert_contains "$out" "Hesap sayisi"

it "a domain the server does not host is its own answer, not a bare failure"
: >"$ZRO_MOCK_LOG"
rc=0
ZRO_MOCK_ZMPROV_GD_ERR="$FIX/zmprov_gd_no_such_domain.err" \
ZRO_MOCK_ZMPROV_GD_RC=2 \
  zro_domain_card "yok.example" >/dev/null || rc=$?
assert_eq "$rc" "$ZRO_E_NO_DOMAIN"

it "and a service that could not answer is never reported as a missing domain"
: >"$ZRO_MOCK_LOG"
rc=0
ZRO_MOCK_ZMPROV_GD_ERR="$FIX/zmprov_io_error_refused.err" \
ZRO_MOCK_ZMPROV_GD_RC=1 \
ZRO_MOCK_ZMPROV__L_GD_ERR="$FIX/zmprov_io_error_refused.err" \
ZRO_MOCK_ZMPROV__L_GD_RC=1 \
  zro_domain_card "$DOMAIN" >/dev/null || rc=$?
assert_eq "$rc" "$ZRO_E_UNAVAILABLE"

it "the domain read falls back to LDAP like every other directory read"
: >"$ZRO_MOCK_LOG"
out=$(ZRO_MOCK_ZMPROV_GD_ERR="$FIX/zmprov_io_error_refused.err" \
      ZRO_MOCK_ZMPROV_GD_RC=1 \
      ZRO_MOCK_ZMPROV__L_GD_OUT="$FIX/zmprov_gd_bare.txt" \
        zro_domain_card "$DOMAIN")
assert_contains "$out" "active"
# And the operator is told the answer came from the directory rather than from
# the mailbox service.
assert_contains "$out" "LDAP"

it "a domain name that is not one is refused before anything is run"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_INPUT" zro_domain_card "not a domain"
assert_status "$ZRO_E_INPUT" zro_domain_card "-rf.example.com"
assert_status "$ZRO_E_INPUT" zro_domain_card ""
assert_eq "$(invocations)" "0"

# ----------------------------------------------- the distribution list --

it "the list card names the list and its members"
out=$(dl_card)
assert_contains "$out" "$LIST"
assert_contains "$out" "$ACCT"

it "and the member count the server itself reported"
assert_contains "$(dl_card)" "$(zro_card_line 'Uye sayisi' '1')"
assert_contains "$(dl_card_empty)" "$(zro_card_line 'Uye sayisi' '0')"

it "an empty list renders as none, which is a fact and not a failure"
# The distinction the ticket asks for: a list nobody has joined answers with
# memberCount=0 and no member lines at all, and that is an answer.
out=$(dl_card_empty)
assert_contains "$out" "$ZRO_TXT_NONE"
assert_ok dl_card_empty

it "the members are read from the directory, never from a mailbox"
dl_card >/dev/null
log=$(cat "$ZRO_MOCK_LOG")
assert_contains "$log" "gdl"
assert_not_contains "$log" "zmmailbox"

it "the owners are named, and told apart from who may send"
# Two different rights on the same list, and answering one with the other is how
# an operator ends up telling a user to ask the wrong person.
out=$(dl_card)
assert_contains "$out" "Sahipler"
assert_contains "$out" "Gonderim izni"

it "a grantee is named by its address, not by the identifier the directory holds"
# zimbraACE records a grantee as a zimbraId. A card that printed the identifier
# would answer 'who may send to this list' with a UUID, which is the question
# again rather than an answer.
out=$(dl_card)
assert_contains "$out" "$ACCT"
assert_not_contains "$out" "60b41207-8f1d-470f-8128-d5717e8f29a0"

it "the public grantee is named as what it is, without a lookup"
# Captured: granting to 'pub' writes a fixed sentinel identifier that names no
# entry, so there is nothing to look up and the card says what it means instead.
out=$(dl_card)
assert_contains "$out" "herkes"
assert_not_contains "$out" "99999999-9999-9999-9999-999999999999"

it "and each distinct grantee costs exactly one read, however many rights it holds"
# The captured list grants two rights to each of two grantees. Resolving per ACE
# line instead of per grantee would double the invocations for nothing.
dl_card >/dev/null
assert_eq "$(invocations)" "3"

it "a list with no send permission at all says nobody restricted it"
# Absence here is not 'nobody may send': a list with no grant accepts mail from
# everyone, which is the opposite reading, and it is the reading an operator
# needs when a message to the list was rejected.
out=$(dl_card_empty)
assert_contains "$out" "kisitlama yok"

it "an address that is not a list is refused as no result, not as a missing account"
: >"$ZRO_MOCK_LOG"
rc=0
ZRO_MOCK_ZMPROV_GDL_ERR="$FIX/zmprov_gdl_no_such_list.err" \
ZRO_MOCK_ZMPROV_GDL_RC=2 \
  zro_dl_card "$ACCT" >/dev/null || rc=$?
assert_eq "$rc" "$ZRO_E_NO_RESULT"

it "and a list read that could not run is that, and not an empty list"
: >"$ZRO_MOCK_LOG"
rc=0
ZRO_MOCK_ZMPROV_GDL_ERR="$FIX/zmprov_io_error_refused.err" \
ZRO_MOCK_ZMPROV_GDL_RC=1 \
ZRO_MOCK_ZMPROV__L_GDL_ERR="$FIX/zmprov_io_error_refused.err" \
ZRO_MOCK_ZMPROV__L_GDL_RC=1 \
  zro_dl_card "$LIST" >/dev/null || rc=$?
assert_eq "$rc" "$ZRO_E_UNAVAILABLE"

it "an address that is not one is refused before anything is run"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_INPUT" zro_dl_card "not-an-address"
assert_status "$ZRO_E_INPUT" zro_dl_card ""
assert_eq "$(invocations)" "0"

# ------------------------------------------------------- the parsers --

it "the member count comes from the header the list read always prints"
assert_out_eq "1" zro_dl_member_count "$(cat "$FIX/zmprov_gdl_grants.txt")"
assert_out_eq "0" zro_dl_member_count "$(cat "$FIX/zmprov_gdl_empty.txt")"

it "and a record carrying no count is not answered with one"
# A fact about this program: no capture on TEST-C ever lacked the header, and
# what is asserted is what the parser does when it cannot find one.
assert_fail zro_dl_member_count "mail: $LIST"
assert_fail zro_dl_member_count ""

it "grantees are grouped by the exact right they hold"
raw=$(cat "$FIX/zmprov_gdl_grants.txt")
assert_out_eq "$(printf 'usr\t60b41207-8f1d-470f-8128-d5717e8f29a0\ngrp\teee27787-0043-4d18-b07f-bbddcf628f5e')" \
  zro_dl_grantees "$raw" ownDistList
assert_eq "$(zro_dl_grantees "$raw" sendToDistList | wc -l)" "3"

it "a right this program does not recognise is kept, never silently dropped"
# Zimbra can write a grant this card has no group for — a denial is spelled as
# the same right with a leading '-'. Reading one as permission would answer the
# question backwards, so anything that is not exactly one of the two rights is
# shown as it stands instead.
raw=$(printf 'zimbraACE: 60b41207-8f1d-470f-8128-d5717e8f29a0 usr -sendToDistList\n')
assert_out_eq "" zro_dl_grantees "$raw" sendToDistList
assert_contains "$(zro_dl_other_aces "$raw")" "-sendToDistList"

it "and a list whose grants are all recognised has nothing left over"
assert_out_eq "" zro_dl_other_aces "$(cat "$FIX/zmprov_gdl_grants.txt")"

it "a grantee identifier that is not one reaches no command line"
# The value comes from directory output rather than from an operator, and it is
# still judged: it is about to become an argument, and that is the rule for
# every argument in this program.
: >"$ZRO_MOCK_LOG"
assert_fail zro_dl_grantee_resolve usr "--flag"
assert_fail zro_dl_grantee_resolve usr "id; rm"
assert_eq "$(invocations)" "0"

it "a grantee type with no entry behind it is shown as it stands"
# The lab server has no instance of these, so nothing here claims to know what
# they resolve to — the type is named and the identifier is kept, which is what
# lets an operator go and look it up.
out=$(zro_dl_grantee_label dom "11111111-2222-3333-4444-555555555555")
assert_contains "$out" "dom"
assert_contains "$out" "11111111-2222-3333-4444-555555555555"

it "resolving the grantees of a list is bounded, and says when it stopped"
# A fact about this program, exercised against synthetic input for exactly that
# reason: no captured list has this many grants. What matters is that the bound
# is declared on the screen rather than cutting the answer off silently.
: >"$ZRO_MOCK_LOG"
many=""
i=0
while [ "$i" -lt $((ZRO_DL_GRANTEE_MAX + 5)) ]; do
  many="${many}zimbraACE: 60b41207-8f1d-470f-8128-d5717e8f2$(printf '%03d' "$i") usr sendToDistList
"
  i=$((i + 1))
done
table=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_identity_account.txt" \
          zro_dl_grantee_table "$many")
assert_eq "$(invocations)" "$ZRO_DL_GRANTEE_MAX"
# Every grantee is still in the answer; only the naming is bounded.
assert_eq "$(printf '%s\n' "$table" | grep -c .)" "$((ZRO_DL_GRANTEE_MAX + 5))"
assert_eq "$(printf '%s\n' "$table" | grep -c "$ACCT")" "$ZRO_DL_GRANTEE_MAX"
assert_ok zro_dl_grantee_capped "$many"
assert_fail zro_dl_grantee_capped "$(cat "$FIX/zmprov_gdl_grants.txt")"

rm -f -- "$ZRO_MOCK_LOG"
zro_t_report
