#!/usr/bin/env bash
# Where a value came from: the entry-only read, and the diff that answers.
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

# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"
# shellcheck source=../lib/account.sh
. "$ZRO_SRC/lib/account.sh"

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG
FIX="$ZRO_TEST_ROOT/fixtures"

# THE PAIR EVERY CASE HERE RESTS ON: two forms of one read of one account, RUN
# BACK TO BACK on the lab server. `zmprov ga` answers with the value in force;
# `zmprov ga -e` answers with the attributes set on the entry itself and expands
# nothing. The difference between them is the entire content of this screen, so
# the difference is what the cases below assert.
#
# CAPTURED TOGETHER IS NOT A DETAIL. Two halves taken at different moments differ
# wherever the account changed in between, and every one of those differences
# reads here as 'inherited' — a fixture that would teach this screen to report an
# attribute nothing inherits as an inherited one. That is why the account card's
# own fixture is not reused for the expanding half: it carries a last-logon line
# this account does not answer with, which is right for the card and wrong for a
# pair.
POPULATED="ahmet.yilmaz@example.com"
EFFECTIVE="$FIX/zmprov_ga_quota_set.txt"
ENTRY="$FIX/zmprov_ga_e_quota_set.txt"

# The bare account: nobody has set a quota on it, so the limit it answers with is
# the one its class of service provides. It is the other half of the question —
# the same attribute, inherited on one account and set on the other. Its expanding
# half is the card's own fixture, which a re-capture confirmed is still this
# account line for line, timestamp included.
BARE="sade@example.com"
BARE_EFFECTIVE="$FIX/zmprov_ga_bare.txt"
BARE_ENTRY="$FIX/zmprov_ga_e_bare.txt"

# One provenance screen, with the two forms of the read scripted separately. They
# are different environment variables because the gate treats `-e` as an operation
# of its own and the mock mirrors that; if the two ever answered from one variable
# again, every case in this file would pass against the same text twice.
draw() {
  ZRO_MOCK_ZMPROV_GA_OUT="$2" ZRO_MOCK_ZMPROV_GA__E_OUT="$3" \
    zro_account_provenance "$1"
}

# What the screen said about one attribute, as the word alone.
said_about() {
  printf '%s\n' "$1" | awk -v key="$2" '
    index($0, key) == 1 { sub(/^[^:]*: */, ""); print; exit }
  '
}

ran() { cat "$ZRO_MOCK_LOG"; }

# --------------------------------------------- the fixtures answer the question --

it "the captured pair really carries all three kinds of answer"
# ASSERTED BEFORE ANYTHING READS IT. A pair captured wrong, or a pair that turned
# out to be the same text twice, would let every case below pass while proving
# nothing at all — a screen that printed one word for everything would agree with
# a fixture that only ever asked for one.
assert_ok zro_attr_present "$(cat "$ENTRY")" zimbraMailQuota
assert_fail zro_attr_present "$(cat "$BARE_ENTRY")" zimbraMailQuota
assert_ok zro_attr_present "$(cat "$BARE_EFFECTIVE")" zimbraMailQuota
assert_fail zro_attr_present "$(cat "$EFFECTIVE")" zimbraTwoFactorAuthEnabled
assert_fail zro_attr_present "$(cat "$ENTRY")" zimbraTwoFactorAuthEnabled

it "and the entry-only form really is the shorter of the two"
# The whole premise: `-e` expands nothing, so it cannot carry MORE than the read
# that expands a class of service into the answer. A pair that failed this would
# be two captures of different accounts, or of the same account at two different
# times, and neither can answer a question about one entry.
assert_eq "$(( $(grep -c ': ' "$ENTRY") <= $(grep -c ': ' "$EFFECTIVE") ))" "1"

# ------------------------------------------------------------- the three states --

it "an attribute the entry carries is reported as set on the account"
out=$(draw "$POPULATED" "$EFFECTIVE" "$ENTRY")
assert_eq "$(said_about "$out" zimbraMailQuota)" "$ZRO_TXT_ON_ENTRY"

it "an attribute only the expanding read carries is reported as inherited"
out=$(draw "$BARE" "$BARE_EFFECTIVE" "$BARE_ENTRY")
assert_eq "$(said_about "$out" zimbraMailQuota)" "$ZRO_TXT_INHERITED"

it "an attribute absent from BOTH forms is unset, never inherited"
# The case the whole three-state answer exists for. An attribute nobody set
# anywhere is not a value waiting on a class of service, and reporting it as
# inherited would send an operator to read a COS that has nothing to say about it
# either — the wrong repair, arrived at from a screen that was meant to prevent
# exactly that.
out=$(draw "$POPULATED" "$EFFECTIVE" "$ENTRY")
assert_eq "$(said_about "$out" zimbraTwoFactorAuthEnabled)" "$ZRO_TXT_UNSET"
assert_eq "$(said_about "$out" zimbraIsAdminAccount)" "$ZRO_TXT_UNSET"

