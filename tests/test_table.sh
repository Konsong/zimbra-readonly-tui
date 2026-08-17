#!/usr/bin/env bash
# The one reader every declared table is taken apart by. The five rules its
# header states are asserted here, each of them a defect somewhere first.
#
# NOTHING REAL IS READ BELOW. The tables are local to this file, so a case says
# what it is about without a production declaration having to hold still for it;
# the real tables are held to their shape by the well-formedness case at the end.
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/table.sh
. "$ZRO_SRC/lib/table.sh"

# SC2034 on every table below, for the reason lib/table.sh gives about the real
# ones: a declaration read by NAME is never expanded where it is written, so
# ShellCheck sees a variable nobody uses.
# shellcheck disable=SC2034
ZRO_T_SIMPLE='alpha:one
beta:two'

# Written between newlines, as four of the real tables are, so that the first row
# does not sit on the assignment line. The whitespace-only line is the shape the
# reader this replaced used an external process to drop.
ZRO_T_PADDED='
gamma:three

delta:four

'

# A label really does carry a colon — the search prompts declare
# `address:Adres (ornek: ali@ornek.com)` — which is what the remainder rule is
# for. Anything that cut at every colon would truncate this.
# shellcheck disable=SC2034
ZRO_T_WIDE='k1:a:b:Label with: a colon in it
k2:c:d:Plain label'

# shellcheck disable=SC2034
ZRO_T_BARE='lonely
paired:value'

# shellcheck disable=SC2034
ZRO_T_HOLE='k::tail'

# shellcheck disable=SC2034
ZRO_T_ROOTS='
plain:ZRO_T_ROOT_A
under:ZRO_T_ROOT_A/sub/file.log
literal:/tmp/not-a-variable
lower:zro_t_root_a
'
ZRO_T_ROOT_A=/tmp/zro-root

it "reads the rows of a table and drops the blank ones"
assert_out_eq "alpha:one
beta:two" zro_table_entries ZRO_T_SIMPLE
assert_out_eq "gamma:three
delta:four" zro_table_entries ZRO_T_PADDED

it "and drops exactly the lines the external reader it replaced dropped"
# The shell rule and the grep rule are the same rule, asserted rather than
# assumed: `*[![:space:]]*` is the complement of `^[[:space:]]*$`, and a reader
# that disagreed by one line would change what every table declares.
assert_eq "$(zro_table_entries ZRO_T_PADDED)" \
          "$(printf '%s' "$ZRO_T_PADDED" | grep -v '^[[:space:]]*$')"

it "reads the declared keys, in the order they are declared"
assert_out_eq "alpha
beta" zro_table_keys ZRO_T_SIMPLE
assert_out_eq "k1
k2" zro_table_keys ZRO_T_WIDE

it "refuses a table name it may not hand to an indirect expansion"
# The name is written in code and never by an operator, and this is what makes
# reading lib/table.sh enough to know so — rather than auditing every call site.
assert_fail zro_table_entries lowercase
assert_fail zro_table_entries PATH
assert_fail zro_table_entries HOME
assert_fail zro_table_entries ZRO
assert_fail zro_table_entries ''
assert_fail zro_table_entries 'ZRO_T_SIMPLE; rm -rf /'
assert_fail zro_table_entries 'ZRO_T_SIMPLE[0]'
assert_fail zro_table_entries 'ZRO_t_simple'

it "and refuses a name that is set nowhere, rather than answering with no rows"
# A typo in a table name would otherwise be a menu with no entries or a gate that
# refuses everything — neither of which reads as the mistake it is.
assert_fail zro_table_entries ZRO_T_NO_SUCH_TABLE
assert_fail zro_table_keys ZRO_T_NO_SUCH_TABLE
assert_fail zro_table_entry ZRO_T_NO_SUCH_TABLE alpha

it "finds the row a key declares"
assert_out_eq "alpha:one" zro_table_entry ZRO_T_SIMPLE alpha
assert_out_eq "k1:a:b:Label with: a colon in it" zro_table_entry ZRO_T_WIDE k1

