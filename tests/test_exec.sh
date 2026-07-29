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
export ZRO_TIMEOUT=60
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* 2>/dev/null || true

# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG

it "denies a command outside the allowlist and never executes it"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" zro_exec zmprov ma 'a@b.com'
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "denies a binary that is not on the list at all"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" zro_exec zmmailbox search 'x'
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "denies a call with too few arguments"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" zro_exec zmprov
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "logs every denial"
captured=$(ZRO_MOCK_ID_USER=zimbra zro_exec zmprov ma 'a@b.com' 2>&1 >/dev/null)
assert_contains "$captured" "denied"
assert_contains "$captured" "zmprov ma"

it "reports a missing binary as a capability failure"
ZRO_ZIMBRA_BIN=/nonexistent ZRO_MOCK_ID_USER=zimbra \
  assert_status "$ZRO_E_NOCAP" zro_exec zmprov ga 'a@b.com'

it "refuses to run as an unsupported operating-system user"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=nobody assert_status "$ZRO_E_BADUSER" zro_exec zmprov ga 'a@b.com'
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "zmprov"

it "as zimbra, wraps in timeout but not in runuser"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra zro_exec zmprov ga 'a@b.com' >/dev/null 2>&1
log=$(cat "$ZRO_MOCK_LOG")
assert_not_contains "$log" "runuser"
assert_contains "$log" "$(printf 'timeout\t-k\t5\t60')"
assert_contains "$log" "$(printf 'zmprov\tga\ta@b.com')"

it "as root, places timeout inside the runuser wrapper"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=root zro_exec zmprov ga 'a@b.com' >/dev/null 2>&1
runuser_line=$(grep '^runuser' "$ZRO_MOCK_LOG")
assert_contains "$runuser_line" "$(printf 'runuser\t-u\tzimbra\t--')"
# The token straight after -- is what runuser executes. timeout being there is
# the whole point: outside the wrapper, killing runuser would orphan the JVM.
assert_contains "$runuser_line" "$(printf -- '--\t%s/mocks/bin/timeout\t-k\t5\t60' "$ZRO_TEST_ROOT")"
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'zmprov\tga\ta@b.com')"

it "passes an argument containing spaces as a single field"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra zro_exec zmprov ga 'a b@c.com' >/dev/null 2>&1
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'zmprov\tga\ta b@c.com')"

it "passes shell metacharacters through as literal data"
: >"$ZRO_MOCK_LOG"
rm -f /tmp/zro_pwned
ZRO_MOCK_ID_USER=zimbra zro_exec zmprov ga 'x; touch /tmp/zro_pwned' >/dev/null 2>&1
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'zmprov\tga\tx; touch /tmp/zro_pwned')"
assert_fail test -e /tmp/zro_pwned

it "passes a glob through without expanding it"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra zro_exec zmprov ga '*' >/dev/null 2>&1
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'zmprov\tga\t*')"

it "normalises a timeout to the documented exit code"
ZRO_MOCK_ID_USER=zimbra ZRO_MOCK_TIMEOUT_FIRE=1 \
  assert_status "$ZRO_E_TIMEOUT" zro_exec zmprov ga 'a@b.com'

it "passes through the command's own failure status"
ZRO_MOCK_ID_USER=zimbra ZRO_MOCK_ZMPROV_GA_RC=2 \
  assert_status 2 zro_exec zmprov ga 'a@b.com'

it "returns the command's stdout unchanged"
fixture=$(mktemp); printf 'zimbraAccountStatus: active\n' >"$fixture"
ZRO_MOCK_ID_USER=zimbra ZRO_MOCK_ZMPROV_GA_OUT="$fixture" \
  assert_out_eq "zimbraAccountStatus: active" zro_exec zmprov ga 'a@b.com'
rm -f -- "$fixture"

it "runs an approved LDAP-mode read and passes the flag through"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra zro_exec zmprov -l ga 'a@b.com' >/dev/null 2>&1
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'zmprov\t-l\tga\ta@b.com')"

it "denies a write subcommand hiding behind the mode flag"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" zro_exec zmprov -l ma 'a@b.com'
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "zmprov"

it "denies an unapproved read behind the mode flag"
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" zro_exec zmprov -l gmi 'a@b.com'

it "still runs the plain two-token form"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra zro_exec zmcontrol -v >/dev/null 2>&1
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'zmcontrol\t-v')"

it "zro_bin_available reflects the filesystem"
assert_ok zro_bin_available zmprov
assert_fail zro_bin_available zmmailbox
assert_fail zro_bin_available 'zmprov; rm -rf /'
assert_fail zro_bin_available ''

rm -f -- "$ZRO_MOCK_LOG"
zro_t_report