it "and the same account gives all three answers on one screen"
# Not three separate screens agreeing with three separate fixtures: one drawing,
# carrying every kind of answer it can give.
#
# READ OFF THE ATTRIBUTE LINES, never off the screen. All three words also appear
# in the legend at the bottom, so a search of the whole text would find every one
# of them on a screen that had answered the same thing sixteen times.
out=$(draw "$POPULATED" "$EFFECTIVE" "$ENTRY")
distinct=$(for attr in "${ZRO_ACCOUNT_ATTRS[@]}"; do said_about "$out" "$attr"; done \
           | sort -u | grep -c .)
assert_eq "$distinct" "3"

it "every attribute the card shows gets a line of its own"
out=$(draw "$POPULATED" "$EFFECTIVE" "$ENTRY")
missing=""
for attr in "${ZRO_ACCOUNT_ATTRS[@]}"; do
  case $out in
    *"$attr"*) ;;
    *) missing="$missing [$attr]" ;;
  esac
done
assert_eq "$missing" ""

it "and each word it can print is explained on the screen that prints it"
# Three words carry the entire content of this screen and none of them says what
# it means on its own — least of all to the operator reading it under pressure,
# which is the only time this screen is opened.
out=$(draw "$POPULATED" "$EFFECTIVE" "$ENTRY")
assert_contains "$out" "kendi kaydinda duruyor"
assert_contains "$out" "COS veya"
assert_contains "$out" "hicbir"

it "the column is derived from the names, not counted by hand"
# The longest attribute name decides where the answers start. Asserted rather
# than trusted, because the list it is derived from grows and a screen whose
# widest line runs into its own value column is a screen nobody can scan.
w=$(zro_provenance_label_w)
for attr in "${ZRO_ACCOUNT_ATTRS[@]}"; do
  [ "${#attr}" -le "$w" ] || zro_t_fail "label column $w is narrower than $attr"
done
assert_eq "$(( w >= 1 ))" "1"

# --------------------------------------------------------- absence, not emptiness --

it "provenance is decided by the line being there, not by what is on it"
# zmprov omits an attribute nobody set, so the line's absence IS the signal. A
# value that happened to read as empty must not be reported as an attribute the
# entry does not carry — on the one screen built to tell those two apart, that is
# the wrong answer rather than a rough one.
empty_line="# name x@example.com
zimbraMailQuota: "
assert_ok zro_attr_present "$empty_line" zimbraMailQuota
assert_eq "$(zro_provenance_state "$empty_line" "$empty_line" zimbraMailQuota)" "entry"

it "and a line with nothing at all after its colon is still a line"
# BOTH SHAPES AN EMPTY VALUE COULD TAKE, because which one zmprov would write has
# not been measured and this must not rest on the answer. The value readers match
# on the space after the separator and would call both of these empty, which is
# right about the value; the presence test matches on the separator alone, which
# is right about the line. Reading the line as absent would report an attribute
# the entry really carries as one it inherits.
no_space="# name x@example.com
zimbraMailQuota:"
assert_ok zro_attr_present "$no_space" zimbraMailQuota
assert_eq "$(zro_provenance_state "$no_space" "$no_space" zimbraMailQuota)" "entry"
assert_eq "$(zro_attr_get "$no_space" zimbraMailQuota)" ""

it "and a name is not read as a longer name that starts with it"
# zmprov really does answer with zimbraMailForwardingAddressMaxLength beside
# zimbraMailForwardingAddress, measured on the lab server. A presence test that
# matched a prefix would report a limit attribute as a forwarding address, and
# would do it silently.
collision="zimbraMailForwardingAddressMaxLength: 4096"
assert_fail zro_attr_present "$collision" zimbraMailForwardingAddress
assert_ok zro_attr_present "zimbraMailForwardingAddress: a@b.com" zimbraMailForwardingAddress

# -------------------------------------------------------------- what it executes --

it "it asks for the entry-only form, in the one spelling the gate approves"
: >"$ZRO_MOCK_LOG"
draw "$POPULATED" "$EFFECTIVE" "$ENTRY" >/dev/null
assert_contains "$(ran)" "$(printf 'zmprov\tga\t-e\t%s' "$POPULATED")"

