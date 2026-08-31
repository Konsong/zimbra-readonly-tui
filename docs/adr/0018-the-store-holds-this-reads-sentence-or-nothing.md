# The store holds this read's sentence or nothing, because at the oracle's seam it is read by the gate and not by an operator

- **Status:** accepted
- **Date:** 2026-08-31
- **Affects:** `lib/account.sh` gains the reason its two `zro_set_error` calls are unguarded and keeps
  them; `CONTEXT.md` gains **the oracle's sentence**; `tests/test_mailbox_gate.sh` gains four cases —
  three behavioural and one static; issue
  [#85](https://github.com/Konsong/zimbra-readonly-tui/issues/85) closes with `zro_prov_read`
  unchanged, and the disagreement it found at `zro_settle` opens as a ticket of its own
- **Evidence:** the call-site census below, read against the tree at `8c13ad1`
- **Follows:** [ADR-0003](./0003-gis-is-the-existence-oracle.md), which decided WHO the oracle is, and
  [ADR-0012](./0012-no-reader-ends-with-the-status-it-was-handed.md), which left this seam alone
  deliberately and is what opened the question

Issue #85 reports that `zro_prov_read` ends every failed read with `zro_set_error "$first_msg"`
whether or not there is a message, where `zro_settle` gates the same write on a non-empty one and
says why. It asks whether the sentence already in the store should survive a gate refusal at this
seam, and it frames the cost as an operator's: *"the screen for that code then has no detail to
print."*

**The framing is wrong, and the answer is the opposite of the one it leans towards.** At this seam
the first thing to read the store is not a screen. It is the gate.

## The store has two readers, and only one of them is an operator

```sh
zro_prov_read "$ZRO_E_NO_ACCOUNT" gis "$acct" >/dev/null || rc=$?
...
if verdict=$(zro_mbox_classify "$(zro_last_error)"); then
```

`zmprov gis` is the existence oracle (ADR-0003), so `zro_mbox_verdict` runs directly on top of
`zro_prov_read` — and it reaches its verdict by classifying **the store's text**. It has to: both
absences exit 2, which is the whole reason `zro_mbox_classify` reads a message rather than a status.
The store is therefore the channel the oracle's answer travels down, from the read to the word
`exists` / `nomailbox` / `noaccount`.

`zro_mbox_classify` is a substring match. It does not know which read wrote what it is given.

## What the guard would have cost

Three of the four refusals happen before anything is executed, so no sentence in the store can be
about this account — which is the premise `zro_settle`'s comment starts from. (`ZRO_E_TIMEOUT` is the
exception worth stating: there the command DID run and was killed, so it may or may not have spoken
first. That widens the argument below rather than narrowing it.) The conclusion drawn there does not transfer, because at
this seam the sentence that would survive is not the oracle's. **It is an earlier operation's**, and
nothing clears the store between the two: every one of the nine `zro_clear_error` call sites in the
tree is on a success path, so a failure sentence stands until something overwrites it.

The reachable failure:

1. An operator asks about `yok@example.com`. The `ga` read fails and the store holds
   `ERROR: account.NO_SUCH_ACCOUNT (no such account: yok@example.com)`.
2. They open a mailbox or search screen for `ahmet.yilmaz@example.com`, which is not yet proven.
3. `zro_prov_read gis` is refused by the exec gate, on one of the two refusals that say nothing on
   the captured stream — the wrong user, or the read timing out.
4. With the guard, the store is untouched. `zro_mbox_classify` matches `no such account` and answers
   `noaccount`, **with status 0**.
5. The screen says *"Boyle bir hesap yok."* about an account that exists.

`zro_mbox_verdict`'s own comment forbids precisely this: *"A gate that answered 'no mailbox' whenever
it failed would put this tool's most consequential sentence behind a stopped service — and that
sentence is what stops an operator looking further."* The guard would have reintroduced it by a
different door — not from a status this time, but from a stale string.

## Which refusals this is actually about

The premise both this seam and `zro_settle` were reasoned from is that *a read the gate refused never
ran, so the file is empty*. **Measured, that is true of half of them.** The caller captures the gate's
stderr, and the gate logs some of its refusals onto it:

| Refusal | Code | What the captured stream holds |
| --- | --- | --- |
| `ZRO_E_DENIED` | 90 | `denied by allowlist: zmprov gis …` |
| `ZRO_E_NOCAP` | 92 | `not available on this host: /nonexistent/zmprov` |
| `ZRO_E_BADUSER` | 91 | nothing |
| `ZRO_E_TIMEOUT` | 22 | nothing |

For the first two a guarded write fires anyway and overwrites; the rule is never tested. For the last
two the guard skips, and an earlier operation's sentence is what `zro_mbox_classify` reads.

This is the argument for writing rather than guarding, and it is stronger than the one about which
reader is downstream: **nothing at that line can see which kind arrived.** A guard there is correct
for two of the four codes and silently wrong for the other two, and no local evidence distinguishes
them. The unconditional write is what makes the rule hold uniformly without the caller having to
know.

