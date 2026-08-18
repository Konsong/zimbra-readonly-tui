# The four lines above the settler stay at the call site

- **Status:** accepted
- **Date:** 2026-08-19
- **Affects:** the four gated reads in `lib/store.sh`, the three in `lib/search.sh`, and any read added
  to either module after this one
- **Evidence:** [`tests/test_readonly_scan.sh`](../../tests/test_readonly_scan.sh) — four cases fail when
  the helper below is built, measured rather than reasoned about
- **Follows:** [ADR-0010](./0010-the-gate-owns-the-predicate-and-one-settler-asks-it.md), which moved
  everything one level down from here, and [ADR-0009](./0009-what-is-not-a-declared-table.md) for the
  shape of a decision about what is deliberately NOT folded in

Seven functions read a mailbox — four in `lib/store.sh`, three in `lib/search.sh` — and each ends the same
four lines:

```bash
err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"

out=$(zro_mbox_run "$acct" gaf 2>"$err") || rc=$?
rc=$(zro_settle "$err" "$rc" zro_store_fail_code)
[ "$rc" -eq 0 ] || return "$rc"
```

Twenty-eight lines that say one thing. Both reviews on #71 raised it independently, as Duplicated Code and
as Shotgun Surgery, and it was declined there as a decision rather than a substitution. **This is that
decision.** It is written down because the duplication is real and the helper that removes it is the
obvious next move — so a reader who does not know what it costs will propose it again.

## The decision

**No helper owns a mailbox read's invocation.** Each of the seven call sites writes
`zro_mbox_run "$acct" <subcommand>` itself, with the subcommand as a literal word beside the account.
`lib/settle.sh` holds everything below that line and nothing above it.

**Two independent constraints say so, and only one of them is the scan.** That matters: a decision resting
on a test invites weakening the test.

### The static proof, measured

`tests/test_readonly_scan.sh` greps the stripped source for `zro_mbox_run` call sites and reads every token
position off them, holding the set equal to the allowlist's `zmmailbox` entries **in both directions**.
That is what lets a reader prove which questions this tool can ask of a mailbox without running it — the
guarantee this whole program is.

The helper was built to find out rather than argued about, in its strongest form: output on stdout, the
code as the status, and the literal still written at the call site.

```bash
out=$(zro_store_read "$acct" gaf) || return $?
```

The scan went from `1340 ok, 0 fail` to `1336 ok, 4 fail`:

- *every mailbox read names its subcommand literally, and the allowlist approves it* — twice
- *and no mailbox read hands the gate a subcommand this reader cannot resolve*
- *and every approved mailbox read has a call site, in exactly one spelling*

**The word `gaf` was still in the source, at the call site, and the scan failed anyway.** The scan does not
read call sites of arbitrary functions; it reads token positions off `zro_mbox_run` lines. A literal that
is not on one of those lines is a literal nobody checks.

**The fourth failure is the one worth recording**, because it is the direction nobody expects: with the
subcommand gone from every `zro_mbox_run` line, `zmmailbox:gaf` becomes an approved read with no call
site — which that case reports, correctly, as an operation that reads as available and can never answer.
The helper does not merely blind the scan. It makes the allowlist read as wrong.

### What Bash will not do

The scan is answered by the one shape that might survive it: the helper takes the already-built vector and
the call site still writes `zro_mbox_run` itself. Then the run line stays literal, and the only lines left
for a helper to absorb are the other three:

```bash
err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"   # a return in the CALLER's frame
rc=$(zro_settle "$err" "$rc" zro_store_fail_code)   # already the extracted helper
[ "$rc" -eq 0 ] || return "$rc"                     # a return in the CALLER's frame
```

Two of the three carry a `return` that has to fire in the caller, and **a Bash function cannot return from
its caller.** The mechanism that would fake it is `errexit`, which this tree does not run and will not:
whiptail returns non-zero on Cancel and would kill the TUI, and `errexit` is silently disabled in
conditional contexts besides. The third line is `zro_settle` — the collapse, already performed by ADR-0010.

**So there is no residue left to name.** The seven repetitions are two caller-frame returns, one invocation
the proof requires to be written out, and one call to the helper that already exists. The duplication is
what is left after the extractable part was extracted.

## What was considered and rejected

**The helper that runs the command and hands back both channels.** Built and measured above. Rejected for
the static proof, and rejected again by the return constraint even if the proof were set aside.

**Teaching the scan to follow the helper.** One indirection is easy to teach it. It is rejected because it
is precisely the weakening the scan exists to prevent: the value of the case is that a reader gets the
answer from the source, and a scan that resolves one hop is a scan that will be asked to resolve two.

**The two-channel objection, which #71 gave as the reason.** It is overstated and is NOT why this is
declined. A settler cannot return both because *a settler that returned the code could not be told apart
from a settler that failed, and 0 is a code* — but a READ helper is not in that bind, as `zro_mbox_run`
and `zro_prov_read` both demonstrate: output goes to stdout and the code comes back as the status. Recorded
here so the wrong reason is not inherited by whoever reopens this.

**Folding `zro_mbox_require` into a helper.** ADR-0010 put it at each of the seven sites deliberately: it
is what tells the existence gate's refusal from the command failing, and that ADR records why no predicate
can answer it instead. A helper that swallowed it would put the reasoning one level away from the reads it
protects — and it does not survive the constraints above in any case.

**Joining the last two lines with `;` at all seven sites.** This is the one change that is actually
available. It saves seven lines, introduces no named thing, and makes the settle and the check on its
answer read as one step when they are two. Declined as not worth a commit; noted so it is recognised as
already-considered rather than overlooked.

## Consequences

**A fifth line added to this ceremony is seven edits, and that is accepted.** It is the cost the two
constraints leave, and it is bounded: the last two times this ceremony changed — #70 and #71 — what changed
was below it, in the part that did collapse.

**A new gated mailbox read writes the four lines out.** It is not a rule anyone can get wrong quietly: the
scan fails the build for a subcommand it cannot resolve, and `tests/test_gate_passthrough.sh` holds the
seam to the settler's rule. What this ADR adds is the reason a reviewer can give without re-deriving it.

**Three modules are still outside all of this** — `lib/queue.sh`, `lib/service.sh` and `lib/logview.sh`
have no settler and no failure reader. ADR-0010 records why, and their sinks remain a decision of their
own. Nothing here changes that.