it "and asks for the same attributes in both forms"
# A screen that asked one form for fewer attributes than the other would report
# the difference between two questions as the difference between two answers,
# and every attribute it left out of the entry-only read would come back
# 'inherited' — a wrong answer that looks exactly like a right one.
: >"$ZRO_MOCK_LOG"
draw "$POPULATED" "$EFFECTIVE" "$ENTRY" >/dev/null
plain=$(ran | grep -F "$(printf 'zmprov\tga\t%s' "$POPULATED")" | head -n 1)
entry=$(ran | grep -F "$(printf 'zmprov\tga\t-e\t%s' "$POPULATED")" | head -n 1)
assert_eq "${entry#*"$POPULATED"}" "${plain#*"$POPULATED"}"

it "it spends two invocations and no more"
: >"$ZRO_MOCK_LOG"
draw "$POPULATED" "$EFFECTIVE" "$ENTRY" >/dev/null
assert_eq "$(ran | grep -c '^zmprov')" "2"

it "the account card does not run it"
# THE REASON THIS IS A SCREEN AND NOT A FIELD. The card answers from one
# invocation per entry it names; a caveat on one of its lines is not worth
# doubling that for every operator who never asked where the value came from.
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ZMPROV_GA_OUT="$EFFECTIVE" ZRO_MOCK_ZMPROV_GC_OUT="$FIX/zmprov_gc_ok.txt" \
  zro_account_card "$POPULATED" >/dev/null
assert_not_contains "$(ran)" "$(printf '\t-e')"

it "and neither does the read the quota screen takes its limit from"
# The quota screen is where the question comes up — is this limit set on the
# account or inherited — and it still answers with the value in force and nothing
# about its origin. That screen is a mailbox screen now and lives in
# tests/test_store.sh, which counts its reads; what belongs here is the limit
# read it shares with the card.
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ZMPROV_GA_OUT="$EFFECTIVE" \
  zro_account_quota_limit "$(ZRO_MOCK_ZMPROV_GA_OUT="$EFFECTIVE" \
                             zro_account_fetch "$POPULATED")" >/dev/null
assert_not_contains "$(ran)" "$(printf '\t-e')"

it "it validates the address before running anything"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_INPUT" zro_account_provenance 'a@b.com; id'
assert_status "$ZRO_E_INPUT" zro_account_entry_fetch '-e'
assert_not_contains "$(ran)" "zmprov"

it "a missing account fails the screen rather than answering about nothing"
ZRO_MOCK_ZMPROV_GA__E_ERR="$FIX/zmprov_ga_no_such_account.err" \
ZRO_MOCK_ZMPROV_GA__E_RC=1 \
  assert_status "$ZRO_E_NO_ACCOUNT" zro_account_provenance 'yok@example.com'

# ------------------------------------------------- the outage it cannot answer in --

it "a mailboxd outage is reported as an outage, not as a defect"
# THE ENTRY-ONLY READ HAS NO APPROVED LDAP FORM, and `zmprov -l ga -e` has never
# been run on the lab server, so it is not in the allowlist. Without a guard the
# degraded read path would retry it anyway, the gate would refuse it, and the
# refusal would be logged as a DEFECT — during an ordinary outage, on a tool whose
# whole point is that an allowlist denial means somebody's mistake.
: >"$ZRO_MOCK_LOG"
rc=0
said=$(ZRO_MOCK_ZMPROV_GA__E_ERR="$FIX/zmprov_io_error_refused.err" \
       ZRO_MOCK_ZMPROV_GA__E_RC=1 \
       zro_account_provenance "$POPULATED" 2>&1 >/dev/null) || rc=$?
assert_eq "$rc" "$ZRO_E_UNAVAILABLE"
assert_not_contains "$said" "denied by allowlist"

it "and the retry it would have made is never attempted"
assert_not_contains "$(ran)" "$(printf 'zmprov\t-l\tga\t-e')"
assert_not_contains "$(ran)" "$(printf 'zmprov\t-l')"

it "the gate refuses that form even if something calls it"
# The guard above decides not to ASK. This is the list still refusing to answer —
# two independent things, and the second is the one the guarantee rests on.
assert_fail zro_allowed zmprov -l ga -e "$POPULATED"
assert_fail zro_ldap_form_allowed ga -e "$POPULATED"

it "while every read that does have an LDAP form still retries into it"
# The guard may not cost the degraded path anything it had. Same outage, ordinary
# account read: it falls back, it answers, and it says which mode answered.
: >"$ZRO_MOCK_LOG"
out=$(ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_io_error_refused.err" \
      ZRO_MOCK_ZMPROV_GA_RC=1 \
      ZRO_MOCK_ZMPROV__L_GA_OUT="$FIX/zmprov_l_ga_active.txt" \
      zro_account_card "$POPULATED")
assert_contains "$out" "LDAP"
assert_contains "$(ran)" "$(printf 'zmprov\t-l\tga')"
assert_ok zro_ldap_form_allowed ga "$POPULATED"

rm -f -- "$ZRO_MOCK_LOG"
zro_t_report