it "refuses a key nobody declared, and an empty one"
assert_fail zro_table_entry ZRO_T_SIMPLE omega
assert_fail zro_table_entry ZRO_T_SIMPLE ''
assert_fail zro_table_entry ZRO_T_SIMPLE

it "matches a key as literal text, so one carrying a glob borrows no other row"
assert_fail zro_table_entry ZRO_T_SIMPLE 'alph?'
assert_fail zro_table_entry ZRO_T_SIMPLE 'al*'
assert_fail zro_table_entry ZRO_T_SIMPLE '*'
assert_fail zro_table_entry ZRO_T_SIMPLE '[ab]lpha'
# The whole row is not a key either: a lookup by the text of a declaration is a
# lookup nobody meant to write.
assert_fail zro_table_entry ZRO_T_SIMPLE 'alpha:one'

it "never matches a row that declares nothing"
# A row with no colon declares no field at all. The well-formedness case below
# refuses one outright; a reader that answered a key with it would hand a screen
# a value that was never declared.
assert_fail zro_table_entry ZRO_T_BARE lonely
assert_ok zro_table_entry ZRO_T_BARE paired

it "cuts the nth field after the key"
assert_out_eq "one" zro_table_field ZRO_T_SIMPLE alpha 1
assert_out_eq "a" zro_table_field ZRO_T_WIDE k1 1
assert_out_eq "b" zro_table_field ZRO_T_WIDE k1 2
assert_out_eq "Label with" zro_table_field ZRO_T_WIDE k1 3

it "and takes the remainder verbatim, colons and all, when asked for the rest"
assert_out_eq "one" zro_table_rest ZRO_T_SIMPLE alpha 1
assert_out_eq "a:b:Label with: a colon in it" zro_table_rest ZRO_T_WIDE k1 1
assert_out_eq "Label with: a colon in it" zro_table_rest ZRO_T_WIDE k1 3
assert_out_eq "Plain label" zro_table_rest ZRO_T_WIDE k2 3

it "refuses a field that is not there, rather than answering with an empty value"
# A row short of a field is a defect in the declaration. Answered with an empty
# string it becomes that defect handed to a screen to render.
assert_fail zro_table_field ZRO_T_SIMPLE alpha 2
assert_fail zro_table_rest ZRO_T_SIMPLE alpha 2
assert_fail zro_table_field ZRO_T_WIDE k2 4
assert_fail zro_table_field ZRO_T_HOLE k 1
assert_out_eq ":tail" zro_table_rest ZRO_T_HOLE k 1

it "and a strict field past a label's own colon reads INTO the label"
# Not a defect — the reason the last field of every table is read with the
# remainder accessor instead. A caller that asked for a fixed field number here
# would get half a Turkish sentence and no error to tell it so, which is what
# `zro_table_rest` exists to make unnecessary.
assert_out_eq " a colon in it" zro_table_field ZRO_T_WIDE k1 4
assert_out_eq "Label with: a colon in it" zro_table_rest ZRO_T_WIDE k1 3

it "refuses a field number that is not one"
assert_fail zro_table_field ZRO_T_SIMPLE alpha 0
assert_fail zro_table_field ZRO_T_SIMPLE alpha ''
assert_fail zro_table_field ZRO_T_SIMPLE alpha x
assert_fail zro_table_field ZRO_T_SIMPLE alpha -1
assert_fail zro_table_field ZRO_T_SIMPLE alpha 1x
assert_fail zro_table_rest ZRO_T_SIMPLE alpha 0

it "refuses with the code this program gives bad input"
assert_status "$ZRO_E_INPUT" zro_table_entry ZRO_T_SIMPLE omega
assert_status "$ZRO_E_INPUT" zro_table_field ZRO_T_SIMPLE alpha 9
assert_status "$ZRO_E_INPUT" zro_table_entries ZRO_T_NO_SUCH_TABLE
assert_status "$ZRO_E_INPUT" zro_table_root ZRO_T_ROOTS omega

