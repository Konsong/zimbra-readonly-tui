# The gate owns the predicate for its own codes, and one settler asks it

- **Status:** accepted
- **Date:** 2026-08-18
- **Affects:** `lib/exec.sh` keeps `zro_exec_own_code`, `lib/settle.sh` is added beside it, and
  `lib/message.sh`, `lib/store.sh` and `lib/search.sh` all finish through it
- **Evidence:** the defect that produced it, fixed on the branch this one follows, and
  [`tests/test_gate_passthrough.sh`](../../tests/test_gate_passthrough.sh), which holds ten gated seams to
  the rule
- **Follows:** [ADR-0009](./0009-what-is-not-a-declared-table.md) twice over — for why a shared routine sits
  beside the gate rather than inside it, and for a name that is checked before it is used

`zro_exec` answers with one of five codes it produced itself, or with the exit status of the command it ran,
verbatim. A module holding that number cannot tell those apart, and the two call for opposite handling: the
gate's codes describe this program or the host it is pointed at and travel to the operator unchanged, while a
binary's status is undocumented here and has to become a code this program defines.

Six modules decided that for themselves and arrived at three different answers — a five-code list in
`lib/logview.sh`, a four-code list in `lib/queue.sh` and `lib/service.sh`, and no list at all in
`lib/store.sh` and `lib/search.sh`, which passed the status through by falling back to it. The sixth stopped
deciding: `73b510e` replaced `zro_msg_fail_code`'s trailing `printf '%s' "$rc"` with a constant, and an
allowlist denial on `zmmetadump` — exit `90`, which this program defines as a defect in itself — reached the
operator as "mailboxd is stopped, check `zmcertmgr`", naming a service that command never talks to.

Merging three copies of a routine is not a decision worth an ADR. **Where the membership lives, what was
rejected, and which modules were left alone** are, because each of the alternatives reads as the obvious one
to whoever did not sit through the reasoning — and one of them is what this replaced.

## The decision

**The gate owns a predicate that says which codes are its own.** `zro_exec_own_code` is in `lib/exec.sh`,
beside the function whose return set it describes, and its membership is read off that function rather than
chosen. It changes exactly when the gate's return set changes — that is one reason, not two, which is what
makes it the gate's knowledge rather than a list about the gate kept somewhere else.

**One settler asks it, and a gated read finishes through the settler.** `lib/settle.sh` holds the four
steps those reads share: keep a bounded prefix of what the command said where the error screen
can find it, ask the predicate, hand a command's own failure to the module's reader, remove the scratch file.

**The settler sits beside the gate and not inside it**, for the reason ADR-0009 gives about the allowlist: a
routine shared by several screens is a routine that will one day be changed for a reason that has nothing to
do with the gate. The gate is the safety core and gains nothing by carrying a second reason to be edited.

**A module hands over only its failure reader, and hands it over by name.** The order is what forces that:
the reader reads the scratch file and the settler is what removes it, so a caller that mapped first would own
the removal again, and the ceremony would be back in three places. The reader is handed the file and not the
status, because by then there is no status worth reading — the gate's own codes have been answered and what
is left is the binary's, which this program does not document.

**The name is checked before anything is called with it** — that it is shaped like a failure reader
(`^zro_[a-z0-9_]+_fail_code$`), and that a function answers to it. This is ADR-0009's rule for a declared
table travelling as a name, applied to a function: one argument does double duty — it is what runs, and it is
the noun in the log line — so reading `lib/settle.sh` has to be enough to know what may run. It is not a
defence against an operator, because no operator text can reach that argument; it is a defence against an
edit.

**Either refusal is logged as a defect in this tool, and answered with the input code.** Logged, because
nothing an operator did can produce one. Answered with `ZRO_E_INPUT` rather than with one of the three codes
the gate keeps for a defect in this tool — `90`, `91`, `92` — because each of those names a refusal that did
not happen: no list refused this, no user was wrong, no binary was missing. CONTEXT.md states that rule about
the word rather than the number, under *Refused by the host*: *denied* is the allowlist's word and may not be
borrowed for a refusal that is not the allowlist's. The code carries the word. `ZRO_E_INPUT` is what
`lib/message.sh` already answers with when the dump prints its usage banner, which is the same kind of fact:
this program built something wrong, the log says what, and the screen for that code ends by sending the
operator to the tool's log.

## What was considered and rejected

**Each module enumerating the gate's codes for itself.** This is what was there, in three different
memberships, and it is what the next reader will re-derive: a `case` listing four or five constants reads
like a complete thought. It is not one. The list is a copy of a fact that lives in `zro_exec`, and the copies
were already wrong — `lib/queue.sh` and `lib/service.sh` name four of the five, `lib/logview.sh` names five,
`lib/store.sh` and `lib/search.sh` name none. Adding a sixth code to the gate would mean finding every module
that guessed at the list, and nothing would fail if one were missed.

**A fall-through: end the failure reader by returning whatever status it was handed.** Proposed first,
because it costs no predicate at all and it demonstrably worked — a gate code arrives, nothing matches, the
code comes back out. It is rejected because it cannot tell the two cases apart, and it is wrong in the case
it does not notice: an unrecognised failure of a command that RAN leaves through the same arm, so the
binary's own exit status reaches the operator as "islem basarisiz (kod 1)" — a number this program does not
define and cannot explain. The arm that made the gate's codes travel correctly is the same arm that leaked
the binary's.

**Putting the predicate in the settler instead of the gate.** It would read tidily — the only caller is
there. It is rejected because the membership is a fact about `zro_exec`'s return set, and a fact kept away
from what it describes is a fact that goes stale silently. The settler asking is cheap; the settler *knowing*
would be a second place to edit when the gate gains a code.

## The modules that keep their own lists are not an oversight

