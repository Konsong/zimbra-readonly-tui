#!/usr/bin/env bash
# The log inventory's thin half: what is actually on disk under the declared
# roots. The fixture tree is built here rather than committed, because what these
# cases turn on is modification times, and a checkout does not carry those.
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/table.sh
. "$ZRO_SRC/lib/table.sh"

# Every timestamp below is a local wall-clock time, which is this tool's only
# time model. Pinned so the suite does not depend on the zone of whoever runs it.
export TZ=UTC

TREE=$(mktemp -d)
mkdir -p "$TREE/var/log" "$TREE/zimbra/log" "$TREE/empty"

# Both roots are overridden before the module is sourced, so its production
# defaults are never reached. Neither of them can be: no test may create
# /var/log/zimbra.log, which is why this seam exists at all.
export ZRO_SYSLOG_FILE="$TREE/var/log/zimbra.log"
export ZRO_LOG_DIR="$TREE/zimbra/log"

# shellcheck source=../lib/inventory.sh
. "$ZRO_SRC/lib/inventory.sh"

mk() {
  printf 'Jul 28 14:02:11 mail postfix/smtp[1]: placeholder\n' >"$1"
  touch -d "$2" -- "$1"
}

SYS="$TREE/var/log/zimbra.log"
MBOX="$TREE/zimbra/log/mailbox.log"
AUDIT="$TREE/zimbra/log/audit.log"

# The syslog family as logrotate leaves it: daily, compressed, no delaycompress,
# fired from cron.daily at 03:20 — so each rotated file's own timestamp names the
# day AFTER the lines it holds.
mk "$SYS"               '2026-07-30 10:00'
mk "$SYS.1.gz"          '2026-07-29 03:20'
mk "$SYS.2.gz"          '2026-07-28 03:20'
# The same program with dateext set, which Zimbra sets neither way, so the
# distribution's default decides at runtime. No host produces both shapes at
# once; the fixture carries both so that one pass covers both.
mk "$SYS-20260727.gz"   '2026-07-27 03:20'
# Neighbours that are not rotations of this log.
mk "$SYS.3.xz"          '2026-07-26 03:20'
mk "$SYS.bak"           '2026-07-26 03:20'
mk "$SYS.old.gz"        '2026-07-26 03:20'
mk "$TREE/var/log/nginx.log" '2026-07-30 10:00'
mkdir -p "$SYS.8"
ln -sfn /etc/passwd "$SYS.9.gz"
# A neighbour the globs reach whose NAME fails admission. The quote is the one
# character that matters: the tracer opens compressed input through a /bin/sh
# command line with the filename interpolated inside single quotes, unescaped.
ODD="$SYS.4'x.gz"
mk "$ODD" '2026-07-26 03:20'

# The mailbox log rotates by log4j2 at midnight and is compressed by a separate
# cron at 02:50, so for part of every day both forms of one rotated file are on
# disk. gzip preserves the modification time, which is why they share one.
mk "$MBOX"               '2026-07-30 09:00'
mk "$MBOX.2026-07-29"    '2026-07-30 00:00'
mk "$MBOX.2026-07-29.gz" '2026-07-30 00:00'
mk "$MBOX.2026-07-28.gz" '2026-07-29 00:00'

mk "$AUDIT"      '2026-07-30 08:00'
mk "$AUDIT.1.gz" '2026-07-29 03:20'
chmod 000 -- "$AUDIT.1.gz"

paths_of() { printf '%s\n' "$1" | cut -f2; }
found()    { paths_of "$(zro_inv_discover "$1" 2>/dev/null)"; }
logged()   { { zro_inv_discover "$1" >/dev/null; } 2>&1; }

it "discovers the live file and every rotation variant, oldest first"
assert_eq "$(found syslog)" \
  "$(printf '%s\n' "$SYS-20260727.gz" "$SYS.2.gz" "$SYS.1.gz" "$SYS")"

it "emits a modification time with each path"
out=$(zro_inv_discover syslog 2>/dev/null)
assert_eq "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" \
  "1785122400 1785208800 1785295200 1785405600 "

it "discovers both forms of one rotated file, and leaves the choice to selection"
# Discovery decides nothing. Both forms hold the same lines, so which one is read
# is selection's answer, asserted below.
assert_eq "$(found mailbox)" "$(printf '%s\n' \
  "$MBOX.2026-07-28.gz" "$MBOX.2026-07-29.gz" "$MBOX.2026-07-29" "$MBOX")"

it "discovers a file the tracer would not be able to read"
# Readability is not a discovery question. A file left out here is a file the
# ticket that discloses a partial scan can never name, and an unreadable day
# would look like a quiet one.
assert_eq "$(found audit)" "$(printf '%s\n' "$AUDIT.1.gz" "$AUDIT")"

it "leaves out a compression format the tracer cannot read, and says so"
assert_not_line "$(found syslog)" "$SYS.3.xz"
assert_contains "$(logged syslog)" "$SYS.3.xz"

it "refuses a candidate whose name fails admission, and logs it"
# Refused rather than merely unrecognised, and said out loud: this is the check
# standing between the inventory and a filename reaching a shell.
assert_not_line "$(found syslog)" "$ODD"
assert_contains "$(logged syslog)" "$ODD"

