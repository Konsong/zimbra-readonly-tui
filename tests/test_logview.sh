#!/usr/bin/env bash
# The bounded log viewer's engine: what it reads, how much of it, and everything
# it refuses to read at all.
#
# The fixture tree is built here rather than committed, for the reason
# tests/test_inventory_discover.sh gives: what these cases turn on is which files
# exist under the declared roots, and a checkout carries neither the compression
# nor the modification times.
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ZIMBRA_LIBEXEC="$ZRO_TEST_ROOT/mocks/libexec"
export ZRO_SYSTEM_BIN="$ZRO_TEST_ROOT/mocks/system"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
export ZRO_MOCK_ID_USER=zimbra
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* "$ZRO_TEST_ROOT"/mocks/libexec/* \
         "$ZRO_TEST_ROOT"/mocks/system/* 2>/dev/null || true

# Local wall clock is this tool's only time model; the zone is pinned so the
# suite does not depend on the zone of whoever runs it.
export TZ=UTC

TREE=$(mktemp -d)
mkdir -p "$TREE/var/log" "$TREE/zimbra/log"
export ZRO_SYSLOG_FILE="$TREE/var/log/zimbra.log"
export ZRO_LOG_DIR="$TREE/zimbra/log"

# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"
# shellcheck source=../lib/inventory.sh
. "$ZRO_SRC/lib/inventory.sh"
# shellcheck source=../lib/logview.sh
. "$ZRO_SRC/lib/logview.sh"

SYS="$TREE/var/log/zimbra.log"
MBOX="$TREE/zimbra/log/mailbox.log"
AUDIT="$TREE/zimbra/log/audit.log"

# Forty numbered lines, so that WHICH end of the file was read is visible in the
# answer. A bound that took the first lines instead of the last would pass every
# case written against a file whose lines are all alike.
lines() { seq 1 "$1" | sed 's/^/line /'; }

lines 40 >"$SYS"
touch -d '2026-07-30 10:00' -- "$SYS"
lines 40 | gzip -c >"$SYS.1.gz"
touch -d '2026-07-29 03:20' -- "$SYS.1.gz"
: >"$SYS.2.gz"                       # empty, and not valid gzip either
touch -d '2026-07-28 03:20' -- "$SYS.2.gz"
# A neighbour the inventory refuses: not a rotation of this base name.
lines 3 >"$SYS.bak"
# A file under a declared root that the inventory never names at all.
lines 3 >"$TREE/var/log/secret.txt"

lines 12 >"$MBOX"
touch -d '2026-07-30 09:00' -- "$MBOX"
lines 12 >"$AUDIT"
touch -d '2026-07-30 08:00' -- "$AUDIT"

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG
ZRO_ERROR_FILE=$(mktemp); export ZRO_ERROR_FILE

# The body of the answer: everything below the header this module prints above it.
body() { printf '%s\n' "$1" | sed -n '/^-----/,$p' | tail -n +2; }
ran()  { grep -E '^(tail|gzip)' "$ZRO_MOCK_LOG"; }

# --- what it reads ---------------------------------------------------------

it "reads the last lines of a plain file and no more"
: >"$ZRO_MOCK_LOG"
out=$(ZRO_LOGVIEW_LINES=5 zro_logview_read syslog "$SYS" 2>/dev/null)
assert_eq "$(body "$out")" "$(lines 40 | tail -n 5)"

it "and the bound reached the command that applied it"
# Asserted on the argv, which is what proves the bound was applied by the reader
# rather than by something on this side after the whole file had been read.
assert_contains "$(ran)" "$(printf 'tail\t-n\t5\t%s' "$SYS")"

it "reads a compressed rotated file through the decompress-to-stdout form"
: >"$ZRO_MOCK_LOG"
out=$(ZRO_LOGVIEW_LINES=5 zro_logview_read syslog "$SYS.1.gz" 2>/dev/null)
assert_eq "$(body "$out")" "$(lines 40 | tail -n 5)"
assert_contains "$(ran)" "$(printf 'gzip\t-dc\t%s' "$SYS.1.gz")"
assert_contains "$(ran)" "$(printf 'tail\t-n\t5')"

it "and leaves the compressed file compressed"
# The form that writes to stdout is approved precisely because the in-place one
# would replace this file and delete the original.
assert_ok test -f "$SYS.1.gz"
assert_fail test -e "$SYS.1"

it "reads a whole file that is shorter than the bound"
out=$(ZRO_LOGVIEW_LINES=500 zro_logview_read mailbox "$MBOX" 2>/dev/null)
assert_eq "$(body "$out")" "$(lines 12)"

it "says which file the lines came from, and that they are only its last ones"
# An operator who reads a tail as the whole file draws a conclusion from an
# absence this screen never claimed. The bound is stated with the answer, not
# only in the documentation.
out=$(ZRO_LOGVIEW_LINES=5 zro_logview_read syslog "$SYS" 2>/dev/null)
assert_contains "$out" "$SYS"
assert_contains "$out" "son 5 satir"
assert_contains "$out" "TAMAMI DEGILDIR"

it "reads each declared log, and only through the name that declares it"
for pair in "syslog $SYS" "mailbox $MBOX" "audit $AUDIT"; do
  assert_ok zro_logview_read "${pair%% *}" "${pair##* }"
done

# --- what it refuses -------------------------------------------------------

it "refuses a path the inventory did not find, and runs nothing"
# THE WHOLE POINT OF THE INVENTORY. Without this the viewer is a general-purpose
# file reader wearing a menu.
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_DENIED" zro_logview_read syslog "$TREE/var/log/secret.txt"
assert_status "$ZRO_E_DENIED" zro_logview_read syslog "$SYS.bak"
assert_status "$ZRO_E_DENIED" zro_logview_read syslog /etc/passwd
assert_status "$ZRO_E_DENIED" zro_logview_read syslog "$TREE/var/log"
assert_status "$ZRO_E_DENIED" zro_logview_read syslog ''
assert_eq "$(ran)" ""

it "refuses a path belonging to another declared log"
# The pair has to agree: a file is read as a rotation of the log it was listed
# under, never as one the caller happened to name.
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_DENIED" zro_logview_read syslog "$MBOX"
assert_status "$ZRO_E_DENIED" zro_logview_read audit "$SYS"
assert_eq "$(ran)" ""

it "refuses a name the inventory does not declare"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_DENIED" zro_logview_read nginx "$TREE/var/log/nginx.log"
assert_status "$ZRO_E_DENIED" zro_logview_read '' "$SYS"
assert_status "$ZRO_E_DENIED" zro_logview_read
assert_eq "$(ran)" ""

it "refuses a path outside the permitted character set, and says so"
: >"$ZRO_MOCK_LOG"
odd="$TREE/var/log/we'ird.log"
assert_status "$ZRO_E_DENIED" zro_logview_read syslog "$odd"
assert_contains "$( { zro_logview_read syslog "$odd" >/dev/null; } 2>&1 )" "we'ird"
assert_eq "$(ran)" ""

it "refuses a line bound that is not a number, and runs nothing"
# The bound reaches a command line. An override carrying anything else is a
# defect in whatever set it, not a reason to fall back to a default nobody chose.
: >"$ZRO_MOCK_LOG"
ZRO_LOGVIEW_LINES='500; id' assert_status "$ZRO_E_INPUT" zro_logview_read syslog "$SYS"
ZRO_LOGVIEW_LINES='' assert_status "$ZRO_E_INPUT" zro_logview_read syslog "$SYS"
ZRO_LOGVIEW_LINES='-5' assert_status "$ZRO_E_INPUT" zro_logview_read syslog "$SYS"
ZRO_LOGVIEW_LINES='0' assert_status "$ZRO_E_INPUT" zro_logview_read syslog "$SYS"
assert_eq "$(ran)" ""

it "reports a file it could not read as a log failure, keeping the reason"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_TAIL_RC=1 ZRO_MOCK_TAIL_ERR="tail: cannot open '$SYS' for reading: Permission denied" \
  assert_status "$ZRO_E_NO_LOG" zro_logview_read syslog "$SYS"
assert_contains "$(zro_last_error)" "Permission denied"

it "reports a compressed file it could not decompress the same way"
# The empty rotated file is not valid gzip, so the real binary refuses it. A
# reader that answered nothing here would look exactly like an empty log.
assert_status "$ZRO_E_NO_LOG" zro_logview_read syslog "$SYS.2.gz"

it "and does so whatever pipeline options the caller happens to have set"
# The decompression and the bound are two commands, and the second one succeeds
# on the empty input a failed first one leaves it. Without the module setting
# pipefail for itself, a caller that had not would be answered "empty file" about
# a file that could not be read at all.
rc=0
( set +o pipefail; zro_logview_read syslog "$SYS.2.gz" ) >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "$ZRO_E_NO_LOG"

it "passes the gate's own refusals through instead of calling them log failures"
# A binary this host does not have is not a log that cannot be read, and an
# operator sent to zmfixperms over a missing tail would repair nothing.
ZRO_SYSTEM_BIN=/nonexistent assert_status "$ZRO_E_NOCAP" zro_logview_read syslog "$SYS"
ZRO_MOCK_ID_USER=nobody assert_status "$ZRO_E_BADUSER" zro_logview_read syslog "$SYS"

it "answers an empty file as an empty answer, not as an unreadable one"
: >"$MBOX"
assert_status "$ZRO_E_NO_RESULT" zro_logview_read mailbox "$MBOX"
lines 12 >"$MBOX"

it "reaches no Zimbra binary and opens no mailbox"
: >"$ZRO_MOCK_LOG"
zro_logview_read syslog "$SYS" >/dev/null 2>&1
log=$(cat "$ZRO_MOCK_LOG")
assert_contains "$log" "tail"
assert_not_contains "$log" "zmprov"
assert_not_contains "$log" "zmmailbox"
assert_not_contains "$log" "zmmsgtrace"

# --- the list the screen offers --------------------------------------------

it "lists a log's files newest first"
# The opposite order to the inventory's, and deliberately: the file an operator
# wants is nearly always the one being written, and it should not be at the
# bottom of a list they have to scroll.
assert_eq "$(zro_logview_files syslog 2>/dev/null | cut -f2)" \
  "$(printf '%s\n' "$SYS" "$SYS.1.gz" "$SYS.2.gz")"

it "and carries each file's modification time beside it"
assert_eq "$(zro_logview_files syslog 2>/dev/null | head -n 1 | cut -f1)" \
  "$(date -d '2026-07-30 10:00' '+%s')"

it "refuses to list a log the inventory does not declare"
assert_status "$ZRO_E_DENIED" zro_logview_files nginx
assert_status "$ZRO_E_DENIED" zro_logview_files ''

it "names every declared log, and nothing else"
# Two declarations held equal, the way the window presets and the window menu
# are: the inventory owns which logs exist, this module owns what they are called
# on screen, and a log added to one and forgotten in the other would reach an
# operator as a menu entry with no name.
missing=""
while IFS= read -r key; do
  [ -n "$key" ] || continue
  zro_logview_label "$key" >/dev/null 2>&1 || missing="$missing [$key]"
done <<EOF
$(zro_inv_keys)
EOF
assert_eq "$missing" ""
assert_fail zro_logview_label nginx
assert_fail zro_logview_label ''

it "labels a file by when it was written and whether it is compressed"
# What an operator picks a file BY. A list of paths alone would make them work
# out which rotation holds yesterday, which is the thing this screen exists to
# save them.
label=$(zro_logview_file_label "$(date -d '2026-07-29 03:20' '+%s')" "$SYS.1.gz")
assert_contains "$label" "2026-07-29 03:20"
assert_contains "$label" "zimbra.log.1.gz"
assert_contains "$label" "sikistirilmis"
assert_not_contains "$(zro_logview_file_label "$(date -d '2026-07-30 10:00' '+%s')" "$SYS")" \
  "sikistirilmis"

rm -f -- "$ZRO_MOCK_LOG" "$ZRO_ERROR_FILE"
rm -rf -- "$TREE"
zro_t_report
