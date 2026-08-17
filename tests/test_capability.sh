#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/table.sh
. "$ZRO_SRC/lib/table.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ZIMBRA_LIBEXEC="$ZRO_TEST_ROOT/mocks/libexec"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* "$ZRO_TEST_ROOT"/mocks/libexec/* 2>/dev/null || true

# The primary mail log, as the readability probe will find it. A real file with a
# real mode, because that is what the probe reads — and its MODE is set explicitly
# in every case below rather than left to the umask of whoever runs the suite.
LOGTREE=$(mktemp -d)
SYS="$LOGTREE/zimbra.log"
printf 'placeholder\n' >"$SYS"
export ZRO_SYSLOG_FILE="$SYS"

# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"
# shellcheck source=../lib/inventory.sh
. "$ZRO_SRC/lib/inventory.sh"
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

# --- the delivery trace's two probes ---------------------------------------

it "a mode is read one permission class at a time, in the kernel's order"
# The FIRST matching class decides and no other is consulted: a file you own with
# mode 0044 is one you cannot read, however wide the group and other bits are.
# Folding the three into an OR is the mistake this function exists not to make.
assert_ok   zro_cap_mode_readable zimbra zimbra 600 zimbra "zimbra"
assert_ok   zro_cap_mode_readable zimbra zimbra 400 zimbra "zimbra"
assert_fail zro_cap_mode_readable zimbra zimbra 200 zimbra "zimbra"
assert_fail zro_cap_mode_readable zimbra zimbra 044 zimbra "zimbra"
# In the file's group, so the group bits decide and the other bits do not.
assert_ok   zro_cap_mode_readable syslog adm 640 zimbra "zimbra adm"
assert_fail zro_cap_mode_readable syslog adm 604 zimbra "zimbra adm"
# Not in it, so the other bits decide.
assert_ok   zro_cap_mode_readable syslog adm 604 zimbra "zimbra"

it "the misconfiguration this probe exists to find reads as unreadable"
# rsyslog creating the mail log itself leaves it syslog:adm 0640, and the zimbra
# account is in neither that group nor the file's ownership. root can read it and
# zimbra cannot, which is the one configuration where dropping identity loses
# access — and the reason it is diagnosed rather than escalated around.
assert_fail zro_cap_mode_readable syslog adm 640 zimbra "zimbra"
# The state Zimbra's own tooling leaves it in, for contrast.
assert_ok zro_cap_mode_readable zimbra zimbra 644 zimbra "zimbra"

it "a four-digit mode means what its last three digits mean"
assert_ok   zro_cap_mode_readable zimbra zimbra 0644 zimbra "zimbra"
assert_fail zro_cap_mode_readable syslog adm 0640 zimbra "zimbra"

it "a mode that is not a mode is never readable"
for mode in '' 64 64444 abc 088 ' 644' '6 4' '-rw-r--r--'; do
  assert_fail zro_cap_mode_readable zimbra zimbra "$mode" zimbra "zimbra"
done

it "and a reader with no name is never a group member either"
# Checked before anything else: a nameless account matching the file's group name
# would otherwise be read as a member of it.
assert_fail zro_cap_mode_readable zimbra zimbra 644 '' "zimbra"
assert_fail zro_cap_mode_readable '' '' 644 '' ""

it "a group nobody could name decides nothing"
# A file whose group stat could not name and an account in no groups at all must
# not match each other on the empty string: the other bits decide instead, which is
# the class that really applies.
assert_fail zro_cap_mode_readable syslog '' 040 zimbra ""
assert_ok   zro_cap_mode_readable syslog '' 044 zimbra ""

it "the tracing binary is probed as the operation the allowlist names"
zro_cap_reset
assert_ok zro_cap_trace_bin
zro_cap_reset
ZRO_ZIMBRA_LIBEXEC=/nonexistent assert_fail zro_cap_trace_bin

it "and it is asked once and remembered for the session"
zro_cap_reset
assert_ok zro_cap_trace_bin
# The answer stands for the session: it was asked, and the host cannot change it
# out from under a menu that has already been drawn from it.
ZRO_ZIMBRA_LIBEXEC=/nonexistent assert_ok zro_cap_trace_bin
zro_cap_reset
ZRO_ZIMBRA_LIBEXEC=/nonexistent assert_fail zro_cap_trace_bin

