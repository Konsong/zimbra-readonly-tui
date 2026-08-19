# No reader ends with the status it was handed, and an overloaded code is asked as two questions

- **Status:** accepted
- **Date:** 2026-08-19
- **Affects:** `lib/delivery.sh` and `lib/account.sh` lose their fall-throughs and split one overloaded code
  each, `lib/logview.sh` asks the predicate instead of naming its five codes, `lib/logsearch.sh` loses a
  comment that cited a rationale this removes, `tests/test_gate_passthrough.sh` gains the rule as a static
  case beside the two #75 added, and CONTEXT.md's *Outcome reader* is defined by what actually separates the
  two roles
- **Evidence:** the errno table below, `tests/test_delivery.sh`, which asserted the leak as a feature, and
  `tests/test_readonly_scan.sh`, which had no rule of this kind at all
- **Follows:** [ADR-0010](./0010-the-gate-owns-the-predicate-and-one-settler-asks-it.md), which rejected the
  fall-through by name and left two of them standing, and #75, which gave those two a name of their own —
  `zro_prov_outcome_code` and `zro_trace_outcome_code` — one merge before this

ADR-0010 gave the gate a predicate and gave three modules a settler to ask it from. It also listed the
modules it was leaving alone, with a reason for each. That list is where this one starts: the reasons were
right about the SETTLER and were read as covering each module's own failure mapping too, and two of those
kept ending with `printf '%s' "$rc"` — the arm ADR-0010's own *What was considered and rejected* calls the
defect. Those two are `zro_prov_outcome_code` and `zro_trace_outcome_code`; they wore the settler's suffix
until #75, which is a separate story told at the end of this one.

Being unable to use the settler never required keeping the fall-through. `zro_msg_head_fetch` asks
`zro_exec_own_code` inline, with no settler at all, in a module ADR-0010 says had moved. The predicate costs
one line wherever a status is held.

## What the leak actually cost

`zmmsgtrace` is Perl, so `die` exits with `$!` and the status a failed trace carries is an **errno**. The
fall-through handed that number to the screen:

| errno | reaches the operator as | what the screen then says |
| --- | --- | --- |
| 11 `EAGAIN` | `ZRO_E_NO_ACCOUNT` | "Hesap bulunamadi" — no account was ever looked up |
| 12 `ENOMEM` | `ZRO_E_NO_MAILBOX` | "Mailbox bulunamadi" — this module opens no mailbox |
| 21 `EISDIR` | `ZRO_E_UNAVAILABLE` | the mailboxd/SOAP screen, for a tool that never talks to mailboxd |
| 22 `EINVAL` | `ZRO_E_TIMEOUT` | "zaman asimina ugradi", for a command that returned at once |
| 23 `ENFILE` | `ZRO_E_NO_LOG` | **nothing.** See below |
| anything else | itself | "Islem basarisiz (kod N)", a number this program does not define |

The last row is the one that matters, and it is not a screen problem. `ZRO_E_NO_LOG` was already carrying a
second meaning at the trace loop: `mapped != ZRO_E_NO_LOG` is how that loop decides **skip this file and keep
going** rather than **refuse the whole trace**. So a tracer that died with `ENFILE` was read as a file that
could not be opened, was disclosed with whatever line happened to be on its stderr, and the scan continued
and answered `ZRO_E_PARTIAL`. That is not a wrong screen. It is a wrong answer about whether a message was
delivered, produced by the screen that exists to answer exactly that.

`tests/test_delivery.sh` already knew the mechanism. Its comment on the neighbouring case reads *"Perl hands
back whatever errno was set, which can collide with the codes this program defines"*, and it picks `RC=13`
deliberately to prove the text wins over a colliding status. The very next case — `it "passes an
unrecognised failure status through unchanged"`, `RC=2 assert_status 2` — pinned the arm where nothing wins.

## The decision

