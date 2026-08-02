# The existence gate, settled — and the load model that replaced the host-locality worry

- **Date:** 2026-08-02
- **Scope:** the oracle question [ADR-0001](../adr/0001-mailbox-existence-gate.md) left open, plus the
  production facts that reshaped which operations may exist at all.
- **Method:** Zimbra source read from `github.com/Zimbra/zm-mailbox` (`develop`), then confirmed by
  experiment on **TEST-C** (`posta.sirket.lcl`, Zimbra 9.0.0 GA FOSS, Ubuntu 20.04).

Two claims were load-bearing and neither had been anchored. One survived and one did not.

## 1. `zimbraLastLogonTimestamp` does NOT prove a mailbox exists — REFUTED

ADR-0001 built the first layer of its oracle on this sentence: *"an account cannot log in without one."*
It is the only claim in that document with no source behind it, and it is **false**.

**The stamp is written without touching a mailbox.** `Auth.java` — which handles the password, preauth,
recovery-code and 2FA paths — calls `prov.authAccount(...)`, and `LdapProvisioning.updateLastLogon` writes
the attribute from there. The file contains **no reference to `MailboxManager`, `getRequestedMailbox` or
`Mailbox`** at all.

**Login creates the mailbox only via session registration**
([`Session.java`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/session/Session.java)):

```java
public Session register() throws ServiceException {
    if (mIsRegistered) { return this; }
    if (isMailboxListener()) {
        MailboxStore mbox = mailbox = MailboxManager.getInstance().getMailboxByAccountId(mTargetAccountId);
```

`SoapSession.isMailboxListener()` returns `true`, and the single-argument
`getMailboxByAccountId` overload is `AUTOCREATE`.

**Three independent guards can skip that registration.** In `Auth.doResponse()`:

```java
boolean isCorrectHost = Provisioning.onLocalServer(acct);
if (isCorrectHost) {
    Session session = updateAuthenticatedAccount(zsc, at, context, true);
```

and in `DocumentHandler.getSession()`:

```java
if (zsc == null || stype == null || !zsc.isNotificationEnabled()) {
    return null;
}
...
if (stype == Session.Type.SOAP && !isLocal && !zsc.isSessionProxied()) {
    return null;
}
```

`isNotificationEnabled()` returns `mSessionEnabled`, which **defaults to `false`** and is only raised when a
`<context>` header is present and carries neither `<nonotify>` nor `<nosession>`
([`ZimbraSoapContext.java`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/soap/ZimbraSoapContext.java)):

```java
boolean suppress = ctxt.getOptionalElement(HeaderConstants.E_NO_NOTIFY) != null;
suppress |= ctxt.getOptionalElement(HeaderConstants.E_NO_SESSION) != null;
if (!suppress) { ... mSessionEnabled = true; }
```

**So a bare `AuthRequest` — no context header, or one carrying `<nosession/>` — authenticates the account,
stamps `zimbraLastLogonTimestamp`, and creates no mailbox.** That is what a credential-checking script, a
monitoring probe, a directory-sync validator or a single `curl` does.

The correlation is what makes it dangerous rather than merely wrong: the accounts whose only authentication
was ever a script are precisely the provisioned-but-never-used population that has no mailbox — the same
population `zmprov gmi` was dangerous for.

Two further weaknesses, recorded although the refutation does not need them: `updateLastLogon` is throttled by
`zimbraLastLogonTimestampFrequency` and writes nothing at all when that is `0`; and the attribute is writable
by an administrator, so it is not tamper-evident either.

## 2. `zmprov gis` is a decisive, proxying, non-provisioning oracle — CONFIRMED

**From source.** `GetIndexStats` passes `DO_NOT_AUTOCREATE`:

```java
Mailbox mbox = MailboxManager.getInstance().getMailboxByAccount(account, false);
```

It extends `AdminDocumentHandler`, declares `TARGET_ACCOUNT_PATH`, overrides `getProxiedAccountPath()` and does
**not** override `proxyIfNecessary()` — so the request is proxied to the account's home server. ADR-0001's
worry that a non-proxying oracle would leave the gate one-sided on every multi-server deployment does not
apply.

**From experiment on TEST-C.** Four outcomes, captured verbatim:

| Condition | Exit | Output |
|---|---|---|
| Account exists, **no mailbox** | 2 | `ERROR: service.FAILURE (system failure: mailbox not found for account 344c2c64-…)` on stderr |
| Account exists, mailbox exists | 0 | `stats: maxDocs:0 numDeletedDocs:0` on stdout |
| Account does not exist | 2 | `ERROR: account.NO_SUCH_ACCOUNT (no such account: nobody-zro-test@sirket.lcl)` |
| Under `zmprov -l` | 2 | `ERROR: service.INVALID_REQUEST (invalid request: can only be used with SOAP)` |

The `mailbox` table held the same five rows with the same ids before and after, and `mailbox.log` gained **no**
`Creating mailbox with id` line. **`gis` does not provision.**

**It does not touch the index either.** Snapshotting the index directory of an unindexed mailbox
(`maxDocs:0`) with nanosecond mtimes, either side of a `gis` call:

```
BEFORE  d 4096 1785446983.4419405070 /opt/zimbra/index/0/9/index
        f   20 1785626898.7805347780 /opt/zimbra/index/0/9/index/0/segments.gen
        f   32 1785626898.7805347780 /opt/zimbra/index/0/9/index/0/segments_1
AFTER   (byte-identical: same sizes, same mtimes, same directory mtime)
```

