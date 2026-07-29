#!/usr/bin/env bash
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
ACTIVE=$(cat "$FIX/zmprov_ga_active.txt")

it "extracts a single attribute value"
assert_out_eq "active" zro_attr_get "$ACTIVE" zimbraAccountStatus
assert_out_eq "Ahmet Yilmaz" zro_attr_get "$ACTIVE" displayName
assert_out_eq "mail01.example.com" zro_attr_get "$ACTIVE" zimbraMailHost

it "returns empty for an absent attribute"
assert_out_eq "" zro_attr_get "$ACTIVE" zimbraNoSuchAttribute

it "does not match an attribute whose name is a prefix of another"
assert_out_eq "" zro_attr_get "$ACTIVE" zimbraMail

it "ignores the header line zmprov prints"
assert_out_eq "" zro_attr_get "$ACTIVE" '# name'

it "extracts every value of a multi-valued attribute"
aliases=$(zro_attr_all "$ACTIVE" zimbraMailAlias)
assert_contains "$aliases" "a.yilmaz@example.com"
assert_contains "$aliases" "ayilmaz@example.com"
assert_eq "$(printf '%s\n' "$aliases" | wc -l | tr -d ' ')" "2"

it "converts Zimbra generalized time"
assert_out_eq "2026-07-15 10:30:12" zro_zimbra_time "20260715103012Z"
assert_out_eq "2026-07-15 10:30:12" zro_zimbra_time "20260715103012"

it "rejects malformed generalized time"
assert_status "$ZRO_E_INPUT" zro_zimbra_time "2026-07-15"
assert_status "$ZRO_E_INPUT" zro_zimbra_time ""
assert_status "$ZRO_E_INPUT" zro_zimbra_time "2026071510301Z"
assert_status "$ZRO_E_INPUT" zro_zimbra_time "2026071510301X; id"

it "rejects an invalid account before running anything"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_INPUT" zro_account_fetch 'a@b.com; id'
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "requests only the attributes M1 displays, in one call"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
  zro_account_fetch 'ahmet.yilmaz@example.com' >/dev/null
assert_eq "$(grep -c '^zmprov' "$ZRO_MOCK_LOG")" "1"
line=$(grep '^zmprov' "$ZRO_MOCK_LOG")
assert_contains "$line" "zimbraAccountStatus"
assert_contains "$line" "zimbraMailQuota"
assert_contains "$line" "zimbraLastLogonTimestamp"
assert_not_contains "$line" "$(printf '\t-l\t')"

it "maps a missing account to the documented exit code"
ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_ga_no_such_account.err" \
ZRO_MOCK_ZMPROV_GA_RC=1 \
  assert_status "$ZRO_E_NO_ACCOUNT" zro_account_fetch 'yok@example.com'

# Both fixtures are verbatim output from real Zimbra test servers on
# 2026-07-29: one with mailboxd stopped, one with an expired admin certificate.
# zmprov speaks SOAP to mailboxd by default, so neither host could answer any
# query, and the operator saw only "islem basarisiz (kod 1)".
# A SOAP failure alone is no longer a failure: the read is retried against
# LDAP. These cases fail BOTH paths, which is what a genuinely unreachable
# Zimbra looks like. The retry itself is covered in test_prov_fallback.sh.
it "maps an unreachable mailbox service to the documented exit code"
ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_io_error_refused.err" \
ZRO_MOCK_ZMPROV_GA_RC=1 \
ZRO_MOCK_ZMPROV__L_GA_ERR="$FIX/zmprov_io_error_refused.err" \
ZRO_MOCK_ZMPROV__L_GA_RC=1 \
  assert_status "$ZRO_E_UNAVAILABLE" zro_account_fetch 'a@b.com'

it "maps a broken admin certificate to the documented exit code"
ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_io_error_ssl.err" \
ZRO_MOCK_ZMPROV_GA_RC=1 \
ZRO_MOCK_ZMPROV__L_GA_ERR="$FIX/zmprov_io_error_ssl.err" \
ZRO_MOCK_ZMPROV__L_GA_RC=1 \
  assert_status "$ZRO_E_UNAVAILABLE" zro_account_fetch 'a@b.com'

it "keeps the underlying Zimbra message for the operator to read"
ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_io_error_refused.err" \
ZRO_MOCK_ZMPROV_GA_RC=1 \
ZRO_MOCK_ZMPROV__L_GA_ERR="$FIX/zmprov_io_error_refused.err" \
ZRO_MOCK_ZMPROV__L_GA_RC=1 \
  zro_account_fetch 'a@b.com' >/dev/null 2>&1
detail=$(zro_last_error)
assert_contains "$detail" "Connection refused"

it "reports the certificate failure in the operator's own words"
ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_io_error_ssl.err" \
ZRO_MOCK_ZMPROV_GA_RC=1 \
ZRO_MOCK_ZMPROV__L_GA_ERR="$FIX/zmprov_io_error_ssl.err" \
ZRO_MOCK_ZMPROV__L_GA_RC=1 \
  zro_account_fetch 'a@b.com' >/dev/null 2>&1
detail=$(zro_last_error)
assert_contains "$detail" "PKIX"

it "keeps the message across a subshell, which is where menus read it"
out=$( ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_io_error_refused.err" \
       ZRO_MOCK_ZMPROV_GA_RC=1 \
       ZRO_MOCK_ZMPROV__L_GA_ERR="$FIX/zmprov_io_error_refused.err" \
       ZRO_MOCK_ZMPROV__L_GA_RC=1 \
       zro_account_summary 'a@b.com' ) || true
assert_eq "$out" ""
assert_contains "$(zro_last_error)" "Connection refused"

it "clears the previous error on a successful call"
ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
  zro_account_fetch 'ahmet.yilmaz@example.com' >/dev/null
assert_eq "$(zro_last_error)" ""

it "renders a summary with the operator-facing fields"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
      zro_account_summary 'ahmet.yilmaz@example.com')
assert_contains "$out" "Ahmet Yilmaz"
assert_contains "$out" "active"
assert_contains "$out" "mail01.example.com"
assert_contains "$out" "2026-07-15 10:30:12"
assert_contains "$out" "5.0 GB"

it "labels last logon as approximate"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
      zro_account_summary 'ahmet.yilmaz@example.com')
assert_contains "$out" "yaklasik"

it "lists the aliases it found"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
      zro_account_summary 'ahmet.yilmaz@example.com')
assert_contains "$out" "a.yilmaz@example.com"
assert_contains "$out" "ayilmaz@example.com"

it "handles an account with no last logon, no COS and no aliases"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_locked.txt" \
      zro_account_summary 'kilitli@example.com')
assert_contains "$out" "locked"
assert_contains "$out" "sinirsiz"
assert_contains "$out" "-"
assert_not_contains "$out" "Aliaslar"

rm -f -- "$ZRO_MOCK_LOG"
zro_t_report