**Every module that holds a status from `zro_exec` asks `zro_exec_own_code` before anything else looks at
it.** Inline where there is no settler, which is `lib/delivery.sh`, `lib/account.sh` and `lib/logview.sh`.
The settler exclusions in ADR-0010 stand and are unrelated: `lib/delivery.sh` still reuses one scratch file
across the window and still appends its disclosure after the bound, and `zro_prov_read` still consumes its
mapping before it returns.

**A code that also answers a second question at the call site is split, and the two questions are asked
separately.** This is the general shape, and both modules had it:

- `lib/delivery.sh` asked `ZRO_E_NO_LOG` to mean both *this file could not be opened* and *this is the answer
  the operator gets*. The per-file outcome becomes its own predicate over the captured stderr;
  `zro_trace_outcome_code` becomes a one-argument mapping like every other one, and `ZRO_E_NO_LOG` is
  free to be its sink.
- `lib/account.sh` asked `ZRO_E_UNAVAILABLE` to mean both *the service is unreachable* and *retry this read
  through LDAP*. The retry asks the text directly — `zro_zimbra_error_code` — instead of comparing the mapped
  code, and the reader's sink becomes `ZRO_E_UNAVAILABLE`, which is the right sentence for `zmprov`: that
  command really does reach mailboxd over SOAP, and the screen for that code says so.

**A gate code no longer reaches the LDAP retry.** Asking the predicate first means a host-level
`ZRO_E_UNAVAILABLE` — no `id`, no `timeout`, no `runuser` — returns instead of triggering a retry that would
fail on the same missing binary. One fewer command runs, and the code that reaches the operator is the same.

**The rule is held statically, in [`tests/test_settle.sh`](../../tests/test_settle.sh).** No mapping of a
failed command — `*_fail_code` or `*_outcome_code` alike — may end by returning the status it was handed.
It goes beside the two cases #75 put at the foot of that file rather than in
`tests/test_gate_passthrough.sh`, which was where this was first going to live: #75 established that file as
the home for claims about a reader's shape read off the source, and gave the reason this ADR would have had
to give anyway — `tests/test_readonly_scan.sh`'s subject is the read-only claim, and a mapping's shape is not
a safety property. One file answers for one question, and it is already answering this one.

## What was considered and rejected

**Leaving `lib/delivery.sh` alone because ADR-0010 excluded it.** The exclusion is real and still holds — for
the settler. It says nothing about the reader, and reading it as though it did is what let the fall-through
survive a change written specifically to remove fall-throughs.

**Sinking the delivery trace into `ZRO_E_UNAVAILABLE`, following `lib/store.sh` and `lib/search.sh`.**
Rejected: that code's screen opens with *"zmprov varsayilan olarak mailboxd servisine SOAP ile baglanir"*.
The tracer is a Perl script over syslog and reaches no service at all, so this would reproduce the exact
defect ADR-0010 was written about — naming a service the command never talks to — while claiming to fix it.
The precedent is a precedent about a sentence being true, not about a constant.

**Keeping the delivery discriminator and giving the sink some other code.** Rejected because it leaves the
overloading in place, and the overloading is the `ENFILE` bug. Any sink at all still has to be told apart
from the skip signal by a reader downstream, which is the same fragility one constant further along.

**Converting `lib/queue.sh`, `lib/service.sh` and `lib/logsearch.sh` in this change.** Rejected as scope, and
each now has a ticket — #77, #78 and #79. The queue and service lists name four of the five codes and use
the fifth AS the sink, so converting them changes which log line a gate refusal writes — a decision about
what the sink means.
`zro_logsearch_gate_code` is the inverse construction: it lists the READERS' statuses and treats everything
else as the gate's, so the predicate is not a drop-in for it and a status belonging to neither still leaves
as a gate code it never was. Folding it in is a redesign.

**Leaving them recorded in prose instead.** Rejected, and this is the correction that produced this ADR at
all. All three findings here came out of a paragraph headed *"The modules that keep their own lists are not
an oversight"*. Six months on, deliberately-left and forgotten read identically. Each open site now has a
ticket naming its own sink question — #77, #78, #79 — and the delivery tracer's one unverified string has
#80. The ADR says why each is open; the ticket says that it still is.

## Two corrections to ADR-0010

