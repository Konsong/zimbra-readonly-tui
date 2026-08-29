# The validator establishes its own precondition, and half a delimiter is refused rather than repaired

- **Status:** accepted
- **Date:** 2026-08-29
- **Affects:** `zro_trace_msgid_bare` leaves `lib/delivery.sh` and becomes `zro_msgid_bare` in
  `lib/validate.sh`, beside the validator that states its result as a precondition; the mailbox-search screen
  at `zimbra-ro-tui.sh:942` loses a second implementation of the rule; `lib/logsearch.sh` loses a comment that
  named the wrong owner and `tests/test_logsearch.sh` loses a whole-module source; the seven cases move from
  `tests/test_delivery.sh` to `tests/test_validate.sh`; `tests/test_search_screen.sh` and
  `tests/test_readonly_scan.sh` gain the pins that were missing; `CONTEXT.md` gains **bare message-id**
- **Evidence:** [§2 of the 2026-08-19 architecture review](../research/2026-08-19-architecture-review.md),
  re-verified at `041d311`, and issue [#89](https://github.com/Konsong/zimbra-readonly-tui/issues/89)
- **Follows:** nothing; this is the first decision about where a *transformer* lives, as opposed to
  [ADR-0009](./0009-what-is-not-a-declared-table.md), which is about what a declaration is not

For a truncated paste — `<CAabc123@example.com`, the leading bracket kept and the trailing one lost — the
delivery trace and the log search **refused** the input and the mailbox search **accepted** it and searched
for `CAabc123@example.com`. One rule, two implementations, and they disagreed for eight months.

## What the rule is

`zro_msgid_bare` removes **one matching pair** of angle brackets from the two ends and nothing else.
`zro_validate_msgid` then refuses anything still wearing one.

Those two sentences are one contract, and the second cannot hold up its end alone. A validator answers a
**status**; taking the brackets off produces a **value**. So `zro_validate_msgid` opens by stating a
precondition — *"a header's angle brackets come off before this function sees it"* — that it has no way to
establish. Whichever module establishes it owns half of the validator's contract.

## Why `lib/validate.sh` and not `lib/delivery.sh`

The rule was in `lib/delivery.sh` because the delivery trace needed it first. §2 of the review proposed
leaving it there and having the screen call it, on the grounds that it moves *"into the module that already
owns it and already tests it."* That reasoning is circular: **present is not owner**, and the review's own
evidence says so.

- `zimbra-ro-tui.sh:176` already called it, so the screen file already carried that edge; `:942` was the sole
  deviation from it rather than a new dependency the fix would create.
- `zro_msgid_bare` was the **only** thing `lib/logsearch.sh` borrowed from `lib/delivery.sh`, and
  `tests/test_logsearch.sh` sourced the entire delivery module to reach six lines. That source is now gone.
- `lib/search.sh` is sourced at `zimbra-ro-tui.sh:42`, before `lib/delivery.sh` at `:50`, and
  `tests/test_search.sh` does not source delivery at all. While the rule lived there, `zro_search_term`
  could never reach it — the module with the most direct claim on the value was the one module locked out.

`lib/validate.sh` is sourced first, so every module can reach it, and it already holds transformers of exactly
this shape: `zro_regex_quote` and `zro_query_quote` each take an operator's string and produce the form
something downstream will accept. The objection that a validator module holds only predicates is false about
this file.

## Why half a pair is refused

Repairing is the tempting reading — a lone bracket is obviously a truncated paste, and refusing costs the
operator a round trip on a screen where they are already under pressure.

It is refused because **the damage is unbounded**. `<CAabc123@example.com` could be a message-id that lost its
closing bracket, or one that lost its closing bracket *and* part of its host. Nothing on the screen can tell
those apart. A value repaired here would be validated, stored, drawn back onto the criteria menu, sent to the
server, and reported on — and every one of those steps would be about a string the operator never typed. An
empty answer then reads as proof the message never arrived. Refusing puts the paste back in front of them
while they can still re-copy it, which is the same discipline the arrival-window and partial-scan banners
follow: say it where it can still be acted on.

## What was considered and rejected

- **Leave it in `lib/delivery.sh` and have the screen call it** — the review's proposal, four lines deleted
  and one added. Cheapest today. It entrenches the split contract, keeps `tests/test_logsearch.sh` sourcing a
  module for six lines, and permanently forecloses `zro_search_term` reaching the rule.
- **A new `lib/msgid.sh`** owning the pair. Honest about the seam and buys nothing the move to
  `lib/validate.sh` does not, at the cost of a file and another entry in the source order.
- **Fold the unwrapping into `zro_validate_msgid`.** It cannot: the function would have to return a status
  and a value, and the refusal of half a pair is precisely a judgement made *after* the unwrapping. Merging
  them would delete the rule rather than move it.
- **One `zro_msgid_accept` replacing the unwrap-then-validate pair at all three call sites.** The
  mailbox-search screen genuinely needs the unwrap **without** the validate, because validation there belongs
  to `zro_search_term`, the function that has to build a query term out of the value. A combined function
  would leave that site reaching for half of it — which is how the fifth copy gets written.
- **Unwrap inside `zro_search_term`,** so the screen does nothing at all. Wrong under every other option:
  `zimbra-ro-tui.sh:1036` stores the pre-term value and `zro_search_value_label` draws it back onto the
  criteria menu. An unwrapping that happened later would show one string and search another — the exact
  hazard this ADR is about.

## What holds it up now

A comment is what failed. `lib/logsearch.sh` warned in place that a second implementation *"is the kind of
pair that drifts"*, and the screen was written anyway. So the rule has a build behind it:
`tests/test_readonly_scan.sh` asserts that the bracket-stripping expansion appears **once** in the tree and
that the trace's old name appears nowhere, and `tests/test_search_screen.sh` drives the three cases through
the screen that drifted. The seven unit cases moved to `tests/test_validate.sh`, directly above the refusal
they explain, because either block read alone makes both look arbitrary.
