# A capability predicate that probes runs in its caller's shell, and only one that probes nothing may be a substitution

- **Status:** accepted
- **Date:** 2026-08-29
- **Affects:** `lib/capability.sh` — `zro_cap_queue_available` becomes a bare `||` chain and its cache starts
  working, `zro_cap_queue_reason` loses a claim that stops being true, and `zro_cap_trace_reason` gains the
  ordering rule it has always depended on; `tests/test_capability.sh` gains the queue's setup and four cases,
  two of which were red; `CONTEXT.md` sharpens **Probe**; `zimbra-ro-tui.sh` keeps the block at `:3040` and
  stops being the only place this rule is written down
- **Evidence:** [§4 of the 2026-08-19 architecture review](../research/2026-08-19-architecture-review.md),
  whose measurement stands and whose recommendation this rejects, and the absence of the word `queue` from
  `tests/test_capability.sh` before this
- **Follows:** [ADR-0002](./0002-delivery-tracing-and-three-binary-roots.md), which put the trace's two probes
  in this module, and issue [#87](https://github.com/Konsong/zimbra-readonly-tui/issues/87)

`zro_cap_queue_available` was written `[ "$(zro_cap_queue_reason)" = ok ]`. The probe behind it fills
`ZRO_CAP_QUEUE_BIN_CACHE` **inside the command substitution**, where the assignment dies with the subshell.
Every caller reached the probe through one, so the cache was empty on every path this program has and
`zro_cap_reset` cleared a variable that was always empty.

This module already records having fixed this once, for the version cache, and `zimbra-ro-tui.sh:3040`
records it a second time for `ZRO_MENU_REASON`: an assignment made inside a substitution dies with the
subshell. `zro_cap_trace_available` is a bare `||` chain specifically to avoid it. The fix landed on the
tracer and not on the queue, and nothing in the tree said why the shapes differed — so there was nothing for
the queue to be inconsistent **with**.

## What the review got right, and the inference this rejects

§4 measured it: on a host without `zimbra-mta`, three warn lines after three calls against one for the
tracer, and **five after five main-menu redraws**. That measurement stands and is the reason this ADR exists.

Its recommendation does not follow. §4 proposes deleting the cache and its reset line, on the grounds that
deleting them changes nothing. The deletion test is true. What it proves is that the variable is inert, and
the argument then treats inert as harmless. The measured cost is precisely the thing that does not change
under deletion: the operator on that host keeps meeting the same warning once per return to the main menu,
all session, and the written promise in `CONTEXT.md` that a capability is observed once per session becomes
quietly false for this one.

The probe really is nearly free — `zro_cap_op_available postqueue -p` is an allowlist match plus a path
resolution and `[ -x ]`, with no external process, unlike the version probe it sits beside, which is a JVM
start. That is what makes §4 read as low-stakes, and it is the inference this rejects. **What is remembered
is the answer, not the price of getting it.** A probe asked twice in one session is a defect at whatever
price, because the thing an operator meets is the warning and not the clock.

## The decision

**A capability predicate that reaches a probe runs in its caller's shell.** In practice that means a bare
`||` chain over the probes, never a test against a substituted reason:

```sh
zro_cap_queue_available() {
  zro_cap_queue_bin || return 1
  zro_cap_queue_denied && return 1
  return 0
}
```

The cache and its line in `zro_cap_reset` **stay**. They were never wrong; nothing had ever run them.

**A predicate that probes nothing may be a substitution, and that is what the shape now says.**
`zro_cap_search_available` keeps its substituted form, because its reason function reads two variables the
gate reads anyway and has no cache to lose. After this ADR the two shapes in this module are not an
inconsistency but a statement: a substitution means no probe happens here.

**A reason function is a printer, so its caller is always a substitution, and it reads the cache by
INHERITANCE.** `zimbra-ro-tui.sh:2460` runs the predicate in the caller's shell and only then draws the
screen at `:2400`, whose `$(zro_cap_queue_reason)` inherits a cache the parent already filled. The tracer has
the same arrangement at `:1578` and `:1504`. That ordering is what the whole thing rests on and it was
written down nowhere; it is now written above both reason functions.

**It is load-bearing for the tracer in a way it never was for the queue.** `zro_cap_probe_log` spawns `stat`
and `groups`, and `zro_cap_trace_log_reason` primes the cache with `zro_cap_trace_log || :` — which dies in
the subshell too if the predicate did not run first. The queue's version of this costs a log line; the
tracer's costs processes.

## What was considered and rejected

**Deleting the cache and the reset line, as §4 recommends.** Rejected above: it closes the dead variable and
leaves the measured cost, which is the only thing an operator can see.

**The loader, following `zro_cap_version_load`.** A `zro_cap_queue_load` called in the caller's shell before
the printer, leaving `zro_cap_queue_available` derived from `zro_cap_queue_reason` and the ranking in one
place. Rejected: it buys the single ranking site back with a calling discipline every future caller can
forget exactly once, and the failure is silent — a forgotten load reads as a working program that re-probes.
The version cache pays that price because it has to: the version is *displayed*, so its caller is a
substitution no matter what shape the predicate has. A yes-or-no has no such obligation.

**A file, following `ZRO_CAP_QUEUE_DENIED_FILE`.** Rejected: that file exists because the fact it holds is
learned inside a screen that itself runs in a subshell, so no variable in any shell could hold it. The
`nobin` fact is learned by the predicate the menu already calls in its own shell. Opening a file per session
to remember a `[ -x ]` is a mechanism looking for its problem.

**Making all three predicates substitutions, for uniformity.** Rejected: it is the current defect generalised,
and it destroys the only signal that tells a reader which of these functions touches the host.

## The price this accepts

`zro_cap_queue_available` now restates *unavailable = nobin OR denied*, which `zro_cap_queue_reason` is
documented as owning. A third reason added to the reason function and not to the predicate would leave the
menu entry unmarked while the screen behind it named the cause — the exact pairing the ranking was
centralised to prevent.

**That drift is held by a test rather than by the structure**, deliberately, and the test is named in the
comment above the ranking so a reader meets it there: `tests/test_capability.sh` asserts the two agree across
`ok`, `nobin` and `denied`. The comment's claim narrows accordingly — `zro_cap_queue_reason` is the one place
the two are ranked **into a word**, and the predicate ranks them into a yes-or-no.

## Consequences

`tests/test_capability.sh` gains `ZRO_POSTFIX_SBIN` and four cases. Two were red before they were green: the
queue predicate asked twice, and the warn written three times for three calls.

**Two of the four are written on the predicate rather than on the probe, and that is the finding rather than
a preference.** The mirror of the tracer's existing case — reset, then `zro_cap_queue_bin` twice with the
root pointed at nothing — **passes against the defect**, because the probe called directly fills its cache
under either shape. The bug only exists where the probe is *reached*. A test written by symmetry would have
been green all along, which is the second half of why this survived: the word `queue` did not appear in that
file at all, and the case that did exist for the tracer pinned `zro_cap_trace_bin` and never
`zro_cap_trace_available`. That gap is closed here too, in the same file, for a predicate this ADR does not
otherwise change.

The warn count is asserted separately from the state, because they are different claims: a cache that filled
while the warning stayed outside it would satisfy the state case and none of the cost §4 measured.
