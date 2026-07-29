#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
MOCKBIN="$ZRO_TEST_ROOT/mocks/bin"
chmod +x "$MOCKBIN"/* 2>/dev/null || true

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG

it "records the exact argument vector it received"
: >"$ZRO_MOCK_LOG"
"$MOCKBIN/zmprov" ga 'user@example.com' zimbraMailQuota >/dev/null 2>&1
assert_eq "$(cat "$ZRO_MOCK_LOG")" "$(printf 'zmprov\tga\tuser@example.com\tzimbraMailQuota')"

it "records an argument containing spaces as one field"
: >"$ZRO_MOCK_LOG"
"$MOCKBIN/zmprov" ga 'subject with spaces' >/dev/null 2>&1
assert_eq "$(cat "$ZRO_MOCK_LOG")" "$(printf 'zmprov\tga\tsubject with spaces')"

it "writes the configured fixture to stdout"
fixture=$(mktemp); printf 'zimbraAccountStatus: active\n' >"$fixture"
ZRO_MOCK_ZMPROV_GA_OUT="$fixture" assert_out_eq "zimbraAccountStatus: active" "$MOCKBIN/zmprov" ga x
rm -f -- "$fixture"

it "exits with the configured status"
ZRO_MOCK_ZMPROV_GA_RC=1 assert_status 1 "$MOCKBIN/zmprov" ga x

it "runuser strips its own flags and execs the rest"
: >"$ZRO_MOCK_LOG"
"$MOCKBIN/runuser" -u zimbra -- "$MOCKBIN/zmprov" gmi 'a@b.com' >/dev/null 2>&1
assert_contains "$(cat "$ZRO_MOCK_LOG")" "runuser"
assert_contains "$(cat "$ZRO_MOCK_LOG")" "zmprov"

it "timeout strips -k and the duration, then execs"
: >"$ZRO_MOCK_LOG"
"$MOCKBIN/timeout" -k 5 60 "$MOCKBIN/zmprov" ga 'a@b.com' >/dev/null 2>&1
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'timeout\t-k\t5\t60')"
assert_contains "$(cat "$ZRO_MOCK_LOG")" "zmprov"

it "timeout can simulate expiry"
ZRO_MOCK_TIMEOUT_FIRE=1 assert_status 124 "$MOCKBIN/timeout" -k 5 60 "$MOCKBIN/zmprov" ga x

it "id reports the configured user"
ZRO_MOCK_ID_USER=root assert_out_eq "root" "$MOCKBIN/id" -un

it "zmcontrol answers the version probe from its fixture"
assert_contains "$(ZRO_MOCK_ZMCONTROL__V_OUT="$ZRO_TEST_ROOT/fixtures/zmcontrol_v.txt" "$MOCKBIN/zmcontrol" -v)" "Release"

rm -f -- "$ZRO_MOCK_LOG"
zro_t_report
