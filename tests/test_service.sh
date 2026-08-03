#!/usr/bin/env bash
# Service status: what reaches the binary, what its output is read as, and what
# the screen says about the one command in this tool that writes.
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ZIMBRA_LIBEXEC="$ZRO_TEST_ROOT/mocks/libexec"
export ZRO_SYSTEM_BIN="$ZRO_TEST_ROOT/mocks/system"
export ZRO_POSTFIX_SBIN="$ZRO_TEST_ROOT/mocks/sbin"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
export ZRO_NICE_BIN="$ZRO_TEST_ROOT/mocks/bin/nice"
export ZRO_IONICE_BIN="$ZRO_TEST_ROOT/mocks/bin/ionice"
export ZRO_UI_BACKEND=stub
export ZRO_SOURCED_ONLY=1
export ZRO_MOCK_ID_USER=zimbra
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* "$ZRO_TEST_ROOT"/mocks/libexec/* \
         "$ZRO_TEST_ROOT"/mocks/system/* "$ZRO_TEST_ROOT"/mocks/sbin/* 2>/dev/null || true

# shellcheck source=../zimbra-ro-tui.sh
. "$ZRO_SRC/zimbra-ro-tui.sh"

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG
FIX="$ZRO_TEST_ROOT/fixtures"

# Captured on the lab server, twice: everything running, and the same host with
# one service stopped. See docs/research/2026-08-02-mta-queue-and-log.md.
OK=$(cat "$FIX/zmcontrol_status_ok.txt")
STOPPED=$(cat "$FIX/zmcontrol_status_stopped.txt")

ran() { cat "$ZRO_MOCK_LOG"; }
reset() { : >"$ZRO_MOCK_LOG"; }

# ------------------------------------------------- what reaches the binary --

it "the status read is what runs, and nothing rides behind it"
reset
export ZRO_MOCK_ZMCONTROL_STATUS_OUT="$FIX/zmcontrol_status_ok.txt"
unset ZRO_MOCK_ZMCONTROL_STATUS_RC
assert_ok zro_svc_fetch
assert_eq "$(ran | grep '^zmcontrol')" "zmcontrol	status"

it "and it runs under the wall-clock timeout, which is the only thing bounding it"
# The command sets an alarm around each service it asks and NONE around the
# directory lookup that runs first, so a hung directory server leaves it waiting
# with nothing of its own to interrupt it.
assert_contains "$(ran | grep '^timeout')" "$ZRO_TEST_ROOT/mocks/bin/zmcontrol"

it "a command that never answered is reported as the timeout it was"
reset
export ZRO_MOCK_ZMCONTROL_STATUS_RC=124
assert_status "$ZRO_E_TIMEOUT" zro_svc_fetch
unset ZRO_MOCK_ZMCONTROL_STATUS_RC

# ------------------------------------------------------- reading the output --

it "every service on the host is read, and the host it is about with them"
rows=$(zro_svc_rows "$OK")
assert_eq "$(printf '%s\n' "$rows" | grep -c .)" "10"
assert_out_eq "mail01.example.com" zro_svc_host "$OK"

it "and a service whose name carries a space is one service, not two"
# Four of the ten are named 'service webapp', 'zimbra webapp', 'zimbraAdmin
# webapp' and 'zimlet webapp'. A reader that took the second word as the status
# would report four services in a state this tool has never seen.
assert_contains "$(printf '%s\n' "$rows" | cut -f2)" "zimbraAdmin webapp"
assert_contains "$(printf '%s\n' "$rows" | cut -f2)" "service webapp"

it "and the state each one is in"
assert_eq "$(printf '%s\n' "$rows" | cut -f1 | sort -u)" "running"
stopped_rows=$(zro_svc_rows "$STOPPED")
assert_eq "$(printf '%s\n' "$stopped_rows" | grep -c '^stopped')" "1"
assert_eq "$(printf '%s\n' "$stopped_rows" | grep '^stopped' | cut -f2)" "stats"
assert_eq "$(printf '%s\n' "$stopped_rows" | grep -c '^running')" "9"

it "a word this tool has not seen is carried through rather than guessed at"
# The two states above are the two the lab server produced. A build that answers
# something else must reach the operator AS that word: reading an unknown state
# as 'stopped' would be this program inventing an outage, and as 'running' would
# be inventing calm.
odd=$(zro_svc_rows "$(printf 'Host mail01.example.com\n\tmailbox                 Unknown\n')")
assert_eq "$(printf '%s' "$odd" | cut -f1)" "other"
assert_eq "$(printf '%s' "$odd" | cut -f3)" "Unknown"

it "and the host line is not a service"
assert_not_contains "$(printf '%s\n' "$rows" | cut -f2)" "mail01.example.com"

it "output with no service line in it is no answer, not an empty server"
assert_eq "$(zro_svc_rows "")" ""
assert_status "$ZRO_E_NO_RESULT" zro_svc_card ""
assert_status "$ZRO_E_NO_RESULT" zro_svc_card "Host mail01.example.com"

# ------------------------------------------------------------- the screen --

it "the card renders every service with the state it is in"
out=$(zro_svc_card "$STOPPED")
assert_contains "$out" "mail01.example.com"
assert_contains "$out" "Servis sayisi        : 10"
assert_contains "$out" "Calisan              : 9"
assert_contains "$out" "Durmus               : 1"
assert_contains "$out" "zimbraAdmin webapp"

it "and a stopped service is not rendered in the same word as a running one"
assert_contains "$out" "DURMUS"
assert_contains "$out" "Calisiyor"

it "and a host with nothing wrong on it says so without a stopped line"
out_ok=$(zro_svc_card "$OK")
assert_contains "$out_ok" "Durmus               : 0"
assert_not_contains "$out_ok" "DURMUS"

it "the screen says what this command writes, in the same box as its answer"
# THE SECOND OF THE THREE CONDITIONS that admit this command at all: it changes
# no domain state, THE SCREEN SAYS WHAT IT WRITES, and an ADR records the
# judgement. The other two are documents; this one is code, and it is asserted
# here so that it cannot be edited away by somebody tidying a screen.
for said in "zmcontrol status" ".zmcontrol.cache" "gecici dosya" "BASLATMAZ" "DURDURMAZ"; do
  assert_contains "$out" "$said"
done

it "and it says plainly that nothing Zimbra manages is changed by asking"
assert_contains "$out" "hicbir hesap, mailbox, klasor veya ayar degismez"

zro_t_report
