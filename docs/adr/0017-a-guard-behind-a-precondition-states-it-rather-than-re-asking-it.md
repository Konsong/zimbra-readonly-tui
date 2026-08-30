# A guard behind a precondition states it rather than re-asking it, and two guards are kept because their absence is a silent success

- **Status:** accepted
- **Date:** 2026-08-30
- **Affects:** `lib/core.sh` gains `ZRO_E_NO_LOW_PRIORITY` and `ZRO_E_NO_SYSTEM_TOOL` and its
  `ZRO_E_NO_SCRATCH` comment loses a deferral to a closed ticket; `lib/exec.sh` loses three guards
  and keeps one; `lib/window.sh`, `lib/core.sh` and `lib/inventory.sh` lose or re-answer the clock's
  and `stat`'s; `lib/delivery.sh`, `lib/logsearch.sh` and `zimbra-ro-tui.sh` stop restating a
  constant at eight call sites; `zro_startup_check` reorders so its own missing-binaries message can
  print, and `zro_report_error` gains two arms; `tests/test_readonly_scan.sh` gains two codes with
  arms and rewrites one declared exception's reason; `CONTEXT.md` gains **no system tool** and **no
  low priority** and corrects **Unavailable**; issues
  [#100](https://github.com/Konsong/zimbra-readonly-tui/issues/100),
  [#101](https://github.com/Konsong/zimbra-readonly-tui/issues/101) and
  [#102](https://github.com/Konsong/zimbra-readonly-tui/issues/102) close
- **Evidence:** the site census in
  [#100](https://github.com/Konsong/zimbra-readonly-tui/issues/100),
  [#101](https://github.com/Konsong/zimbra-readonly-tui/issues/101) and
  [#102](https://github.com/Konsong/zimbra-readonly-tui/issues/102), re-verified against the tree at
  `10d6fce`
- **Follows:** [ADR-0016](./0016-unavailable-names-a-service-that-did-not-answer.md), which bound the
  term and opened these three tickets, and
  [ADR-0014](./0014-the-validator-establishes-its-own-precondition.md), whose shape this applies to
  a second kind of precondition

ADR-0016 bound `ZRO_E_UNAVAILABLE` to one meaning and left three tickets carrying the sites that
still borrow it for something else. Read together rather than one at a time, those sites do not
split three ways along the lines the tickets draw. They split **once**, on a question neither ticket
asks: *was the thing that failed ever actually asked?*

## The census

Fifteen sites, excluding the six in `zro_startup_check` that ADR-0016 puts out of scope because
their code becomes a process exit status rather than a screen.

| Condition | Sites | Established by the preflight? |
| --- | --- | --- |
| `ZRO_ID_BIN` absent | `exec.sh:710`, `exec.sh:726` | yes — `id` |
| `ZRO_TIMEOUT_BIN` absent | `exec.sh:909` | yes — `timeout` |
| `ZRO_RUNUSER` absent, runuser mode | `exec.sh:943` | yes — `runuser` |
| `ZRO_DATE_BIN` absent | `core.sh:159`, `window.sh:78`, `window.sh:119` | yes — `date` |
| `ZRO_STAT_BIN` absent | `inventory.sh:359` | yes — `stat` |
| `nice` or `ionice` absent, low-priority operation | `exec.sh:931` | **no, deliberately** |
| the clock ran and answered something that is not a time | `core.sh:160,161`, `window.sh:80,81,99`, `delivery.sh:97` | **no, and cannot be** |

Eight stand behind a guarantee `zro_startup_check` already makes. Seven do not. That line, and not
the boundary between the gate and the system tools, is where the decisions differ — which is why
#100 and #101 have the same internal split and neither ticket can see it from where it stands.

## A guard behind a precondition states it

**The rule: where `zro_startup_check` establishes a binary, the code downstream says so in a comment
and does not test it again.**

This is the shape ADR-0014 already set. That ADR did not delete `zro_validate_msgid`'s precondition;
it made the validator **state** it — *"a header's angle brackets come off before this function sees
it"* — and left the establishing to the module that could establish it. Whichever module holds up
the precondition owns half the contract, and the half it owns is not re-asked by the other.

The objection is the suite: the runner sources the entry point under `ZRO_SOURCED_ONLY`, so the
preflight never runs and a case can still drive these lines. It does not survive. A test that skips
the preflight is driving a path production cannot reach, and the answer is for that case to
establish the precondition itself — which is what every one of them already does, by setting
`ZRO_DATE_BIN` and its neighbours at the mock. Production code carrying a guard on behalf of a test
is the tail wagging the dog, and the guard it carries is the one telling the operator the wrong
thing.

**A rule decided per site is not a rule.** The alternative considered was to keep each guard where
the evidence happened to favour it, and it is rejected for the reason the term itself was bound: the
tenth site arrives with nothing to consult and the argument is had again.

## Two guards are kept, and both for the same reason

An exception is not "the evidence favoured it here". It is a condition the rule's own justification
does not cover: **the rule assumes that deleting a guard lets a failure propagate, and at two sites
it does not — it produces a silent success instead.**

**`exec.sh:710`, `zro_current_user`.** This guard is not merely behind the preflight; it *is* how the
preflight detects a missing `id`. `zro_startup_check:72` calls it before reaching its own list of
required binaries, so deleting the guard would break the check that establishes the precondition the
rule leans on.

It is kept **and corrected**, because it is also wrong today. Neither `zro_current_user` nor line 72
logs anything, so a host without `id` gets a bare code 21 and no account of it at all — and
`zro_startup_check:87`, which would have named `id` in the missing-binaries message, is unreachable
behind the earlier return. The message an operator needs exists and cannot print.

**`inventory.sh:359`, `zro_inv_discover`.** Deleting this one does not propagate a failure either.
`zro_inv_mtime` prints nothing when `stat` cannot run, every candidate is then skipped by the
`''|*[!0-9]*` arm, and the loop ends on `return 0` — **an empty inventory, reported as success.** The
comment already standing on the guard says exactly why that may not happen: *"Silence here would be
indistinguishable from an empty inventory."* For the delivery trace an empty inventory means there
was nothing to scan, which reads on the screen as a quiet day rather than as a host without `stat`.

The two exceptions share the shape and not the mechanism, and the shape is the part that generalises:
**a guard may be deleted when what follows it fails loudly, and is kept when what follows it succeeds
quietly.**

## Seven sites, two codes

```sh
ZRO_E_NO_LOW_PRIORITY=28
ZRO_E_NO_SYSTEM_TOOL=29
```

Both in the environment band, beside the five codes that already answer this shape of question, and
both named for **the thing that could not be had** rather than for the tool that could not supply
it — the discipline `ZRO_E_NO_QUEUE` follows in not being called `NO_POSTQUEUE`, and the one
ADR-0016 enforced when it refused `ZRO_E_NO_SERVICE` for making a claim its own card refuses to
make.

**`ZRO_E_NO_LOW_PRIORITY`** is `exec.sh:931`: the operation must run at reduced priority, this host
has no `nice` or `ionice`, and the gate refuses rather than running it at ordinary priority. What
could not be had is not the binary but the **promise** — that a whole-file read yields to the mail —
and ADR-0008 states it in those words. The name reuses the phrase already in the tree at
`ZRO_LOW_PRIORITY` and `zro_runs_low_priority` rather than inventing a synonym for it.

It may not be called a scan refusal. `ZRO_LOW_PRIORITY` holds `grep` **and** `gzip`, so ADR-0008's
compressed blob read is refused by this arm too, and a name mentioning scans would be false on that
path.

**`ZRO_E_NO_SYSTEM_TOOL`** is the clock's six sites and the one kept `stat` guard. One code and not
two, although the two conditions differ — a clock that answered nonsense is not a broken precondition
and an absent `stat` is — because **the repair is the same afternoon's work in the same place**, and
the repair is what a code has to be true about. ADR-0016 already drew this line and put both on the
same side of it: the comment on `ZRO_E_NO_SCRATCH` separates a scratch file, which sends an operator
to `TMPDIR`, from *"a clock or a formatter that answered nonsense"*, which sends them to *"the tool
itself, which is installed rather than provisioned"*.

That one code covers both an absent tool and a present one talking nonsense is not a stretch of `NO_`
but its established reading here: `ZRO_E_NO_BLOB` already means *"a file the store no longer has, **or**
one the account every command runs as cannot open."*

**Rejected for the first:** `ZRO_E_NO_NICE`, which names the tool and breaks the pattern;
`ZRO_E_NO_PRIORITY`, which reads as *no priority*; `ZRO_E_NO_YIELD`, which names the promise with a
word the tree does not use anywhere else. **Rejected for the second:** `ZRO_E_BAD_CLOCK`, too narrow
once `stat` is inside; `ZRO_E_NO_TOOL`, which collides with `ZRO_E_NOCAP` — the gate's binaries are
tools too.

## What was considered and rejected

**A defect code for the kept `stat` guard.** Reaching `inventory.sh:359` means a guarantee
`zro_startup_check` made no longer holds, which is the definition of the 90 band. Rejected because
the band's own words are *"a defect, not operator error"*, and a host without `stat` is neither: it
is a fact about the host, and the operator is the one who can act on it.

**Borrowing `ZRO_E_NO_LOG` for the kept `stat` guard.** Tempting, and closer than what is there
today: that screen already says the sentence the guard exists to protect — *"hicbir sey taranamadi.
Bu, kayit bulunamadi demek DEGILDIR."* Rejected because its second paragraph names the repair, and
the repair it names is file ownership and `zmfixperms`. An operator sent there for a missing `stat`
finds nothing wrong, which is the disease ADR-0016 treats, one command along.

## A caller ends on what the clock decided

Eight sites call a clock function and, on failure, **restate a constant of their own**:

```sh
from_h=$(zro_win_human "$ws") || return "$ZRO_E_UNAVAILABLE"
```

`delivery.sh:267,268,274,275`, `logsearch.sh:552,553` and `zimbra-ro-tui.sh:324,325`. All eight
become `|| return $?`, which is the idiom `zro_trace_stamp` already uses 177 lines above the first
of them.

This is not the passthrough ADR-0012 forbids. That rule is about a **gated read** ending on the
status `zro_exec` handed it — a number from a command. A clock function answers with a code this
program defines, so ending on it is ending on this program's own word.

What flattening costs is that the call site asserts something about a function it does not own —
*this can only fail one way* — and the assertion rots silently. It has already rotted once: all eight
name `ZRO_E_UNAVAILABLE` because that was true when they were written.

**The `ZRO_E_INPUT` hazard is recorded rather than fixed.** `zro_clock_fmt` also answers
`ZRO_E_INPUT` for a timestamp that is not one, and that code's arm in `zro_report_error` is written
about an **email address**. Propagated blindly, a broken clock could in principle draw
*"Bu islem icin secili adres gecerli bir e-posta adresi degil."* It cannot in production: `ws` and
`we` are digits validated in the window module before they get here, and `zimbra-ro-tui.sh:325`'s
`$now` passed `zro_win_now`'s own digit test one line above. That is the same shape as the eight
guards above — the path is in the code and the condition is not on the host — so it is handled the
same way, by saying so. **Narrowing that arm is not part of this change**, and an implementation that
widens it has done something this ADR did not ask for.

## What `ZRO_E_BADUSER` gets, which is a better reason

Nothing, and that is the decision. It stays on `tests/test_readonly_scan.sh`'s list of codes with no
arm of their own, with the placeholder reason — *"reaches an operator as a bare number today, and has
issue 102"*, which points at the ticket this ADR closes — replaced by the reason the census found:

```
ZRO_E_BADUSER:never reaches a screen — its one reachable site is
  zro_startup_check, which logs and whose code becomes a process exit
  status, the channel ADR-0016 puts out of scope
```

Its three sites are `exec.sh:738`, `exec.sh:907` and `zimbra-ro-tui.sh:75`. The last already logs
*"Bu arac yalnizca zimbra veya root ile calisir"* and returns into the exit-status channel. The gate
site is unreachable: `zro_startup_check` refuses any user that is neither `zimbra` nor `root`, and a
running process's real uid does not change — a property of the platform rather than of this host, so
unlike ADR-0016's premise it needs no run on TEST-C to settle.

**An arm was the tempting answer and is rejected.** It is four lines, and it would remove the last
asymmetry in the 90 band, where `ZRO_E_DENIED` and `ZRO_E_NOCAP` both have screens. But those two are
returned by `zro_exec` into module code that draws screens, and this one is not — so the arm would be
**a screen no operator can reach**. The pin exists to make screenlessness deliberate and stated, not
to make every code carry an arm; ADR-0016 says so when it introduces the list — *"this is the list a
maintainer has to add a fourth line to, and the equality below is what makes them stop and write the
reason down."* Writing an unreachable screen to empty the list defeats the mechanism instead of using
it.

## Both new codes get an arm, and neither needs the call site

ADR-0016's rule transfers without argument: *the call site handles what needs local knowledge, and
the shared reporter handles the rest.* Neither `ZRO_E_NO_LOW_PRIORITY` nor `ZRO_E_NO_SYSTEM_TOOL`
needs anything a call site knows — there is no capability to consult and no per-module wording, the
way `ZRO_E_TIMEOUT` has — so both get an arm in `zro_report_error`, which is also what the pin
requires of them.

Each arm names **where the repair is**, because that is the whole difference between it and a bare
number: the base tooling on this host for one, `nice` and `ionice` for the other. The low-priority
arm additionally says that **nothing ran** — the gate refuses rather than falling back to ordinary
priority, and an operator who reads it as "it ran, just slowly" has been told the opposite of what
happened.

## What this leaves behind

The comment on `ZRO_E_NO_SCRATCH` in `lib/core.sh` ends by deferring to this decision — *"IT DOES NOT
COVER THE SYSTEM TOOLS, which are the other condition that borrows the constant above and are issue
101's to decide"*. It is corrected in place rather than left pointing at a closed ticket, under
ADR-0012's rule that a reader should meet the correction with the claim.

After this, no site in the tree returns `ZRO_E_UNAVAILABLE` for anything but a Zimbra service that
did not answer, and the five jobs ADR-0016 found the constant doing are five constants.
