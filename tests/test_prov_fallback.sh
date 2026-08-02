#!/usr/bin/env bash
set -uo pipefail
# By default zmprov talks SOAP to mailboxd. Two real test servers on
# 2026-07-29 could not answer a single query — one with the mailbox service
# stopped, one with an admin certificate that no longer validated — which is
# precisely when an administrator wants to look at an account.
#
# `zmprov -l` reads straight from LDAP and needs neither. Measured on the
# server with mailboxd stopped: -l ga, -l gam and -l gc all answered, and
# -l gmi refused with "can only be used with SOAP", because mailbox usage
# lives in the mailbox database rather than in LDAP.
#
# The fixtures here keep the shape of that real output with the names changed.
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

it "knows which subcommands LDAP can answer"
assert_ok   zro_prov_ldap_capable ga
assert_ok   zro_prov_ldap_capable gam
assert_ok   zro_prov_ldap_capable gc
assert_fail zro_prov_ldap_capable gmi
assert_fail zro_prov_ldap_capable getMailboxInfo
assert_fail zro_prov_ldap_capable ''

it "declares no mailbox command as a read"
assert_not_contains "$ZRO_PROV_READS" "gmi"
assert_not_contains "$ZRO_PROV_READS" "gqu"

it "uses SOAP when SOAP works, and says so"
: >"$ZRO_MOCK_LOG"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
      zro_prov_read "$ZRO_E_NO_ACCOUNT" ga 'ahmet.yilmaz@example.com')
assert_contains "$out" "Ahmet Yilmaz"
assert_eq "$(zro_mode)" "soap"
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "-l"

it "falls back to LDAP when the mailbox service is unreachable"
: >"$ZRO_MOCK_LOG"
out=$(ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_io_error_refused.err" \
      ZRO_MOCK_ZMPROV_GA_RC=1 \
      ZRO_MOCK_ZMPROV__L_GA_OUT="$FIX/zmprov_l_ga_active.txt" \
      zro_prov_read "$ZRO_E_NO_ACCOUNT" ga 'ahmet.yilmaz@example.com')
assert_contains "$out" "Ahmet Yilmaz"
assert_eq "$(zro_mode)" "ldap"
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'zmprov\t-l\tga')"

it "falls back when the admin certificate is the thing that is broken"
out=$(ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_io_error_ssl.err" \
      ZRO_MOCK_ZMPROV_GA_RC=1 \
      ZRO_MOCK_ZMPROV__L_GA_OUT="$FIX/zmprov_l_ga_active.txt" \
      zro_prov_read "$ZRO_E_NO_ACCOUNT" ga 'ahmet.yilmaz@example.com')
assert_contains "$out" "Ahmet Yilmaz"
assert_eq "$(zro_mode)" "ldap"

it "falls back for membership too"
out=$(ZRO_MOCK_ZMPROV_GAM_ERR="$FIX/zmprov_io_error_refused.err" \
      ZRO_MOCK_ZMPROV_GAM_RC=1 \
      ZRO_MOCK_ZMPROV__L_GAM_OUT="$FIX/zmprov_l_gam_ok.txt" \
      zro_prov_read "$ZRO_E_NO_ACCOUNT" gam 'ahmet.yilmaz@example.com')
assert_contains "$out" "sistem@example.com"

it "refuses a subcommand that was never declared a read"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_DENIED" zro_prov_read "$ZRO_E_NO_MAILBOX" gmi 'a@b.com'
assert_status "$ZRO_E_DENIED" zro_prov_read "$ZRO_E_NO_ACCOUNT" ma 'a@b.com'
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "does not reach for LDAP when the account simply does not exist"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_ga_no_such_account.err" \
ZRO_MOCK_ZMPROV_GA_RC=1 \
  assert_status "$ZRO_E_NO_ACCOUNT" zro_prov_read "$ZRO_E_NO_ACCOUNT" ga 'yok@example.com'
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'zmprov\t-l')"

it "reports the original failure when LDAP cannot help either"
ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_io_error_refused.err" \
ZRO_MOCK_ZMPROV_GA_RC=1 \
ZRO_MOCK_ZMPROV__L_GA_ERR="$FIX/zmprov_io_error_refused.err" \
ZRO_MOCK_ZMPROV__L_GA_RC=1 \
  assert_status "$ZRO_E_UNAVAILABLE" zro_prov_read "$ZRO_E_NO_ACCOUNT" ga 'a@b.com'
assert_contains "$(zro_last_error)" "Connection refused"

