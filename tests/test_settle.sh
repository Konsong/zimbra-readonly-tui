#!/usr/bin/env bash
# THE ONE THING NO HIGHER SEAM CAN REACH: the settler refusing the name it was
# handed.
set -uo pipefail
#
# Every other question about the settler is answered where an operator would meet
# it — tests/test_message.sh drives the read that finishes through it, and
# tests/test_gate_passthrough.sh holds the gate's own codes to travelling out as
# themselves. Neither can produce a bad name: a module names its failure reader in
# its own source, so a name that is not one is a maintainer's edit rather than
# anything an operator can do. That is why the refusal is asserted here and why
# NOTHING ELSE IS — a case here for the success path or for the mapping would be a
# second statement of what those suites already prove, free to drift from them.
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/table.sh
. "$ZRO_SRC/lib/table.sh"
# shellcheck source=../lib/validate.sh
. "$ZRO_SRC/lib/validate.sh"
# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"
# shellcheck source=../lib/settle.sh
. "$ZRO_SRC/lib/settle.sh"

ZRO_ERROR_FILE=$(mktemp); export ZRO_ERROR_FILE

# One capture file, emptied per case rather than one per case: what is asserted is
# what THIS call logged, and a file left behind for every case is the kind of litter
# a suite that runs on the server itself may not leave.
LOG=$(mktemp)

# A FUNCTION THAT REALLY EXISTS AND IS NOT A FAILURE READER. Without it the shape
# check could not be told from the existence check: a name nothing answers to is
# refused by either, so only a name that WOULD run proves which one refused it.
# It records the fact of being called in a file rather than a variable, because
# the settler is called inside command substitution and a variable set in that
# subshell would never reach the assertion.
ZRO_T_SPY=$(mktemp)
zro_t_ran_something() { printf 'ran\n' >>"$ZRO_T_SPY"; printf '%s' "$ZRO_E_NO_RESULT"; }

# A scratch file per case, carrying something to keep. Both halves of that matter to
# the cases below: a refused name does not excuse the settler from what the command
# said — the capture happens before the name is judged, and the assertion below is
# what holds it there — and a file the settler failed to remove is a leak whichever
# way the name was refused.
new_err() {
  local f
  f=$(mktemp)
  printf '%s\n' 'ERROR: service.FAILURE (something the command said)' >"$f"
  printf '%s' "$f"
}

# ------------------------------------------------- a name that is not one --

it "a name that is not a failure reader is refused rather than called"
ERR=$(new_err); : >"$LOG"; : >"$ZRO_T_SPY"
out=$(zro_settle "$ERR" 1 zro_t_ran_something 2>"$LOG")
assert_eq "$out" "$ZRO_E_INPUT"
assert_eq "$(cat "$ZRO_T_SPY")" ""

it "and the refusal is logged as a defect in this tool, naming the name"
assert_contains "$(cat "$LOG")" "settle defect"
assert_contains "$(cat "$LOG")" "not the name of a failure reader"
assert_contains "$(cat "$LOG")" "zro_t_ran_something"

it "and the scratch file is removed anyway, because the settler owns it"
assert_fail test -e "$ERR"

it "and what the command said is still kept, because the refusal is not the read's"
# The one thing this path shares with every other ending, and the only place it is
# asserted: nothing above the settler can produce a refused name, so a capture moved
# below the name check would leave the operator a bare code with no clue in it.
assert_contains "$(zro_last_error)" "service.FAILURE"

# --------------------------------------------- a name nothing answers to --

it "a name shaped like a failure reader that nothing answers to is refused"
ERR=$(new_err); : >"$LOG"
out=$(zro_settle "$ERR" 1 zro_nosuch_fail_code 2>"$LOG")
assert_eq "$out" "$ZRO_E_INPUT"

it "and it is logged as the other refusal, so the two can be told apart"
assert_contains "$(cat "$LOG")" "settle defect"
assert_contains "$(cat "$LOG")" "no function answers"
assert_contains "$(cat "$LOG")" "zro_nosuch_fail_code"
assert_not_contains "$(cat "$LOG")" "not the name of a failure reader"

it "and that scratch file is removed too"
assert_fail test -e "$ERR"

it "a name that is empty is refused, and nothing about it is a special case"
ERR=$(new_err); : >"$LOG"
out=$(zro_settle "$ERR" 1 "" 2>"$LOG")
assert_eq "$out" "$ZRO_E_INPUT"
assert_contains "$(cat "$LOG")" "settle defect"
assert_fail test -e "$ERR"

rm -f -- "$ZRO_T_SPY" "$ZRO_ERROR_FILE" "$LOG"
zro_t_report