It is also what the first draft of this decision's test got wrong. A behavioural case built on
`ZRO_E_NOCAP` passes with the guard in place, because the gate's log line overwrites the seeded
sentence — a case that looks like it holds the rule and holds nothing. The two cases that survive are
built on the silent codes, and the reason is written beside them so the next reader does not swap one
back.

## One rule, and it covers both writes

The two `zro_set_error` calls in `zro_prov_read` look like separate concerns and are two halves of
one mechanism:

- **The write after the mapping** is the oracle's data path. It puts `no such account` where
  `zro_mbox_classify` reads it. Guard it and the gate can no longer tell an absent mailbox from an
  absent account at all.
- **The write in the gate-refusal arm** is what keeps that path clean. It writes the empty message,
  and writing nothing is the point.

Stated once: **the store holds this read's sentence, or nothing.** Never a previous read's.

The LDAP retry cannot reach the oracle and so does not enter the rule: `gis` is in `ZRO_PROV_READS`
and deliberately absent from `ZRO_LDAP_READS`, which is the same fact `zro_mbox_verdict` states as
*"the oracle speaks SOAP and nothing else."*

## What was considered and rejected

**Make `zro_prov_read` match `zro_settle`.** The issue's own proposal, and the reason this ADR
exists: it is a one-line change that reads as a consistency fix and silently converts a refusal into
a false absence. Rejected on the failure above.

**Leave it, and say only that no screen shows the sentence.** The issue offers this as the likely
outcome — *"If nothing does, the answer is to leave it and say so here."* Rejected because it is
right by accident. It closes the ticket with a reason that a later reader can check, find false — a
screen **does** read the store, at `zro_msg_unreadable_text` — and reopen. The durable reason is that
something reads it that is not a screen at all.

**Make `zro_settle` match `zro_prov_read`.** Tempting, and it may yet be right: at settle's seams the
guard either preserves nothing or preserves a stale sentence, because every caller in `lib/search.sh`
and `lib/store.sh` runs `zro_mbox_require` immediately before — which returns early on failure, and
on success has either cleared the store or hit the proof cache and left whatever was there —  while
`zro_msg_dump_fetch` has no gate in front of it at all. **Not decided here.** That is seven call
sites and a rewrite of a paragraph ADR-0012 wrote one merge ago; it gets its own ticket and its own
evidence rather than riding out on this one. What is decided here is only that `zro_prov_read` is not
the seam to change.

## The census that corrects the ticket

#85 says the tree is *"two-to-one against this seam"*, counting `zro_settle` and `zro_msg_head_fetch`
against `zro_prov_read`. It is **six to three**:

| Guarded on a non-empty message | Unguarded |
| --- | --- |
| `logsearch.sh:622`, `logview.sh:194`, `message.sh:516`, `queue.sh:249`, `service.sh:148`, `settle.sh:99` | both writes in `zro_prov_read`, and `delivery.sh:371` |

Only two `zro_set_error` calls are outside the question — the ones that append
`Okunamayan log dosyalari` — because those build a message that cannot be empty.

**`delivery.sh:371` IS in it, and an earlier draft of this ADR put it with those two.** It reads
`said=$(head -c … -- "$err")`, appends the skipped-file list only when there is one, and then writes
unconditionally — so when the tracer said nothing and nothing was skipped, it writes an empty message
exactly as `zro_prov_read` does. Whether that is right there is a question about the delivery trace's
own screen and is not decided here; what it changes for this decision is only the count.

The corrected count makes `zro_prov_read` less lonely than the first draft claimed, and that is worth
saying plainly: **a majority was never the argument.** Six sites guard because their store is read by
an operator. This one does not because its store is read by the gate. If the census had come out the
other way the decision would be the same, which is the test of whether a count was ever evidence.

The line numbers above are the six guarded sites, which this change does not move. The two in
`zro_prov_read` are named by function rather than by line because this same change adds comments above
them and would have invalidated the numbers it shipped with.

## What holds this

`tests/test_mailbox_gate.sh` carries it, and not `tests/test_settle.sh`, because the rule's whole
justification is the oracle, and a rule kept away from its reason becomes a prohibition nobody can
weigh.

Six cases. **One holds the positive half** — a real read, a real answer, asserting that the oracle's
sentence replaces what an earlier read left and that the verdict is `noaccount`. **Two hold the
negative half**, which is the one this ticket is about: each seeds a stale sentence the classifier
would recognise, drives a real refusal, and asserts the gate's own code came out rather than a
verdict. **One** asserts that a refusal proves nothing about the mailbox either way. **Two are
static**: one finds the function's text, one holds both of its writes unguarded.

The static pair is what answers this ticket. The behavioural cases catch a wrong **answer**; only the
static ones catch the wrong **fix** — and the wrong fix is what was proposed, in one line, by a reader
who had the code in front of them.

**The two negative cases are built on `ZRO_E_BADUSER` and `ZRO_E_TIMEOUT`, and that is not
incidental.** A case built on `ZRO_E_NOCAP` passes with the guard in place, because the gate's own log
line overwrites the seeded sentence and the rule is never reached. The first draft of these tests had
one, and it was green against a tree carrying the very defect it was written to catch.
