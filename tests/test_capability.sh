#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* 2>/dev/null || true

# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"
# shellcheck source=../lib/capability.sh
. "$ZRO_SRC/lib/capability.sh"

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG
export ZRO_MOCK_ID_USER=zimbra
export ZRO_MOCK_ZMCONTROL__V_OUT="$ZRO_TEST_ROOT/fixtures/zmcontrol_v.txt"

it "reads the version through the exec gate"
zro_cap_reset
assert_contains "$(zro_cap_version)" "Release 10.0.8"

it "caches the version, running zmcontrol only once"
zro_cap_reset
: >"$ZRO_MOCK_LOG"
zro_cap_version >/dev/null
zro_cap_version >/dev/null
zro_cap_version >/dev/null
assert_eq "$(grep -c '^zmcontrol' "$ZRO_MOCK_LOG")" "1"

it "zro_cap_reset makes the next call probe again"
: >"$ZRO_MOCK_LOG"
zro_cap_reset
zro_cap_version >/dev/null
assert_eq "$(grep -c '^zmcontrol' "$ZRO_MOCK_LOG")" "1"

it "ZRO_CAP_FORCE replaces the probe entirely"
zro_cap_reset
: >"$ZRO_MOCK_LOG"
ZRO_CAP_FORCE="Release 8.8.15" assert_out_eq "Release 8.8.15" zro_cap_version
assert_eq "$(grep -c '^zmcontrol' "$ZRO_MOCK_LOG")" "0"

it "an unreachable Zimbra yields an empty version, not an error string"
zro_cap_reset
ZRO_ZIMBRA_BIN=/nonexistent assert_out_eq "" zro_cap_version
zro_cap_reset

it "an operation is available only when allowlisted and present"
assert_ok zro_cap_op_available zmprov ga
assert_fail zro_cap_op_available zmprov ma
assert_fail zro_cap_op_available zmmailbox search
assert_fail zro_cap_op_available zmprov ''
assert_fail zro_cap_op_available '' ga

it "an allowlisted operation whose binary is missing is unavailable"
ZRO_ZIMBRA_BIN=/nonexistent assert_fail zro_cap_op_available zmprov ga

rm -f -- "$ZRO_MOCK_LOG"
zro_t_report