it "decides nothing by racing a builtin against a reader that exits early"
# `printf | grep -q` under `set -o pipefail` returns 141 when the reader wins the
# race, and the earlier in a table a row sits the likelier it is. In the exec gate
# that was a spurious allowlist denial — exit 90, a defect by this program's own
# definition — arriving at random under load. Measured at one in three thousand
# before the lookup was put on a heredoc, so the FIRST row is the one asked for
# here, three hundred times, and a single non-zero status fails the case.
races=0
i=0
while [ "$i" -lt 300 ]; do
  zro_table_entry ZRO_T_SIMPLE alpha >/dev/null || races=$((races + 1))
  zro_table_root ZRO_T_ROOTS plain >/dev/null 2>&1 || races=$((races + 1))
  i=$((i + 1))
done
assert_eq "$races" "0"

# --- roots ------------------------------------------------------------------

it "resolves a declared root through the variable it names"
assert_out_eq "/tmp/zro-root" zro_table_root ZRO_T_ROOTS plain

it "and follows that variable when it is overridden after this file was sourced"
# What the whole indirection is for: the value in a table is a NAME, so the suite
# can point a production root at its fixtures.
assert_eq "$( ZRO_T_ROOT_A=/tmp/other; zro_table_root ZRO_T_ROOTS plain )" "/tmp/other"

it "and appends the path the declaration carries, when it carries one"
assert_out_eq "/tmp/zro-root/sub/file.log" zro_table_root ZRO_T_ROOTS under
assert_eq "$( ZRO_T_ROOT_A=/tmp/other; zro_table_root ZRO_T_ROOTS under )" \
          "/tmp/other/sub/file.log"

it "refuses a key that declares no root, and the log names the declaration"
# The message names the TABLE as well as the key, which is the whole reason a
# table travels as a name rather than as a value: a maintainer reading this line
# knows which declaration to edit without going looking.
assert_fail zro_table_root ZRO_T_ROOTS omega
err=$( { zro_table_root ZRO_T_ROOTS omega >/dev/null; } 2>&1 )
assert_contains "$err" "ZRO_T_ROOTS"
assert_contains "$err" "omega"

it "refuses a root variable that is empty rather than resolving bare"
# Never a fallback: there is no default root, and a bare relative path is how a
# tool reads a file nobody declared.
rc=0; ( ZRO_T_ROOT_A=''; zro_table_root ZRO_T_ROOTS plain ) >/dev/null 2>&1 || rc=$?
assert_eq "$([ "$rc" -ne 0 ] && printf 'refused')" "refused"
# shellcheck disable=SC2034
err=$( { ( ZRO_T_ROOT_A=''; zro_table_root ZRO_T_ROOTS plain ) >/dev/null; } 2>&1 )
assert_contains "$err" "ZRO_T_ROOT_A"

it "refuses a declaration that names a path instead of a variable"
# A path written in a root table is a root the operator cannot override and the
# suite cannot point at its fixtures. It is refused here as well as by the case
# that reads the real tables, because this is where the reason is visible.
assert_fail zro_table_root ZRO_T_ROOTS literal
err=$( { zro_table_root ZRO_T_ROOTS literal >/dev/null; } 2>&1 )
assert_contains "$err" "ZRO_T_ROOTS"
assert_fail zro_table_root ZRO_T_ROOTS lower

# --- every declared table in the tree ----------------------------------------
#
# THE GUARANTEE A SHARED READER MAKES CHEAP, and the reason this change was worth
# more than the lines it removed. Nothing before it would have caught two rows
# declaring the same key: the first silently wins and the second is a declaration
# that reads as live and can never answer.
#
# The whole program is loaded rather than the libraries alone, because three of
# the eleven — the window presets, the cost classes and the one list of
# operations — are declared in it. A table checked only where it happens to be
# convenient is a table the next one will be added beside without being checked.
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
# shellcheck source=../zimbra-ro-tui.sh
. "$ZRO_SRC/zimbra-ro-tui.sh"