Recorded there, in place, because they are wrong facts rather than superseded decisions — a reader who meets
the claim should meet the correction with it, not discover it two files later.

**`lib/logview.sh` was grouped with `lib/queue.sh` and `lib/service.sh`, and was never in their position.**
Its list named all five, so no code the gate produces has ever reached its sink, and none can afterwards.
Replacing it with the predicate is a substitution with nothing an operator can see attached to it, and no
sink decision was ever in the way. What that paragraph got right is the half nobody acted on: the list
lacked a reason to stay complete.

**The paragraph excluding `lib/account.sh` and `lib/delivery.sh` was true of the settler and read as true of
more.** Both reasons still hold and neither module finishes through `lib/settle.sh`. What went unexamined is
that both mappings still ended with the rejected arm. #75 has since given them a name of their own; it did
not touch the arm.

ADR-0011's closing line inherits the first correction: `lib/logview.sh` is no longer one of the three modules
outside all of this.

## What an outcome reader is, once this lands

#75 landed one merge before this and is the reason the two modules here are no longer called failure readers.
It found that `zro_settle`'s name check cannot ask arity, that `zro_prov_fail_code` and `zro_trace_fail_code`
matched the shape while taking three arguments and two, and it separated the roles by name. That finding is
right and the rename stands.

**The property it defined the new term BY does not survive this change.** *Outcome reader* is written as a
mapping that *"may be holding one of the gate's own codes, because nothing has answered them yet"*, and
`lib/delivery.sh` gained a comment saying the same: *"the status it is handed can still be one of the gate's."*
After this ADR neither is true of either function. Both ask `zro_exec_own_code` before anything reads the
status, so neither ever holds a gate code — which was the defect, not the definition.

**What actually separates the two roles is the thing #75 discovered and then did not put in the term: whether
the settler can call it.** That is now literal and enforced in both directions —
[`tests/test_settle.sh`](../../tests/test_settle.sh) holds that the set of `*_fail_code` functions equals the
set of names handed to `zro_settle`. So the suffix has stopped meaning *maps a failure* and started meaning
*travels to the settler*, and the term beside it should say so:

> **Outcome reader**: a module's own mapping of a failed command that is NOT handed to the settler, because
> the settler cannot call it — it takes an argument the settler has no way to supply. There is one,
> `zro_prov_outcome_code`, which also takes the caller's missing code.

**And there is only one, because splitting the delivery trace dissolved the other.** This was drafted
expecting `zro_trace_outcome_code` to survive as a one-argument mapping that keeps the outcome name for the
seam's sake. Writing it showed otherwise: everything that function recognised was the one unopenable text,
and once that moved to `zro_trace_unopenable` what remained had a single arm and nothing to decide. A
function that returns a constant is not a mapping, so it is gone rather than kept for the symmetry. The
category #75 created for two members has one, and the property it was defined by — holding a gate code —
belonged to neither.

## Consequences

`tests/test_delivery.sh` loses the case that asserted the leak and gains two: an unrecognised status now
refuses the whole trace as `ZRO_E_NO_LOG`, and `RC=23` no longer disappears into the skipped-file banner. The
other errno rows above are not cased individually — that would test errno numbers rather than the behaviour
being protected, and the existing `RC=13` case already records that collisions happen.

`tests/test_gate_passthrough.sh` gains the static rule and a case for the retry that no longer runs. That
seam was previously held only for `90`, `91` and `92`; `21` had never been asserted there, which is why the
retry's dependence on it went unseen.

The text `'unable to open file'` becomes a declared constant, `ZRO_TRACE_TXT_UNOPENABLE`, following
`ZRO_STORE_TXT_NO_FOLDER` and `ZRO_SEARCH_TXT_NO_FOLDER`. The module's standing note that it comes from the
tool's source and not from a capture moves onto the declaration, where the ticket asking for a real capture
from the lab server (#80) can point at it. Nothing here narrows the tree's dependence on that string, and the
predicate does not make it load-bearing in any way it was not already: what changes is that missing it now
ends in a documented code instead of an errno.
