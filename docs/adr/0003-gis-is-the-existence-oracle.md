# `zmprov gis` is the existence oracle, and last-logon is not evidence

- **Status:** accepted
- **Date:** 2026-08-02
- **Amends:** [ADR-0001](./0001-mailbox-existence-gate.md) — supersedes its layered oracle
- **Evidence:** [2026-08-02 research](../research/2026-08-02-existence-gate-settled.md)
- **Affects:** M2, M3, M4, M8

ADR-0001 designed a layered oracle: `zimbraLastLogonTimestamp` being set would prove a mailbox exists at no
extra cost, with `zmprov gis` as the fallback. Both halves have now been read from source and run against a
real server. **The cheap layer is wrong and the fallback is better than we thought.** The layering is removed.

## The decision

**`zmprov gis` is the only existence oracle.** It is decisive — it proves existence and proves absence — it
proxies to the account's home server, it does not provision, and it does not write the index. Source and
experiment agree; both are recorded in the research file.

**`zimbraLastLogonTimestamp` is not evidence of anything and is never consulted by the gate.** A SOAP
`AuthRequest` sent with no `<context>` header, or with `<nosession/>`, stamps the attribute and creates no
mailbox: `Auth.java` never touches `MailboxManager`, and the session registration that would have created the
mailbox is skipped by any of three guards. The population this gets wrong is exactly the population the gate
exists to protect — accounts a script has authenticated but a human has never used.

The attribute stays on the account card as an operational fact an administrator wants to see. It carries no
weight in a safety decision, and the card is not allowed to phrase it as one.

**The gate distinguishes three answers, not two.** `gis` reports a missing account and a missing mailbox with
different messages, so *"there is no such account"*, *"the account has no mailbox"* and *"the mailbox is
there"* are three outcomes with three screens. Classification is on message text, as everywhere else in this
tool, because all three failures exit `2`.

**The gate cannot answer during a degraded read, and says so.** `gis` is SOAP-only —
`invalid request: can only be used with SOAP`. When mailboxd is unreachable the gate refuses, which costs
nothing real because `zmmailbox` is equally unusable then. What it must not do is surface as a bare refusal:
the screen names the cause, the way the delivery tracer's unavailability screens already do.

**Verdicts still cache one way.** A proof of existence is held for the session; an absence verdict is never
cached, because the next delivered message falsifies it.

## Considered options

**Keep the layering, with last-logon first — rejected.** It was chosen to save an invocation per account, and
the saving is real: the account card reads the attribute anyway. It is rejected because a false positive here
is not a degraded answer, it is the guarantee breaking — the tool would open `zmmailbox` on an account with no
mailbox and create one. A safety layer that is cheap and sometimes wrong is worse than no layer.

**Use last-logon only to *skip* the `gis` call when it is set — rejected, same reason.** This is the same claim
wearing a different hat. Skipping the oracle on that evidence is trusting it.

**`zmmetadump` as the oracle — rejected, but it stays in the design elsewhere.** It is the best-evidenced
read-only command in the whole survey and it works with mailboxd stopped. It reads the *local* MySQL only,
which on a single-server deployment is no limitation at all — but the gate should not be the thing that
assumes the deployment never grows a second server. It remains the right tool for message detail, where the
same locality is a stated precondition rather than a hidden one.

## Consequences

**M2, M3, M4 and M8 are unblocked.** The condition ADR-0001 set — that the `gis` claim reach the depth of §A.3
and §A.5 before shipping — is met: the call site is cited, the no-mailbox case was run against a real account
with the `mailbox` table checked either side, and the index directory was snapshotted with nanosecond mtimes.

**The gate costs one invocation, roughly two seconds, per account per session.** Cached after the first proof.
Against a single-server production of 100k accounts this is cost class 2 — a per-account read, not a sweep —
and is the cheapest part of any mailbox screen.

**`zmprov gis` enters the allowlist** together with its `-l` sibling being deliberately *absent*: LDAP mode
cannot answer, so an entry for it would approve a call that can only fail.

**One claim remains bounded rather than closed.** Whether `gis` would create an index directory that is absent
was not observable — every mailbox on the test server has one, created with the mailbox. No known state
produces a mailbox without an index directory, so this is recorded rather than defended against.

**ADR-0001 is not withdrawn.** Its architecture stands: the guarantee admits no operator-confirmed exception,
the D1/D2 split holds, enforcement is structural through a single function owning the `zmmailbox` prefix, and
refusal is an answer rather than an error. Only the oracle changes.
