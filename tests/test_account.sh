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

# NOT A HYPOTHETICAL. An unfiltered `zmprov ga` on the lab server returns
# zimbraMailForwardingAddressMaxLength and zimbraMailForwardingAddressMaxNumAddrs
# beside the forwarding attribute itself, and the card's whole point about
# forwarding is that the administrator-set value is read correctly.
it "reads a forwarding address whose name prefixes two other attributes"
collision='zimbraMailForwardingAddress: denetim@example.net
zimbraMailForwardingAddressMaxLength: 4096
zimbraMailForwardingAddressMaxNumAddrs: 100'
assert_out_eq "denetim@example.net" zro_attr_get "$collision" zimbraMailForwardingAddress
assert_out_eq "4096" zro_attr_get "$collision" zimbraMailForwardingAddressMaxLength
assert_eq "$(zro_attr_all "$collision" zimbraMailForwardingAddress | wc -l | tr -d ' ')" "1"

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

# A production server returned 20260728064034.819Z. The invented fixture had no
# fractional part, so the validator rejected the real thing and every account
# showed a last logon of "-".
it "accepts the fractional seconds Zimbra really writes"
assert_out_eq "2026-07-28 06:40:34" zro_zimbra_time "20260728064034.819Z"
assert_out_eq "2026-07-15 10:30:12" zro_zimbra_time "20260715103012.1Z"
assert_out_eq "2026-07-15 10:30:12" zro_zimbra_time "20260715103012.123456Z"
assert_out_eq "2026-07-15 10:30:12" zro_zimbra_time "20260715103012.819"

it "accepts an explicit timezone offset"
assert_out_eq "2026-07-15 10:30:12" zro_zimbra_time "20260715103012+0300"
assert_out_eq "2026-07-15 10:30:12" zro_zimbra_time "20260715103012.819-0500"

it "rejects malformed generalized time"
assert_status "$ZRO_E_INPUT" zro_zimbra_time "2026-07-15"
assert_status "$ZRO_E_INPUT" zro_zimbra_time ""
assert_status "$ZRO_E_INPUT" zro_zimbra_time "2026071510301Z"
assert_status "$ZRO_E_INPUT" zro_zimbra_time "2026071510301X; id"
assert_status "$ZRO_E_INPUT" zro_zimbra_time "20260715103012.Z"
assert_status "$ZRO_E_INPUT" zro_zimbra_time "20260715103012.819Z; id"
assert_status "$ZRO_E_INPUT" zro_zimbra_time "20260715103012.8199999999Z"

it "rejects an invalid account before running anything"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_INPUT" zro_account_fetch 'a@b.com; id'
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

# THE CARD IS ONE INVOCATION. A JVM start costs the same for five attributes as
# for twenty-five, so every field the card shows is asked for in this one call —
# and a field added later that quietly brings a second call with it fails here.
it "requests every attribute the card displays, in one call"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
  zro_account_fetch 'ahmet.yilmaz@example.com' >/dev/null
assert_eq "$(grep -c '^zmprov' "$ZRO_MOCK_LOG")" "1"
line=$(grep '^zmprov' "$ZRO_MOCK_LOG")
for attr in displayName zimbraAccountStatus zimbraCOSId zimbraMailHost \
            zimbraMailQuota zimbraLastLogonTimestamp zimbraMailAlias \
            zimbraMailDeliveryAddress zimbraPasswordModifiedTime \
            zimbraPasswordLockoutLockedTime zimbraTwoFactorAuthEnabled \
            zimbraFeatureTwoFactorAuthAvailable zimbraIsAdminAccount \
            zimbraIsDelegatedAdminAccount zimbraPrefMailForwardingAddress \
            zimbraMailForwardingAddress; do
  assert_contains "$line" "$(printf '\t%s' "$attr")"
done
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
       zro_account_card 'a@b.com' ) || true
assert_eq "$out" ""
assert_contains "$(zro_last_error)" "Connection refused"

it "clears the previous error on a successful call"
ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
  zro_account_fetch 'ahmet.yilmaz@example.com' >/dev/null
assert_eq "$(zro_last_error)" ""

rm -f -- "$ZRO_MOCK_LOG"
zro_t_report
