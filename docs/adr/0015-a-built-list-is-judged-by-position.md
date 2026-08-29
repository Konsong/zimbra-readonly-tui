# A built list is judged by position, and the position is read in one place

- **Status:** accepted
- **Date:** 2026-08-29
- **Affects:** `zimbra-ro-tui.sh:758`, `:1143` and `:1835` lose eight lines each and keep their own
  statement of what they guarantee; `lib/list.sh` arrives holding `zro_list_position`;
  `tests/test_list.sh` and `tests/lib/list.sh` arrive with the hostile vector;
  `tests/test_store_screen.sh`, `tests/test_search_screen.sh` and `tests/test_logview_screen.sh` all run
  it; `tests/test_readonly_scan.sh` gains the classification of all thirteen `zro_ui_menu` call sites;
  `CONTEXT.md` gains **declared list** and **built list**; `CLAUDE.md` gains the convention once the scan
  enforces it
- **Evidence:** [§8 of the 2026-08-19 architecture review](../research/2026-08-19-architecture-review.md),
  whose measurement stands and whose ranking this rejects, and two defects measured under WSL against the
  suite's own fixtures — set out below. Issues
  [#91](https://github.com/Konsong/zimbra-readonly-tui/issues/91) and
  [#92](https://github.com/Konsong/zimbra-readonly-tui/issues/92) carry the work
- **Follows:** [ADR-0011](./0011-the-four-lines-above-the-settler-stay-at-the-call-site.md), which declined
  a helper of this shape for two constraints, one of which does not reach here; and
  [ADR-0009](./0009-what-is-not-a-declared-table.md) for the shape of a decision about what a declaration
  is not

Three screens draw a list out of an answer — a mailbox's folders, a search's conversations, a log's files —
and each ends the same eight lines: a `case` refusing non-digits, an `if` refusing out-of-range, two
`zro_log error` lines, then `${arr[choice - 1]}`. §8 of the review reported three byte-identical copies of
one safety rule, all three documented, all three pointing at each other, and ranked it a concentration
available with the smallest blast radius in that report.

The duplication is real. **The rule it concentrates is not correct, and it is incorrect identically in all
three copies.**

## The decision

**A built list's position is read by `zro_list_position` in `lib/list.sh`, and by nothing else.** It takes
the operator's answer, the count of the list, and the noun that names the list in the log. It prints the
0-based index on stdout, and on refusal it logs its own message — both of today's, unchanged to the byte —
and returns `ZRO_E_INPUT`. The array never travels; the call site writes `path=${paths[i]}` itself.

### The guard admits what the line it protects cannot evaluate

Two values pass it today, both measured against the suite's own fixtures.

**`08`, on any list of eight or more entries.** `*[!0-9]*` does not match it. `[ 08 -lt 1 ]` and
`[ 08 -gt 15 ]` read it as decimal 8 and let it through. Then `${paths[08 - 1]}` evaluates the subscript
with bash's base detection, where a leading zero means octal:

```
zimbra-ro-tui.sh: line 758: 08: value too great for base (error token is "08")
```

`zro_menu_folder` is abandoned, the folder is never read, and three cases in `tests/test_store_screen.sh`
fail. Zimbra's default folder set is twelve entries, so every real mailbox is long enough.

**An integer wider than 64 bits.** `[` reports `integer expression expected` **twice** and both comparisons
come back false, so the guard falls through rather than refusing. `set -u` then finds `paths[choice - 1]`
unset and the shell exits — no `__ZRO_RESULT__`, and `tests/run.sh` reports CRASHED.

Neither is reachable through whiptail, because this program writes the tags itself as `i=$((i + 1))`.
**That is the point rather than the defence.** The guard exists because what comes back from the screen is
not trusted; it is correct only by virtue of the assumption it exists in order not to make. The stub
backend reaches both today, which is how they were found.

What is admitted is `''|*[!0-9]*|0*` and at most nine characters: `[1-9]` and up to eight more digits. What
survives is a decimal integer bash can evaluate, which is what makes the range check below it total.

### The class is three sites, not a sample of them

The tree holds four computed array subscripts. Three are these. The fourth, `zimbra-ro-tui.sh:838`, steps a
loop counter by two over `ZRO_SEARCH_SEL` and never sees operator text. Arithmetic comparison against an
operator's answer exists at exactly three lines: `:754`, `:1139`, `:1831`. The reader covers the class
entire.

### The scan is the precondition, not the bonus

§8 offered *"`tests/test_readonly_scan.sh` does not read these call sites"* as what separates this from
ADR-0011's declined helper. The fact is true and the argument is not: no measurement goes red here because
this rule has never been measured, which is a gap rather than a licence. What does separate them is
ADR-0011's *living* constraint — two lines carrying a `return` that has to fire in the caller's frame. It
does not reach here, because the refusal is a `continue` in the caller's loop and `|| continue` is one line
at the call site. The reader is available on that ground.

§8 also has the dependency backwards. It offers the scan's silence as evidence the change is cheap, having
already written the reason that silence is fatal: whoever writes the fourth list screen *"will find the
rule stated wherever they look, and will still write the fourth copy."* A helper does not stop them. A
build that fails does.

So the scan gains the rule. Each of the thirteen `zro_ui_menu` call sites is declared in the test by its
enclosing function and its family — `declared`, `built` or `fixed` — and the set found in the source is
held equal to the declared set **in both directions**, exactly as the `zmmailbox` allowlist is. The
families are proved from the source rather than asserted: a `fixed` site passes literal word pairs and no
`"${items[@]}"`, the other two pass `"${items[@]}"`, and a `built` site calls `zro_list_position`. All
thirteen sit in thirteen distinct functions, so the function name is the key.

### What stays at the call site

Each screen keeps its own statement of what it guarantees: `:695` that no value from the screen becomes an
argument, `:1104` that no id comes from the screen, `:1822` that the viewer stays bounded to the inventory.
Those are three different promises to three different operators, and they are how the rule reaches whoever
reads one screen. Only the mechanism moves. §8's deletion test counted their removal as part of the win; it
is not one, and **the concentration is eight lines of code, not eight lines and three comments.**

### What does not move: the empty list

A folder listing that names no folder is a defect and is logged as one. A log with no files is ordinary and
gets its own screen, whose comment insists an empty list must never read as an empty file. A conversation
list with no rows returns silently — the one of the three nobody decided, and the subject of its own issue.
Folding them into the reader would replace three right answers with one wrong one.

## What was considered and rejected

**A reader that takes the array by name and returns the element**, so a call site is one line instead of
two. Measured at the 4.2 floor: `${!ref}` resolves `name[i]` and `name[@]`, and a `local -a` in the caller
is visible to the callee — but `#name[@]` is a fatal expansion error, so the count cannot be reached that
way. The name check that makes `lib/table.sh` safe demands `ZRO_[A-Z0-9_]*`, which `paths` and `ids` are
not, so admitting them means a second and looser name predicate. That spends the property `lib/table.sh`
bought: that reading one file is enough to know every indirect expansion in this tree is safe, without
auditing the call sites. Rejected for one line.

**The same, with the three arrays renamed to `ZRO_`-prefixed locals** so `zro_table_name_ok` is reused
unchanged. Legal bash. Rejected because `ZRO_` in this tree means a declaration, and three locals wearing
that prefix would say something false at the only three places this rule is written.

**Fixing the guard in place at all three sites and leaving them there.** The cheaper change, and what §8
would have recommended had it measured. Rejected: it accepts in advance that the fourth copy carries the
same fault, and the fault is what makes the copies worth removing rather than merely untidy.

**Declaring the classification as a `ZRO_` table in the program, read through `lib/table.sh`.** It is the
convention for a declared table. Rejected because the program never needs to know which family a menu
belongs to — only the build does — and a declaration standing in the program whose only real reader is the
suite is exactly what §12 of the same review reports about the cost class. ADR-0009 points the same way: a
list answering its own classification question for one reader keeps that answer to itself.

**A section on ADR-0011 rather than an ADR of its own.** ADR-0011's `Affects` line is the gated mailbox
reads in `lib/store.sh` and `lib/search.sh`; this is the screen layer and a different constraint set. Its
"Corrected" block is precedent for correcting that decision, not for carrying a second one. ADR-0011 gains
a forward pointer instead, because it is where a reader asking *why is there no helper* lands.

## Consequences

**A fourth list screen fails the build until it says which kind of list it drew**, and fails again until a
`built` one calls the reader. That is the friction, and it is the friction the allowlist keeps on purpose.

**The reader is a pure function, so its refusals are proved without a mailbox, a stub or a fixture.** The
exhaustive vector lives in its unit test; the same vector, declared once in `tests/lib/list.sh`, also runs
against all three screens, where the assertion is the different one — that nothing ran. Before this the
vector existed at one screen out of three, and it did not contain `08`.

**The classification is proved from the source, but the family names are still written by hand.** A site
can only be misclassified in a way one of the three source facts contradicts, which fails the build;
nothing catches a name that is wrong and consistent with all three. That is the residue, and it is smaller
than the declaration it replaced.

**Three commits, three issues.** [#91](https://github.com/Konsong/zimbra-readonly-tui/issues/91) is the
defect and ships alone and first — a red case at each of the three screens, then the admission fixed in
place — because a defect folded into a refactor cannot be reviewed or picked on its own.
[#92](https://github.com/Konsong/zimbra-readonly-tui/issues/92) is the reader, the scan's rule and the
`CLAUDE.md` convention, and is blocked by #91.
[#93](https://github.com/Konsong/zimbra-readonly-tui/issues/93) — the conversation screen's silent empty
list — is neither, and waits on neither.
