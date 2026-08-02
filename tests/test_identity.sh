#!/usr/bin/env bash
set -uo pipefail
# What an address turns out to BE, before any screen assumes it is an account.
#
# The premise is a measurement, not a guess: on TEST-C on 2026-08-02,
# `zmprov ga` on a distribution list answers
# `ERROR: account.NO_SUCH_ACCOUNT (no such account: ...)` — the same sentence an
# address that exists nowhere produces. An operator who reads the first as the
# second goes on to look in the wrong place, which is the whole reason this
# module exists. Every fixture below keeps the shape of real output from that
# server with the names changed; see docs/research/2026-08-02-address-identity.md.
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

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG
FIX="$ZRO_TEST_ROOT/fixtures"

ACCT="ahmet.yilmaz@example.com"
ALIAS="a.yilmaz@example.com"
RES="toplanti-odasi@example.com"
LIST="tum-personel@example.com"
NOWHERE="yok@example.com"

# One resolution, with the whole environment scripted per case. Every mock
# answer is passed here rather than exported, so a case cannot inherit the
# previous one's server.
resolve() {
  local addr=$1
  shift
  : >"$ZRO_MOCK_LOG"
  # SC2016: the script below is expanded by the child shell, not by this one —
  # that is the point of running it in a fresh process with a scripted server.
  # shellcheck disable=SC2016
  env "$@" ZRO_CASE_ADDR="$addr" bash -c '
    . "$ZRO_SRC/lib/core.sh"; . "$ZRO_SRC/lib/validate.sh"
    . "$ZRO_SRC/lib/exec.sh"; . "$ZRO_SRC/lib/account.sh"
    . "$ZRO_SRC/lib/identity.sh"
    zro_identity_resolve "$ZRO_CASE_ADDR"'
}

# How many times zmprov was started for the last resolution. The cost claim is
# a number, so it is asserted as one.
invocations() { grep -c '^zmprov' "$ZRO_MOCK_LOG"; }

# ------------------------------------------------------- the pure parser --

it "reads the entry zmprov says answered, from the header it always prints"
assert_out_eq "$ACCT" zro_identity_canonical "$(cat "$FIX/zmprov_ga_identity_account.txt")"

it "reads a distribution list's own name from its header"
assert_out_eq "$LIST" zro_identity_canonical "$(cat "$FIX/zmprov_gdl_ok.txt")"

it "refuses output carrying no header rather than inventing a name"
# No fixture claims zmprov ever wrote this: every capture on TEST-C carried the
# header, in both SOAP and LDAP mode. What is asserted here is what this parser
# does when it cannot find one, which is a fact about this program.
assert_fail zro_identity_canonical "displayName: Ahmet Yilmaz"
assert_fail zro_identity_canonical ""

it "takes only the name, not a header that carries more after it"
# A list's header is `# distributionList <name> memberCount=1`. Reading to the
# end of the line would make the count part of the address.
assert_out_eq "$LIST" zro_identity_canonical "# distributionList $LIST memberCount=1"

# ----------------------------------------------------- the five outcomes --

it "an account address resolves to an account"
rec=$(resolve "$ACCT" \
        "ZRO_MOCK_ZMPROV_GA_OUT=$FIX/zmprov_ga_identity_account.txt")
assert_out_eq "account" zro_identity_kind "$rec"
assert_out_eq "$ACCT" zro_identity_account "$rec"
assert_out_eq "$ACCT" zro_identity_address "$rec"

it "and costs one invocation, which is cost class 1"
assert_eq "$(invocations)" "1"

it "an alias resolves to the account behind it, and the record names both"
rec=$(resolve "$ALIAS" \
        "ZRO_MOCK_ZMPROV_GA_OUT=$FIX/zmprov_ga_identity_account.txt")
assert_out_eq "alias" zro_identity_kind "$rec"
assert_out_eq "$ACCT" zro_identity_account "$rec"
assert_out_eq "$ALIAS" zro_identity_address "$rec"

it "and still costs one invocation: the account read resolves the alias itself"
assert_eq "$(invocations)" "1"

it "an address differing from the canonical only in case is not an alias"
# Measured: `zmprov ga ZimScope-Alias-A@Sirket.LCL` answers with the canonical
# name in lower case. Comparing the two literally would report every operator
# who capitalised an address as having typed an alias.
rec=$(resolve "AHMET.YILMAZ@example.com" \
        "ZRO_MOCK_ZMPROV_GA_OUT=$FIX/zmprov_ga_identity_account.txt")
assert_out_eq "account" zro_identity_kind "$rec"

it "a resource resolves as a resource"
rec=$(resolve "$RES" \
        "ZRO_MOCK_ZMPROV_GA_OUT=$FIX/zmprov_ga_identity_resource.txt")
assert_out_eq "resource" zro_identity_kind "$rec"
assert_out_eq "$RES" zro_identity_account "$rec"