it "the capability override pins it, and is not remembered as an answer"
zro_cap_reset
ZRO_CAP_FORCE_TRACE_BIN=no assert_fail zro_cap_trace_bin
ZRO_ZIMBRA_LIBEXEC=/nonexistent ZRO_CAP_FORCE_TRACE_BIN=yes assert_ok zro_cap_trace_bin
# Neither forced answer went into the cache, so the host is still asked.
zro_cap_reset
ZRO_ZIMBRA_LIBEXEC=/nonexistent assert_fail zro_cap_trace_bin

it "the primary log is readable when its mode says everyone may read it"
chmod 644 -- "$SYS"
zro_cap_reset
assert_ok zro_cap_trace_log
assert_out_eq "ok" zro_cap_trace_log_reason

it "and unreadable when it says nobody may"
chmod 000 -- "$SYS"
zro_cap_reset
assert_fail zro_cap_trace_log
assert_out_eq "unreadable" zro_cap_trace_log_reason

it "the answer is the same whoever is running the tool"
# root can read a file the zimbra account cannot, so a probe testing its OWN
# access would answer yes to exactly the misconfiguration this one exists to find.
# It asks about the account every command runs as instead, which is why the
# identity decision needs no branch for any of this.
zro_cap_reset; ZRO_MOCK_ID_USER=zimbra assert_fail zro_cap_trace_log
zro_cap_reset; ZRO_MOCK_ID_USER=root   assert_fail zro_cap_trace_log

it "and it asks about that account by name"
# The account's own groups are read from the host, not assumed, because the group
# class is what decides the syslog:adm case. Which membership implies what is the
# table above; that the probe asks about the right account is this.
zro_cap_reset
: >"$ZRO_MOCK_LOG"
zro_cap_trace_log 2>/dev/null
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'id\t-Gn\tzimbra')"

it "a log that is not there is missing, not unreadable"
# Different causes, different repairs: a mode is not the problem when the file is not
# found, and a message naming the permission repair tool would send an operator
# looking for one.
zro_cap_reset
ZRO_SYSLOG_FILE=/nonexistent/zimbra.log assert_fail zro_cap_trace_log
zro_cap_reset
ZRO_SYSLOG_FILE=/nonexistent/zimbra.log assert_out_eq "missing" zro_cap_trace_log_reason

it "a log this tool would refuse to read is denied, not missing"
# The probe applies the inventory's own admission, so the menu and the search cannot
# disagree: without it an inadmissible path would offer the entry and then refuse the
# search, telling the operator an operation is not on the allowlist — about a path.
# A setting to correct is not a file that is absent, and not a mode to repair.
zro_cap_reset
ZRO_SYSLOG_FILE="$LOGTREE/zimbra log.txt" assert_out_eq "denied" zro_cap_trace_log_reason
zro_cap_reset
ZRO_SYSLOG_FILE="relative/zimbra.log" assert_out_eq "denied" zro_cap_trace_log_reason
zro_cap_reset
ZRO_SYSLOG_FILE="$LOGTREE/../zimbra.log" assert_out_eq "denied" zro_cap_trace_log_reason
# A log root nobody configured is the same kind of defect, and reaches the same
# screen: there is no file to name, so there is nothing to say about its mode.
zro_cap_reset
ZRO_SYSLOG_FILE="" assert_out_eq "denied" zro_cap_trace_log_reason

it "the reason is asked for the probe, never for an empty cache"
# A caller that asks why before asking whether must not be told nothing is wrong.
chmod 000 -- "$SYS"
zro_cap_reset
assert_out_eq "unreadable" zro_cap_trace_log_reason

it "the capability override pins the log probe too"
zro_cap_reset
ZRO_CAP_FORCE_TRACE_LOG=ok assert_ok zro_cap_trace_log
ZRO_CAP_FORCE_TRACE_LOG=unreadable assert_fail zro_cap_trace_log
ZRO_CAP_FORCE_TRACE_LOG=unreadable assert_out_eq "unreadable" zro_cap_trace_log_reason
ZRO_CAP_FORCE_TRACE_LOG=missing assert_out_eq "missing" zro_cap_trace_log_reason
ZRO_CAP_FORCE_TRACE_LOG=denied assert_out_eq "denied" zro_cap_trace_log_reason