# When mailboxd is down, EVERY SOAP call fails — not just the first. These
# scenarios script that faithfully, or the fallback would only look tested.
it "the account card works end to end with mailboxd down"
out=$(ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_io_error_refused.err" \
      ZRO_MOCK_ZMPROV_GA_RC=1 \
      ZRO_MOCK_ZMPROV_GC_ERR="$FIX/zmprov_io_error_refused.err" \
      ZRO_MOCK_ZMPROV_GC_RC=1 \
      ZRO_MOCK_ZMPROV_GAM_ERR="$FIX/zmprov_io_error_refused.err" \
      ZRO_MOCK_ZMPROV_GAM_RC=1 \
      ZRO_MOCK_ZMPROV__L_GA_OUT="$FIX/zmprov_l_ga_active.txt" \
      ZRO_MOCK_ZMPROV__L_GC_OUT="$FIX/zmprov_gc_ok.txt" \
      ZRO_MOCK_ZMPROV__L_GAM_OUT="$FIX/zmprov_l_gam_ok.txt" \
      zro_account_card 'ahmet.yilmaz@example.com')
assert_contains "$out" "Ahmet Yilmaz"
assert_contains "$out" "active"
assert_contains "$out" "mail01.example.com"
assert_contains "$out" "default"
assert_contains "$out" "sistem@example.com"

it "warns that LDAP values may not include what a COS provides"
out=$(ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_io_error_refused.err" \
      ZRO_MOCK_ZMPROV_GA_RC=1 \
      ZRO_MOCK_ZMPROV_GC_ERR="$FIX/zmprov_io_error_refused.err" \
      ZRO_MOCK_ZMPROV_GC_RC=1 \
      ZRO_MOCK_ZMPROV_GAM_ERR="$FIX/zmprov_io_error_refused.err" \
      ZRO_MOCK_ZMPROV_GAM_RC=1 \
      ZRO_MOCK_ZMPROV__L_GA_OUT="$FIX/zmprov_l_ga_active.txt" \
      ZRO_MOCK_ZMPROV__L_GC_OUT="$FIX/zmprov_gc_ok.txt" \
      ZRO_MOCK_ZMPROV__L_GAM_OUT="$FIX/zmprov_l_gam_ok.txt" \
      zro_account_card 'ahmet.yilmaz@example.com')
assert_contains "$out" "LDAP"

it "no warning when the answer came from SOAP"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
      ZRO_MOCK_ZMPROV_GC_OUT="$FIX/zmprov_gc_ok.txt" \
      ZRO_MOCK_ZMPROV_GAM_OUT="$FIX/zmprov_gam_ok.txt" \
      zro_account_card 'ahmet.yilmaz@example.com')
assert_not_contains "$out" "LDAP"

# The COS fixture here is 10 GB while the account fixture is 5 GB, so these two
# tests actually distinguish which value was used. LDAP mode does not expand
# what a COS provides, so without the fallback an account inheriting its quota
# would be reported as unlimited — worse than reporting nothing.
it "reads the quota limit from the COS when the account does not carry one"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_l_ga_no_quota.txt" \
      ZRO_MOCK_ZMPROV_GC_OUT="$FIX/zmprov_gc_10gb.txt" \
      zro_account_card 'kotasiz@example.com')
assert_contains "$out" "10.0 GB"
assert_not_contains "$out" "sinirsiz"

it "an explicit account quota still wins over the COS"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
      ZRO_MOCK_ZMPROV_GC_OUT="$FIX/zmprov_gc_10gb.txt" \
      zro_account_card 'ahmet.yilmaz@example.com')
assert_contains "$out" "5.0 GB"
assert_not_contains "$out" "10.0 GB"

it "the limit an inherited quota resolves to survives mailboxd being down"
# The quota LIMIT is a directory fact and the degraded path answers it. Read
# through the card, because the screen that shows usage beside it is a mailbox
# screen now: usage comes from the mailbox itself, behind the existence gate,
# whose oracle speaks SOAP and nothing else.
out=$(ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_io_error_refused.err" \
      ZRO_MOCK_ZMPROV_GA_RC=1 \
      ZRO_MOCK_ZMPROV_GC_ERR="$FIX/zmprov_io_error_refused.err" \
      ZRO_MOCK_ZMPROV_GC_RC=1 \
      ZRO_MOCK_ZMPROV__L_GA_OUT="$FIX/zmprov_l_ga_no_quota.txt" \
      ZRO_MOCK_ZMPROV__L_GC_OUT="$FIX/zmprov_gc_10gb.txt" \
      zro_account_card 'kotasiz@example.com')
assert_contains "$out" "10.0 GB"
assert_contains "$out" "LDAP"

it "the banner claims no more than LDAP mode actually costs"
out=$(ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_io_error_refused.err" \
      ZRO_MOCK_ZMPROV_GA_RC=1 \
      ZRO_MOCK_ZMPROV__L_GA_OUT="$FIX/zmprov_l_ga_active.txt" \
      zro_account_card 'ahmet.yilmaz@example.com')
# zmprov expands COS-inherited values in BOTH modes -- getAttrs(expandCos)
# reaching setAccountDefaults(true) -- and only `-e` suppresses it. The banner
# used to warn that inherited settings might be missing, which was untrue.
assert_not_contains "$out" "COS uzerinden miras"

it "a genuinely missing account still fails the account card"
ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_ga_no_such_account.err" \
ZRO_MOCK_ZMPROV_GA_RC=1 \
  assert_status "$ZRO_E_NO_ACCOUNT" zro_account_card 'yok@example.com'

rm -f -- "$ZRO_MOCK_LOG"
zro_t_report