it "a distribution list resolves as a list, not as a missing account"
rec=$(resolve "$LIST" \
        "ZRO_MOCK_ZMPROV_GA_ERR=$FIX/zmprov_ga_no_such_account.err" \
        "ZRO_MOCK_ZMPROV_GA_RC=2" \
        "ZRO_MOCK_ZMPROV_GDL_OUT=$FIX/zmprov_gdl_ok.txt")
assert_out_eq "list" zro_identity_kind "$rec"
assert_out_eq "$LIST" zro_identity_address "$rec"

it "and costs two invocations, never more"
assert_eq "$(invocations)" "2"

it "an address present nowhere is reported as absent, and that is an answer"
# Status 0: absence is something this program learned, and telling it from a
# question that could not be asked is the point of the whole module.
rec=$(resolve "$NOWHERE" \
        "ZRO_MOCK_ZMPROV_GA_ERR=$FIX/zmprov_ga_no_such_account.err" \
        "ZRO_MOCK_ZMPROV_GA_RC=2" \
        "ZRO_MOCK_ZMPROV_GDL_ERR=$FIX/zmprov_gdl_no_such_list.err" \
        "ZRO_MOCK_ZMPROV_GDL_RC=2")
assert_out_eq "absent" zro_identity_kind "$rec"
assert_eq "$(invocations)" "2"

it "the resolution that found nothing succeeded"
assert_status 0 resolve "$NOWHERE" \
  "ZRO_MOCK_ZMPROV_GA_ERR=$FIX/zmprov_ga_no_such_account.err" \
  "ZRO_MOCK_ZMPROV_GA_RC=2" \
  "ZRO_MOCK_ZMPROV_GDL_ERR=$FIX/zmprov_gdl_no_such_list.err" \
  "ZRO_MOCK_ZMPROV_GDL_RC=2"

# ------------------------------------------- a failure is not an absence --

it "an unreachable mailbox service is a failure, not an address that does not exist"
rc=0
out=$(resolve "$ACCT" \
        "ZRO_MOCK_ZMPROV_GA_ERR=$FIX/zmprov_io_error_refused.err" \
        "ZRO_MOCK_ZMPROV_GA_RC=1" \
        "ZRO_MOCK_ZMPROV__L_GA_ERR=$FIX/zmprov_io_error_refused.err" \
        "ZRO_MOCK_ZMPROV__L_GA_RC=1") || rc=$?
assert_eq "$rc" "$ZRO_E_UNAVAILABLE"
assert_not_contains "$out" "absent"

it "and a list read that could not run is a failure too"
rc=0
out=$(resolve "$LIST" \
        "ZRO_MOCK_ZMPROV_GA_ERR=$FIX/zmprov_ga_no_such_account.err" \
        "ZRO_MOCK_ZMPROV_GA_RC=2" \
        "ZRO_MOCK_ZMPROV_GDL_ERR=$FIX/zmprov_io_error_ssl.err" \
        "ZRO_MOCK_ZMPROV_GDL_RC=1" \
        "ZRO_MOCK_ZMPROV__L_GDL_ERR=$FIX/zmprov_io_error_ssl.err" \
        "ZRO_MOCK_ZMPROV__L_GDL_RC=1") || rc=$?
assert_eq "$rc" "$ZRO_E_UNAVAILABLE"
assert_not_contains "$out" "absent"

it "an authentication failure is a failure, and never an absence either"
# A third cause, and a differently mapped one: an admin certificate or password
# the directory would not accept answers every query the same way, and an
# operator told their address does not exist would go looking for the wrong
# repair. Captured on TEST-C by asking zmprov to authenticate with a password
# that is not the admin's.
assert_status "$ZRO_E_PERM" resolve "$ACCT" \
  "ZRO_MOCK_ZMPROV_GA_ERR=$FIX/zmprov_auth_failed.err" \
  "ZRO_MOCK_ZMPROV_GA_RC=2"

it "an address that is not one is refused before anything is run"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_INPUT" zro_identity_resolve 'not-an-address'
assert_status "$ZRO_E_INPUT" zro_identity_resolve ''
assert_status "$ZRO_E_INPUT" zro_identity_resolve '-rf@example.com'
assert_eq "$(invocations)" "0"

it "the account read falls back to LDAP like every other directory read"
rec=$(resolve "$ACCT" \
        "ZRO_MOCK_ZMPROV_GA_ERR=$FIX/zmprov_io_error_refused.err" \
        "ZRO_MOCK_ZMPROV_GA_RC=1" \
        "ZRO_MOCK_ZMPROV__L_GA_OUT=$FIX/zmprov_ga_identity_account.txt")
assert_out_eq "account" zro_identity_kind "$rec"
assert_contains "$(cat "$ZRO_MOCK_LOG")" "-l"

it "and so does the list read"
rec=$(resolve "$LIST" \
        "ZRO_MOCK_ZMPROV_GA_ERR=$FIX/zmprov_ga_no_such_account.err" \
        "ZRO_MOCK_ZMPROV_GA_RC=2" \
        "ZRO_MOCK_ZMPROV_GDL_ERR=$FIX/zmprov_io_error_refused.err" \
        "ZRO_MOCK_ZMPROV_GDL_RC=1" \
        "ZRO_MOCK_ZMPROV__L_GDL_OUT=$FIX/zmprov_gdl_ok.txt")
