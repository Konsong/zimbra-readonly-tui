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
# NO SECOND BEHAVIOUR IS — a case here for the success path or for the mapping would
# be a second statement of what those suites already prove, free to drift from them.
#
# That reason is about RUNNING the program, and it does not reach the two cases at
# the foot of this file: those read the source and assert the contract the run-time
# refusal is unable to check. A claim no run can make is not a second statement of
# one that was made by running.
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

# ------------------------------------------ the contract, read off the source --
#
# TWO CLAIMS ABOUT THE SOURCE RATHER THAN ABOUT A RUN, which is why the reason
# above does not bar them. What it bars is a second BEHAVIOURAL statement of what
# tests/test_message.sh and tests/test_gate_passthrough.sh already prove by running
# the program; neither case below runs it.
#
# THEY ARE HERE AND NOT IN tests/test_readonly_scan.sh because that file's subject
# is the read-only claim, and a failure reader's shape is not a safety property.
# Widening the one file that proves the guarantee is a cost with nothing behind it.
#
# WHY THE SOURCE AND NOT `declare -F`: bash cannot be asked how many arguments a
# function takes. The check zro_settle makes at run time can therefore ask whether a
# name is SHAPED like a failure reader and whether anything answers to it, and no
# more — so the third question, whether the thing that answers can be CALLED the way
# the settler calls it, has to be asked of the text. That question is not a
# weakening of the run-time refusal and does not replace it: it moves a defect that
# no operator can produce to the build, where the maintainer who produced it is.
#
# COMMENTS ARE REMOVED FIRST. Prose in this tree names these functions — lib/exec.sh
# and lib/search.sh each name a failure reader, lib/message.sh names the settler —
# and a claim about what the program DOES may not be answered by what a comment
# SAYS. None of those sentences happens to match the patterns below today, and that
# is the reason the stripping is written rather than left out: a case that is
# correct by luck reports the luck running out as a defect in the program.
#
# This is the narrow form of the stripper in tests/test_readonly_scan.sh: that one
# also tracks quote state across the whole tree, because it goes on to decide what
# stands in executable position. Neither question below is about quoting, so neither
# pays for it.
ZRO_T_SOURCES=("$ZRO_SRC/zimbra-ro-tui.sh" "$ZRO_SRC"/lib/*.sh)
stripped=$(sed -e 's/^[[:space:]]*#.*$//' -e 's/\([[:space:]]\)#.*$/\1/' "${ZRO_T_SOURCES[@]}")
readers=$(printf '%s\n' "$stripped" | sed -n 's/^\(zro_[a-z0-9_]*_fail_code\)() {$/\1/p' | sort -u)

it "the source the two cases below read is the program, and the extraction found it"
# THE FLOOR UNDER BOTH OF THEM, and it is not ceremony. Each compares a set against
# something, and each is satisfied by two EMPTY sets — a glob that matched nothing,
# a path that moved, a stripper that ate the file. Under `set -uo pipefail` with no
# errexit not one of those stops this file, so both would report green while having
# read nothing at all. This tree has shipped a case that passed while proving
# nothing before; the floor is a case of its own rather than a comment promising it
# cannot happen again.
#
# IT NAMES ONE READER RATHER THAN COUNTING THEM. A count is the number this file
# would then be describing back to itself, and a fourth reader added tomorrow is not
# a failure — which is the rule tests/lib/cost.sh states for the class it reads.
assert_contains "$stripped" "zro_settle"
assert_contains "$readers" "zro_msg_fail_code"

it "every failure reader takes the scratch file and nothing else, because that is all the settler passes"
# zro_settle calls the reader with one argument. A reader that reads a second one is
# refused by nothing and fails where nothing is watching: under `set -u` with no
# errexit the assignment dies, zro_settle prints nothing, and the caller compares an
# empty string against zero. The operator is handed a code this program does not
# define, by the module written to stop exactly that, and neither refusal is logged
# because neither fires.
wide=""
unread=""
while IFS= read -r fn; do
  [ -n "$fn" ] || continue
  body=$(printf '%s\n' "$stripped" \
         | awk -v fn="$fn" '$0 == fn "() {" { inside = 1; next }
                            inside && $0 == "}" { inside = 0 }
                            inside')
  # A body this loop could not find is the floor's own hole one function down: the
  # count below would be zero and the reader would pass for having no text rather
  # than for taking one argument. Collected under its own name because the two say
  # different things — a reader that reads too much, against a reader nobody read.
  [ -n "$body" ] || { unread="$unread [$fn]"; continue; }
  # grep exits 1 when it counts nothing, which is not a failure here. Counted
  # rather than asked with -q: -q stops at the first match and can close the pipe
  # under the reader, and this tree has already been bitten once by a status that
  # meant a closed pipe rather than an answer.
  #
  # WHAT COUNTS AS READING PAST THE FIRST ARGUMENT: `$2` upwards and the two-digit
  # forms, `$@` and `$*`, and `shift` — which is the one that does it while naming
  # no positional at all, and the one a plain search for `$2` waves through.
  n=$(printf '%s\n' "$body" \
      | grep -cE '\$\{?([2-9]|[0-9][0-9]|[@*])|(^|[^[:alnum:]_])shift([^[:alnum:]_]|$)') || n=0
  [ "$n" -eq 0 ] || wide="$wide [$fn]"
done <<EOF
$readers
EOF
assert_eq "$wide" ""

it "and each of their bodies was found, so the case above judged text rather than silence"
assert_eq "$unread" ""

it "and every failure reader is one the settler is handed, in exactly one spelling"
# The two sets are held equal in BOTH DIRECTIONS, as the allowlist's mailbox reads
# are. A reader nobody hands over is a function wearing the name of a role it does
# not fill, which is what the two mappers in lib/account.sh and lib/delivery.sh were
# before they were named for what they do; and it is the half the case above cannot
# see, because that one judges the readers it finds rather than the ones that should
# never have been in the set. The other direction answers the mirror of it: a name
# handed to the settler that no module defines under that spelling.
#
# A CALL SITE THAT NAMED ITS READER THROUGH A VARIABLE would not match, and that is
# the safe direction rather than a hole: the name would be missing from `handed`,
# the two sets would differ, and the case goes red. What it may not do is pass in
# silence, and it cannot — the reader it failed to see is still in `readers`.
handed=$(printf '%s\n' "$stripped" \
         | grep -oE 'zro_settle[[:space:]]+"[^"]*"[[:space:]]+"[^"]*"[[:space:]]+[a-z0-9_]+' \
         | awk '{print $NF}' | sort -u)
assert_eq "$readers" "$handed"

rm -f -- "$ZRO_T_SPY" "$ZRO_ERROR_FILE" "$LOG"
zro_t_report
