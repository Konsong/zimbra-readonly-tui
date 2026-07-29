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

it "never calls the server-wide quota command"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
ZRO_MOCK_ZMPROV_GMI_OUT="$FIX/zmprov_gmi_ok.txt" \
  zro_account_quota 'ahmet.yilmaz@example.com' >/dev/null
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "gqu"
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "getQuotaUsage"

it "reads per-account usage from gmi"
: >"$ZRO_MOCK_LOG"
info=$(ZRO_MOCK_ZMPROV_GMI_OUT="$FIX/zmprov_gmi_ok.txt" zro_account_mailbox_info 'a@b.com')
assert_contains "$info" "mailboxId: 214"
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'zmprov\tgmi\ta@b.com')"

it "renders quota with limit, usage and percentage"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
      ZRO_MOCK_ZMPROV_GMI_OUT="$FIX/zmprov_gmi_ok.txt" \
      zro_account_quota 'ahmet.yilmaz@example.com')
assert_contains "$out" "214"
assert_contains "$out" "1.0 GB"
assert_contains "$out" "5.0 GB"
assert_contains "$out" "20%"

it "reports an account that is exactly at its quota"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
      ZRO_MOCK_ZMPROV_GMI_OUT="$FIX/zmprov_gmi_full.txt" \
      zro_account_quota 'ahmet.yilmaz@example.com')
assert_contains "$out" "100%"

it "reports unlimited quota without dividing by zero"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_locked.txt" \
      ZRO_MOCK_ZMPROV_GMI_OUT="$FIX/zmprov_gmi_ok.txt" \
      zro_account_quota 'kilitli@example.com')
assert_contains "$out" "sinirsiz"
assert_not_contains "$out" "%"

it "maps a missing mailbox to the documented exit code"
ZRO_MOCK_ZMPROV_GMI_ERR="$FIX/zmprov_gmi_no_mailbox.err" \
ZRO_MOCK_ZMPROV_GMI_RC=1 \
  assert_status "$ZRO_E_NO_MAILBOX" zro_account_mailbox_info 'yok@example.com'

it "lists distribution-list membership"
out=$(ZRO_MOCK_ZMPROV_GAM_OUT="$FIX/zmprov_gam_ok.txt" \
      zro_account_membership 'ahmet.yilmaz@example.com')
assert_contains "$out" "bilgi-islem@example.com"
assert_contains "$out" "tum-personel@example.com"

it "reports no membership distinctly from an error"
empty=$(mktemp); : >"$empty"
ZRO_MOCK_ZMPROV_GAM_OUT="$empty" \
  assert_status "$ZRO_E_NO_RESULT" zro_account_membership 'yalniz@example.com'
rm -f -- "$empty"

it "resolves a COS id to its name"
ZRO_MOCK_ZMPROV_GC_OUT="$FIX/zmprov_gc_ok.txt" \
  assert_out_eq "default" zro_account_cos_name 'e00428a1-0c00-11d9-836a-000d93afea2a'

it "returns a dash for an unresolvable COS id"
assert_out_eq "-" zro_account_cos_name ""
assert_out_eq "-" zro_account_cos_name 'not a uuid; id'

it "never executes anything for a malformed COS id"
: >"$ZRO_MOCK_LOG"
zro_account_cos_name 'x; touch /tmp/zro_cos_pwned' >/dev/null
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "zmprov"

it "the summary shows the COS name, not the raw id"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
      ZRO_MOCK_ZMPROV_GC_OUT="$FIX/zmprov_gc_ok.txt" \
      zro_account_summary 'ahmet.yilmaz@example.com')
assert_contains "$out" "default"
assert_not_contains "$out" "e00428a1-0c00-11d9"

it "the summary survives an account with no COS set"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_locked.txt" \
      zro_account_summary 'kilitli@example.com')
assert_contains "$out" "locked"

it "validates the account before any of these calls"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_INPUT" zro_account_mailbox_info 'a@b.com; id'
assert_status "$ZRO_E_INPUT" zro_account_membership 'a@b.com; id'
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "zmprov"

rm -f -- "$ZRO_MOCK_LOG"
zro_t_report