it "leaves out a neighbour that is not a rotation of the base, quietly"
# An operator's own copy is ordinary and not worth a line on stderr.
assert_not_line "$(found syslog)" "$SYS.bak"
assert_not_line "$(found syslog)" "$SYS.old.gz"
assert_not_contains "$(logged syslog)" "$SYS.bak"

it "refuses a symbolic link and logs it"
# The inventory is what keeps a log viewer from becoming a general-purpose file
# reader, and a link is a name for a file somewhere else.
assert_not_line "$(found syslog)" "$SYS.9.gz"
assert_contains "$(logged syslog)" "$SYS.9.gz"

it "leaves out a directory wearing a rotation name"
assert_not_line "$(found syslog)" "$SYS.8"

it "never reaches a log the inventory does not declare"
assert_not_contains "$(found syslog)$(found mailbox)$(found audit)" "nginx"

it "reads names and timestamps, never a line of a log"
assert_not_contains "$(found syslog)$(found mailbox)" "placeholder"

it "refuses a name the inventory does not declare"
assert_status "$ZRO_E_DENIED" zro_inv_discover nginx
assert_status "$ZRO_E_DENIED" zro_inv_discover sync
assert_status "$ZRO_E_DENIED" zro_inv_discover ''
assert_status "$ZRO_E_DENIED" zro_inv_discover
assert_contains "$(logged nginx)" "nginx"

it "refuses a root that fails path admission, before it globs anything"
# The environment decides where the logs are, and an override carrying a quote
# would reach a /bin/sh command line inside the tracer.
bad="$TREE/we'ird"
rc=0; ( ZRO_LOG_DIR="$bad"; zro_inv_discover mailbox ) >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "$ZRO_E_DENIED"
err=$( { ( ZRO_LOG_DIR="$bad"; zro_inv_discover mailbox ) >/dev/null; } 2>&1 )
assert_contains "$err" "we'ird"

it "a log that is simply not on this host is an empty answer, not a failure"
rc=0
out=$( ( ZRO_LOG_DIR="$TREE/empty"; zro_inv_discover audit ) 2>/dev/null ) || rc=$?
assert_eq "$rc" "0"
assert_eq "$out" ""

it "refuses to answer at all when it cannot read a modification time"
# An empty inventory here would be indistinguishable from a host with no logs,
# which is the ambiguity this whole feature exists to remove.
rc=0; ( ZRO_STAT_BIN=''; zro_inv_discover syslog ) >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "$ZRO_E_UNAVAILABLE"

it "hands selection exactly what it read, with no reshaping in between"
# The two halves composed: the operator's window is the afternoon of the 28th, so
# the answer must be the file rotated on the MORNING OF THE 29th.
out=$(zro_inv_discover syslog 2>/dev/null | zro_inv_select 1785240000 1785261600 2>/dev/null)
assert_eq "$out" "$(printf '2026\t%s' "$SYS.1.gz")"

it "and reads one of the two forms of a rotated file, never both"
# The afternoon of the 29th, which log4j2 left in the file it named for the 29th.
out=$(zro_inv_discover mailbox 2>/dev/null | zro_inv_select 1785326400 1785348000 2>/dev/null)
assert_eq "$out" "$(printf '2026\t%s' "$MBOX.2026-07-29.gz")"

it "reports a file's owner, group and mode as three fields in that order"
# The format has one producer here and one consumer in lib/capability.sh, which
# splits it to decide whether the account every command runs as may read the log.
# Pinned by a case rather than by a comment, so that reordering the fields fails
# here instead of quietly marking a readable log unavailable.
chmod 640 -- "$SYS"
perms=$(zro_inv_file_perms "$SYS")
assert_eq "$(printf '%s' "$perms" | awk '{print NF}')" "3"
assert_eq "$(printf '%s' "$perms" | awk '{print $1}')" "$(stat -c '%U' -- "$SYS")"
assert_eq "$(printf '%s' "$perms" | awk '{print $2}')" "$(stat -c '%G' -- "$SYS")"
assert_eq "$(printf '%s' "$perms" | awk '{print $3}')" "640"
chmod 644 -- "$SYS"

it "and answers nothing at all about a file that is not there"
# Not knowing is not a mode. The caller refuses rather than assuming readable, so
# an empty answer here has to stay empty.
assert_out_eq "" zro_inv_file_perms "$TREE/empty/nope.log"

it "reports how many bytes a file holds, which is what a scan is about to cost"
# The third question this program asks a log file, and it belongs to the module
# that declares where the logs are. What it MEANS is decided by the screen: for a
# compressed rotation this is the size on disk, not the bytes that come out of it.
assert_out_eq "$(stat -c '%s' -- "$SYS")" zro_inv_size "$SYS"

it "and answers nothing about a file that is not there, rather than zero"
# Zero is a fact about an empty file. A file nobody could stat is not one, and a
# cost declaration that showed it as zero would understate what it is about to
# spend — the caller decides what to do with the silence.
assert_out_eq "" zro_inv_size "$TREE/empty/nope.log"

chmod 644 -- "$AUDIT.1.gz" 2>/dev/null || true
rm -rf -- "$TREE"
zro_t_report