**`lib/queue.sh` and `lib/service.sh` use `ZRO_E_UNAVAILABLE` as their own fall-through sink while naming the
gate's other four codes above it.** That looks like the bug this ADR is about and is not: the fifth gate code
IS `ZRO_E_UNAVAILABLE`, so a gate refusal that falls into the sink leaves as the same number it arrived as.
What differs is the log — the sink writes `queue unreadable` for a refusal the gate had already explained.
Converting them is therefore a decision about what that sink MEANS, not a substitution, and it is deliberately
not taken here.

**`lib/logview.sh` names all five and sinks the rest into `ZRO_E_NO_LOG`.** Its list is complete today; what
it lacks is a reason to stay complete. It is left for the same reason: the sink is the decision, and this
change is not about sinks.

**Three modules move rather than six, because only three have a ceremony to move.** `lib/message.sh`,
`lib/store.sh` and `lib/search.sh` each carried a `*_settle` routine that was a copy of the other two apart
from the reader it named — until the message one grew the predicate check the settler now holds for all of
them — and each names a `*_fail_code` reader that is genuinely its own. The other three have no settler and no
reader: the capture, the classification and the sink are written inline in the fetch function, and
`lib/queue.sh` additionally records a host refusal as a capability while it is there. Folding them in would be
a redesign rather than a de-duplication, and the passthrough suite holds them to the rule meanwhile, which is
what makes leaving them safe.

**The message read moved first**, and it was chosen because nothing an operator saw changed: its
unrecognised-failure code was already the documented one. The store and search reads followed in a change of
their own, because deleting their fall-through changes what an operator is shown — an unrecognised failure of
a command that ran now names the mail service the read needed instead of printing the mailbox binary's exit
status as a bare number. Splitting it that way is what put that one change where a reviewer was looking for
it.

**One read inside the migrated module does not move either.** `zro_msg_head_fetch` reads the stored blob
and runs the same steps inline, and it already asks the predicate — but it has no failure reader to hand
over: what it has is one sink, `ZRO_E_NO_BLOB`, and a warning that names the file. It also needs what the
command said AFTER the file is gone, for that warning, so the settler's order does not describe it either.
Named here rather than left to be found, because a module the ADR says has moved is exactly where an
unconverted read reads as an oversight.

**Two more modules map a failure and are not in this at all.** `zro_prov_read` in `lib/account.sh` consumes
its mapping BEFORE it returns — an unreachable service is what decides whether the read is retried through
LDAP — so its reader is not a last step and the settler's order does not describe it. `lib/delivery.sh` reuses
one scratch file across every log file in the window and appends the list of files it could not read to the
kept message, after the bound; a settler that removed the file and stopped at the bound would take the
disclosure with it. Both are named here so that a later reader does not take them for work somebody forgot.

## The existence gate is asked before the command, not read off its status

The store and search reads do not reach `zro_exec` directly. They go through `zro_mbox_run`, which asks the
existence gate first and runs nothing at all for an account whose mailbox has not been proven. So a status
those reads hold can be one of THREE things rather than two — a code the exec gate produced, a refusal the
existence gate answered with, or the mailbox binary's own exit status — and the predicate answers for the
first only.

The fall-through hid that. `printf '%s' "$rc"` passed `ZRO_E_NO_MAILBOX` and `ZRO_E_NO_ACCOUNT` out as
themselves for exactly the accidental reason it passed the exec gate's codes out as themselves. Deleting it
without noticing turns an account that has never been used into a stopped mail service on the screen — the
same shape of defect this ADR was written about, running the other way. Seven cases in
[`tests/test_store.sh`](../../tests/test_store.sh) catch it; it is written down here because reasoning from
the spec alone did not.

**A second predicate is not the answer.** `zro_exec_own_code` works because its membership is READ OFF
`zro_exec`'s return set — that is the whole reason it belongs to the gate. `zro_mbox_run` has no such set to
read off: `zro_mbox_verdict` forwards whatever the oracle's directory read returned, and that read ends in a
fall-through of its own, so the codes the existence gate can produce are not bounded by anything the mailbox
module wrote.

**So each read asks the gate itself, before it runs anything.** `zro_mbox_require` at the top of the seven
reads, with the gate's answer returning from there instead of travelling on as a status. `zro_mbox_run` goes
on asking it too — that precondition is what makes it the only path to the gated binary, and weakening it was
never on the table — and the second ask costs no invocation, because a mailbox proven once is proven for the
session and the proof is a file. What reaches the settler after that is a command that ran.

## Consequences

`lib/settle.sh` is sourced after `lib/exec.sh` — in the entry point, and in the four test files that source
the message, store or search module directly. Two of those four needed nothing but that source line. The
store and search suites needed it and gained cases as well, for the one behaviour that changed and for the
claim about what the second gate ask costs. Nothing else in any of the four moved, which is what makes them
evidence that the migration preserved behaviour rather than evidence of nothing.

`tests/test_settle.sh` tests one thing, the refused name, and nothing else. No higher seam can reach it: a
module names its reader in its own source, so a bad name is a maintainer's edit rather than anything an
operator can do. Every other question about the settler is asked where an operator would meet it.

The bound on the kept message has a name now: `ZRO_ERROR_KEEP_BYTES`, declared in `lib/core.sh` beside the
exit codes and the error store it belongs to, and read at the settler and at the ten other sites that were
each carrying the number. It is deliberately NOT enforced inside `zro_set_error`, because two of those sites
bound what the command said and then append the log files they could not open — a bound one layer down would
let a long message spend the whole budget and cut the disclosure off the end, which turns a bound into a
silence. The declaration carries the note that 500 was chosen and never measured: nothing in this tree
records where it came from. The bound also has its first test, at the message read, where two captured
failures are already longer than it.
