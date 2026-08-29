#!/usr/bin/env bash
# The one reader a built list's position goes through. It runs nothing, opens no
# file, and never sees the array whose position it judges — so every refusal it
# makes is proved here without a mailbox, a stub or a fixture.
#
# NOTHING IS DRAWN BELOW. The counts are written out, so a case says what it is
# about without a screen having to hold still for it. The vector itself is not
# written out: it is the one declared in tests/lib/list.sh, which is also what
# runs against all three screens — there the assertion is the different one, that
# nothing ran. Two vectors would be two rules, and the value that gets through is
# the one the author of the second copy did not think to try.
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=lib/list.sh
. "$ZRO_TEST_ROOT/lib/list.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/list.sh
. "$ZRO_SRC/lib/list.sh"

# TWELVE, because that is Zimbra's default folder set and therefore the smallest
# list a real mailbox draws. It matters to more than realism: 08 read as decimal
# is 8, which is INSIDE a list of twelve, so refusing it here proves the admission
# arm caught it rather than the range check agreeing by accident. On a shorter
# list every case below would pass for the wrong reason, and a case that passes
# for the wrong reason stops passing when the reason moves.
COUNT=12

it "reads a position as the index below it"
# THE MINUS ONE IS PART OF THE RULE and travels with it. A screen builds its menu
# tags from one upwards because that is what an operator counts from; the array
# under it starts at zero, and the conversion is the reader's, not the caller's.
assert_out_eq "0"  zro_list_position 1 "$COUNT" "folder list"
assert_out_eq "4"  zro_list_position 5 "$COUNT" "folder list"
assert_out_eq "11" zro_list_position 12 "$COUNT" "folder list"
assert_ok zro_list_position 1 "$COUNT" "folder list"

it "admits the last position of a list, and refuses the one after it"
assert_out_eq "0" zro_list_position 1 1 "log file list"
assert_status "$ZRO_E_INPUT" zro_list_position 2 1 "log file list"

it "refuses every answer the shared vector carries"
# The vector is the screens' vector. What is asserted here is the refusal itself;
# what is asserted at a screen is that the refusal cost nothing and left the
# operator where they were.
for answer in "${ZRO_T_LIST_HOSTILE[@]}"; do
  assert_status "$ZRO_E_INPUT" zro_list_position "$answer" "$COUNT" "folder list"
done

it "and prints nothing at all when it refuses"
# A refusal that printed would be read by the caller as an index, because the
# caller reads stdout and the status separately. Empty is the only safe answer.
for answer in "${ZRO_T_LIST_HOSTILE[@]}"; do
  assert_eq "$(zro_list_position "$answer" "$COUNT" "folder list" 2>/dev/null)" ""
done

it "says which of its two refusals about the ANSWER it made, in today's words"
# BOTH MESSAGES ARE THE ONES THE THREE SCREENS WROTE, unchanged to the byte. A
# maintainer reading a log from a server that has not been upgraded yet, and one
# reading a log from a server that has, are reading the same two lines.
said=$(zro_list_position 08 "$COUNT" "folder list" 2>&1 >/dev/null)
assert_contains "$said" "denied, not a position in the folder list: 08"
said=$(zro_list_position 99 "$COUNT" "folder list" 2>&1 >/dev/null)
assert_contains "$said" "denied, position outside the folder list: 99"

it "and names the list it was handed, at every list that has one"
# The noun is why the message is worth logging at all: three screens draw a built
# list, and a log line that cannot say which one sends a maintainer looking. This
# is zro_table_root's rule about a refusal that cannot name its declaration.
for noun in "folder list" "conversation list" "log file list"; do
  said=$(zro_list_position "/etc/passwd" "$COUNT" "$noun" 2>&1 >/dev/null)
  assert_contains "$said" "not a position in the $noun:"
  said=$(zro_list_position 99 "$COUNT" "$noun" 2>&1 >/dev/null)
  assert_contains "$said" "position outside the $noun:"
done

it "refuses zero one arm before the range check, which is what makes that check one-sided"
# THE ARM THAT CARRIES THE OCTAL HAZARD carries zero with it, so the range check
# below has a lower bound it can rely on rather than one it repeats. If this case
# fails, the admission has been loosened and ${list[0 - 1]} is reachable again —
# the fix is that arm, not a second comparison under it.
said=$(zro_list_position 0 "$COUNT" "folder list" 2>&1 >/dev/null)
assert_contains "$said" "not a position"
assert_not_contains "$said" "outside"

it "refuses a tenth digit as not a position, rather than reading it as a number"
# NINE CHARACTERS, [1-9] AND AT MOST EIGHT MORE. What survives is a decimal
# integer this shell can evaluate, and that is the whole of why the range check
# below is total. The ninth digit is compared; the tenth is not admitted.
said=$(zro_list_position 1234567890 "$COUNT" "folder list" 2>&1 >/dev/null)
assert_contains "$said" "not a position"
said=$(zro_list_position 123456789 "$COUNT" "folder list" 2>&1 >/dev/null)
assert_contains "$said" "position outside"

it "and reads a position at the very top of what it admits"
# The other end of the same rule: nine digits are not merely refused politely,
# they are evaluated. A reader that only ever saw small lists would not show this.
assert_out_eq "999999998" zro_list_position 999999999 999999999 "log file list"

it "refuses a count that is not one, and says so as a defect in this program"
# A COUNT IS NOT OPERATOR INPUT. It is ${#arr[@]} at the three call sites, so a
# value that is not a count means a caller reached this reader with a list nobody
# can pick from — an empty one included. That is logged here rather than at the
# call site for the reason zro_table_root logs its own: the caller is not the only
# one, and a refusal that cannot name the list sends a maintainer looking.
for count in "" 0 -1 abc 08 "1 2" 99999999999999999999 1234567890; do
  assert_status "$ZRO_E_INPUT" zro_list_position 1 "$count" "folder list"
  assert_eq "$(zro_list_position 1 "$count" "folder list" 2>/dev/null)" ""
done
said=$(zro_list_position 1 0 "folder list" 2>&1 >/dev/null)
assert_contains "$said" "list defect, not a count of the folder list: 0"

it "and judges the count before the answer, because the count is its own precondition"
# Both are wrong here and only one line is logged. A defect in this program is
# what a maintainer must be told about; reporting it as something the operator
# typed is how it would be read as one and left alone.
said=$(zro_list_position 99 "" "folder list" 2>&1 >/dev/null)
assert_contains "$said" "list defect"
assert_not_contains "$said" "denied,"

it "refuses a call with nothing in it"
assert_status "$ZRO_E_INPUT" zro_list_position

zro_t_report
