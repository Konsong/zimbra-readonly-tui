#!/usr/bin/env bash
# The bounded log viewer's screens, driven through the stub UI backend.
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
export ZRO_UI_BACKEND=stub
export ZRO_SOURCED_ONLY=1
export ZRO_MOCK_ID_USER=zimbra
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* "$ZRO_TEST_ROOT"/mocks/libexec/* \
         "$ZRO_TEST_ROOT"/mocks/system/* 2>/dev/null || true

export TZ=UTC

TREE=$(mktemp -d)
mkdir -p "$TREE/var/log" "$TREE/zimbra/log"
export ZRO_SYSLOG_FILE="$TREE/var/log/zimbra.log"
export ZRO_LOG_DIR="$TREE/zimbra/log"

SYS="$TREE/var/log/zimbra.log"
MBOX="$TREE/zimbra/log/mailbox.log"

lines() { seq 1 "$1" | sed 's/^/line /'; }

lines 40 >"$SYS"
touch -d '2026-07-30 10:00' -- "$SYS"
lines 40 | gzip -c >"$SYS.1.gz"
touch -d '2026-07-29 03:20' -- "$SYS.1.gz"
lines 12 >"$MBOX"
touch -d '2026-07-30 09:00' -- "$MBOX"
chmod 644 -- "$SYS" "$SYS.1.gz" "$MBOX"
# The audit log is declared and simply not on this host, which is ordinary and
# is one of the screens below.

# shellcheck source=../zimbra-ro-tui.sh
. "$ZRO_SRC/zimbra-ro-tui.sh"

ZRO_MOCK_LOG=$(mktemp);  export ZRO_MOCK_LOG
ZRO_UI_QUEUE=$(mktemp);  export ZRO_UI_QUEUE
ZRO_UI_OUT=$(mktemp);    export ZRO_UI_OUT
export ZRO_MOCK_ZMCONTROL__V_OUT="$ZRO_TEST_ROOT/fixtures/zmcontrol_v.txt"

queue() { printf '%s\n' "$@" >"$ZRO_UI_QUEUE"; zro_ui_reset; }
transcript() { cat "$ZRO_UI_OUT"; }
ran() { grep -E '^(tail|gzip)' "$ZRO_MOCK_LOG"; }

# The common path: the mail log, its newest file.
NEWEST=("3" "syslog" "1" "__CANCEL__" "__CANCEL__" "__CANCEL__")

it "the log viewer is reachable from the main menu"
queue "3" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
zro_menu_main
assert_contains "$(transcript)" "Log dosyalari"

it "the first screen offers every declared log by name"
queue "__CANCEL__"
: >"$ZRO_UI_OUT"
zro_menu_logview
out=$(transcript)
missing=""
while IFS= read -r key; do
  [ -n "$key" ] || continue
  case $out in
    *"$(zro_logview_label "$key")"*) ;;
    *) missing="$missing [$key]" ;;
  esac
done <<EOF
$(zro_inv_keys)
EOF
assert_eq "$missing" ""

it "the second screen lists that log's files, newest first, with their times"
queue "syslog" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
zro_menu_logview
# The entries follow the prompt's last line, which is where the stub joins them.
menu=$(grep -F 'Dosya secin:' "$ZRO_UI_OUT" | tail -n 1)
assert_contains "$menu" "zimbra.log"
assert_contains "$menu" "zimbra.log.1.gz"
assert_contains "$menu" "2026-07-30 10:00"
assert_contains "$menu" "2026-07-29 03:20"
assert_contains "$menu" "sikistirilmis"
# Newest first: the live file's entry comes before the rotated one's.
live=${menu%%zimbra.log.1.gz*}
assert_contains "$live" "2026-07-30 10:00"

it "choosing a file shows its last lines, under a header naming the bound"
queue "${NEWEST[@]}"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
ZRO_LOGVIEW_LINES=5 zro_menu_logview
out=$(transcript)
assert_contains "$out" "TEXT Log:"
assert_contains "$out" "$SYS"
assert_contains "$out" "son 5 satir"
assert_contains "$out" "line 40"
# The bound is the point: the head of the file never reached the screen.
assert_not_contains "$out" "line 1
"
assert_contains "$(ran)" "$(printf 'tail\t-n\t5\t%s' "$SYS")"

it "and says the search is running before the wait begins"
assert_contains "$out" "NOTICE"
assert_contains "$out" "bekleyin"

it "a compressed rotated file is read through the approved decompression"
queue "3" "syslog" "2" "__CANCEL__" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
ZRO_LOGVIEW_LINES=5 zro_menu_main
out=$(transcript)
assert_contains "$out" "$SYS.1.gz"
assert_contains "$out" "line 40"
assert_contains "$(ran)" "$(printf 'gzip\t-dc\t%s' "$SYS.1.gz")"
# The in-place forms are refused by the gate; this is the file still being there.
assert_ok test -f "$SYS.1.gz"

it "no screen hands a path to a reader, whatever the operator's answer is"
# The list is offered by position and the position is what comes back, so a value
# that is not one of them cannot name a file. A path typed where a position was
# expected is refused, and nothing is read.
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
for answer in "/etc/passwd" "$SYS" "0" "99" "-1" "1 2" "1;id" ""; do
  queue "syslog" "$answer" "__CANCEL__" "__CANCEL__"
  zro_menu_logview
done
assert_eq "$(ran)" ""
assert_not_contains "$(transcript)" "TEXT Log:"

it "and every path that did reach a reader came from the inventory"
queue "syslog" "1" "__CANCEL__" "__CANCEL__" "__CANCEL__"
: >"$ZRO_MOCK_LOG"
zro_menu_logview
outside=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  path=$(printf '%s' "$line" | awk -F'\t' '{print $NF}')
  case $path in
    "$SYS"*) ;;
    [0-9]*) ;;                  # the bound, on the reader that takes stdin
    *) outside="$outside [$path]" ;;
  esac
done <<EOF
$(ran)
EOF
assert_eq "$outside" ""

it "a log that is not on this host says so, and is not read"
# The audit log is declared and absent, which is ordinary on a host that does not
# write it. An empty list must not read as an empty file.
queue "audit" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
zro_menu_logview
out=$(transcript)
assert_contains "$out" "bulunamadi"
assert_eq "$(ran)" ""

it "an empty file is answered as empty, not as a file that could not be read"
: >"$MBOX"
queue "mailbox" "1" "__CANCEL__" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
zro_menu_logview
out=$(transcript)
assert_contains "$out" "bos"
assert_not_contains "$out" "okunamadi"
lines 12 >"$MBOX"

it "a file that cannot be read names the cause and the repair"
queue "${NEWEST[@]}"
: >"$ZRO_UI_OUT"
ZRO_MOCK_TAIL_RC=1 \
ZRO_MOCK_TAIL_ERR="tail: cannot open '$SYS' for reading: Permission denied" \
  zro_menu_logview
out=$(transcript)
assert_contains "$out" "okunamadi"
assert_contains "$out" "zmfixperms"
assert_contains "$out" "Permission denied"

it "a read cut off by the clock names the file and says nothing was written"
# The bound protects the server's memory; the timeout protects the terminal. A
# very large compressed file can reach it, because the end of one cannot be read
# without decompressing all of it — and the shared reporter would say only that a
# command timed out.
queue "${NEWEST[@]}"
: >"$ZRO_UI_OUT"
ZRO_MOCK_TIMEOUT_FIRE=1 zro_menu_logview
out=$(transcript)
assert_contains "$out" "Zaman asimi"
assert_contains "$out" "$SYS"
assert_contains "$out" "DOKUNULMADI"

it "cancelling the log menu returns to the caller"
queue "__CANCEL__"
: >"$ZRO_MOCK_LOG"
assert_ok zro_menu_logview
assert_eq "$(ran)" ""

it "cancelling the file menu returns to the log menu, not out of it"
queue "syslog" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
assert_ok zro_menu_logview
# Drawn once before the file list and once after it: the operator is back where
# they were, not one screen further out.
assert_eq "$(grep -c 'MENU Log dosyalari' "$ZRO_UI_OUT")" "2"
assert_eq "$(ran)" ""

it "and returning from a report lands on the file list again"
queue "syslog" "1" "__CANCEL__" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
zro_menu_logview
# The file list is drawn again after the report, so the next file is one keypress
# away rather than two menus back.
assert_eq "$(grep -c "MENU $(zro_logview_label syslog)" "$ZRO_UI_OUT")" "2"

it "the viewer opens no mailbox and runs no Zimbra binary"
queue "syslog" "1" "__CANCEL__" "__CANCEL__" "__CANCEL__"
: >"$ZRO_MOCK_LOG"
zro_menu_logview
log=$(cat "$ZRO_MOCK_LOG")
assert_contains "$log" "tail"
assert_not_contains "$log" "zmprov"
assert_not_contains "$log" "zmmailbox"
assert_not_contains "$log" "zmmsgtrace"

it "the viewer is offered whether or not a delivery trace can run here"
# It reads the same files the trace does, but through neither the tracing binary
# nor the primary log alone: a host missing the tracer can still read mailbox.log,
# and marking this entry with the trace's probe would hide a screen that works.
queue "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_CAP_FORCE_TRACE_BIN=no zro_menu_main
out=$(transcript)
assert_contains "$out" "Log dosyalari"
assert_not_contains "$out" "Log dosyalari (son satirlar) - KULLANILAMAZ"

rm -f -- "$ZRO_MOCK_LOG" "$ZRO_UI_QUEUE" "$ZRO_UI_QUEUE.pos" "$ZRO_UI_OUT"
rm -rf -- "$TREE"
zro_t_report