**Bounded claim:** every mailbox on TEST-C already owns an index directory, created with the mailbox. Whether
`gis` would *create* an index directory that is absent was therefore not observable, and no state is known in
which a mailbox exists without one.

**Two consequences for the gate.** "No account" and "no mailbox" arrive as *different* messages, so the gate
can tell them apart and answer the operator precisely. And `gis` is **SOAP-only**, so the gate cannot answer
during a degraded read — which costs nothing, because `zmmailbox` is equally unusable then, but must be said
on screen rather than surfacing as a bare refusal.

## 3. `zmprov gid` does not create the DEFAULT identity — CONFIRMED

`GetIdentities` (`AccountDocumentHandler`) only iterates `prov.getAllIdentities(account)`; there is no
`createIdentity` call. `getAllIdentities` synthesises a DEFAULT identity, and the question was whether that
synthesis persists.

It does not. Counting `(objectClass=zimbraIdentity)` entries in LDAP either side of `zmprov gid`, on an account
with a mailbox and on an account without one: **0 before, 0 after, both times.** Output is the familiar
`ga` shape:

```
# name DEFAULT
zimbraCreateTimestamp: 20260730212937.687Z
zimbraPrefFromAddress: zimscope-fixture-populated-20260731@sirket.lcl
zimbraPrefIdentityId: 60b41207-8f1d-470f-8128-d5717e8f29a0
zimbraPrefIdentityName: DEFAULT
…
```

`gid` also answers for an account with **no mailbox**, exit 0 — identities live in the directory, so this
whole area needs no existence gate.

`zmprov gsig` on an account with no signatures prints **nothing** and exits **0**, the same "no results is not
a failure" shape `gam` already has.

## 4. `zmprov -l` DOES expand COS-inherited values — closes an open question

[`observed §6.4`](./2026-07-29-observed-on-our-servers.md) listed this as unsettled because the sample
accounts carried identical values on the account and its COS. One account, three modes, same attribute list:

| Attribute | `ga` (SOAP) | `-l ga` (LDAP) | `ga -e` |
|---|---|---|---|
| `zimbraMailQuota: 0` | present | **present** | **absent** |
| `zimbraCOSId` | present | **present** | **absent** |
| `zimbraFeatureTwoFactorAuthAvailable: FALSE` | present | **present** | **absent** |

Absence under `-e` proves the value is not set on the entry; presence under `-l` proves LDAP mode expanded it
from the COS. The source's claim is confirmed, and the degraded-read path does not silently under-report
inherited quota.

It also validates `-e` as the **provenance discriminator**: it is the only way to answer *"is this set on the
account or inherited?"*, which is a question operators actually ask about quota.

## 5. Formats captured for fixtures

`zmprov ga` on a real account, SOAP and `-l` byte-identical:

```
# name zimscope-fixture-populated-20260731@sirket.lcl
displayName: ZimScope temporary populated fixture 2026-07-31
zimbraAccountStatus: active
zimbraCOSId: e00428a1-0c00-11d9-836a-000d93afea2a
zimbraFeatureTwoFactorAuthAvailable: FALSE
zimbraId: 60b41207-8f1d-470f-8128-d5717e8f29a0
zimbraMailDeliveryAddress: zimscope-fixture-populated-20260731@sirket.lcl
zimbraMailHost: posta.sirket.lcl
zimbraMailQuota: 0
zimbraPasswordModifiedTime: 20260730212937.687Z
```

- `zimbraPasswordModifiedTime` carries **fractional seconds**, like `zimbraLastLogonTimestamp`.
- Every unset attribute is simply **absent** — no placeholder line. Requesting twenty attributes and receiving
  ten is the normal case, and absence must never be read as a default.

`zmprov gd`:

```
# name sirket.lcl
zimbraDomainStatus: active
zimbraDomainType: local
```

## 6. Production facts that changed the design

Stated by the operator on 2026-08-02: production is **one Zimbra server** carrying **more than 100,000 users**.

**Single server removes the host-locality constraint entirely.** Every mailbox is homed locally, so
`zmmetadump` and direct blob reads serve every account. Message detail therefore needs no `zmsoap`, and no
general-purpose SOAP door is opened.

**100k accounts make server-wide reads the real hazard.** Nothing here can corrupt data — the guarantee holds
— but a full LDAP sweep on a box this size is a production event. `zmprov gqu`, `gaa -v` and unbounded `sa`
are ruled out; per-account quota usage comes from `gms` behind the gate instead. Mail logs are large enough
that a whole-file scan is disk I/O competing with the MTA, so log search is window-scoped, declares how many
files and bytes it will read before reading them, and runs niced.

This is what the **cost class** vocabulary in [`CONTEXT.md`](../../CONTEXT.md) exists to keep honest.

## What this leaves open

| Question | What would settle it |
|---|---|
| Does `gis` create an index directory that is absent? | Not observable on TEST-C — every mailbox has one. Needs a mailbox with its index directory removed, which is a deliberately damaged state. |
| Does `gis` need the `reindexMailbox` right for a delegated admin? | Ours runs as full admin. Only matters if the tool is ever run delegated. |
| `postqueue` behaviour on a real queue, and the `authorized_mailq_users` ACL | TEST-C has **no `zimbra-mta`** — no `postqueue`, no populated `mail.log`. Needs the MTA package installed there first. |
