# Unavailable names a service that did not answer, and a constant doing five jobs is trusted with none

- **Status:** accepted
- **Date:** 2026-08-30
- **Affects:** `ZRO_E_UNAVAILABLE` gains a definition in `lib/core.sh` and in `CONTEXT.md`;
  `lib/core.sh` gains `ZRO_E_NO_QUEUE` and `ZRO_E_NO_STATUS`; `lib/queue.sh` and `lib/service.sh`
  lose their hand-written code lists and their sink, through
  [#78](https://github.com/Konsong/zimbra-readonly-tui/issues/78) and then
  [#77](https://github.com/Konsong/zimbra-readonly-tui/issues/77); `zro_report_error` gains two
  arms; `CONTEXT.md` gains three terms and loses one wrong gloss;
  [ADR-0010](./0010-the-gate-owns-the-predicate-and-one-settler-asks-it.md) and
  [ADR-0012](./0012-no-reader-ends-with-the-status-it-was-handed.md) gain corrections in place; the
  comment above `zro_exec_own_code` loses a stale claim; four tickets are opened —
  [#99](https://github.com/Konsong/zimbra-readonly-tui/issues/99),
  [#100](https://github.com/Konsong/zimbra-readonly-tui/issues/100),
  [#101](https://github.com/Konsong/zimbra-readonly-tui/issues/101),
  [#102](https://github.com/Konsong/zimbra-readonly-tui/issues/102)
- **Evidence:** [docs/research/2026-08-30](../research/2026-08-30-the-gate-cannot-reach-these-two-sinks.md),
  which holds the script and the runs, and issues
  [#77](https://github.com/Konsong/zimbra-readonly-tui/issues/77) and
  [#78](https://github.com/Konsong/zimbra-readonly-tui/issues/78)
- **Follows:** [ADR-0012](./0012-no-reader-ends-with-the-status-it-was-handed.md), whose deferral of
  these two modules this supersedes, and
  [ADR-0010](./0010-the-gate-owns-the-predicate-and-one-settler-asks-it.md), one of whose two
  reasons for the deferral this corrects and the other of which it leaves standing

`lib/queue.sh` and `lib/service.sh` sink an unrecognised failure into `ZRO_E_UNAVAILABLE`, whose one
screen opens by explaining that `zmprov` connects to mailboxd over SOAP. `postqueue` speaks no SOAP.
`zmcontrol status` does not either, and the screen tells an operator whose `zmcontrol status` just
failed to go and run `zmcontrol status`. Two ADRs left this alone as a decision about what the sink
means. The decision could not be made because the constant meant five different things, and this
ADR is the one that binds it to one.

## The constant was doing five jobs

| What a site meant by it | Where |
| --- | --- |
| A Zimbra service this read needed did not answer | the mailbox and provisioning reads, the store and the search |
| A binary this program's own plumbing needs is not on this host | the exec gate and its identity helpers |
| A scratch file could not be created | around fifteen sites in nine modules |
| A system tool is missing, or answered something unusable | the clock, the log inventory, the two window formatters |
| A command ran and failed for a reason nothing recognised | `lib/queue.sh` and `lib/service.sh` |

CLAUDE.md already states the rule this breaks, about codes rather than about this code: *a constant
doing two jobs can be trusted with neither.* Five is not a different problem.

## What it means now

**`ZRO_E_UNAVAILABLE` names a Zimbra service that a read needed and that did not answer.** Nothing
else. It is the meaning its screen already describes, the meaning `zro_store_fail_code` and
`zro_search_fail_code` already state in as many words — *"anything else is the service this read
needed, not a number"* — and the only one of the five that is an answer an operator can act on:
check the mail service, check the certificate.

The other four are not deprecated behaviours to be tolerated. They are violations, each with a
ticket: [#99](https://github.com/Konsong/zimbra-readonly-tui/issues/99) for the scratch file,
[#100](https://github.com/Konsong/zimbra-readonly-tui/issues/100) for the gate,
[#101](https://github.com/Konsong/zimbra-readonly-tui/issues/101) for the system tools, and this ADR
for the two sinks. Each ticket carries one question — which code — because the term was the part
that could not be decided piecemeal and now is.

**The definition binds the screen channel and not the process exit status.** `zro_startup_check`
answers `ZRO_E_UNAVAILABLE` for five conditions of its own and none of them is a service that did
not answer — but its code becomes the status the shell receives, never a screen an operator reads.
A number in that channel says only that the tool would not start, and the message beside it is what
carries the reason. Declared here so that it reads as out of scope rather than as forgotten; what
that function tells an operator is a question about its five messages, not about its one code.

## The premise that did not survive

Both open issues, both ADRs and the comment above `zro_exec_own_code` say the same thing: these two
modules name four of the gate's five codes and use the fifth AS the sink, so a gate refusal that
lands there leaves as the number it arrived as, and converting them changes which log line it
writes. That makes the sink a decision rather than a substitution.

**The gate cannot return `ZRO_E_UNAVAILABLE` to either module.** Four separate mechanisms close it:
the startup preflight refuses to run without `id`, `timeout` or `runuser`; the identity helper's
status is discarded inside a command substitution and becomes `ZRO_E_BADUSER`; the remaining helper
is never called by the gate; and the low-priority arm is reached only for `grep` and `gzip`, which
is measured rather than read — with `nice` and `ionice` both absent, both fetches still return
cleanly. The evidence document holds the runs.

So converting these two is a substitution, exactly as `lib/logview.sh` was in ADR-0012, and the log
line a gate refusal writes was never at stake. **The path is real in the suite and only there:** the
runner sources the entry point without the preflight, which is why a case can drive it and why the
passthrough suite gains one that says so.

## Two codes, not one

`ZRO_E_NO_QUEUE` and `ZRO_E_NO_STATUS`, in the environment band beside the two codes that already
answer this shape of question. `ZRO_E_NO_LOG` and `ZRO_E_NO_BLOB` were deliberately not folded into
each other, and `lib/core.sh` gives the reason on the second one: *the two name different files with
different repairs.* It transfers without change. A `postqueue` that failed sends an operator to
Postfix; a `zmcontrol status` that failed sends them to the Zimbra control plane and the directory.
One shared code would be true about neither, which is the disease being treated rather than a
smaller dose of it.

**`ZRO_E_NO_SERVICE` was the obvious name and is rejected.** On that screen *no service* is the most
alarming reading available, and `zro_svc_card` already carries a comment refusing to invent it — a
row of zeroes *"would be the most alarming screen in the tool, invented"*. The thing that could not
be read is the **status**; the services themselves are exactly what this program has learned
nothing about. The code name may not make the claim the card refuses to make.

## Where a screen for a code lives

The rule the tree was already following without stating it: **the call site handles what needs local
knowledge, and the shared reporter handles the rest.** The queue screen answers `ZRO_E_PERM` and
`ZRO_E_NOCAP` itself because it has to ask the capability module which one to draw; both screens
answer `ZRO_E_TIMEOUT` themselves because that code is shared across every module and each has
different words for it. Neither new code needs anything the call site knows, so both get an arm in
`zro_report_error`, beside every other code's screen, where the next reader will look.

## What does not change

**Neither module moves to `lib/settle.sh`.** ADR-0010 gave two reasons for leaving them out, and
only the first was the sink. The second stands untouched: the capture, the classification and the
sink are written inline, `lib/queue.sh` records a host refusal as a capability while it is in there,
and it needs what the command said for its own log line before the scratch file is removed — which
is the step the settler owns. A failure reader is a mapping the settler can call; neither of these
is one. Recorded explicitly because a reader who finds one of ADR-0010's two reasons falsified will
otherwise discard both.

**`zro_exec_own_code` is asked before anything else looks at the status**, which is where ADR-0012
puts it in as many words. In `lib/queue.sh` that moves the predicate above the host-refusal check.
Nothing observable changes — Postfix answers 69 for that refusal and no gate code is 69, so the two
cannot collide — and what is gained is that conformance can be seen rather than re-derived.

## The pin

A code with no screen is how this defect survived twenty-four cases written about these two screens.
`tests/test_service_queue_screen.sh` covers the timeout, the missing tool and the host's refusal; the
one code both modules fell back to is the one code it never asks about.

So the suite gains a pin, in the shape `tests/test_readonly_scan.sh` uses for the thirteen menus:
**every code this program defines has its own screen, or is declared by name as one that does not.**
The generic arm catches everything, so *has a screen* is trivially true and is the wrong question;
what the pin asks is whether the code has an arm of its own, and the search has to reach into the
modules — `ZRO_E_NO_BLOB` is answered in `lib/message.sh` rather than by the shared reporter.

The declared exceptions are `ZRO_E_OK` and `ZRO_E_CANCEL`, neither of which is a failure, and
`ZRO_E_BADUSER`, which has no screen anywhere and reaches an operator as a bare number today. That
last one is not a violation of this definition — it came out of measuring the pin's cost — and it
has [#102](https://github.com/Konsong/zimbra-readonly-tui/issues/102) rather than a decision here.

## What was considered and rejected

**Leaving the constant undefined and giving the two sinks a new code anyway.** Rejected: it fixes
two symptoms and leaves the term meaning five things, so the third module to need a sink arrives at
the same wall and invents a sixth meaning. The tickets exist because the definition is the part that
generalises.

**Splitting the constant across all of its sites in this change.** Rejected as scope. It reaches
around sixty sites and eight screens, and the two modules that started this would be the smallest
part of the diff.

**Giving both modules one shared code for an unrecognised failure, with each call site writing its
own screen.** Tempting, because both call sites already write their own timeout screen and so the
code need not carry the binary's name. Rejected because the code would then be true about nothing in
particular, and a code that is true about nothing in particular is what `ZRO_E_UNAVAILABLE` had
become.

**Adding the four unreachable gate sites to the log instead.** This was the answer while the premise
above still stood, and it narrowed when the premise fell: three of those sites stand behind a
precondition `zro_startup_check` establishes, so logging them would document a path nobody can take.
[#100](https://github.com/Konsong/zimbra-readonly-tui/issues/100) carries what is left of it —
whether the reachable arm gets a code of its own and whether the others are rewritten as the
precondition they stand behind, which is the shape
[ADR-0014](./0014-the-validator-establishes-its-own-precondition.md) describes.

**Folding the low-priority check into the startup preflight so the gate needs no fifth code at
all.** Rejected: reduced priority is decided per operation, so a host without `nice` still answers
every screen that is not a scan, and refusing the session would take away far more than it protects.

## Two corrections recorded in place

Both are wrong facts rather than superseded decisions, so each is corrected where a reader will meet
the claim — the rule ADR-0012 set when it corrected ADR-0010, for the reason it gave: *a reader who
meets the claim should meet the correction with it, not discover it two files later.*

ADR-0010's paragraph and ADR-0012's rejection note both say a gate refusal reaches these sinks. The
comment above `zro_exec_own_code` says it too, and additionally still names `lib/logview.sh` as one
of three hand-written lists that stand — ADR-0012 converted it, and after
[#77](https://github.com/Konsong/zimbra-readonly-tui/issues/77) and
[#78](https://github.com/Konsong/zimbra-readonly-tui/issues/78) there are none.