it "a forced answer nobody recognises is a defect, not a diagnosis"
# Echoing it verbatim would let a typo pick a screen — and the screen it picks names
# a repair for a cause nobody diagnosed. Refused as the strictest answer there is, so
# a mistyped override can only ever hide the feature.
zro_cap_reset
ZRO_CAP_FORCE_TRACE_LOG=OK assert_fail zro_cap_trace_log
ZRO_CAP_FORCE_TRACE_LOG=OK assert_out_eq "unreadable" zro_cap_trace_log_reason
captured=$(ZRO_CAP_FORCE_TRACE_LOG=OK zro_cap_trace_log_reason 2>&1 >/dev/null)
assert_contains "$captured" "ZRO_CAP_FORCE_TRACE_LOG=OK"
ZRO_CAP_FORCE_TRACE_BIN=YES assert_fail zro_cap_trace_bin
captured=$(ZRO_CAP_FORCE_TRACE_BIN=YES zro_cap_trace_bin 2>&1)
assert_contains "$captured" "ZRO_CAP_FORCE_TRACE_BIN=YES"
# And neither defect was remembered as an answer about this host.
zro_cap_reset
chmod 644 -- "$SYS"
assert_ok zro_cap_trace_log

it "which probe refused is answered once, and the binary comes first"
# The one place the two probes are ranked. A screen that asked each probe again to
# find out which refused would rank them a second time, and the pair that drifted
# would be the mark on the menu entry and the message behind it.
zro_cap_reset
assert_out_eq "ok" zro_cap_trace_reason
zro_cap_reset
ZRO_CAP_FORCE_TRACE_BIN=no assert_out_eq "nobin" zro_cap_trace_reason
zro_cap_reset
ZRO_CAP_FORCE_TRACE_LOG=unreadable assert_out_eq "unreadable" zro_cap_trace_reason
zro_cap_reset
ZRO_CAP_FORCE_TRACE_LOG=missing assert_out_eq "missing" zro_cap_trace_reason
# Neither on this host: the binary is named, because repairing the log permission
# changes nothing until the binary is there.
zro_cap_reset
ZRO_CAP_FORCE_TRACE_BIN=no ZRO_CAP_FORCE_TRACE_LOG=unreadable \
  assert_out_eq "nobin" zro_cap_trace_reason

it "a delivery trace needs both probes, asked as one question"
chmod 644 -- "$SYS"
zro_cap_reset
assert_ok zro_cap_trace_available
ZRO_CAP_FORCE_TRACE_BIN=no assert_fail zro_cap_trace_available
ZRO_CAP_FORCE_TRACE_LOG=unreadable assert_fail zro_cap_trace_available
ZRO_CAP_FORCE_TRACE_BIN=no ZRO_CAP_FORCE_TRACE_LOG=unreadable \
  assert_fail zro_cap_trace_available

it "zro_cap_reset forgets every probe, not only the version"
zro_cap_reset
assert_ok zro_cap_trace_available
zro_cap_reset
ZRO_ZIMBRA_LIBEXEC=/nonexistent assert_fail zro_cap_trace_bin
zro_cap_reset
chmod 000 -- "$SYS"
assert_fail zro_cap_trace_log
chmod 644 -- "$SYS"

# --- the log search, and the promise it cannot keep without two commands ------

it "a log search needs the two commands that make it yield"
# NOT a probe about a log. Which files are readable is answered by the scan itself
# and disclosed as a partial scan; what can be known beforehand is whether this
# host can run a scan at reduced processor and idle disk priority at all.
assert_ok zro_cap_search_available
assert_out_eq "ok" zro_cap_search_reason

it "and reports a host without either of them as the same one cause"
# One cause because there is one repair: both commands come from the base system,
# and a scan that cannot yield is refused whichever of them is missing.
ZRO_NICE_BIN='' assert_out_eq "noprio" zro_cap_search_reason
ZRO_IONICE_BIN='' assert_out_eq "noprio" zro_cap_search_reason
ZRO_NICE_BIN='' ZRO_IONICE_BIN='' assert_out_eq "noprio" zro_cap_search_reason
ZRO_NICE_BIN='' assert_fail zro_cap_search_available
ZRO_IONICE_BIN='' assert_fail zro_cap_search_available

it "and it is not cached, because the fact it reads cannot go stale"
# The trace's probes cache because each costs a filesystem walk or an invocation.
# This one reads two variables the gate reads anyway, so a cache would be a second
# copy of a fact that is already free — and one that zro_cap_reset would have to
# remember to clear.
zro_cap_reset
ZRO_NICE_BIN='' assert_out_eq "noprio" zro_cap_search_reason
assert_out_eq "ok" zro_cap_search_reason

rm -f -- "$ZRO_MOCK_LOG"
rm -rf -- "$LOGTREE"
zro_t_report