# The eleven, written out. A list built by scanning the source would pass on a
# tree with none in it, and this is the list a maintainer adds the twelfth to.
ZRO_T_DECLARED='ZRO_BIN_ROOTS
ZRO_INVENTORY
ZRO_BULK_QUESTIONS
ZRO_LOGSEARCH_QUESTIONS
ZRO_LOGSEARCH_LOOKUPS
ZRO_SEARCH_CRITERIA
ZRO_SEARCH_STATES
ZRO_SEARCH_ATTACHMENTS
ZRO_WINDOW_CHOICES
ZRO_COST_CLASSES
ZRO_MENU_OPS'

it "every declared table is one the reader can read at all"
assert_eq "$(printf '%s\n' "$ZRO_T_DECLARED" | wc -l)" "11"
while IFS= read -r t; do
  [ -n "$t" ] || continue
  assert_ok zro_table_entries "$t"
done <<EOF
$ZRO_T_DECLARED
EOF

it "and every row of every one of them declares at least one field"
# A row with no colon declares nothing. The reader never matches one, so it would
# sit in a table reading like an offer this tool cannot make.
bare=""
while IFS= read -r t; do
  [ -n "$t" ] || continue
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    case $row in
      *:*) ;;
      *) bare="$bare [$t: $row]" ;;
    esac
  done <<ROWS
$(zro_table_entries "$t")
ROWS
done <<EOF
$ZRO_T_DECLARED
EOF
assert_eq "$bare" ""

it "and no key is declared twice in the same table"
# THE CASE THAT EXISTS BECAUSE NOTHING ELSE COULD HAVE. The reader stops at the
# first row a key matches, which is what keeps a lookup cheap; a second row with
# the same key is therefore a declaration that is never read, and it fails the
# build here rather than reading as live for the next person who edits the table.
dupes=""
while IFS= read -r t; do
  [ -n "$t" ] || continue
  keys=$(zro_table_keys "$t")
  total=$(printf '%s\n' "$keys" | wc -l)
  unique=$(printf '%s\n' "$keys" | sort -u | wc -l)
  [ "$total" -eq "$unique" ] || dupes="$dupes [$t]"
done <<EOF
$ZRO_T_DECLARED
EOF
assert_eq "$dupes" ""

it "and every root a root table declares is a variable name, never a path"
# A path written here would be a root the operator cannot override and the suite
# cannot point at its fixtures. Asked of both root tables at once, so the next one
# inherits the rule instead of needing its own case.
bad=""
for t in ZRO_BIN_ROOTS ZRO_INVENTORY; do
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    spec=$(zro_table_rest "$t" "$key" 1) || { bad="$bad [$t:$key]"; continue; }
    zro_table_name_ok "${spec%%/*}" || bad="$bad [$t:$key=$spec]"
  done <<ROWS
$(zro_table_keys "$t")
ROWS
done
assert_eq "$bad" ""

it "and every declared root resolves, so none reads as available and answers nothing"
for key in $(zro_table_keys ZRO_BIN_ROOTS); do
  assert_ok zro_table_root ZRO_BIN_ROOTS "$key"
done
for key in $(zro_table_keys ZRO_INVENTORY); do
  assert_ok zro_table_root ZRO_INVENTORY "$key"
done

it "the two lists that are enumerated but never looked up are still readable"
# The allowlist and the low-priority list answer their own membership question,
# for the reason docs/adr/0009 records. What they share is the line enumeration,
# and this is what holds that half to working.
assert_ok zro_table_entries ZRO_ALLOW
assert_ok zro_table_entries ZRO_LOW_PRIORITY
assert_eq "$(zro_low_priority_bins)" "$(printf '%s\n%s' 'grep' 'gzip')"
assert_contains "$(zro_allow_entries)" "zmprov:ga"

zro_t_report
