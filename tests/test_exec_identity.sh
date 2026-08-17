#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/table.sh
. "$ZRO_SRC/lib/table.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* 2>/dev/null || true

# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"

it "runs directly as zimbra"
assert_out_eq "direct" zro_identity_mode zimbra

it "wraps in runuser as root"
assert_out_eq "runuser" zro_identity_mode root

it "refuses every other user"
assert_status "$ZRO_E_BADUSER" zro_identity_mode nobody
assert_status "$ZRO_E_BADUSER" zro_identity_mode postfix
assert_status "$ZRO_E_BADUSER" zro_identity_mode ''
assert_status "$ZRO_E_BADUSER" zro_identity_mode 'zimbra x'
assert_status "$ZRO_E_BADUSER" zro_identity_mode 'ZIMBRA'
assert_status "$ZRO_E_BADUSER" zro_identity_mode 'zimbra2'
assert_status "$ZRO_E_BADUSER" zro_identity_mode ' zimbra'

it "prints nothing for a refused user"
assert_out_eq "" zro_identity_mode nobody

it "reads the current user from the resolved id binary"
ZRO_MOCK_ID_USER=root assert_out_eq "root" zro_current_user
ZRO_MOCK_ID_USER=zimbra assert_out_eq "zimbra" zro_current_user

it "resolves a real id binary when no override is set"
resolved=$( unset ZRO_ID_BIN ZRO_LIB_EXEC_LOADED
            # shellcheck source=../lib/exec.sh
            . "$ZRO_SRC/lib/exec.sh"
            printf '%s' "$ZRO_ID_BIN" )
case $resolved in
  /usr/bin/id|/bin/id) zro_t_pass ;;
  *) zro_t_fail "expected a real id path, got [$resolved]" ;;
esac

it "resolves production defaults for the other system binaries"
defaults=$( unset ZRO_RUNUSER ZRO_TIMEOUT_BIN ZRO_ZIMBRA_BIN ZRO_LIB_EXEC_LOADED
            # shellcheck source=../lib/exec.sh
            . "$ZRO_SRC/lib/exec.sh"
            printf '%s|%s' "$ZRO_ZIMBRA_BIN" "$ZRO_TIMEOUT_BIN" )
assert_contains "$defaults" "/opt/zimbra/bin"
assert_contains "$defaults" "timeout"

zro_t_report
