# What is not a declared table

- **Status:** accepted
- **Date:** 2026-08-18
- **Affects:** `lib/table.sh`, the exec gate's two lists, and every table added after this one

Eleven `<key>:<field>…` tables were read by sixteen hand-rolled readers, two of which —
`zro_bin_path` and `zro_inv_base_path` — were the same thirty lines twice, comments included.
`lib/table.sh` now holds that reader. Merging readers is not a decision worth an ADR; **which
lists were kept out of it, and why the table travels as a name**, are, because both look like
oversights to anyone who did not sit through the reasoning.

## The decision

**`ZRO_ALLOW` and `ZRO_LOW_PRIORITY` are enumerated through the shared reader and looked up by
nothing in it.** They share the line enumeration — a blank line is not a row, everywhere — and
keep their own membership question: `zro_allow_has` and `zro_runs_low_priority` still match a
whole line with `grep -qxF` on a heredoc, in `lib/exec.sh`, unchanged.

They look exactly like the others. `ZRO_ALLOW` is even colon-separated. Three things separate
them:

1. **The question is different.** Every other table answers *what does this key declare*. These
   answer *is this line present*. A key that appears in `ZRO_ALLOW` eleven times — `zmprov:ga`,
   `zmprov:gam`, `zmprov:gc` — is not a duplicate declaration, it is the list working as
   intended, which is why the duplicate-key case in `tests/test_table.sh` runs over the other
   eleven and not over this one. `ZRO_LOW_PRIORITY` carries no colon at all.
2. **The failure mode is different.** An allowlist lookup that answers wrongly is exit `90`,
   which this program defines as a defect in itself and always logs. Every other table's wrong
   answer is a menu entry that reads oddly. A reader shared with eleven screens is a reader that
   will one day be changed for a reason that has nothing to do with the gate, and the change will
   be reviewed by whoever cares about the screen.
3. **The measured hazard lives there.** The 141 race — `printf | grep -q` under `pipefail`
   reporting a spurious denial once in three thousand lookups — was measured *in the allowlist*.
   The rule survives in both places; what the gate does not take on is a second reason for its
   own lookup to change.

**`ZRO_SEARCH_PROMPTS` is kept out for a different reason: it is not this shape.** Its values run
over several lines, and what ends an entry is *declared* — the next line whose key is a kind some
criterion claims — rather than counted in fields. Folding it in would buy a parameter meaning
*which of two readers am I*, which is the thing a shared reader exists to remove.

**A table travels as a NAME, not as its text.** `lib/logsearch.sh` held the only generic reader
here before this and stated the opposite: *the table travels as a value rather than as a name, so
nothing here has to know which declarations exist*. That was right for what it did — it read two
tables and logged nothing. It stops being right at `zro_table_root`, which logs its own refusals
precisely because a root that quietly resolves to nothing reaches the operator as a greyed-out
menu entry or an empty answer, and a log line that cannot name the declaration to edit sends a
maintainer looking. One argument does double duty: it is the table, and it is the noun in the
message. The name is checked against `ZRO_[A-Z0-9_]*` before it is expanded, so reading
`lib/table.sh` is enough to know the indirect expansions are safe.

## What it costs

Every table needs a `# shellcheck disable=SC2034` with the reason on it: a declaration nothing
expands where it is written reads to ShellCheck as a variable nobody uses. That is the price of
the convention, not an oversight, and it is written above each table so the next one is told
rather than discovering it from a red build.

## What was considered and rejected

**Folding the two lists in anyway, for symmetry.** It reads tidier and it is how this will be
"cleaned up" one day. The three reasons above are why it is not, and this ADR exists so that the
cleanup arrives as a decision rather than as a diff.

**Leaving the two root resolvers duplicated and sharing nothing.** That was the smaller change,
and it would have left the five rules — heredoc, quoted literal key, blank line, remainder,
refusal over empty — re-derived at ten more readers. The line count was never the point; the
rules being in one place is.

**Declaring a field count per table so the reader knows which field is last.** A table about
tables, and a second declaration that can drift from the first. Two accessors instead:
`zro_table_field` cuts at the next colon, `zro_table_rest` takes the remainder, and labels use
the second because a Turkish label really does carry a colon.

## Consequences

`ZRO_BIN_ROOTS` and `ZRO_INVENTORY` do not move. The static scan permits the literal `zmmailbox`
in `lib/exec.sh` and nowhere else, and the two-edit friction between the allowlist and the root
table is unchanged: adding an operation still means editing both.

`tests/test_table.sh` holds the eleven to a shape nothing held them to before — every row carries
a colon, no key is declared twice, every root is a variable name and resolves. The duplicate-key
case is the one that could not have existed without the shared reader: the reader stops at the
first match, so a second row with the same key was a declaration that read as live and could
never answer.
