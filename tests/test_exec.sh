#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
# A directory of its own, not an alias for the one above: the tracing binary is
# installed under libexec while a stale upstream mapping still names bin, so a
# gate that resolved it under the wrong root must fail the suite rather than
# find the mock anyway.
export ZRO_ZIMBRA_LIBEXEC="$ZRO_TEST_ROOT/mocks/libexec"
# The third root: the system binaries the log viewer runs. A directory of its own
# for the same reason libexec is one — a gate that resolved them under the Zimbra
# root has to fail the suite rather than find the mock anyway.
export ZRO_SYSTEM_BIN="$ZRO_TEST_ROOT/mocks/system"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
export ZRO_TIMEOUT=60
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* "$ZRO_TEST_ROOT"/mocks/libexec/* \
         "$ZRO_TEST_ROOT"/mocks/system/* 2>/dev/null || true

# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG

it "denies a command outside the allowlist and never executes it"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" zro_exec zmprov ma 'a@b.com'
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "denies a binary that is not on the list at all"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" zro_exec zmsoap ga 'a@b.com'
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "and denies the gated binary from a caller that does not own the gate"
# It is on the list now — four reads behind the existence gate are approved — so
# what refuses it here is WHO IS ASKING, before the list is consulted at all.
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" zro_exec zmmailbox gaf 'a@b.com'
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

it "runs the binary at the path its declared root resolves to"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra zro_exec zmprov ga 'a@b.com' >/dev/null 2>&1
# What timeout was asked to run is the resolved path. Asserting on the argv
# rather than on the resolution is what proves nothing else assembled it.
assert_contains "$(grep '^timeout' "$ZRO_MOCK_LOG")" \
  "$(printf -- '%s/mocks/bin/zmprov\tga\ta@b.com' "$ZRO_TEST_ROOT")"

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

# ------------------------------------------- a flag in the data position ------
#
# Everything after an approved subcommand used to reach the binary unread, on the
# grounds that a caller validated it. A flag written there is not data: it changes
# what the command does, and one form of this very read writes files and deletes
# them. So the gate reads the data, and the argument vector below is the proof of
# what it let through.

it "runs the entry-only account read with the flag in the vector"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra zro_exec zmprov ga -e 'a@b.com' >/dev/null 2>&1
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'zmprov\tga\t-e\ta@b.com')"

it "refuses the file-writing form of the same read, and runs nothing"
# -t writes binary attribute values to files and deletes what was there first.
# The status is not the guarantee; the empty log below is.
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" zro_exec zmprov ga -t 'a@b.com'
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" zro_exec zmprov ga --temp 'a@b.com'
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" zro_exec zmprov ga -fd 'a@b.com'
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" zro_exec zmprov ga 'a@b.com' -t
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" \
  zro_exec zmprov -l ga -t 'a@b.com'
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "logs the refusal as a defect, naming the flag it refused"
# Code 90 is a defect in this program, not something an operator did — so it is
# logged like every other allowlist denial, and the line has to carry the token
# that caused it or the next reader is left guessing which one it was.
captured=$(ZRO_MOCK_ID_USER=zimbra zro_exec zmprov ga 'a@b.com' -t 2>&1 >/dev/null)
assert_contains "$captured" "[error]"
assert_contains "$captured" "denied by allowlist"
assert_contains "$captured" "zmprov ga a@b.com -t"

it "still runs the plain two-token form"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra zro_exec zmcontrol -v >/dev/null 2>&1
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'zmcontrol\t-v')"

it "zro_bin_available reflects the filesystem"
assert_ok zro_bin_available zmprov
assert_fail zro_bin_available zmpurge
assert_fail zro_bin_available 'zmprov; rm -rf /'
assert_fail zro_bin_available ''

it "resolves each binary under the root its own declaration names"
assert_out_eq "$ZRO_TEST_ROOT/mocks/bin/zmprov" zro_bin_path zmprov
assert_out_eq "$ZRO_TEST_ROOT/mocks/bin/zmcontrol" zro_bin_path zmcontrol

# Two binaries under two different declared roots is the behaviour the table
# exists for. It was simulated with a hand-built table until the tracing binary
# arrived; now it is the real declaration that is asserted.
it "resolves two binaries under two different declared roots"
two_roots=$( zro_bin_path zmprov; printf '|'; zro_bin_path zmmsgtrace )
assert_eq "$two_roots" \
  "$ZRO_TEST_ROOT/mocks/bin/zmprov|$ZRO_TEST_ROOT/mocks/libexec/zmmsgtrace"

# The stale upstream mapping names the bin path for this binary; the packaging
# installs it under libexec. Emptying the bin root has to leave tracing working,
# or the declaration is not what the gate is really using.
it "resolves the tracing binary without consulting the Zimbra bin root"
: >"$ZRO_MOCK_LOG"
ZRO_ZIMBRA_BIN=/nonexistent ZRO_MOCK_ID_USER=zimbra \
  assert_ok zro_exec zmmsgtrace --recipient 'ahmet.yilmaz@example.com'
assert_contains "$(cat "$ZRO_MOCK_LOG")" \
  "$(printf -- '%s/mocks/libexec/zmmsgtrace\t--recipient\tahmet.yilmaz@example.com' "$ZRO_TEST_ROOT")"

it "runs each approved filter of the tracing binary under the same root"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra assert_ok zro_exec zmmsgtrace --sender 'ahmet.yilmaz@example.com'
ZRO_MOCK_ID_USER=zimbra assert_ok zro_exec zmmsgtrace --id 'CAabc123@example.com'
assert_contains "$(cat "$ZRO_MOCK_LOG")" \
  "$(printf -- '%s/mocks/libexec/zmmsgtrace\t--sender\tahmet.yilmaz@example.com' "$ZRO_TEST_ROOT")"
assert_contains "$(cat "$ZRO_MOCK_LOG")" \
  "$(printf -- '%s/mocks/libexec/zmmsgtrace\t--id\tCAabc123@example.com' "$ZRO_TEST_ROOT")"

it "refuses a filter of the tracing binary that nobody approved, and runs nothing"
# The short forms of the approved filters are here too: an operation reaches the
# gate in one spelling, so `-s` is refused although `--sender` is approved.
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" \
  zro_exec zmmsgtrace -s 'ahmet.yilmaz@example.com'
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" \
  zro_exec zmmsgtrace -i 'CAabc123@example.com'
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" \
  zro_exec zmmsgtrace --srchost 'mail.example.com'
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" \
  zro_exec zmmsgtrace --time '20260729,20260730'
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" zro_exec zmmsgtrace --man
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

# --------------------------------------- the log viewer's two system binaries --
#
# The first two allowlisted binaries that are not Zimbra's, and the first to be
# resolved outside the Zimbra tree. One of them is approved narrowly enough that
# the refusal has to be shown to have an EFFECT, not just a status.

it "runs the bounded read under the system root, with the bound in the vector"
: >"$ZRO_MOCK_LOG"
plain=$(mktemp)
seq 1 40 >"$plain"
ZRO_MOCK_ID_USER=zimbra assert_out_eq "$(seq 38 40)" zro_exec tail -n 3 "$plain"
assert_contains "$(cat "$ZRO_MOCK_LOG")" \
  "$(printf -- '%s/mocks/system/tail\t-n\t3\t%s' "$ZRO_TEST_ROOT" "$plain")"

it "runs the decompression in the form that writes to stdout"
packed=$(mktemp -u).gz
seq 1 40 | gzip -c >"$packed"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra assert_out_eq "$(seq 1 40)" zro_exec gzip -dc "$packed"
assert_contains "$(cat "$ZRO_MOCK_LOG")" \
  "$(printf -- '%s/mocks/system/gzip\t-dc\t%s' "$ZRO_TEST_ROOT" "$packed")"

it "and leaves the compressed file exactly where it was"
# The whole reason this form is the only one approved: -dc reads, the forms below
# replace the file and delete the original.
assert_ok test -f "$packed"

it "refuses the in-place decompression with the allowlist-denial code"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" zro_exec gzip -d "$packed"
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" zro_exec gzip --decompress "$packed"
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "refuses the bare decompression command with the same code"
# Bare gzip COMPRESSES in place and deletes the original, which is a write by a
# command nobody suspects. Refused by being absent from the list rather than by a
# rule about it.
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" zro_exec gzip "$plain"
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" zro_exec gzip -f "$plain"
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "and every refused form left both files untouched"
# The status is not the guarantee; this is. A denial that still ran the command
# would show up here as a file that is no longer there.
assert_ok test -f "$packed"
assert_ok test -f "$plain"
assert_eq "$(wc -l <"$plain" | tr -d ' ')" "40"
assert_fail test -e "$plain.gz"
rm -f -- "$plain" "$packed"

it "refuses a bounded read that would never return"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" zro_exec tail -f '/var/log/zimbra.log'
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" zro_exec tail '/var/log/zimbra.log'
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "resolves the system binaries without consulting either Zimbra root"
assert_out_eq "$ZRO_TEST_ROOT/mocks/system/tail" zro_bin_path tail
assert_out_eq "$ZRO_TEST_ROOT/mocks/system/gzip" zro_bin_path gzip
ZRO_ZIMBRA_BIN=/nonexistent ZRO_ZIMBRA_LIBEXEC=/nonexistent assert_ok zro_bin_available tail
ZRO_ZIMBRA_BIN=/nonexistent ZRO_ZIMBRA_LIBEXEC=/nonexistent assert_ok zro_bin_available gzip

it "refuses to resolve a binary that declares no root"
# The mailbox binary was this case's example until the folder and size screens
# gave it a declaration. What the case is about is the absence of a default root,
# so any undeclared name serves — and one that exists on a real Zimbra host says
# more than an invented one: being installed is not being declared.
assert_fail zro_bin_path zmpurge
assert_fail zro_bin_path ''
# The declaration is matched as literal text, so a name carrying a glob or a
# shell metacharacter cannot borrow another binary's root.
assert_fail zro_bin_path 'zm*'
assert_fail zro_bin_path 'zmprov; rm -rf /'
assert_fail zro_bin_path zmprov:ZRO_ZIMBRA_BIN

it "refuses to resolve against a root variable that is empty"
ZRO_ZIMBRA_BIN='' assert_fail zro_bin_path zmprov

# The allowlist and the root table are two separate declarations. A binary the
# first one names and the second one does not must be refused, not resolved
# against a default — the whole point of declaring roots is that reaching a new
# directory cannot happen by omission. Every binary in the tree is declared, so
# the omission is simulated with a table that names one and forgets the other,
# which is the shape the mistake would really take.
it "refuses an allowlisted binary whose root is not declared, and runs nothing"
: >"$ZRO_MOCK_LOG"
ZRO_BIN_ROOTS='zmcontrol:ZRO_ZIMBRA_BIN' ZRO_MOCK_ID_USER=zimbra \
  assert_status "$ZRO_E_DENIED" zro_exec zmprov ga 'a@b.com'
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

# Logged wherever the declaration is read, not only by the gate: the capability
# probe resolves the same path to decide whether to offer a menu entry, and a
# missing declaration must not reach the operator as an absent program.
it "logs the refusal of an undeclared root, whichever caller reads it"
captured=$(ZRO_BIN_ROOTS='zmcontrol:ZRO_ZIMBRA_BIN' ZRO_MOCK_ID_USER=zimbra \
           zro_exec zmprov ga 'a@b.com' 2>&1 >/dev/null)
assert_contains "$captured" "denied"
assert_contains "$captured" "zmprov"
captured=$(ZRO_BIN_ROOTS='zmcontrol:ZRO_ZIMBRA_BIN' \
           zro_bin_available zmprov 2>&1 >/dev/null)
assert_contains "$captured" "denied"
assert_contains "$captured" "zmprov"

rm -f -- "$ZRO_MOCK_LOG"
zro_t_report
