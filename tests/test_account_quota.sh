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

# THE QUOTA LIMIT IS A DIRECTORY FACT and it is read here; the USAGE beside it is
# a mailbox fact and lives in lib/store.sh, behind the existence gate. This file
# is about the half that stayed: which read answered the limit, and what happens
# when nothing did.
#
# `zmprov gmi` is why the two are apart at all. Its handler, GetMailbox, calls
# MailboxManager.getMailboxByAccount(account) — the AUTOCREATE overload — so
# reading an account's usage created a mailbox for any account that had none. It
# is the only read-named admin handler that does this, and it is nowhere in this
# tool. Usage came back through a command that cannot provision, not through it.
it "reading the limit runs no mailbox command at all"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
  zro_account_card 'ahmet.yilmaz@example.com' >/dev/null
log=$(cat "$ZRO_MOCK_LOG")
assert_not_contains "$log" "$(printf '\tgmi')"
assert_not_contains "$log" "getMailboxInfo"
assert_not_contains "$log" "$(printf '\tgqu')"
assert_not_contains "$log" "getQuotaUsage"

it "the gate refuses the mailbox command even if something calls it"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_DENIED" zro_exec zmprov gmi 'a@b.com'
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "zmprov"

it "the limit is read off the account entry, and says which read answered"
raw=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
      zro_account_fetch 'ahmet.yilmaz@example.com')
assert_contains "$(zro_quota_field "$(zro_account_quota_limit "$raw")")" "5.0 GB"
assert_contains "$(zro_quota_field "$(zro_account_quota_limit "$raw")")" "hesap sorgusundan"

it "reports an unlimited quota as such, and never as zero"
# Zimbra writes zimbraMailQuota: 0 to mean unlimited.
raw=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_locked.txt" \
      zro_account_fetch 'kilitli@example.com')
assert_contains "$(zro_quota_field "$(zro_account_quota_limit "$raw")")" "sinirsiz"

it "falls back to the COS limit when the account carries none"
raw=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_l_ga_no_quota.txt" \
      zro_account_fetch 'kotasiz@example.com')
limit=$(ZRO_MOCK_ZMPROV_GC_OUT="$FIX/zmprov_gc_10gb.txt" \
        zro_account_quota_limit "$raw")
field=$(zro_quota_field "$limit")
assert_contains "$field" "10.0 GB"
assert_contains "$field" "COS kaydindan"
assert_not_contains "$field" "sinirsiz"

it "an explicit account quota still wins over the COS"
raw=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
      zro_account_fetch 'ahmet.yilmaz@example.com')
limit=$(ZRO_MOCK_ZMPROV_GC_OUT="$FIX/zmprov_gc_10gb.txt" \
        zro_account_quota_limit "$raw")
field=$(zro_quota_field "$limit")
assert_contains "$field" "5.0 GB"
assert_not_contains "$field" "10.0 GB"

it "a limit nobody could read is neither zero nor unlimited"
# The single most misleading thing this field can say. An account read that
# answered nothing has no limit in it, and the difference between that and a
# limit of 0 is the difference between 'unknown' and 'no limit at all'.
assert_status "$ZRO_E_NO_RESULT" zro_account_quota_limit ""
assert_out_eq "$ZRO_TXT_UNKNOWN" zro_quota_field ""

it "validates the account before running anything"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_INPUT" zro_account_fetch 'a@b.com; id'
assert_status "$ZRO_E_INPUT" zro_account_membership 'a@b.com; id'
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "zmprov"

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

it "the card shows the COS name, not the raw id"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
      ZRO_MOCK_ZMPROV_GC_OUT="$FIX/zmprov_gc_ok.txt" \
      zro_account_card 'ahmet.yilmaz@example.com')
assert_contains "$out" "default"
assert_not_contains "$out" "e00428a1-0c00-11d9"

it "the card survives an account with no COS set"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_locked.txt" \
      zro_account_card 'kilitli@example.com')
assert_contains "$out" "locked"

rm -f -- "$ZRO_MOCK_LOG"
zro_t_report