assert_out_eq "list" zro_identity_kind "$rec"

# ------------------------------------------------ what the operator reads --

it "the card for an account names the account"
card=$(zro_identity_card "$(printf 'kind: account\naddress: %s\naccount: %s\nname: Ahmet Yilmaz\n' "$ACCT" "$ACCT")")
assert_contains "$card" "$ACCT"
assert_contains "$card" "Ahmet Yilmaz"

it "the card for an alias names BOTH the alias and the account behind it"
card=$(zro_identity_card "$(printf 'kind: alias\naddress: %s\naccount: %s\nname: Ahmet Yilmaz\n' "$ALIAS" "$ACCT")")
assert_contains "$card" "$ALIAS"
assert_contains "$card" "$ACCT"

it "the card for a distribution list says so, and does not say no such account"
card=$(zro_identity_card "$(printf 'kind: list\naddress: %s\n' "$LIST")")
assert_contains "$card" "dagitim listesi"
assert_not_contains "$card" "Hesap bulunamadi"

it "an alias reaching a resource is still a resource, and still names both"
# The two facts do not compete: the kind says what the entry is, and how it was
# reached is carried by the record. Deciding both by the order of one cascade
# would have dropped whichever came second.
rec=$(zro_identity_classify "oda-alias@example.com" \
        "$(cat "$FIX/zmprov_ga_identity_resource.txt")")
assert_out_eq "resource" zro_identity_kind "$rec"
assert_ok zro_identity_aliased "$rec"
assert_contains "$(zro_identity_card "$rec")" "oda-alias@example.com"
assert_contains "$(zro_identity_card "$rec")" "$RES"

it "and an address that only differs in case is not aliased, on any kind"
# The card used to compare these literally while the classifier folded case, so
# an operator who capitalised an address got a second line naming the same one.
rec=$(zro_identity_record account "AHMET.YILMAZ@example.com" "$ACCT")
assert_fail zro_identity_aliased "$rec"
assert_not_contains "$(zro_identity_card "$rec")" "Hesap "

it "a record with no account behind it is not aliased either"
assert_fail zro_identity_aliased "$(zro_identity_record list "$LIST")"
assert_fail zro_identity_aliased ""

it "the card for a resource says which it is"
card=$(zro_identity_card "$(printf 'kind: resource\naddress: %s\naccount: %s\nname: Toplanti Odasi\n' "$RES" "$RES")")
assert_contains "$card" "kaynak"
assert_contains "$card" "Toplanti Odasi"

it "the card for an absent address says the directory has no such entry"
card=$(zro_identity_card "$(printf 'kind: absent\naddress: %s\n' "$NOWHERE")")
assert_contains "$card" "$NOWHERE"
assert_contains "$card" "dizinde"

it "and it never reads as a query that failed"
card=$(zro_identity_card "$(printf 'kind: absent\naddress: %s\n' "$NOWHERE")")
assert_not_contains "$card" "basarisiz"

it "a record naming no kind is a defect, and the card refuses it"
assert_fail zro_identity_card "$(printf 'address: %s\n' "$ACCT")"
assert_fail zro_identity_card ""

it "an account whose canonical name could not be read is not called an alias"
# The header is what names the entry that answered. Without it there is nothing
# to compare the requested address against, and claiming an alias would be
# claiming evidence this program does not have.
rec=$(zro_identity_classify "$ALIAS" "displayName: Ahmet Yilmaz")
assert_out_eq "account" zro_identity_kind "$rec"
assert_out_eq "" zro_identity_account "$rec"

# -------------------------------------- which address an account screen asks about --

it "an account screen asks about the selected address when it is the account"
. "$ZRO_SRC/lib/selection.sh"
zro_sel_clear
zro_sel_set "$ACCT"
zro_sel_set_identity "$(zro_identity_record account "$ACCT" "$ACCT")"
assert_out_eq "$ACCT" zro_identity_selected_account

it "and about the account behind an alias, not about the alias"
zro_sel_set "$ALIAS"
zro_sel_set_identity "$(zro_identity_record alias "$ALIAS" "$ACCT")"
assert_out_eq "$ACCT" zro_identity_selected_account

it "and about what the operator chose when nothing was resolved"
# A resolution that failed leaves the address selected and nothing else known.
# Falling back to it is what keeps a screen reached anyway asking about the
# address the operator gave rather than about nothing at all.
zro_sel_set "$ACCT"
assert_out_eq "$ACCT" zro_identity_selected_account

it "and about it for a list too, where there is no account to prefer"
zro_sel_set "$LIST"
zro_sel_set_identity "$(zro_identity_record list "$LIST")"
assert_out_eq "$LIST" zro_identity_selected_account
zro_sel_clear

it "every kind the classifier can produce has a card"
for kind in account alias resource list absent; do
  assert_ok zro_identity_card "$(printf 'kind: %s\naddress: %s\naccount: %s\n' "$kind" "$ACCT" "$ACCT")"
done

zro_t_report
