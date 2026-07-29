# Zimbra CLI Read-Only Reference

**Date:** 2026-07-29
**Scope:** `zmprov`, `zmmailbox`, `zmmetadump`, `zmmsgtrace`, `zmcontrol` — what is safe to run against a
production server, and what the output actually looks like.

## How to use this

This file exists because two production bugs shipped from *assumed* output formats. Every claim below is
anchored to a primary source — almost always the line of Java that does the printing or the writing — and the
load-bearing fragment is quoted inline. Where a question could not be settled from source it is marked
**UNKNOWN** and listed in the final section with the experiment that would settle it.

Rules for reading:

- **A quoted format string outranks a prose description**, including prose written here. If you are writing a
  parser, go to the cited line and read it.
- **Line numbers are for the `develop` branch** of `github.com/Zimbra/zm-mailbox` as cloned on 2026-07-29
  (`cd897c3`, "ZBUG-5535", 2026-06-24). They drift between releases. Where a site matters, per-version line
  numbers are given. The *code* was verified identical across 8.8.15.p47-v1, 9.0.0, 10.0.14, 10.1.18 and
  `develop` unless a difference is called out.
- **"Safe" here means "does not change server state."** It does not mean cheap, and it does not mean it cannot
  fail. Cost and failure modes are noted separately.
- Sources ranked: zm-mailbox / zm-core-utils source > official SOAP API reference > official wiki and admin
  guide. No blog or forum post is the basis for any claim in this document.

### The three questions §8 of the design spec left open

All three are now answered from source, and **all three answers are the unsafe one**:

| Design-spec question | Answer | Where |
|---|---|---|
| Does `zmmailbox -z -m <acct>` create a mailbox for an account that never logged in? | **Yes** | [A.1](#a1-does-zmmailbox--z--m-account-create-a-mailbox) |
| Does `zmmailbox gm <id>` clear the unread flag? | **Yes**, unconditionally, no flag disables it | [A.2](#a2-does-zmmailbox-gm-clear-the-unread-flag) |
| Does `zmprov gmi` on an account with no mailbox error, or provision one? | **It provisions one** | [A.3](#a3-does-zmprov-gmi-provision-a-mailbox) |

`zmprov gmi` is in the shipped M1 allowlist (design spec §5.2). See [A.3](#a3-does-zmprov-gmi-provision-a-mailbox)
for the safe replacement.

---

## Summary table

Legend — **Safe**: no server state change. **Unsafe**: writes. **Care**: read-only but with a caveat noted in
the linked section. `-l` column applies to `zmprov` only.

| Command | Verdict | Needs mailboxd | Works under `zmprov -l` | Notes |
|---|---|---|---|---|
| `zmprov ga <acct> [attrs]` | **Safe** | No (with `-l`) | **Yes** | Expands COS in *both* modes — see [C.2](#c2-does--l-expand-cos-inherited-values) |
| `zmprov ga -e <acct>` | **Safe** | No (with `-l`) | **Yes** | Only attrs set on the entry |
| `zmprov gmi <acct>` | **UNSAFE** | Yes | **No** — `can only be used with SOAP` | **Auto-creates the mailbox.** [A.3](#a3-does-zmprov-gmi-provision-a-mailbox) |
| `zmprov gqu <server>` | **Safe** | Yes | **No** — `can only be used with SOAP` | Safe bulk replacement for `gmi`. [A.3](#a3-does-zmprov-gmi-provision-a-mailbox) |
| `zmprov gam <acct>` | **Safe** | No (with `-l`) | **Yes** | Order unstable — sort client-side. [B.3](#b3-zmprov-gam-account) |
| `zmprov gc <cos>` | **Safe** | No (with `-l`) | **Yes** | No `-e` flag exists. [B.4](#b4-zmprov-gc-cos) |
| `zmprov gaa` | **Safe** | No | **LDAP only** — rejects under SOAP | `Via.ldap`; see [C.1](#c1-which-subcommands-work-in--l-mode) |
| `zmprov gsi <owner>` | **Safe** | Yes | **No** | SOAP-only |
| `zmprov gis <acct>` (getIndexStats) | **Safe** | Yes | **No** | No autocreate; needs the *reindex* admin right |
| `zmprov vi <acct>` (verifyIndex) | **Care** | Yes | **No** | Lucene `CheckIndex`, never the fix path. [A.4](#a4-read-sounding-commands-that-write) |
| `zmprov ri` / `rmc` / `fc` / `ulm` | **UNSAFE** | Yes | **No** | reindex / recalculate / flushCache / unlockMailbox |
| `zmprov cps <acct> <pw>` | **Care** | No | Yes | Password lands in `argv`. [A.4](#a4-read-sounding-commands-that-write) |
| `zmmailbox -z -m <acct> <any cmd>` | **UNSAFE** for never-logged-in accounts | Yes | n/a | Session registration auto-creates. [A.1](#a1-does-zmmailbox--z--m-account-create-a-mailbox) |
| `zmmailbox … gm <id>` | **UNSAFE** | Yes | n/a | **Clears UNREAD.** [A.2](#a2-does-zmmailbox-gm-clear-the-unread-flag) |
| `zmmailbox … search -t message` | **Safe** | Yes | n/a | Never sets `markAsRead`. [B.5](#b5-zmmailbox-search) |
| `zmmailbox … gaf` | **Safe** | Yes | n/a | [B.6](#b6-zmmailbox-getallfolders--gaf) |
| `zmmailbox … gms` | **Safe** | Yes | n/a | Use `gms -v` for raw bytes. [B.8](#b8-zmmailbox-getmailboxsize--gms) |
| `zmmailbox … gfrl` / `gofrl` | **Safe** | Yes | n/a | [B.9](#b9-zmmailbox-getfilterrules--gfrl--getoutgoingfilterrules--gofrl) |
| `zmmailbox … gc <conv-id>` | **Safe** | Yes | n/a | Does *not* send `read`. [A.4](#a4-read-sounding-commands-that-write) |
| `zmmailbox … gru <path>` | **Care** | Yes | n/a | HTTP GET; `-o` writes a local file. [A.4](#a4-read-sounding-commands-that-write) |
| `zmmailbox … sf` (syncFolder) | **UNSAFE** | Yes | n/a | Fetches a remote feed *into* the folder |
| `zmmailbox … whoami` | **Safe** | Yes | n/a | Prints **nothing** non-interactively. [B.10](#b10-the-connection-banner) |
| `zmmetadump -m <acct> -i <id>` | **Safe** | **No** (needs **mysqld**) | n/a | Strictly read-only. Must run on the mailbox's host. **Hangs forever if DB is down.** [A.5](#a5-is-zmmetadump-read-only) |
| `zmmsgtrace` | **Safe** | No | n/a | Strictly read-only. Year-guessing bug across rotations. [B.11](#b11-zmmsgtrace) |
| `zmcontrol -v` | **Safe** | No | n/a | Must run as `zimbra`. **Never `--version`.** [B.12](#b12-zmcontrol--v-and-zmcontrol-status) |
| `zmcontrol status` | **Care** | No (needs **LDAP**) | n/a | Changes no service state, but **writes temp files and a cache**. Can hang before its own alarm arms. [B.12](#b12-zmcontrol--v-and-zmcontrol-status) |

**Auxiliary tools at a glance:**

| | `zmmsgtrace` | `zmcontrol status` | `zmcontrol -v` | `zmmetadump` |
|---|---|---|---|---|
| Strictly read-only | **Yes** | **No** — mkdir, temp files, rewrites `.zmcontrol.cache` | No writes, but forks `dpkg`/`rpm` | **Yes** |
| Must run as `zimbra` | no check; needs log read access | **yes, hard `die`** | **yes, hard `die`** | effectively yes (localconfig is 640) |
| Needs a service up | none | LDAP master (**untimed**) | none | **mysqld** |
| Needs mailboxd | no | no | no | no |
| Host-local | reads whatever files you name | yes (or ssh via `-H`) | yes | **yes** — mailbox must be homed here |
| Own timeout | none | 180 s, armed **after** the LDAP call | none | **none — unbounded retry loop** |
| Exit code useful | 0 on success regardless of matches | 0/1, but `stats`/`snmp`/`logger`/`spell` failures **don't** set 1 | 0 for `-v`; **1 for `--version`** | 0 ok / 1 error |
| Machine-parseable | free-form, no header row | `^\t(name)\s+(Running\|Stopped)$` | one line ending `edition.` | `[Database Columns]` / `[Blob Path]` / `[Metadata]` |

---

## A. Side effects — the safety questions

### A.1 Does `zmmailbox -z -m <account>` create a mailbox?

**Yes.** Not at connect time, but on the first subcommand that reaches the server — which is every subcommand,
because `zmmailbox` always requests a full SOAP session.

**What `-z -m` actually does before running a subcommand.** With `-z` and `-m` and no `-A`/`--auth`, the auth
account defaults to the target account
([`ZMailboxUtil.java:2876-2882`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L2876)):

```java
            } else {
                // default case
                authAccount = targetAccount;
            }
```

`initMailbox()` then does an admin auth followed by `selectMailbox`
([`ZMailboxUtil.java:774-791`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L774)),
and `getMailboxOptions` performs exactly two admin SOAP calls
([`ZMailboxUtil.java:620-635`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L620)):

```java
            SoapAccountInfo sai = prov.getAccountInfo(authBy, authAccount);
            DelegateAuthResponse dar = prov.delegateAuth(authBy, authAccount, lifetimeSeconds > 0 ? lifetimeSeconds: Constants.SECONDS_PER_DAY);
            options = new ZMailbox.Options(dar.getAuthToken(), sai.getAdminSoapURL());
```

So the connect sequence is `AdminAuthRequest` → `GetAccountInfoRequest` → `DelegateAuthRequest`. **None of
these touches a mailbox.** `DelegateAuth.handle()` is pure LDAP lookup plus token minting — it never
references `MailboxManager`
([`DelegateAuth.java:56-97`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/service/admin/DelegateAuth.java#L56)).
Constructing the `ZMailbox` from an existing auth token issues no request either
([`ZMailbox.java:748-753`](https://github.com/Zimbra/zm-mailbox/blob/develop/client/src/java/com/zimbra/client/ZMailbox.java#L748) —
`initAuthToken` merely stores the token; an `AuthRequest` is only sent when `authAuthToken` is set, which
`zmmailbox` never sets).

**Where the mailbox gets created.** `zmmailbox` never calls `setNoSession(true)`, so the session preference is
`full` ([`ZMailbox.java:407-419`](https://github.com/Zimbra/zm-mailbox/blob/develop/client/src/java/com/zimbra/client/ZMailbox.java#L407),
`ZMailbox.Options.mNoSession` defaults `false` at
[`:439`](https://github.com/Zimbra/zm-mailbox/blob/develop/client/src/java/com/zimbra/client/ZMailbox.java#L439)),
and that flows into every request as `nosession=false`
([`ZMailbox.java:1049-1056`](https://github.com/Zimbra/zm-mailbox/blob/develop/client/src/java/com/zimbra/client/ZMailbox.java#L1049)).
Registering that session auto-creates the mailbox
([`Session.java:135-145`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/session/Session.java#L135)):

```java
    public Session register() throws ServiceException {
        if (mIsRegistered) {
            return this;
        }

        if (isMailboxListener()) {
            MailboxStore mbox = mailbox = MailboxManager.getInstance().getMailboxByAccountId(mTargetAccountId);
```

That single-argument overload is `AUTOCREATE`
([`MailboxManager.java:294-296`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/mailbox/MailboxManager.java#L294)):

```java
    public Mailbox getMailboxByAccountId(String accountId) throws ServiceException {
        return getMailboxByAccountId(accountId, FetchMode.AUTOCREATE);
    }
```

Independently, every mail handler resolves its mailbox with `autoCreate` defaulted to `true`
([`DocumentHandler.java:187-198`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/soap/DocumentHandler.java#L187)):

```java
    public static Mailbox getRequestedMailbox(ZimbraSoapContext zsc) throws ServiceException {
        return getRequestedMailbox(zsc, true);
    }
```

Creation is a real, logged, redo-logged DB write: `DbMailbox.createMailbox(...)` plus `mbox.initialize()` to
build the default folder set
([`MailboxManager.java:879-916`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/mailbox/MailboxManager.java#L879)):

```java
                data = DbMailbox.createMailbox(conn, id, account.getId(), account.getName(), -1);
                ZimbraLog.mailbox.info("Creating mailbox with id %d and group id %d for %s.", data.id, data.schemaGroupId, account.getName());
```

**Interactive vs one-shot.** In interactive mode (`args.length < 1`) the banner calls `getUserRoot()`, which
issues `NoOpRequest` and/or `GetFolderRequest`
([`ZMailbox.java:4415-4431`](https://github.com/Zimbra/zm-mailbox/blob/develop/client/src/java/com/zimbra/client/ZMailbox.java#L4415)),
so the mailbox is created **before you type anything**. In one-shot mode the banner early-returns
([`ZMailboxUtil.java:746`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L746),
`if (!mInteractive) return;`), so creation happens on the subcommand's first request instead. Either way it
happens.

**Consequence for the TUI.** There is no `zmmailbox` invocation — not even `noOp`, not even `whoami` — that can
be used as a "does this mailbox exist" probe. An existence pre-check must be done with something else; see
[A.3](#a3-does-zmprov-gmi-provision-a-mailbox) for the only safe option found.

**Not affected:** delegated admin auth does **not** update `zimbraLastLogonTimestamp`. `updateLastLogon` is
reached only from the password / preauth / SSO / recovery-code auth paths and from `accountAuthed`
([`LdapProvisioning.java:5426, 5502, 5521, 5559, 5599`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ldap/LdapProvisioning.java#L5602)),
and `accountAuthed` has exactly two callers, both SASL authenticators for IMAP/POP
(`GssAuthenticator.java:236`, `ZimbraAuthenticator.java:112`). `DelegateAuth` calls none of them.

**Audit trail.** `DelegateAuth` does write a security log line
([`DelegateAuth.java:79-81`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/service/admin/DelegateAuth.java#L79)):

```java
        ZimbraLog.security.info(ZimbraLog.encodeAttrs(
                new String[] {"cmd", "DelegateAuth","accountId", account.getId(),"accountName", account.getName()}));
```

Not a data change, but every `zmmailbox -z -m` leaves a traceable entry in `audit.log`.

### A.2 Does `zmmailbox gm` clear the unread flag?

**Yes. Unconditionally, and there is no flag to prevent it.**

The chain has four links; all four were read directly.

**1 — the CLI hard-codes it**
([`ZMailboxUtil.java:2672-2674`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L2672)):

```java
    private void doGetMessage(String[] args) throws ServiceException {
        ZGetMessageParams params = new ZGetMessageParams();
        params.setMarkRead(true);
```

The command definition carries only `O_VERBOSE`
([`ZMailboxUtil.java:429`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L429)) —
there is no option that reaches `setMarkRead`.

**2 — the client always emits the attribute**
([`ZMailbox.java:3032`](https://github.com/Zimbra/zm-mailbox/blob/develop/client/src/java/com/zimbra/client/ZMailbox.java#L3032)):

```java
                msgEl.addAttribute(MailConstants.A_MARK_READ, params.isMarkRead());
```

Unconditional — not inside an `if`. `A_MARK_READ = "read"`
([`MailConstants.java:894`](https://github.com/Zimbra/zm-mailbox/blob/develop/common/src/java/com/zimbra/common/soap/MailConstants.java#L894)),
and booleans serialise as `"1"`/`"0"`
([`Element.java:209-211`](https://github.com/Zimbra/zm-mailbox/blob/develop/common/src/java/com/zimbra/common/soap/Element.java#L209)).
**The wire form is `<m id="…" read="1"/>`.** There is also a second path: on a client-cache hit it issues an
explicit `markMessageRead` ([`ZMailbox.java:3060-3063`](https://github.com/Zimbra/zm-mailbox/blob/develop/client/src/java/com/zimbra/client/ZMailbox.java#L3060)).

**3 — the schema default is "leave unchanged"**
([`MsgSpec.java:71-77`](https://github.com/Zimbra/zm-mailbox/blob/develop/soap/src/java/com/zimbra/soap/mail/type/MsgSpec.java#L71)):

```java
    /**
     * @zm-api-field-tag mark-read
     * @zm-api-field-description Set to mark the message as read, unset to leave the read status unchanged.
     * By default, the read status is left unchanged.
     */
    @XmlAttribute(name=MailConstants.A_MARK_READ /* read */, required=false)
    private ZmBoolean markRead;
```

So the *protocol* is safe by default. It is `zmmailbox` that opts in.

**4 — the handler clears UNREAD when told to**
([`GetMsg.java:82`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/service/mail/GetMsg.java#L82) and
[`:148-156`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/service/mail/GetMsg.java#L148)):

```java
        boolean read = msgSpec.getMarkRead() != null ? msgSpec.getMarkRead() : false;
```
```java
        Message msg = mbox.getMessageById(octxt, iid.getId());
        if (read && msg.isUnread() && !RedoLogProvider.getInstance().isSlave()) {
            try {
                mbox.alterTag(octxt, msg.getId(), MailItem.Type.MESSAGE, Flag.FlagInfo.UNREAD, false, null);
```

**Corroboration from Zimbra itself.** `GetMsg` is one of only **two** handlers in the entire
`com.zimbra.cs.service` tree that override `isReadOnly()` (the other is `doc/SaveDocument`), and it declares
itself *not* read-only on a normal server
([`GetMsg.java:138-141`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/service/mail/GetMsg.java#L138)):

```java
    @Override
    public boolean isReadOnly() {
        return RedoLogProvider.getInstance().isSlave();
    }
```

`isSlave()` is false on a master, so `isReadOnly()` returns **false**.

> **Do not use `isReadOnly()` as a general safety oracle.** The base class defaults it to `true`
> ([`DocumentHandler.java:329-331`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/soap/DocumentHandler.java#L329)),
> almost no write handler overrides it, and its only consumer is redolog-slave gating
> ([`SoapEngine.java:567`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/soap/SoapEngine.java#L567)).
> It is meaningful here only because `GetMsg` bothered to set it.

**Version-invariant.** Verified identical at `8.8.15.p47-v1` and `10.1.18` (`ZMailbox.java:2963`/`3032`,
`GetMsg.java:82` and `:151`).

**Safe ways to read a message body.** None via `zmmailbox gm`. The options are: issue `GetMsgRequest` yourself
*omitting* the `read` attribute (e.g. via `zmsoap`), use the REST content servlet, or read the item with
`zmmetadump` ([A.5](#a5-is-zmmetadump-read-only)). `zmmailbox search` is safe and gives subject/sender/date
without touching flags.

### A.3 Does `zmprov gmi` provision a mailbox?

**Yes.** This is the highest-impact finding in this document, because `zmprov gmi` is in the shipped M1
allowlist.

`gmi` maps to the admin `GetMailboxRequest`
([`ProvUtil.java:1962-1970`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L1962)),
and the handler calls the **auto-creating** overload
([`GetMailbox.java:77-79`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/service/admin/GetMailbox.java#L77)):

```java
        Mailbox mbox = MailboxManager.getInstance().getMailboxByAccount(account);
        GetMailboxResponse resp = new GetMailboxResponse(
                new MailboxWithMailboxId(mbox.getId(), null, mbox.getSize()));
```

`getMailboxByAccount(Account)` is documented as creating
([`MailboxManager.java:227-239`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/mailbox/MailboxManager.java#L227)):

```java
    /** Returns the mailbox for the given account.  Creates a new mailbox
     *  if one doesn't already exist.
     …
    public Mailbox getMailboxByAccount(Account account) throws ServiceException {
        return getMailboxByAccount(account, FetchMode.AUTOCREATE);
    }
```

**This is not incidental — it is unique.** Sweeping every admin handler that resolves a mailbox, `GetMailbox`
is the **only read-named one** that uses the auto-creating overload. Every other read-ish admin handler passes
`false` (= `DO_NOT_AUTOCREATE`) and throws `mailbox not found` instead:

| Handler | Call | Autocreates? |
|---|---|---|
| `GetMailbox` (`gmi`) | `getMailboxByAccount(account)` | **YES** |
| `GetIndexStats` (`gis`) | `getMailboxByAccount(account, false)` | no |
| `VerifyIndex` (`vi`) | `getMailboxByAccount(account, false)` | no |
| `CompactIndex`, `ManageIndex` | `…(account, false)` | no |
| `RecalculateMailboxCounts` (`rmc`) | `…(account, false)` | no |
| `PurgeAccountCalendarCache`, `PurgeMessages`, `ReIndex` | `…(account, false)` | no |
| `DeleteMailbox` | `getMailboxByAccountId(accountId, false)` | no |

The `false` variants produce, e.g.
([`VerifyIndex.java:83-86`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/service/admin/VerifyIndex.java#L83)):

```java
        Mailbox mbox = MailboxManager.getInstance().getMailboxByAccount(account, false);
        if (mbox == null) {
            throw ServiceException.FAILURE("mailbox not found for account " + accountId, null);
        }
```

**Precise behaviour of `zmprov gmi <account>`:**

- Account does not exist → `lookupAccount` throws first:
  `ERROR: account.NO_SUCH_ACCOUNT (no such account: x@y)`, exit **2**. No side effect.
- Account exists, mailbox exists → prints the two lines, no side effect.
- **Account exists, no mailbox → the mailbox is created**, default folders are built, a `Creating mailbox with
  id N …` line is written to `mailbox.log`, and `gmi` returns the brand-new id with `quotaUsed: 0`.

#### The safe replacement: `zmprov gqu <server>`

`getQuotaUsage` never creates anything. Its argument is a **server**, not an account
([`ProvUtil.java:701-702`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L701),
`"getQuotaUsage", "gqu", "{server}"`), and the request is proxied to that server
([`SoapProvisioning.java:1231-1239`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/soap/SoapProvisioning.java#L1231)).

It enumerates accounts from LDAP and joins against the `mailbox` table
([`GetQuotaUsage.java:299-315`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/service/admin/GetQuotaUsage.java#L299)):

```java
            Map<String, Long> quotaUsed = MailboxManager.getInstance().getMailboxSizes(accounts);
…
                Long used = quotaUsed.get(acct.getId());
                aq.quotaUsed = used == null ? 0 : used;
```

and `getMailboxSizes` only consults **already-known** mailbox ids
([`MailboxManager.java:790-808`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/mailbox/MailboxManager.java#L790)):

```java
                for (NamedEntry account : accounts) {
                    Integer mailboxId = mailboxIds.get(account.getId());
                    if (mailboxId != null)
                        requested.add(mailboxId);
                }
```

`mailboxIds` is loaded in full at mailboxd startup
([`MailboxManager.java:167`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/mailbox/MailboxManager.java#L167),
`mailboxIds = DbMailbox.listMailboxes(conn, this);`), so the figures are complete, not lazily populated.

**Trade-offs, stated honestly:** `gqu` returns *every* account on the server (one line each), requires
system-admin rights when no domain is given, and does a full LDAP account search plus a DB query — it is much
heavier than `gmi` for a single account, and it caches per admin session. It is the right tool for a
"quota overview" screen and a poor tool for "show me this one account". For a single account, the safe options
are: read the quota *limit* from LDAP (`zmprov ga <acct> zimbraMailQuota`, safe), and either accept `gqu` for
usage or accept that usage is unavailable without risking provisioning.

An account that appears in `gqu` output with `quotaUsed` `0` may either have an empty mailbox or **no mailbox
row at all** — the two are indistinguishable in that output. See
[What this research could not settle](#what-this-research-could-not-settle).

### A.4 Read-sounding commands that write

This is the list the design spec's "judge commands by effect, not name" rule needs.

#### Definite writes with read-ish names

| Command | Binary | What it actually does | Source |
|---|---|---|---|
| `getMessage` / `gm` | `zmmailbox` | **Clears UNREAD** on the fetched message | [A.2](#a2-does-zmmailbox-gm-clear-the-unread-flag) |
| `getMailboxInfo` / `gmi` | `zmprov` | **Creates the mailbox** if absent | [A.3](#a3-does-zmprov-gmi-provision-a-mailbox) |
| *any* subcommand with `-m` | `zmmailbox` | **Creates the mailbox** if absent (session registration) | [A.1](#a1-does-zmmailbox--z--m-account-create-a-mailbox) |
| `syncFolder` / `sf` | `zmmailbox` | Fetches the folder's remote feed **into** the folder | `ZMailboxUtil.java:475` |
| `importURLIntoFolder` / `iuif` | `zmmailbox` | Adds remote content to a folder | `ZMailboxUtil.java:437` |
| `recalculateMailboxCounts` / `rmc` | `zmprov` | Rewrites mailbox counters | `ProvUtil.java:2052` |
| `verifyIndex` / `vi` | `zmprov` | See "read-only with caveats" below | `VerifyIndex.java:83` |
| `flushCache` / `fc` | `zmprov` | Invalidates server caches (name is neutral, effect is a state change) | `ProvUtil.java:4641` |
| `syncGalAccount` / `syg` | `zmprov` | Runs a GAL sync | `ProvUtil.java` |
| `unlockMailbox` / `ulm` | `zmprov` | Clears maintenance state | `ProvUtil.java:857` |

#### Read-only, but with a caveat

- **`zmprov vi` (verifyIndex).** Does not autocreate and does not call Lucene's fix path — it runs
  `CheckIndex.checkIndex()` only
  ([`LuceneIndex.java:569-580`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/index/LuceneIndex.java#L569)):
  ```java
        CheckIndex check = new CheckIndex(luceneDirectory);
        …
        CheckIndex.Status status = check.checkIndex();
        return status.clean;
  ```
  There is no `exorciseIndex`/`fixIndex` call. Caveat: it requires the **`reindexMailbox` admin right**, not a
  read right (`VerifyIndex.java:65-68`), and whether opening the Lucene directory takes a write lock is
  **UNKNOWN**.
- **`zmprov ga` with a binary attribute.** With the global `-t`/`--temp` flag, values are **written to files**
  under `LC.zmprov_tmp_directory` instead of printed
  ([`ProvUtil.java:3967-3992`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L3967)):
  ```java
        File file = new File(sb.toString());
        if (file.exists()) {
            file.delete();
        }
  ```
  A local filesystem write (and delete) triggered by a read command. Never pass `-t`.
- **`zmprov cps` (checkPasswordStrength).** Read-only against the directory, but the candidate password is
  passed in `argv` and is therefore visible in `ps` to any local user. Treat as a credential-handling command.
- **`zmmailbox gru` (getRestURL).** An HTTP GET, so read-only server-side, but the relative path is
  operator-supplied and `-o` writes a local file
  ([`ZMailboxUtil.java:3018-3031`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L3018)).
- **`zmprov gqu`, `gaa`, `cta`, `cto`, `sa`.** Read-only but potentially very expensive — full LDAP searches.

#### Reads that were suspected and are clean

Worth recording, because these were checked and found safe:

- **`zmmailbox search`** never marks read. `ZSearchParams.mMarkAsRead` defaults `false`, `ZMailboxUtil` never
  calls `setMarkAsRead`, and the client only emits the attribute when it is true
  ([`ZMailbox.java:4288-4290`](https://github.com/Zimbra/zm-mailbox/blob/develop/client/src/java/com/zimbra/client/ZMailbox.java#L4288)).
- **`zmmailbox gc` (getConversation)** does not send `read` at all
  ([`ZMailbox.java:2370-2379`](https://github.com/Zimbra/zm-mailbox/blob/develop/client/src/java/com/zimbra/client/ZMailbox.java#L2370)),
  so the server default (`false`) applies. Unlike `gm`, it is safe.
- **`zmmailbox autoComplete` / `ac`** does not update contact rankings. `ContactRankings.increment` has exactly
  one caller, `MailSender` on send
  ([`MailSender.java:773`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/mailbox/MailSender.java#L773)).

#### Metadata that reads do *not* touch

- **`last_soap_access`** in the `mailbox` table is only written on a **write** op. `SoapSession.updateLastWrite`
  is called on the session's first write, and `unregister()` only persists when `lastWrite != -1`
  ([`SoapSession.java:850-861`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/session/SoapSession.java#L850),
  [`:515-526`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/session/SoapSession.java#L515)). The
  `Mailbox` javadoc is explicit
  ([`Mailbox.java:1538-1543`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/mailbox/Mailbox.java#L1538)):
  *"Returns the last time that the mailbox had a **write op** caused by a SOAP session."* Pure reads leave it
  alone.
- **`zimbraLastLogonTimestamp`** is not touched by delegated auth — see [A.1](#a1-does-zmmailbox--z--m-account-create-a-mailbox).
  Separately, it is throttled: `updateLastLogon` returns early unless
  `zimbraLastLogonTimestampFrequency` has elapsed, and does nothing at all if that is `0`
  ([`LdapProvisioning.java:5602-5620`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ldap/LdapProvisioning.java#L5602)).
  **A displayed "last logon" can legitimately be up to one frequency-interval stale.** The attribute's own
  description calls it a *"rough estimate"*.

#### In-memory side effects that are not writes but are not nothing

Every `zmmailbox` invocation registers a full server-side `SoapSession`
([A.1](#a1-does-zmmailbox--z--m-account-create-a-mailbox)). That consumes a session slot and pins the mailbox
in the mailbox cache until the session times out. It does not change persistent state, but a TUI that shells
out to `zmmailbox` in a tight loop will accumulate sessions on the server.

### A.5 Is `zmmetadump` read-only?

**Yes — genuinely and strictly.** It is the safest of the three auxiliary tools by this criterion, and the only
safe way to inspect a message's stored state without touching flags.

**Installed path:** `/opt/zimbra/bin/zmmetadump`
([`zm-build/instructions/bundling-scripts/zimbra-core.sh:268`](https://github.com/Zimbra/zm-build/blob/develop/instructions/bundling-scripts/zimbra-core.sh)).
The wrapper is one executable line
([`zm-core-utils/src/bin/zmmetadump:19`](https://github.com/Zimbra/zm-core-utils/blob/develop/src/bin/zmmetadump)):

```bash
exec `dirname $0`/zmjava com.zimbra.cs.mailbox.util.MetadataDump "$@"
```

**It talks to MySQL directly over JDBC — not to mailboxd, not over SOAP**
([`MetadataDump.java:365-398`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/mailbox/util/MetadataDump.java#L365)):

```java
            // Get data from db.
            DbPool.startup();
            DbConnection conn = null;
```

There is no `SoapProvisioning`, `SoapHttpTransport` or `ZMailbox` anywhere in the class; the imports are
`java.sql.*`, `org.apache.commons.cli.*`, `DbMailItem`, `DbPool`, `Metadata`, `volume.*`. The JDBC URL comes
from localconfig (`mysql_bind_address`, `mysql_port`, default **7306**).

**Read-only proof.** Every SQL statement is a `SELECT`; there is no `executeUpdate`, `INSERT`, `UPDATE` or
`DELETE` in the file. The four statements are at `MetadataDump.java:168`, `:188`, `:206` and `:238`. The
connection is opened with `autoCommit(false)` and **never committed** — `DbPool.quietClose` returns it to the
pool, which rolls back.

**No file writes.** `-f`/`--file` is an **input** option (decode metadata from a file), not an output one
([`MetadataDump.java:71`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/mailbox/util/MetadataDump.java#L71)):

```java
        sOptions.addOption("f", OPT_FILE, true, "Decode metadata value in a file (other options are ignored)");
```

**It never dumps blobs.** The `[Blob Path]` section prints a *computed path string*; it never opens or copies
the blob ([`MetadataDump.java:134-155`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/mailbox/util/MetadataDump.java#L134)).

#### Requirements

| Requirement | Detail |
|---|---|
| **User** | No check in the script, but effectively **`zimbra`** (or root): `zmjava` → `zmsetvars` → `zmlocalconfig`, and `/opt/zimbra/conf/localconfig.xml` is mode **640 `zimbra:zimbra`** ([`zmfixperms:248-250`](https://github.com/Zimbra/zm-core-utils/blob/develop/src/libexec/zmfixperms)). The MySQL password comes from there. |
| **mailboxd** | **Not required.** Neither running nor stopped is checked, and neither matters. |
| **mysqld** | **Required.** |
| **Host locality** | **Required** — implicitly. It connects to the *local* MySQL, whose `mailbox` table only holds locally-homed mailboxes. |

**Locality is enforced by the error message, not by an LDAP check**
([`MetadataDump.java:192-193`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/mailbox/util/MetadataDump.java#L192)):

```java
            if (!rs.next())
                throw ServiceException.INVALID_REQUEST("Account " + email + " not found on this host", null);
```

**Use the email form of `-m`, not a numeric mailbox id.** With a numeric id that lookup is skipped entirely, a
wrong-host id falls through to a query against the non-existent `mboxgroup0.mail_item`, and you get a
**misleading `No such item`** instead of a clear locality error.

> **Hang risk — no timeout.** If MySQL is unreachable, `DbPool.startup()` → `waitForDatabase()` **loops
> forever** ([`DbPool.java:237-254`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/db/DbPool.java#L237)):
> ```java
>          while (conn == null) {
>              try {
>                  conn = DbPool.getConnection();
>              } catch (ServiceException e) {
>                  ZimbraLog.misc.warn("Could not establish a connection to the database.  Retrying in %d seconds.",
> ```
> There is no bound. **The TUI must impose its own wall-clock timeout and kill the process.**

#### Options

```
Usage: zmmetadump -m <mailbox id/email> -i <item id> [--dumpster]
   or: zmmetadump -f <file containing encoded metadata>
   or: zmmetadump -s <encoded string>
```

([`MetadataDump.java:76-83`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/mailbox/util/MetadataDump.java#L76), printed to **stderr**.)

| Option | Long | Meaning |
|---|---|---|
| `-m` | `--mailboxId` | mailbox id (numeric) **or** email address. Email is upper-cased and matched against `mailbox.comment`. |
| `-i` | `--itemId` | required whenever `-m` is used |
| — | `--dumpster` | read from `mail_item_dumpster` / `revision_dumpster` |
| `-f` | `--file` | decode metadata from a file; all other options ignored |
| `-s` | `--String` | decode from a literal string. **Note the capital `S`** — `--String`, not `--string`. |
| `-h` | `--help` | usage to stderr, exit **0** |

Exit codes: success **0**; missing `-m`/`-i`, parse error, missing `-f` file, or any exception → **1**, with the
message, two blank lines and a **full stack trace** on stderr.

#### Output structure

Three sections, whose header constants are `public` so a parser may rely on them
([`MetadataDump.java:61-63`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/mailbox/util/MetadataDump.java#L61)):

```java
    public static final String DB_COLS_HDR = "[Database Columns]";
    public static final String METADATA_HDR = "[Metadata]";
    public static final String BLOBPATH_HDR = "[Blob Path]";
```

```
[Database Columns]
  id: 257
  type: 5
  folder_id: 2
  date: 1753783501 (Wed 2025/07/29 10:45:01 CEST)
  size: 7596
  subject: Fatura hk.
  ...

[Blob Path]
/opt/zimbra/store/0/2/msg/0/257-12.msg

[Metadata]
{
  d = 1753783501
  s = 7596
  ...
}
```

- `[Database Columns]`: `"  " + <lowercased column> + ": " + value`, or the literal `<null>`. The `metadata`
  column is excluded here.
- `date` and `change_date` get a rendered suffix `<epoch_seconds> (<formatted>)`, format
  `"EEE yyyy/MM/dd HH:mm:ss z"` in the **JVM default timezone**
  ([`MetadataDump.java:290-293`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/mailbox/util/MetadataDump.java#L290)).
- `[Blob Path]` appears **only** when `blob_digest` is non-null and the volume resolves.
- `[Metadata]` is the BEncoded blob decoded into a brace tree, **keys sorted, 2-space indent**
  ([`Metadata.java:362-405`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/mailbox/Metadata.java#L362)).
- With revisions present, a `Current Revision` banner precedes the item and each revision gets
  `********************   Revision <n>   ********************`, separated by two blank lines, ordered
  `version DESC`.

Because the query is `SELECT *`, **the exact column set is schema-version dependent**. Parse tolerantly; the
`  <name>: <value>` shape is what is stable. Zimbra's own integration test asserts exactly that contract
([`TestMetadataDump.java:106-112`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/qa/unittest/TestMetadataDump.java#L106)).

---

## B. Exact output formats

### B.0 Cross-cutting facts

**`zmprov` writes attribute lines through a UTF-8 writer with a hard `\n`**
([`ProvUtil.java:4027-4036`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L4027)):

```java
    private static void printOutput(String text) {
        PrintStream ps = console;
        try {
            BufferedWriter writer = new BufferedWriter(new OutputStreamWriter(ps, Charsets.UTF_8));
            writer.write(text + "\n");
            writer.flush();
```

Note the asymmetry: attribute lines are forced to UTF-8; the `# name …` header and blank lines go through
`console.println(...)` using the JVM's default encoding.

**Logs go to stderr, so stdout is clean**
([`ProvUtil.java:4040`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L4040)):
`ZimbraLog.toolSetupLog4jConsole("INFO", true, false); // send all logs to stderr`.

**Errors**: `ERROR: <code> (<message>)` on stderr, exit **2**
([`ProvUtil.java:4211-4221`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L4211)).
Usage/`Via` violations go to **stdout** and exit **1**.

**`zmmailbox` uses UTF-8 autoflush writers for both streams**
([`ZMailboxUtil.java:1914-1920`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L1914)),
`ERROR: …` on stderr with exit **2**, usage on stdout with exit **1**.

**`-d`/`--debug` on `zmmailbox` writes SOAP dumps to stdout**, not stderr
([`ZMailboxUtil.java:2971-2985`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L2971)).
Never pass `-d` when parsing.

**`zmmailbox` has two different `-v` flags.** Global `-v` (before the command) only affects stack traces and
interactive echo. Per-command `-v` (after the command name) is the one that switches to JSON
([`ZMailboxUtil.java:1005-1007`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L1005)).
Position is load-bearing: `zmmailbox -v … gm 257` gives the table, `zmmailbox … gm -v 257` gives JSON.

**`zmprov` has no per-command `-v` for `ga`/`gc`/`gam`/`gmi`.** The global `-v` does not change their output at
all. `zmprov ga -v user@x` treats `-v` as the account key and fails with `no such account: -v`.

**`formatSize`** — used by `zmmailbox` for human-readable sizes
([`ZMailboxUtil.java:571-585`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L571)):

```java
    private String formatSize(long size) {
        if (size > GBYTES) {
            return String.format("%.2f GB", (((double) size) / GBYTES));
        } else if (size > MBYTES) {
            return String.format("%.2f MB", (((double) size) / MBYTES));
        } else if (size > KBYTES) {
            return String.format("%.2f KB", (((double) size) / KBYTES));
        } else {
            return String.format("%d B", size);
        }
    }
```

Binary units, thresholds are **strictly greater than** (1024 → `1024 B`, 1025 → `1.00 KB`), always exactly two
decimals for K/M/G. **The decimal separator is locale-dependent** — `String.format` without a `Locale`. Under a
European locale this yields `1,50 MB`. Prefer raw-byte modes and/or set `LC_ALL=C` in the subprocess.

### B.1 `zmprov ga <account> [attrs…]`

Record shape — header, attribute lines, one trailing blank line
([`ProvUtil.java:3214-3219`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L3214)):

```java
    private void dumpAccount(Account account, boolean expandCos, Set<String> attrNames) throws ServiceException {
        console.println("# name " + account.getName());
        Map<String, Object> attrs = account.getAttrs(expandCos);
        dumpAttrs(attrs, attrNames);
        console.println();
    }
```

```
# name user@example.com
zimbraAccountStatus: active
zimbraCOSId: e00428a1-0c00-11d9-836a-000d93afea2a
zimbraId: 8a3f1c2e-...
zimbraMailAlias: sales@example.com
zimbraMailAlias: info@example.com

```

The line format
([`ProvUtil.java:3994-4014`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L3994)):

```java
        } else {
            printOutput(attrName + ": " + value);
        }
```

- **Separator** is `": "` — colon plus exactly one space. No indentation, no alignment.
- **Multi-valued attributes repeat the name**, one line per value, in **source order** (LDAP/SOAP document
  order). Only the attribute *names* are sorted, via a `TreeMap`
  ([`ProvUtil.java:3251`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L3251)).
  That sort is **case-sensitive ASCII**: `zimbraFeatureMAPIConnectorEnabled` precedes
  `zimbraFeatureMailEnabled` because `'M'` (77) < `'a'` (97). Do not assume case-insensitive ordering.
- **Long values are never wrapped, folded or truncated.** A 8 KB `zimbraPrefOutOfOfficeReply` is one line —
  except for embedded newlines, below.
- **`# name` uses the canonical primary address**, not the key you typed.

#### Values containing newlines — the parsing hazard

Values are emitted **raw**. There is no escaping, no quoting, no continuation marker. This is not theoretical:
`zimbraMailSieveScript` is a single-valued string that holds a multi-line Sieve script. The repo's own fixture
builds it with embedded newlines
([`TestFolderFilterRules.java:334-339`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/qa/unittest/TestFolderFilterRules.java#L334)):

```java
    private static final String FILTER_RULES = StringUtil.join("\n", new String[] {
        "require [\"fileinto\", \"reject\", \"tag\", \"flag\"];",
        "",
        "# Folder 1",
        "if anyof (header :is \"subject\" \"" + SUBJECT1 + "\" )",
        "{",
```

So `zmprov ga <acct> zimbraMailSieveScript` produces output containing **blank lines** and lines starting with
`#` — indistinguishable from the record separator and the `# name` header respectively, to a naive parser.
`zimbraPrefOutOfOfficeReply` (`max="8192"`) and the multi-valued `description` have the same property.

**Mitigation:** always request an explicit attribute list so no free-text attribute is in the output, and treat
any line that does not match `^[A-Za-z][A-Za-z0-9;.\-]*::? ` as a continuation of the previous value.

#### Binary attributes

Binary values use a **double colon** and **are** wrapped
([`ProvUtil.java:3996-4010`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L3996)):

```java
                // print base64 encoded content
                // follow ldapsearch notion of using two colons when printing base64 encoded data
                // re-encode into 76 character blocks
                String based64Chunked = new String(Base64.encodeBase64Chunked(binary));
```

76-char chunks separated by **CRLF** (commons-codec `MIME_CHUNK_SIZE = 76`, `CHUNK_SEPARATOR = {'\r','\n'}`),
with **no leading space** on continuation lines — so it is *not* valid LDIF folding. The code strips only the
trailing `\n`, leaving a stray `\r` at the end of the block. Affected attributes in `develop`:
`userSMIMECertificate`, `zimbraPrefMailSMIMECertificate`, `zimbraSSLDHParam`, `zimbraAPNSCertificate`,
`thumbnailPhoto`.

#### Attributes that silently do not appear

Empty-valued attributes are **suppressed**
([`ProvUtil.java:3299-3317`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L3299),
guard `aSv.length() > 0`, commented `// don't print permission denied attr`). An absent attribute therefore
means *unset*, *empty*, *permission-denied*, or — for `zimbraLastLogonTimestamp` with a non-LDAP ephemeral
backend — *the ephemeral store was unreachable*. **Never infer a semantic default from absence.**

In SOAP mode, secrets are replaced server-side with a sentinel
([`Provisioning.java:464-481`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/Provisioning.java#L464)):
you will see `userPassword: VALUE-BLOCKED`.

#### Flags

| Flag | Effect on `ga` |
|---|---|
| `-e` (command arg) | Do **not** expand COS/inherited defaults; only attrs set on the entry. See [C.2](#c2-does--l-expand-cos-inherited-values). |
| `[attr1 attr2 …]` | Filter. Matching is **case-insensitive** (names are lowercased). `attr=value` also filters by value — but the value is lowercased too, so `zimbraMailAlias=Foo@Bar` never matches. |
| `-fd` / `--forcedisplay` | Also print empty attrs as `name: ` (trailing space). Tends to print already-printed attrs a second time, lowercased. |
| `-t` / `--temp` | Binary attrs go to files instead of stdout — **a write**. See [A.4](#a4-read-sounding-commands-that-write). |
| `-v` / `--verbose` | **No effect on output.** |

### B.2 `zmprov gmi <account>`

Two lines. The field is `quotaUsed`, not `used`
([`ProvUtil.java:1969`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L1969)):

```java
        console.printf("mailboxId: %s\nquotaUsed: %d\n", info.getMailboxId(), info.getUsed());
```

```
mailboxId: 214
quotaUsed: 508559360
```

- Separator `": "`. **No `# name` header, no blank line, no trailer.** Exactly two lines.
- `quotaUsed` is **bytes**, plain decimal, no grouping and no unit suffix. Source is
  `MailboxWithMailboxId.size`, documented *"Size in bytes"*
  ([`MailboxWithMailboxId.java:43-48`](https://github.com/Zimbra/zm-mailbox/blob/develop/soap/src/java/com/zimbra/soap/admin/type/MailboxWithMailboxId.java#L43)).
- SOAP-only. Under `-l`: `ERROR: service.INVALID_REQUEST (invalid request: can only be used with SOAP)`.
- **Running it has a side effect** — [A.3](#a3-does-zmprov-gmi-provision-a-mailbox).

Per-version line numbers for the format string: 8.8.15.p47-v1 **1948**, 9.0.0 **1948**, 10.0.14 **1962**,
10.1.18/develop **1969**. The format string itself is identical in all five.

For contrast, `gqu` prints space-separated fields with **no names**
([`ProvUtil.java:1958`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L1958)):

```java
            console.printf("%s %d %d\n", u.getName(), u.getLimit(), u.getUsed());
```

i.e. `user@example.com 0 508559360` — name, limit, used. `0` limit means unlimited.

### B.3 `zmprov gam <account>`

One group per line, no header, no trailing blank line
([`ProvUtil.java:2223-2234`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L2223)):

```java
            for (Group group : groups) {
                String viaDl = via.get(group.getName());
                if (viaDl != null) {
                    console.println(group.getName() + " (via " + viaDl + ")");
                } else {
                    console.println(group.getName());
                }
            }
```

```
staff@example.com
all@example.com (via staff@example.com)
```

Parse with `^(\S+)(?: \(via (\S+)\))?$`. An undocumented `-i` flag prints zimbraId UUIDs instead.

**Ordering is not stable.** Static distribution lists come first, sorted by name
(`LdapProvisioning.java:6955`, `Collections.sort(result)`), then dynamic groups are appended from a `HashSet`
(`LdapProvisioning.java:9963-9976`, `Entry.getMultiAttrSet` returns a `HashSet`). **Sort client-side** if you
need reproducible output.

Do not confuse with `zmprov gdlm` (getDistributionListMembership), which has a completely different shape:
`# distributionList <name> memberCount=N`, blank line, `members`, then one member per line
([`ProvUtil.java:2394-2409`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L2394)).

### B.4 `zmprov gc <cos>`

Identical in shape to `ga`
([`ProvUtil.java:2789-2794`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L2789)):

```java
    private void dumpCos(Cos cos, Set<String> attrNames) throws ServiceException {
        console.println("# name " + cos.getName());
        Map<String, Object> attrs = cos.getAttrs();
        dumpAttrs(attrs, attrNames);
        console.println();
    }
```

Same `# name` header, same `dumpAttrs` printer, same sorting, same blank-line terminator, same filtering.

**Two differences from `ga`:**

1. **There is no `-e` flag.** `cos.getAttrs()` is `getAttrs(true)`, so defaults are always applied. The dispatch
   takes `args[1]` as the COS name directly
   ([`ProvUtil.java:1242-1244`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L1242)).
2. Not-found error is `ERROR: account.NO_SUCH_COS (no such cos: …)`.

Sibling dumps follow the same `# name X` + attrs + blank pattern (`dumpDomain`, `dumpServer`, `dumpUCService`,
`dumpCalendarResource`, `dumpIdentity`, `dumpSignature`). Two exceptions: `dumpDataSource` adds a second header
line `# type <type>`, and `zmprov gcf <key>` (getConfig) prints attributes with **no header at all**.

### B.5 `zmmailbox search`

Definition
([`ZMailboxUtil.java:472`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L472)):

```java
        SEARCH("search", "s", "{query}", "perform search", Category.SEARCH, 0, 1, O_LIMIT, O_SORT, O_TYPES, O_VERBOSE, O_CURRENT, O_NEXT, O_PREVIOUS, O_DUMPSTER),
```

**Option names — several common assumptions are wrong:**

| Option | Real name | Note |
|---|---|---|
| limit | `-l` / `--limit` | 1–1000, **default 25** (overrides `ZSearchParams`' own 100) |
| offset | **does not exist** | paging is page-based via `-n`/`-p`/`-c` |
| sort | `-s` / `--sort` | not `--sortBy`; default `dateDesc` |
| types | `-t` / `--types` | **default `conversation`**, not message |
| current page | `-c` / `--current` | not `--currentPage` |
| dumpster | `--dumpster` | long form only |

`-t` *after* the command is `--types`; `-t` *before* the command is the global `--timeout`. Position matters.

Because the default type is `conversation`, **`-t message` is mandatory** if you want message ids.

The table
([`ZMailboxUtil.java:2244-2262`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L2244)):

```java
        stdout.printf("num: %d, more: %s%n%n", sr.getHits().size(), sr.hasMore());
        int width = colWidth(last);
…
        String headerFormat = String.format("%%%d.%ds  %%%d.%ds  %%4s   %%-20.20s  %%-50.50s  %%s%%n",
                width, width, id_len, id_len);
        String itemFormat = String.format(  "%%%d.%ds. %%%d.%ds  %%4s   %%-20.20s  %%-50.50s  %%tD %%<tR%%n",
                width, width, id_len, id_len);
        stdout.format(headerFormat, "", "Id", "Type", "From", "Subject", "Date");
```

`width` = digits needed for the largest index on the page; `id_len` = `max(4, longest hit id)`. For a typical
page the runtime formats are `"%2.2s  %4.4s  %4s   %-20.20s  %-50.50s  %s%n"` and
`"%2.2s. %4.4s  %4s   %-20.20s  %-50.50s  %tD %<tR%n"`.

```
num: 3, more: false

     Id  Type   From                  Subject                                             Date
  ----  ----   --------------------  --------------------------------------------------  --------------
 1.  257  mess   Ayşe                  Fatura hk.                                          07/29/26 09:14
 2.  261  mess   <none>                Re: Fatura hk.                                      07/29/26 11:02

```

- **Six columns, in order:** index, `Id`, `Type`, `From`, `Subject`, `Date`.
- **Fixed-width padding, no tabs.** Gaps: index→Id 2 chars (`". "` on rows, `"  "` in the header, so they stay
  aligned), Id→Type 2 spaces, Type→From **3** spaces, From→Subject 2, Subject→Date 2.
- **Two header rows**, then rows, then one trailing blank line. Preceded by `num: N, more: true|false` and a
  blank line.
- **Zero hits → `num: 0, more: false`, a blank line, and nothing else** — no header rows at all.
- **Column 1 is an index, not an id.** It is a 1-based counter (`offset + 1`), usable as `#N` only within the
  same interactive process (`mIndexToId` is in-memory,
  [`ZMailboxUtil.java:846-889`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L846)).
  **A one-shot TUI must use column 2.**
- **There is no folder column.** `ZMessageHit` carries `mFolderId` but `dumpSearch` never prints it — and
  `-v` JSON omits it too. To learn a hit's folder you must use `in:` in the query or fetch the message.
- **Date is `%tD %<tR` = `MM/dd/yy HH:mm`** (Java `Formatter`: `'D'` is `%tm/%td/%ty`, `'R'` is `%tH:%tM`), in
  the **server's local timezone**, 2-digit year, no seconds, no zone marker.
- **Subject is hard-truncated at 50 chars, From at 20**, no ellipsis. Nulls render as the literal `null`; a
  missing sender renders as the literal `<none>`.
- **From is a display name, not an address** — `ZEmailAddress.getDisplay()`, which the server populates from
  `pa.firstName` ([`ToXML.java:3021`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/service/mail/ToXML.java#L3021)).
  You will never get `user@domain` in this column.
- **`num:` can exceed the printed row count.** `dumpSearch` handles only conversation/contact/message/
  appointment/document hits; `ZWikiHit`, `ZVoiceMailItemHit`, `ZCallHit` and `ZIdHit` produce no row.

**`-n`/`-p`/`-c` are useless one-shot.** `mSearchParams` is per-process, so `zmmailbox … search -n` prints
nothing and exits 0. Since there is no `--offset`, paging must be done by narrowing the query.

**`-v`** replaces everything with pretty-printed JSON (5-space indent) — no `num:` line, no headers
([`ZMailboxUtil.java:2232-2236`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L2232)).
Keys per message hit: `id, conversationId, flags, isInvite, fragment, subject, date, size, sender, sortField,
mimePartHits, addresses, message`. `date` is epoch millis, `flags` is the raw flag-character string. **This is
the best machine-readable option for search** — but note it still omits `folderId`.

`searchConv`/`sc` uses the same shape minus the `Type` column (five columns).

### B.6 `zmmailbox getAllFolders` / `gaf`

([`ZMailboxUtil.java:2415-2424`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L2415)):

```java
            String hdrFormat = "%10.10s  %4.4s  %10.10s  %10.10s  %s%n";
            stdout.format(hdrFormat, "Id", "View", "Unread", "Msg Count", "Path");
            stdout.format(hdrFormat, "----------", "----", "----------", "----------",  "----------");
            doDumpFolder(mMbox.getUserRoot(), true);
```

and the row
([`ZMailboxUtil.java:2406-2408`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L2406)):

```java
        stdout.format("%10.10s  %4.4s  %10d  %10d  %s%n",
                folder.getId(), folder.getDefaultView().name(), folder.getUnreadCount(), folder.getMessageCount(), path);
```

```
        Id  View      Unread   Msg Count  Path
----------  ----  ----------  ----------  ----------
         1  conv           0           0  /
         2  mess          12         431  /Inbox
         3  mess           0          77  /Inbox/2026
```

- **Columns:** `Id`, `View`, `Unread`, `Msg Count`, `Path`. Two header rows. **2 spaces between every column.**
- **No indentation for nesting.** Traversal is depth-first pre-order from the user root; hierarchy is expressed
  **only** by the `Path` column. The first row is the root itself, path `/`.
- **Path is an absolute `/`-rooted path**, not an id
  ([`ZFolder.java:594-609`](https://github.com/Zimbra/zm-mailbox/blob/develop/client/src/java/com/zimbra/client/ZFolder.java#L594)).
- Three decorations append a parenthesised suffix **inside** the Path column, so "path = rest of line" is wrong
  if you assume no spaces: search folders get ` (<query>)`, mountpoints get ` (<owner>:<remoteId>)`, feed
  folders get ` (<url>)`.
- **`View` is truncated to 4 chars** (`%4.4s`): `conv`, `mess`, `cont`, `appo`, `docu`, `task`, `wiki`, `remo`,
  `sear`, `voic`, `unkn`.
- **`Msg Count` is the folder's item count** (SOAP `n`), not messages specifically — for a contacts or calendar
  folder it counts non-messages.
- **`Id` is truncated to 10 chars.** Safe in practice for local folders.
- No trailing blank line.

**`gaf -v`** emits one JSON object for the root with the whole tree nested under `subFolders`
([`ZFolder.java:935-966`](https://github.com/Zimbra/zm-mailbox/blob/develop/client/src/java/com/zimbra/client/ZFolder.java#L935)).
Note the key is **`itemCount`**, not `msgCount`; `defaultView` is the **full** enum name; `size` is raw bytes.
Much safer to parse than the fixed-width table.

### B.7 `zmmailbox gm <id>`

**Running this clears the unread flag** — [A.2](#a2-does-zmmailbox-gm-clear-the-unread-flag).

([`ZMailboxUtil.java:2654-2670`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L2654)):

```java
        stdout.format("Id: %s%n", msg.getId());
        stdout.format("Conversation-Id: %s%n", msg.getConversationId());
        ZFolder f =  mMbox.getFolderById(msg.getFolderId());
        stdout.format("Folder: %s%n", f == null ? msg.getFolderId() : f.getPath());
        stdout.format("Subject: %s%n", msg.getSubject());
        doHeader(msg.getEmailAddresses(), "From", ZEmailAddress.EMAIL_TYPE_FROM);
        doHeader(msg.getEmailAddresses(), "To", ZEmailAddress.EMAIL_TYPE_TO);
        doHeader(msg.getEmailAddresses(), "Cc", ZEmailAddress.EMAIL_TYPE_CC);
        stdout.format("Date: %s\n", DateUtil.toRFC822Date(new Date(msg.getReceivedDate())));
        if (msg.hasTags()) stdout.format("Tags: %s%n", lookupTagNames(msg.getTagIds()));
        if (msg.hasFlags()) stdout.format("Flags: %s%n", ZMessage.Flag.toNameList(msg.getFlags()));
        stdout.format("Size: %s%n", formatSize(msg.getSize()));
```

RFC822-*looking* but hand-rolled. Fixed order: `Id`, `Conversation-Id`, `Folder`, `Subject`, then optional
`From`/`To`/`Cc`, then `Date`, optional `Tags`, optional `Flags`, `Size`, blank line, body, blank line.

- **`Folder` is a path**, not an id (falls back to the id only on a folder-cache miss). Contrast with `-v`
  JSON, where `folderId` is numeric.
- **There is no `Bcc`, `Message-ID`, `Reply-To`, raw MIME headers, or attachment listing.**
- **Address lines are folded** at ~76 columns with a `"\n "` continuation, so `To:` with many recipients spans
  multiple physical lines starting with a space. Format is `Personal <user@domain>` or `<user@domain>`.
- **`Date` is RFC822**: `Wed, 29 Jul 2026 15:04:05 +0300 (EEST)` — 4-digit year, seconds, numeric offset,
  optional zone abbreviation ([`DateUtil.java:91-114`](https://github.com/Zimbra/zm-mailbox/blob/develop/common/src/java/com/zimbra/common/util/DateUtil.java#L91)).
  **Completely different from the search table's `MM/dd/yy HH:mm`** — do not share a parser.
- **`Flags` are uppercase enum names** joined by `", "` (e.g. `UNREAD, ATTACHED`).
- **Body is the first `body="1"` part only**, depth-first; an HTML-only message prints raw HTML. No truncation
  limit is set.
- Line 2663 uses `\n` while every other line uses `%n` — identical on Linux, but it is a real inconsistency.

**`gm -v`** dumps the full `ZMessage` JSON, including a nested `mimeStructure` tree — **the only way to
enumerate attachments from `zmmailbox`.**

### B.8 `zmmailbox getMailboxSize` / `gms`

Inline in the dispatch switch
([`ZMailboxUtil.java:1209-1212`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L1209)):

```java
        case GET_MAILBOX_SIZE:
            if (verboseOpt()) stdout.format("%d%n", mMbox.getSize());
            else stdout.format("%s%n", formatSize(mMbox.getSize()));
            break;
```

- Default: one line, human-formatted, **value only** — no label, no key. e.g. `1.44 GB`.
- `-v`: one line, **raw bytes** as decimal. e.g. `1546188226`.

**Always use `gms -v`.** It sidesteps `formatSize`'s locale-dependent decimal separator and its `>`-not-`>=`
thresholds. The value is the same quantity as `gmi`'s `quotaUsed`, obtained through the mail session rather
than the admin API — and unlike `gmi`, reaching it requires a `zmmailbox` session, which auto-creates the
mailbox ([A.1](#a1-does-zmmailbox--z--m-account-create-a-mailbox)).

### B.9 `zmmailbox getFilterRules` / `gfrl` + `getOutgoingFilterRules` / `gofrl`

**Neither Sieve nor XML/JSON** — Zimbra's own single-line rule syntax, the same form `addFilterRule` parses
([`ZMailboxUtil.java:1581-1585`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L1581)):

```java
    private static void printFilterRules(ZFilterRules rules) {
        for (ZFilterRule r : rules.getRules()) {
            stdout.println(r.generateFilterRule());
        }
    }
```

([`ZFilterRule.java:178-200`](https://github.com/Zimbra/zm-mailbox/blob/develop/client/src/java/com/zimbra/client/ZFilterRule.java#L178)):

```java
        sb.append(quotedString(name)).append(' ');
        sb.append(active ? "active" : "inactive").append(' ');
        sb.append(allConditions ? "all" : "any").append(' ');
```

One line per rule:

```
"spam to junk" active all header "subject" contains "viagra" fileinto "/Junk" stop
```

- No header, no separator, no blank lines, no count. **Zero rules → zero bytes.**
- **These commands accept no options at all, not even `-v`.** `gfrl -v` fails argument-count validation and
  prints usage to stdout with exit 1.
- Names are double-quoted. The quote-escaping helper is a **no-op bug**
  ([`ZFilterRule.java:174-176`](https://github.com/Zimbra/zm-mailbox/blob/develop/client/src/java/com/zimbra/client/ZFilterRule.java#L174)):
  `s.replaceAll("\"", "\\\"")` — in Java that replacement string is `\"`, which as a regex replacement means a
  literal `"`. **A rule name containing `"` comes out unescaped and the line is ambiguous.**

### B.10 The connection banner

**A non-interactive one-shot `zmmailbox` invocation prints no banner — zero bytes.**
([`ZMailboxUtil.java:746`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L746)):

```java
    private void dumpMailboxConnect() throws ServiceException {
        if (!mInteractive) return;
```

`mInteractive` is set from the argument count *before* the mailbox is opened
([`ZMailboxUtil.java:2893-2897`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L2893)):
`pu.setInteractive(args.length < 1);`. So stdout contains exactly and only the subcommand's own output.

Consequences:

- The `mailbox: …, size: …, messages: N, unread: N` and `authenticated as …` lines appear **only** in the REPL
  (and under `-f`, which also counts as interactive).
- **`zmmailbox -z -m user@dom whoami` prints nothing and exits 0**, because `whoami`'s only action is
  `dumpMailboxConnect()`. It is useless as a connectivity probe. `noOp`/`no` also prints nothing but does
  perform a round trip and surfaces auth failures as `ERROR:` + exit 2 — though it still creates the mailbox
  ([A.1](#a1-does-zmmailbox--z--m-account-create-a-mailbox)).
- If you ever do parse the banner: `messages`/`unread` are **client-side sums over the whole folder tree**
  using each folder's item count, not server counters.

### B.11 `zmmsgtrace`

**Installed at `/opt/zimbra/libexec/zmmsgtrace`, not `/opt/zimbra/bin/`**
([`zm-build/instructions/bundling-scripts/zimbra-core.sh:351`](https://github.com/Zimbra/zm-build/blob/develop/instructions/bundling-scripts/zimbra-core.sh)).
`zm-core-utils/src/libexec/zmrcd:44` still maps `"msgtrace" => "/opt/zimbra/bin/zmmsgtrace"` — that path is
**stale**. Perl, 716 lines, `$VERSION = "1.05"`.

**Strictly read-only — proven.** The only file primitive in the whole script is one read-mode `IO::File->new`
([`zmmsgtrace:357-358`](https://github.com/Zimbra/zm-core-utils/blob/develop/src/libexec/zmmsgtrace)). No
`open(… ">" …)`, no `unlink`, no `mkdir`, no `system()`, no temp file, no state file. Side effects are limited
to forking `gzip`/`bunzip2` for compressed inputs and writing stdout/stderr. Its own POD warns about memory
(`:80-81`): *"This utility reads a lot of data into memory so beware of running this on platforms that have
limited memory available."*

**Privileges:** no user check. It needs only read access to the log files — see
[D.3](#d3-log-files-for-delivery-tracing) for whether `zimbra` has that.

#### Input files

Default is `/var/log/zimbra.log` (`zmmsgtrace:145`). **Override is positional arguments, not a flag**
(`:275`). Multiple files are de-duplicated and sorted **oldest→newest by mtime** unless `--nosort` (`:333-341`).

**Gzip/bzip2 rotated logs are supported**, detected by **filename suffix only** (`zmmsgtrace:311-330`):

```perl
    if ( $file =~ /\.gz$/ ) {
        @prog = qw(gzip -dc);
    }
    elsif ( $file =~ /\.bz(?:|2)$/ ) {
        @prog = qw(bunzip2 -dc);
    }

    if (@prog) {
        $file = "@prog < '$file' |";
```

`.xz` and `.zst` are **not** supported and would be read as garbage.

> **Shell-injection hazard.** That pipe form interpolates the filename into a `/bin/sh` command line inside
> single quotes **with no escaping**. A path containing `'` executes arbitrary shell. If the TUI ever lets an
> operator supply or glob a log path, sanitise it before passing it through.

**Structural limit:** parser state is re-initialised **per file** (`:361`), so a message whose hops straddle a
rotation boundary is **not** chained across files.

#### Options (verbatim from the POD, `zmmsgtrace:24-43`)

```
zmmsgtrace [options] [<mail-syslog-file>...]

    --id|i "msgid"                # case sensitive regex
    --sender|s "user@domain"      # case insensitive regex
    --recipient|r "user@domain"   # case insensitive regex
    --srchost|F "hostname_or_ip"  # case insensitive regex
    --desthost|D "hostname_or_ip" # case insensitive regex
    --time|t "start_ts,end_ts"    # YYYYMM[DD[HH[MM[SS]]]]
    --year "YYYY"                 # file year if no YYYY in file
    --nosort                      # do not sort @ARGV files by mtime
    --debug+                      verbose output useful for debugging
    --help                        display a brief help message
    --man                         display the entire man page

  Where:
    <mail-syslog-file> defaults to "/var/log/zimbra.log"

  Files ending in '.gz', '.bz' or '.bz2' will be read using gzip or
  bunzip2.
```

**All the filters are Perl regexes, not literals.** `--id` is case-**sensitive**; the rest are
case-insensitive. `--desthost` strips a trailing `:port` before matching. `--recipient` matches recipients
*and* `orig_to` values, and additionally filters which recipient blocks print. `--time` is compared against
**arrival time only** — a message that arrived at 23:59 and delivered at 00:02 is found only by the arrival
window.

#### The log format it parses

Only `postfix/*` and `amavis*` lines (`zmmsgtrace:379`). `policyd-spf`, `zmmailboxd`, `nginx`, `slapd`,
`opendkim`, `clamd` and `saslauthd` lines are **ignored**.

The master syslog regex (`zmmsgtrace:366-374`):

```perl
                $line =~ /(^\w{3} \s [\s\d]\d \s \d{2}:\d{2}:\d{2})\s
                    (?:<[^>]+> \s)?
                    (\S+)\s
                    ([^[]+)\[(\d+)\]:\s
                    (?:\[ID \s \d+ \s \w+\.\w+\] \s)?
                    (.*)$/x
```

Captures: 1 `log_date` (`Mmm DD HH:MM:SS` — **no year, no timezone**), 2 `host`, 3 `app`, 4 `pid`, 5 `msg`.
The optional `<mail.info>` group handles FreeBSD; the optional `[ID nnn fac.pri]` group handles Solaris.

Queue-ID regex, handling both classic and `enable_long_queue_ids` forms (`zmmsgtrace:150-161`):

```perl
my $REGEX_POSTFIX_QID = qr{(?:${SF_QID_CHAR}{6,}+|${LF_QID_TIME_CHAR}{10,}z${LF_QID_INODE_CHAR}++)};
```

Key per-line handlers:

| Line | Regex | Captures |
|---|---|---|
| dispatcher | `^(${REGEX_POSTFIX_QID}\|NOQUEUE): (.*)` (`:383-384`) | qid-or-`NOQUEUE`, rest. Records keyed `qid:host`, so multi-MTA logs don't collide |
| `smtpd` reject | `^RCPT\sfrom\s([^[]+)\[(.*)\]\:\s([^;]+)\;\sfrom=<(.*?)>\sto=<(.*?)>` (`:405-419`) | client host, client IP, refusal text, sender, recipient |
| `qmgr` removed | `^removed` (`:428`) | **the only completion trigger** — a still-deferred queue entry is never emitted |
| `cleanup` | `^message-id=<([^>]+)>` (`:436`) | message-id; also sets `arriveTime` to the **cleanup** timestamp |
| `smtpd` client | `^client=([^[]+)\[(.*)\]` (`:440`) | reverse-DNS host, IP |
| `qmgr` from | `^from=<(.*)>, size=(\d+)` (`:444`) | sender (empty ⇒ `postmaster`), size |
| `smtp`/`lmtp` | `^to=<([^>]*)>(?:, \s orig_to=<([^>]*)>)?,\s relay=([^[,]+)(?:\[(.*?)\](:\d+))?,\s delay=\S+, \s delays=\S+, \s dsn=\S+ \s status=(\S+) \s (.*)` (`:450-456`) | 1 recipient, 2 orig_to, 3 relay host, 4 relay IP, 5 relay port, 6 status, 7 server response |

From group 7 it extracts `nextQueueId` via `/ queued as ([^ )]+)/` — **this is what chains hops** — and
`amavisId` via `/ id=([^ ,]+)/`. Note `nextHost = $3.$5` and `nextIp = $4.$5`, so **the port is glued onto
both**.

#### Output format

**No header row and no column separator** — a free-form indented report.

```
Tracing messages

Message ID 'CAabc123@example.com'
alice@example.com -->
→   bob@zimbra.local
  Recipient bob@zimbra.local
  Jul 29 10:15:01 - mx.example.com (203.0.113.10) --> 127.0.0.1:10024 (127.0.0.1:10024) status sent
  Jul 29 10:15:02 - mail --> mail.zimbra.local:7025 (10.0.0.5:7025) status sent

```

(The `→` marks a literal **TAB**; every other indent is two spaces.)

The hop line (`zmmsgtrace:695-703`):

```perl
    print( $indent, "$at - $ph ",
        ( $pi ? "($pi) "     : "" ),
        ( $nh ? "--> $nh "   : "" ),
        ( $ni ? "($ni) "     : "" ),
        ( $st ? "status $st" : "" ), "\n",
    );
    print( $indent, "  ", $ref->{statusMsg}, "\n" )
      if ( $ref->{statusMsg} and ( !$st or $st ne "sent" ) );
```

Grammar: `"  " <arriveTime> " - " <prevHost> [" (" prevIp ")"] [" --> " nextHost] [" (" nextIp ")"]
["status " status]`. The `statusMsg` detail line is **suppressed for `status=sent`**. A loopback client IP
collapses to the syslog hostname with no IP.

Rejects and bounces render as:

```
Message ID '[reject:NOQUEUE:mail]'
spam@bad.tld -->
→   victim@other.tld
  Recipient victim@other.tld
  Jul 29 10:20:10 - unknown (198.51.100.9) status reject
    554 5.7.1 <spam@bad.tld>: Relay access denied
```

**`leaveTime` is computed but deliberately never printed** — the source says so (`zmmsgtrace:693`):
`# XXX: Show $lt to indicate time in queue? Would break the output syntax.` If the TUI wants time-in-queue, it
must reimplement.

**Exit code is 0 on a successful run regardless of whether anything matched.** An unopenable file `die`s with
`zmmsgtrace: unable to open file '...'` on stderr.

#### Two defects worth knowing

**1 — the amavis line is dead code.** `zmmsgtrace:562` reads `my $id = $12 || $1;` but the amavis regex has
only **11** capture groups, so `$12` is always `undef` and `%amav` is keyed by the amavis task id
(`<pid>-<seq>`). `printRecip` looks it up by the **Postfix** queue id (`:680-681`). The
`... Passed by amavisd on <host>(CLEAN) hits: ... in ... ms` line therefore never prints with standard Zimbra
amavis output. **Do not build a TUI feature on it.**

**2 — the year is guessed once, globally, from the local clock.** Syslog has no year, so
(`zmmsgtrace:235-241`):

```perl
    else {
        $opt{year} = localtime->year() + 1900;
    }
```

That single year is stamped onto **every** timestamp (`:180-198`). Consequences:

- Searching a **rotated** log from last year with `-t 2025…` silently returns **nothing**. `--year 2025` is
  the only fix.
- `--year` is one scalar for all files, so **you cannot trace across a New-Year boundary in one invocation**.
- No timezone handling at all — timestamps are opaque local wall-clock strings. Remote-host logs filter in
  *that* host's local time. No DST awareness.

**Recommendation:** do not shell out to `zmmsgtrace` for time-bounded queries that cross a rotation boundary.
Either derive the year per file from its mtime and pass `--year` per invocation, or reimplement using the
regexes above — they are the genuinely valuable part of this script.

### B.12 `zmcontrol -v` and `zmcontrol status`

**Must run as `zimbra`.** The check is the first executable statement, before option parsing
([`zm-core-utils/src/bin/zmcontrol:19-23`](https://github.com/Zimbra/zm-core-utils/blob/develop/src/bin/zmcontrol)):

```perl
my $id = qx(id -u -n);
chomp $id;
if ($id ne "zimbra") {die "Run as the zimbra user!\n";}
```

So **even `zmcontrol -v` fails as root** with exit 255. A TUI running as root must
`su - zimbra -c '/opt/zimbra/bin/zmcontrol ...'`.

#### `zmcontrol -v`

Exits **0** (`zmcontrol:189`). The string is **not read from a version file** — it is assembled from the
package manager, the platform tag, a file-existence test and `/opt/zimbra/.install_history`
(`zmcontrol:536-638`):

| Piece | Source |
|---|---|
| platform tag | `qx(/opt/zimbra/libexec/get_plat_tag.sh)` |
| release | Debian/Ubuntu `dpkg -s zimbra-core \| egrep '^Version:'`; RPM `rpm -q --queryformat "%{version}_%{release}" zimbra-core` |
| `NETWORK` vs `FOSS` | **mere existence of `/opt/zimbra/bin/zmbackupquery`** |
| patch level | parsed from `/opt/zimbra/.install_history` |

Shapes (the literal depends on the installed package):

```
Release 8.8.15.GA.3869.UBUNTU18.64 UBUNTU18_64 FOSS edition.
Release 9.0.0.GA.4571.UBUNTU20.64 UBUNTU20_64 NETWORK edition, Patch 9.0.0_P39.
```

Always one line, always exactly one trailing period, always ending `edition.` or `_P<n>.`. The VMware-appliance
branch emits **two** lines (`ZCA Release …` then `ZCS Build …`). For non-9.0.0 builds with a patch, the **micro
version is replaced by the patch number** — `Release <maj>.<min>.<patch>.<rtype>.<build>.<platform> … edition.`

> **Never use `--version` or `--help`.** The script uses `Getopt::Std` (`getopts('vhH:')`), which has **no long
> options**. `--version` leaves `%GlobalOpts` empty, emits Getopt::Std boilerplate to stderr, falls through to
> `usage()` — which happens to call `displayVersion()` first — and exits **1**. So it does print the version,
> but wrapped in noise, on mixed streams, with the wrong exit code. **`-v` only.**

#### `zmcontrol status`

([`zmcontrol:236-262`](https://github.com/Zimbra/zm-core-utils/blob/develop/src/bin/zmcontrol)):

```perl
	print "Host $localHostName\n";
	foreach (sort keys %{$services}) {
…
		my $rc = 0xffff & system ("$allservices{$_} status > $statusfile 2> $errfile");
		$rc = $rc >> 8;
…
			$stat = sprintf "\t%-20s %10s\n",$_,($rc)?"Stopped":"Running";
		}
		print "$stat";
		if ($rc) {
			open (ST, "$statusfile") or next;
			foreach my $s (<ST>) {
				print "\t\t$s";
			}
```

```
Host mail.example.com
→   amavis                  Running
→   ldap                    Running
→   mailbox                 Running
→   mta                     Running
→   service webapp          Running
→   stats                   Stopped
→   →   zmstat is not running.
→   zimbra webapp           Running
→   zmconfigd               Running
```

(`→` = literal TAB.)

- Header `Host <hostname>` where `<hostname>` is localconfig `zimbra_server_hostname`.
- Per service: `sprintf "\t%-20s %10s\n"` — one **TAB**, name padded to 20, one space, then `Running`/`Stopped`
  right-justified in 10 (both words are 7 chars, so **3 leading spaces**).
- Ordering is **alphabetical**, not start-order.
- Four services get ` webapp` appended: `service`, `zimbra`, `zimbraAdmin`, `zimlet`.
- When a service is down, the ctl script's **stdout** is echoed, each line prefixed with **two TABs**.
- Only LDAP-enabled services on this host are listed, plus `zmconfigd`, which is forced in.

Parser: `^\t(?<name>.{1,20}?)\s+(?<state>Running|Stopped)$`, detail lines match `^\t\t`.

**Exit codes:**

| Situation | Exit |
|---|---|
| everything up | 0 |
| a **monitored** service down | 1 |
| **`stats`/`snmp`/`logger`/`spell` down** | **0** |
| services not determinable | 1 |
| 180 s alarm fired | 1 (prints `Timeout after 180 seconds` on **stdout**) |
| run as non-`zimbra` | 255 |
| `-h`, `--help`, `--version`, unknown command | 1 |

The carve-out is real (`zmcontrol:411-420`): `@services = grep(!/stats|snmp|logger|spell/, keys %allservices)`
when `zmcontrol_service_status_list` is unset — and that localconfig key is **not defined anywhere in either
repo**, so the fallback is what runs on a stock install. **A TUI branching on the exit code will see 0 even
while the text shows `stats  Stopped`. Parse the text.**

> **`zmcontrol status` is NOT filesystem-clean.** It starts and stops nothing, but it does write:
> 1. `mkpath($zimbra_tmp_directory)` if missing (`zmcontrol:37-39`);
> 2. two temp files per invocation, created by shell redirection and `unlink`ed at the end (`:229-230`, `:245`,
>    `:267-268`) — note `OPEN=>0` is a documented `File::Temp` race, so two concurrent runs could collide;
> 3. **rewrites `/opt/zimbra/log/.zmcontrol.cache`** on every successful LDAP lookup (`:518-524`);
> 4. `/opt/zimbra/bin/ldap status` unconditionally `mkdir -p`s `…/state/run/` at script top level
>    (`ldap.production:23-27`);
> 5. `postfix status` will `touch` and rewrite `main.cf` **if it is absent** (`bin/postfix:38-43`) — normally a
>    no-op.
>
> If the tool's contract is "touches nothing on disk", `zmcontrol status` violates it. The strictly-read-only
> alternative is to call the individual `*ctl status` scripts (mostly pure `ps`/pid-file reads) or read
> `.zmcontrol.cache` plus pid files directly.

**Subprocesses.** One `<script> status` per enabled service, serially. Several use pre-authorised sudo —
`zmmailboxdctl status` runs `sudo /opt/zimbra/libexec/zmmailboxdmgr`, and `postfix status` runs
`sudo /opt/zimbra/libexec/zmmtastatus` (which itself requires root). Both are covered by the shipped sudoers
drop-ins `02_zimbra-store` and `02_zimbra-mta`. **If those drop-ins are missing, `mailbox` and `mta` report
`Stopped` spuriously** — worth a TUI diagnostic.

**Timing.** `alarm(180)` is armed at `:228` — but **after** `getEnabledServices()` and
`getServiceStatusList()`. LDAP connect has its own 30 s timeout; the subsequent `start_tls`/`bind`/`search`
have **none**, so a hung LDAP master can block `zmcontrol status` **indefinitely before the alarm is ever
set**. `zmconfigd`'s check alone can burn 15 s (`nc -w 15`). Typical is ~2–10 s on a full single-server
install. **Wrap it in your own 30–60 s wall-clock timeout.**

### B.13 LDAP generalized time

**The fractional-second part is server-configuration-dependent, not attribute-dependent — with exactly one
exception.**

There are two format constants and a runtime switch between them
([`LdapDateUtil.java:29-45`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/ldap/LdapDateUtil.java#L29)):

```java
    public static final String ZIMBRA_LDAP_GENERALIZED_TIME_FORMAT_LEGACY = "yyyyMMddHHmmss'Z'";
    public static final String ZIMBRA_LDAP_GENERALIZED_TIME_FORMAT_WITH_MS = "yyyyMMddHHmmss.SSS'Z'";

    public static String toGeneralizedTime(Date date) {
        boolean enabled = false;
        Server server = Provisioning.getInstance().getLocalServerIfDefined();
        enabled = server == null ? false : server.isLdapGentimeFractionalSecondsEnabled();
        if (enabled) {
            return toGeneralizedTimeWithMs(date);
        } else {
            return toGeneralizedTimeLegacyFormat(date);
        }
    }
```

The gate is `zimbraLdapGentimeFractionalSecondsEnabled`
([`zimbra-attrs.xml:8946-8950`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/conf/attrs/zimbra-attrs.xml)):

```xml
  <globalConfigValue>TRUE</globalConfigValue>
  <globalConfigValueUpgrade>FALSE</globalConfigValueUpgrade>
  <desc>Whether to include fractional seconds in LDAP gentime values … Releases prior to 8.7 are unable to
  parse gentime values which include fractional seconds; therefore this value must remain set to FALSE in
  environments where any release 8.6 or lower is present.</desc>
```

**This is why `20260728064034.819Z` was observed.** Fresh installs default to `TRUE`; only servers *upgraded*
from ≤8.6 get `FALSE`. Same definition and defaults at 8.8.15.p47-v1 and 10.1.18.

**A parser must accept both forms**, because a single directory can hold a mix: values written before the flag
was flipped keep their old form forever (nothing rewrites them), and `getLocalServerIfDefined()` returning
`null` silently produces the legacy form regardless of config.

**The one attribute-specific exception:** `zimbraAutoProvLastPolledTimestamp` always carries `.SSS`, bypassing
the gate ([`AutoProvisionEager.java:200`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ldap/AutoProvisionEager.java#L200)) —
the only external caller of `toGeneralizedTimeWithMs`.

**Always UTC with a literal `Z`**; the offset is applied by hand rather than via `setTimeZone`
([`LdapDateUtil.java:58-68`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/ldap/LdapDateUtil.java#L58)).
The fraction is `.SSS` — exactly three zero-padded digits. `.819Z` and `.000Z` are possible; `.19Z` is not.

**Three different grammars are in play — do not confuse them:**

| Role | Accepts | Source |
|---|---|---|
| **Writer** | exactly 0 or 3 fraction digits, always `Z` | `LdapDateUtil.java:29-31` |
| **Validator** (on write) | `^\d{14}(\.\d{1,3})?[zZ]$` | [`AttributeInfo.java:47-48`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/AttributeInfo.java#L47) |
| **Parser** (on read) | ≥14 digits, any fraction length (micros truncated), `Z` **optional** | [`DateUtil.java:598-649`](https://github.com/Zimbra/zm-mailbox/blob/develop/common/src/java/com/zimbra/common/util/DateUtil.java#L598) |

The parser's javadoc gives real examples: `20150527191216GMT`, `20150527191216.000040Z`,
`20150610215759.659Z`. **Trap: a value with no trailing `Z` is interpreted in the JVM's default timezone**, not
UTC. Treat non-`Z`-suffixed gentime as suspect.

Recommended read-side regex:
`^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(?:\.(\d+))?([Zz])?$`, treating a missing `Z` as ambiguous.

LDAP syntax is RFC 4517 Generalized Time, OID `1.3.6.1.4.1.1466.115.121.1.24`
([`AttributeManagerUtil.java:432-436`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/AttributeManagerUtil.java#L432)).

#### Which attributes use it

**21 attributes** are `type="gentime"` in develop/10.1.18 (19 in 8.8.15; the additions are
`zimbraTrialExpirationDate` and `zimbraDomainTrialExpirationDate`). The ones an admin TUI would show:

| Attribute | Card. | Meaning |
|---|---|---|
| `zimbraCreateTimestamp` | single | created |
| `zimbraLastLogonTimestamp` | single | last logon (**ephemeral**, throttled — see below) |
| `zimbraPasswordModifiedTime` | single | password changed |
| `zimbraPasswordLockoutLockedTime` | single | when locked out |
| `zimbraPasswordLockoutFailureTime` | **multi** | one value per failed login in the window — renders as repeated lines |
| `zimbraQuotaLastWarnTime` | single | last over-quota warning |
| `zimbraPrefOutOfOfficeFromDate` / `…UntilDate` | single | vacation window |

Others: `zimbraPrefPop3DownloadSince`, `zimbraExternalAccountDisabledTime`, `zimbraTrialExpirationDate`,
`zimbraTwoFactorAuthLastReset`, `zimbraTwoFactorAuthLockoutFailureTime` (multi),
`zimbraDomainTrialExpirationDate`, `zimbraAutoProvLastPolledTimestamp`,
`zimbraGalDefinitionLastModifiedTime`, `zimbraGalLastSuccessfulSyncTimestamp`,
`zimbraGalLastFailedSyncTimestamp`, `zimbraDataSourceFailingSince`, `zimbraVersionCheckLastAttempt`,
`zimbraVersionCheckLastSuccess`.

**Time-ish names that are NOT gentime — do not parse these as timestamps:**

- `zimbraLastLogonTimestampFrequency` — `type="duration"` (e.g. `7d`). Very easy to confuse with
  `zimbraLastLogonTimestamp`.
- `zimbraGalSyncTimestampFormat` — `type="string"`, and it holds a *pattern* (default `yyyyMMddHHmmss'Z'`).
- `zimbraFeatureContactBackupLifeTime`, `zimbraMailIdleSessionTimeout`, `zimbraIndexingQueueTimeout` — durations.
- `zimbraAuthTokens` — `type="string"`, encoded `tokenId|expirationMillis|serverVersion`; the expiry is
  **epoch millis**, not gentime.
- **There is no `zimbraLastLogonTime`** attribute — only `…Timestamp`.

OpenLDAP's own `createTimestamp`/`modifyTimestamp` are **not** returned by `zmprov ga`.

#### The ephemeral store

`zimbraLastLogonTimestamp` is the only gentime attribute flagged `ephemeral` (the others are `zimbraAuthTokens`,
`zimbraCsrfTokenData`, `zimbraInvalidJWTokens`).

**It does not change the format** — the writer still calls `LdapDateUtil.toGeneralizedTime`
([`ZAttrAccount.java:28275`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ZAttrAccount.java)),
and for a non-dynamic, non-expiring key the value is stored verbatim with no wrapper.

**It does change where the value comes from.** With the default backend (`zimbraEphemeralBackendURL` =
`ldap://default`) the value lives in LDAP and `getEphemeralAttrs()` short-circuits
([`Entry.java:381-389`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/Entry.java#L381)):

```java
            if (ephemeralFactory == null || ephemeralFactory instanceof LdapEphemeralStore.Factory) {
                //Short-circuit for LDAP backends, since the data will already be in mAttrs.
                //This also catches scenarios where the EphemeralStore is not available.
                return attrs;
            }
```

With a non-LDAP backend (e.g. SSDB) the value is fetched live and merged in, so `zmprov ga` still shows it —
**but failures are swallowed**
([`Entry.java:415-418`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/Entry.java#L415),
`// don't propagate this exception`). With an unreachable ephemeral store the attribute **silently vanishes**
from `ga` output. **Treat "absent" as "unknown", never as "never logged in".**

**Staleness.** `updateLastLogon` writes at most once per `zimbraLastLogonTimestampFrequency` and never if that
is `0` ([`LdapProvisioning.java:5602-5620`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ldap/LdapProvisioning.java#L5602)).
The attribute's own description calls it a *"rough estimate"*.

### B.14 Version differences

**None that affect any format in this document.** `ProvUtil.java` print paths (`dumpAttrs`, `printAttr`,
`printOutput`, `doGetMailboxInfo`, `doGetAccountMembership`, `doGetAccount`, `dumpAccount`, `dumpCos`,
`dumpGroup`, `dumpDomain`) are byte-identical across `8.8.15.p47-v1`, `9.0.0`, `10.0.14`, `10.1.18` and
`develop`. 8.8.15.p47-v1 and 9.0.0 are identical whole files.

`ZMailboxUtil.java` is byte-identical across all four tags and develop (same MD5, 131 785 bytes, 3042 lines),
as are `ZFilterRule.java`, `ZFolder.java`, `ZSearchResult.java`, `ZMessage.java`, `ZJSONObject.java`.
`LdapDateUtil.java` is likewise unchanged.

**You can hard-code one parser for 8.8.15 through 10.1.x.** No version detection is needed for any command
covered here.

**Caveat:** these are upstream `develop`/tag sources. Zimbra NE/Daffodil 10.x binaries and vendor-patched
8.8.15 builds are not fully represented by the public repo. Nothing observed suggests divergence, but confirm
with one `zmprov gmi` on each targeted build.

---

## C. `zmprov -l` (LDAP mode) limits

### C.1 Which subcommands work in `-l` mode

There are **two separate rejection mechanisms**, with different messages, different streams and different exit
codes.

**Mechanism 1 — static `Via`, checked before dispatch.** A command may declare `Via.ldap` or `Via.soap`
([`ProvUtil.java:1057-1082`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L1057)):

```java
    private Command.Via violateVia(Command cmd) {
        Command.Via via = cmd.getVia();
        if (via == null) {
            return null;
        }
        if (via == Command.Via.ldap && !(prov instanceof LdapProv)) {
            return Command.Via.ldap;
        }
        if (via == Command.Via.soap && !(prov instanceof SoapProvisioning)) {
            return Command.Via.soap;
        }
```

**Exactly eight commands are marked**, and this is the complete list:

| `Via` | Command | Line |
|---|---|---|
| `ldap` — **requires `-l`**, rejected under SOAP | `getAllAccounts` / `gaa` | 630 |
| `ldap` | `renameDomain` / `rd` | 799 |
| `ldap` | `searchCalendarResources` / `scr` | 820 |
| `ldap` | `getAllReverseProxyDomains` / `garpd` | 841 |
| `soap` — rejected under `-l` | `reloadMemcachedClientConfig` / `rmcc` | 845 |
| `soap` | `getMemcachedClientConfig` / `gmcc` | 848 |
| `soap` | `updatePresenceSessionId` / `upsid` | 853 |
| `soap` | `unlockMailbox` / `ulm` | 857 |

Everything else that is SOAP-only — including `gmi`, `gqu`, `gsi`, `flushCache` and the index/logger
families — is caught at runtime by mechanism 2 below, **not** by `Via`.

The message goes to **stdout**, followed by the whole usage block, exit **1**
([`ProvUtil.java:266-270`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L266)):

```
getAllAccounts can only be used with  "zmprov -l/--ldap"
```

Note the **double space** before the quote — that is in the constant
([`ProvUtil.java:149`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L149)):
`ERR_VIA_LDAP_ONLY = "can only be used with  \"zmprov -l/--ldap\""`.

**Mechanism 2 — runtime `throwSoapOnly()`, inside the command implementation.** This is where most SOAP-only
commands are caught
([`ProvUtil.java:5698-5700`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L5698)):

```java
    private void throwSoapOnly() throws ServiceException {
        throw ServiceException.INVALID_REQUEST(ERR_VIA_SOAP_ONLY, null);
    }
```

The message goes to **stderr**, exit **2**:

```
ERROR: service.INVALID_REQUEST (invalid request: can only be used with SOAP)
```

**Complete list of `throwSoapOnly()` sites** (every `zmprov` subcommand that rejects `-l`), obtained by mapping
each call site to its enclosing method:

| Method | Command(s) |
|---|---|
| `execute` → `SELECT_MAILBOX` | `selectMailbox` / `sm` |
| `doGetHab`, `modifyHabGroup`, `modifyHabGroupSeniority`, `doCreateHabGroup` | HAB family |
| `doGetDomainInfo` | `getDomainInfo` / `gdi` |
| **`doGetQuotaUsage`** | **`getQuotaUsage` / `gqu`** |
| **`doGetMailboxInfo`** | **`getMailboxInfo` / `gmi`** |
| `doReIndexMailbox` | `reIndexMailbox` / `ri` |
| `doManageMailboxIndex`, `doCompactIndexMailbox`, `doVerifyIndex`, `doGetIndexStats` | index family (`mi`, `cim`, `vi`, `gis`) |
| `doRecalculateMailboxCounts` | `recalculateMailboxCounts` / `rmc` |
| `doAddAccountLogger`, `doGetAccountLoggers`, `doGetAllAccountLoggers`, `doRemoveAccountLogger`, `doResetAllLoggers` | logger family |
| `doGetShareInfo` | `getShareInfo` / `gsi` |
| `doChangePrimaryEmail` | `changePrimaryEmail` |
| `doGetRightsDoc` | `getRightsDoc` / `grd` |
| `doGetAllActiveServers` | `getAllActiveServers` / `gaas` |
| `doFlushCache` | `flushCache` / `fc` |
| `doPurgeAccountCalendarCache` | `pacc` |
| `doSetServerOffline`, `doSetLocalServerOnline` | server state |

**Everything not in that list and not marked `Via` works under `-l`** — including all of `ga`, `gam`, `gc`,
`gd`, `gs`, `gcf`, `gdl`, `gdlm`, `gaa` (which in fact *requires* `-l`). The commands the TUI's M1 allowlist
uses are therefore: `ga` ✅, `gam` ✅, `gc` ✅, **`gmi` ❌**.

### C.2 Does `-l` expand COS-inherited values?

**Yes, it does. The tool's current assumption is wrong, and the COS fallback is unnecessary.**

This was traced end-to-end.

**1 — `ga` defaults to expanding**
([`ProvUtil.java:2191-2205`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L2191)):

```java
    private void doGetAccount(String[] args) throws ServiceException {
        boolean applyDefault = true;
        …
        dumpAccount(lookupAccount(args[acctPos], true, applyDefault), applyDefault, getArgNameSet(args, acctPos + 1));
```

**2 — the expansion happens client-side, in the `Entry` object**
([`ProvUtil.java:3216`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L3216)):
`Map<String, Object> attrs = account.getAttrs(expandCos);`, and
([`Entry.java:355-370`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/Entry.java#L355)):

```java
    public Map<String, Object> getAttrs(boolean applyDefaults, boolean includeEphemeral) {
        Map<String, Object> attrs = new HashMap<String, Object>();
        if (applyDefaults) {
            // put the second defaults
            if (mSecondaryDefaults != null)
                attrs.putAll(mSecondaryDefaults);
            // put the defaults
            if (mDefaults != null)
                attrs.putAll(mDefaults);
        }
        // override with currently set
        attrs.putAll(mAttrs);
```

**3 — in LDAP mode those defaults are populated when the account is built**
([`LdapProvisioning.java:6597-6622`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ldap/LdapProvisioning.java#L6597)):

```java
        Account acct = (isAccount) ? new LdapAccount(dn, emailAddress, attrs, null, this) : …

        setAccountDefaults(acct, makeObjOpt);
…
    private void setAccountDefaults(Account acct, MakeObjectOpt makeObjOpt) throws ServiceException {
        if (makeObjOpt == MakeObjectOpt.NO_DEFAULTS) {
            // don't set any default
        } else if (makeObjOpt == MakeObjectOpt.NO_SECONDARY_DEFAULTS) {
            acct.setAccountDefaults(false);
        } else {
            acct.setAccountDefaults(true);
        }
    }
```

**4 — and `setAccountDefaults` reads the COS (and the domain)**
([`Account.java:408-431`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/Account.java#L408)):

```java
    public void setAccountDefaults(boolean setSecondaryDefaults) throws ServiceException {

        Cos cos = getProvisioning().getCOS(this); // will set cos if not set yet

        Map<String, Object> defaults = null;
        if (cos != null) {
            defaults = cos.getAccountDefaults();
…
            Domain domain = getProvisioning().getDomain(this);
            if (domain != null)
                secondaryDefaults = domain.getAccountDefaults();
            setDefaults(defaults, secondaryDefaults);
```

**Precedence, from the code above:** account entry > COS defaults > domain defaults.

**Scope of inheritance.** Only attributes flagged `accountInherited` in `zimbra-attrs.xml` participate
([`Cos.java:65-72`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/Cos.java#L65)):

```java
    protected void resetData() {
        super.resetData();
        try {
            getDefaults(AttributeFlag.accountInherited, mAccountDefaults);
```

**SOAP mode reaches the same result by a different route.** `GetAccountRequest` carries `applyCos`, defaulting
to true, and the server merges before responding
([`GetAccount.java:83-88`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/service/admin/GetAccount.java#L83)):

```java
        boolean applyCos = !Boolean.FALSE.equals(req.isApplyCos());
        …
        ToXML.encodeAccount(response, account, applyCos, false, reqAttrs, aac.getAttrRightChecker(account), isEffectiveQuota);
```

**Both modes expand by default. Both suppress expansion with `-e`.** `-e` is handled correctly in LDAP mode:
`lookupAccount` still loads defaults into the entry
([`ProvUtil.java:3539-3554`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L3539),
`if (applyDefault == true || (prov instanceof LdapProv))`), but `dumpAccount` then calls `getAttrs(false)`,
which skips `mDefaults`.

**Action for the tool:** the COS fallback path can be removed. If it is kept as belt-and-braces, note it will
never fire — and if the intent was ever to show *only* explicitly-set attributes, the correct mechanism is
`zmprov ga -e`, in either mode.

### C.3 What else is lost in `-l` mode

- **Right-based attribute hiding.** In SOAP mode the server applies an `AttrRightChecker` and blanks
  attributes the admin may not read; `dumpAttrs` then suppresses them. `-l` binds as the LDAP admin DN and
  bypasses this entirely, so **`-l` can show more than SOAP**.
- **Secret sanitisation.** `VALUE-BLOCKED` substitution happens in the SOAP encoding path
  ([`Provisioning.java:464-481`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/Provisioning.java#L464)).
  Under `-l` you get whatever LDAP holds.
- **Everything requiring mailboxd** — the entire `throwSoapOnly()` list in [C.1](#c1-which-subcommands-work-in--l-mode).
  Most importantly `gmi`, `gqu`, `gsi` and the index/logger families. Anything that is a *mailbox* fact rather
  than a *directory* fact is unavailable.
- **`effectiveQuota`.** `GetAccountRequest` supports an `effectiveQuota` flag that makes the server compute the
  applicable quota; there is no equivalent in `-l`.
- **Ephemeral attributes with a non-LDAP backend.** With the default `ldap://default` backend this is a
  non-issue. With SSDB, whether the `zmprov -l` JVM initialises the ephemeral store factory at all is
  **UNKNOWN** — see the final section.
- **CRLF normalisation.** XML 1.0 requires CRLF→LF normalisation, so a value stored with CRLF would likely
  arrive as LF over SOAP but as CRLF via `-l`. Not confirmed in code — see the final section.

### C.4 What `-l` requires

- **LDAP reachability.** Replica URLs come from the `ldap_url` localconfig key (space-separated); `-m`/`--master`
  switches to `ldap_master_url`
  ([`LdapServerConfig.java:181, 199`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/ldap/LdapServerConfig.java#L181)).
- **Credentials from localconfig.** Binds as `zimbra_ldap_userdn` (default `uid=zimbra,cn=admins,cn=zimbra`)
  with `zimbra_ldap_password`
  ([`LdapServerConfig.java:156-157`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/ldap/LdapServerConfig.java#L156)).
  `zimbra_ldap_password` is declared `.protect()`
  ([`LC.java:96`](https://github.com/Zimbra/zm-mailbox/blob/develop/common/src/java/com/zimbra/common/localconfig/LC.java#L96)),
  so it is not printed by a bare `zmlocalconfig`. Reading it requires being the `zimbra` user (or root).
- **It does NOT require mailboxd**, and it does **not** require running on the LDAP node. Any node that can
  reach `ldap_url` and read localconfig works. This is exactly the property the TUI's fallback depends on, and
  it holds.
- **StartTLS** is negotiated per `ldap_starttls_supported` / `ldap_starttls_required` /
  `zimbra_require_interprocess_security` ([`LdapServerConfig.java:163-168`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/ldap/LdapServerConfig.java#L163)).
- **`-L`/`--logpropertyfile`** is valid only with `-l`; `-m`/`--master` likewise.

**One trap worth knowing:** the default mode is itself a localconfig key
([`ProvUtil.java:165`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L165)):

```java
    private boolean useLdap = LC.zimbra_zmprov_default_to_ldap.booleanValue();
```

It defaults to `false` ([`LC.java:130`](https://github.com/Zimbra/zm-mailbox/blob/develop/common/src/java/com/zimbra/common/localconfig/LC.java#L130)),
so `zmprov` normally uses SOAP — **but a site can flip it, and then a bare `zmprov gmi` fails with
`can only be used with SOAP` for reasons that have nothing to do with the command line.** A tool that wants
deterministic behaviour should pass the mode explicitly rather than relying on the default.

---

## D. Operational facts for later milestones

### D.1 Multi-server: does `zmmailbox -z -m` proxy to `zimbraMailHost`?

**Yes. It follows the account's `zimbraMailHost` by itself. You do not have to run it on that host.**

The client asks the server where the account lives and then talks to that host directly
([`ZMailboxUtil.java:626-628`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L626)):

```java
            SoapAccountInfo sai = prov.getAccountInfo(authBy, authAccount);
            DelegateAuthResponse dar = prov.delegateAuth(authBy, authAccount, …);
            options = new ZMailbox.Options(dar.getAuthToken(), sai.getAdminSoapURL());
```

The server computes that URL from the account's mail host
([`GetAccountInfo.java:90-108`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/service/admin/GetAccountInfo.java#L90)):

```java
        Server server = Provisioning.getInstance().getServer(account);
        …
        String adminUrl = URLUtil.getAdminURL(server);
        if (adminUrl != null)
            response.addNonUniqueElement(AdminConstants.E_ADMIN_SOAP_URL).setText(adminUrl);
```

and `getServer(account)` is literally a `zimbraMailHost` lookup
([`Account.java:249-252`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/Account.java#L249)):

```java
    public Server getServer() throws ServiceException {
        String serverName = getAttr(Provisioning.A_zimbraMailHost);
        return (serverName == null ? null : getProvisioning().get(Key.ServerBy.name, serverName));
    }
```

So `adminSoapURL` = `https://<mailhost's zimbraServiceHostname>:<its zimbraAdminPort>/service/admin/soap/`, and
that URL is handed straight to a new transport
([`ZMailbox.java:958-962`](https://github.com/Zimbra/zm-mailbox/blob/develop/client/src/java/com/zimbra/client/ZMailbox.java#L958)).

**Network requirement:** the node running the TUI must reach *a* mailboxd admin port (default
`https://localhost:7071`) for the initial admin auth, **and** the target account's mail host on its admin port.

**`zmprov` in SOAP mode** needs a mailboxd on 7071 locally (or `-s host[:port]`), but **which** mailbox node
does not matter — LDAP is global, and mailbox-scoped admin commands auto-proxy server-side
([`AdminDocumentHandler.java:609-618`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/service/admin/AdminDocumentHandler.java#L609)).
`GetMailbox` (i.e. `gmi`) opts into that proxying via `getProxiedAccountPath()`.

**`zmprov -l`** needs neither mailboxd nor a particular node — see [C.4](#c4-what--l-requires).

**`zmmetadump` is the exception:** it must run on the mailbox's own host — see
[A.5](#a5-is-zmmetadump-read-only).

#### `zimbraMailHost` vs `zimbraMailTransport`

| | `zimbraMailHost` | `zimbraMailTransport` |
|---|---|---|
| Description | *"the server hosting the account's mailbox"* | *"where to deliver parameter for use in postfix transport_maps"* |
| Consumed by | SOAP/admin layer, for proxying and `adminSoapURL` | Postfix `transport_maps` LDAP lookup |
| Format | a `zimbraServiceHostname` | `lmtp:<host>:<port>` |

Kept in sync by an attribute callback
([`MailHost.java:99-110`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/callback/MailHost.java#L99)); setting both in one request is rejected.
**For reaching a mailbox only `zimbraMailHost` matters; for explaining why a message routed somewhere,
`zimbraMailTransport` is what Postfix actually used — and a mismatch is a real, diagnosable
misconfiguration.**

### D.2 Search query language — quoting and escaping

Grammar: `store/src/java/com/zimbra/cs/index/query/parser/Parser.jjt` (JavaCC/JJTree).

#### The escaping rule

**A literal double quote inside a quoted term is escaped with a BACKSLASH (`\"`). Not by doubling.**

([`Parser.jjt:44-51`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/index/query/parser/Parser.jjt)):

```
|   <QUOTED_TERM: "\"" (<_ESCAPED_QUOTE> | ~["\n", "\""])* "\"">  : DEFAULT
|   <#_ESCAPED_QUOTE: "\\\"">
```

`"\\\""` is JavaCC for the two characters **backslash + double-quote**. Confirmed by the unescaper
([`QueryParser.java:491-503`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/index/query/parser/QueryParser.java#L491)):
`token.image.substring(1, token.image.length() - 1).replaceAll("\\\\\"", "\"")`, and by Zimbra's own escaper
([`Query.java:122-134`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/index/query/Query.java#L122)):

```java
                if (ch == '"') {
                    buf.append("\\\"");
                } else {
                    buf.append(ch);
                }
```

Inside a `"…"` term:

| Character | Status |
|---|---|
| `"` | **must** be written `\"` |
| newline | **cannot appear** — excluded by `~["\n", "\""]`; the query will not lex |
| `\` alone | **literal.** Backslash is *not* a general escape; only the exact 2-char sequence `\"` is special |
| `( ) : + - * ? & \| ! { } @` | all literal inside quotes |
| space, tab | literal inside quotes |

> **The project's current `zro_query_quote` (design spec §5.4) is wrong on one point.** It does
> `s=${s//\\/\\\\}` — doubling backslashes. Zimbra's unescaper only ever collapses `\"`; a doubled backslash is
> **not** collapsed, so `C:\path` would be searched as `C:\\path`. The correct rule is Zimbra's own: escape
> `"` as `\"`, leave every other character alone, and separately **reject a trailing backslash** (which would
> consume the closing quote and break the lexer) and **reject embedded newlines**. The existing rejection of
> control characters and newlines before this point already covers the second.

#### Special characters at top level

([`Parser.jjt:27-42`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/index/query/parser/Parser.jjt)):
`(` and `)` are active in **every** lexical state; `and`/`&&`, `or`/`||`, `not`/`!` are boolean operators
(case-insensitive); `+` and `-` are modifiers; `:` is the field separator; `{` `}` delimit `BRACED_TERM` (used
after `item:`). Only space and tab are skipped — a bare newline anywhere in a query is a lexer error.

Two subtleties:

1. **Longest-match beats keywords.** `!foo` lexes as one TERM, because `!` is a legal term start character. But
   a *bare* `and`/`or`/`not` at top level is an operator, so searching for the literal word `and` unquoted is a
   syntax error.
2. **Field tokens flip the lexer to a `TEXT` state** where the boolean keywords are undefined — which is why
   `from:and` works ([`QueryParserTest.java:522-525`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java-test/com/zimbra/cs/index/query/QueryParserTest.java#L522)).
   But `(` is state-independent and switches **back** to DEFAULT, so `from:(and)` re-enables the keyword.

#### Operator semantics

| Operator | Semantics |
|---|---|
| `from:` | Lucene text on `L_H_FROM`; a leading `<`/`>`/`<=`/`>=` makes it a **sender range** DB query |
| `to:` / `cc:` / `envto:` / `envfrom:` | Lucene text on the matching header; **a leading `@` makes it a whole-domain match** (`DomainQuery`) |
| `tofrom:` | address query over `{TO, FROM}`. Also `tocc:`, `fromcc:`, `tofromcc:` |
| `subject:` | Lucene text on `L_H_SUBJECT`; a leading `<`/`>` makes it a **subject range** query |
| `content:` | Lucene text on `L_CONTENT`; becomes `(ContactQuery OR content)` when CONTACT is in the search types |
| `filename:` | Lucene text on `L_FILENAME` |
| `attachment:` | maps a friendly name to MIME types and ORs them — `any`, `pdf`, `word`/`msword`, `excel`/`xls`, `ppt`/`powerpoint`, `image`, `jpeg`, `gif`, `bmp`, `text`, `application`, `ms-tnef`, `none`, plus `type/*` and full MIME forms |
| `has:` | object presence. **Exact accepted set: `attachment`, `att`, `phone`, `u.po`, `ssn`, `url`** — nothing else |
| `in:` | exact folder; `inbox`/`trash`/`junk`/`sent`/`drafts`/`contacts` resolve to well-known ids first, else by path |
| `under:` | as `in:` but **includes sub-folders** |
| `is:` | fixed table; unknown value is an error. Full set: `read, unread, flagged, unflagged, draft, received, replied, unreplied, forwarded, unforwarded, invite, anywhere, local, remote, solo, sent, tome, fromme, ccme, tofromme, toccme, fromccme, tofromccme` |
| `larger:` | **alias of `bigger:`** — same token. Size greater than |
| `smaller:` | size less than |
| `size:` | equals; the value may carry `>`/`<`/`=`. Units: bare = bytes, `k`/`kb` ×1024, `m`/`mb` ×1024², `g`/`gb` ×1024³ |
| `before:` / `after:` | strictly `<` / `>`. An explicit `<`/`>` prefix in the value is **rejected** for these two |
| `date:` | equality over the whole day. Pure digits = epoch **milliseconds**; relative `[+-]N[mi\|m\|h\|d\|w\|y\|…]`; `today`/`yesterday`; else an absolute date parsed with the request locale's `DateFormat.SHORT`, falling back to `mm/dd/yyyy` |

Relative dates are **truncated to the unit boundary** — `date:-1d` means midnight-to-midnight yesterday. Date
terms are special-cased in the grammar so a leading `-` is **not** a NOT
([`Parser.jjt:216-225`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/index/query/parser/Parser.jjt)).

#### `is:anywhere`, and the default scope trap

**Default search excludes Trash and Junk/Spam.** The prefs that control it default to FALSE
(`zimbra-attrs.xml:611-621`, `zimbraPrefIncludeSpamInSearch` / `zimbraPrefIncludeTrashInSearch`), and the
exclusion is applied in
[`ZimbraQuery.java:604-635`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/index/ZimbraQuery.java#L604) →
[`DBQueryOperation.java:201-218`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/index/DBQueryOperation.java#L201).

**`is:anywhere` is purely an override of that exclusion. It does not widen the search to other mailboxes.**
([`DbSearchConstraints.java:911-922`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/index/DbSearchConstraints.java#L911)):

```java
        void addAnyFolder(boolean bool) {
            // support for "is:anywhere" basically as a way to get around
            // the trash/spam autosetting
            forceHasSpamTrashSetting();
```

It applies **per query part**, not globally (`DbSearchConstraints.java:1270-1283`) — so
`(tag:foo is:anywhere) or (tag:bar)` still excludes trash/spam from the second half. Corroborated by the
official wiki: *"is:anywhere: in any folder (overrides spam-trash setting for that query part)"*
(https://wiki.zimbra.com/wiki/Zimbra_Web_Client_Search_Tips).

> **A "did this message arrive?" search MUST append `is:anywhere`** (or explicitly name `in:trash` /
> `in:junk`), or it will silently miss spam-foldered and deleted mail. This is the single most common
> false-negative in delivery tracing. Naming the Trash/Spam folder explicitly also drops the exclusion
> automatically.

#### Wildcards

**`*` only, trailing only — and it does work inside quotes.**
([`TextQuery.java:108-120`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/index/query/TextQuery.java#L108)):

```java
        if (quick || text.endsWith("*")) { // wildcard, must look at original text here b/c analyzer strips *'s
            // only the last token is allowed to have a wildcard in it
```

The test runs on the **de-quoted** text, so `subject:"quarterly report*"` is a phrase query with a wildcard on
the last token. Mid-string `*` is **not** a wildcard — it is stripped by the analyzer and the star is simply
lost. **`?` is not a wildcard anywhere** in this language; it is an ordinary term character. Expansion is
capped by `zimbra_index_wildcard_max_terms_expanded` (default 20000).

### D.3 Log files for delivery tracing

#### The files

| Path | Purpose | Written by |
|---|---|---|
| `/var/log/zimbra.log` | **Postfix + amavis + auth** — the primary delivery trace | the **syslog daemon** |
| `/opt/zimbra/log/mailbox.log` | mailboxd general log **and the root logger's sink** — so **LMTP final-delivery lines land here** | mailboxd (as `zimbra`) |
| `/opt/zimbra/log/audit.log` | auth successes/failures, admin actions (incl. `DelegateAuth`) | mailboxd |
| `/opt/zimbra/log/sync.log` | ActiveSync | mailboxd |
| `/opt/zimbra/log/zmmailboxd.out` | raw mailboxd stdout/stderr, stack traces | the JVM |
| `/opt/zimbra/log/nginx.log`, `nginx.access.log` | proxy | nginx (as `zimbra`) |
| `/opt/zimbra/log/access_log.YYYY-MM-DD` | Jetty request log | mailboxd |
| `/opt/zimbra/log/clamd.log`, `freshclam.log` | AV | clamd / freshclam |

**Important:** `zimbra.lmtp`, `zimbra.smtp`, `zimbra.filter` and `zimbra.mailop` have **no dedicated
appender** — they fall through to the root logger, whose only sink is `mailbox.log`. There is no separate LMTP
log.

`/var/log/zimbra.log` receives three facilities
([`zmsyslogsetup:288-295`](https://github.com/Zimbra/zm-core-utils/blob/develop/src/libexec/zmsyslogsetup)):
`local0.*` (amavis), `auth.*`, and `mail.*` (Postfix). `local1.*` goes to `zimbra-stats.log`.

#### Rotation and compression — six independent mechanisms

**A single `*.log.*` glob is wrong for most of these.**

| Mechanism | Runs as | Suffix shape |
|---|---|---|
| `logrotate` (`/etc/logrotate.d/zimbra`) | root, cron.daily | `.1`, `.2.gz` |
| log4j2 `TimeBasedTriggeringPolicy` | mailboxd | `.YYYY-MM-DD`, **no `.gz`** |
| `zmcompresslogs` cron @ 02:50 | zimbra | adds `.gz` to the above |
| Jetty `NCSARequestLog` | mailboxd | `access_log.YYYY-MM-DD` |
| mailboxd `FirstServlet` timer | mailboxd | `.YYYYMMDDHHmm` |
| JVM `-Xlog:gc` | JVM | `gc.log.N` (0–19) |

The logrotate stanza for the main log
([`zm-core-utils/conf/zmlogrotate:1-12`](https://github.com/Zimbra/zm-core-utils/blob/develop/conf/zmlogrotate)):

```
/var/log/zimbra.log {
    daily
    missingok
    notifempty
    create 0644 USER GROUP
…
    compress
}
```

**daily, `compress`, no `delaycompress`** ⇒ the most recent rotated file is already gzipped: **`zimbra.log.1.gz`**.
There is **no `rotate` directive**, so retention inherits the distro default.

**The nginx stanza is the only one with `delaycompress`** (`zmlogrotate:108-121`, `rotate 7`), so
**`nginx.log.1` is plain text** and `.2.gz`…`.7.gz` are compressed. A TUI assuming `.1.gz` will silently skip
yesterday's proxy logs — the most likely off-by-one bug in this area.

**Not in logrotate at all:** `mailbox.log`, `audit.log`, `sync.log`, `milter.log`, `imapd.log`, `ews.log`,
`activity.log`, `searchstat.log`, `access_log.*`, `zmmailboxd.out`, `gc.log`. **`mailbox.log.1.gz` will never
exist.**

log4j2's `filePattern` carries no `.gz`, so compression is a separate 02:50 cron
([`zmcompresslogs:30, 46-48`](https://github.com/Zimbra/zm-core-utils/blob/develop/src/libexec/zmcompresslogs)):

```perl
my @logfiles = qw(mailbox.log audit.log sync.log synctrace.log wbxml.log milter.log convertd.log ews.log);
```
```perl
      next if ($log !~ /\.\d{4}-\d{2}-\d{2}$/);
```

Three consequences: (a) there is a **daily 2h50m window** in which rotated files are uncompressed, so the TUI
must glob **both** `<name>.YYYY-MM-DD` and `<name>.YYYY-MM-DD.gz`; (b) only those eight names ever get
gzipped; (c) retention for these is a `find -mtime +8 -delete` cron at 02:30, **not** logrotate — and it runs
*before* the compress job.

**`dateext` is UNKNOWN and it changes every filename.** Zimbra sets neither `dateext` nor `nodateext`
anywhere, so the distro global wins: without it you get `zimbra.log.1.gz`, with it `zimbra.log-20260728.gz`.
Zimbra's own tooling assumes the numbered form (the `zmmsgtrace` POD example uses `zimbra.log.1.gz`), which is
evidence of intent but not proof of runtime. **Glob both shapes.**

#### Ownership, mode, and what `zimbra` can read

The authority is `zmfixperms`
([`:39-45`](https://github.com/Zimbra/zm-core-utils/blob/develop/src/libexec/zmfixperms)):

```bash
if [ "X$PLAT" = "XUBUNTU10_64" -o … -o X$PLAT = "XUBUNTU24_64" ]; then
  syslog_user=syslog
  syslog_group=adm
else
  syslog_user=zimbra
  syslog_group=zimbra
fi
```
([`:382-389`](https://github.com/Zimbra/zm-core-utils/blob/develop/src/libexec/zmfixperms)):
```bash
  chown ${syslog_user}:${syslog_group} /var/log/zimbra.log
  chmod 644 /var/log/zimbra.log
```

**Verdict:**

- **Everything under `/opt/zimbra/log` — readable by `zimbra`, robustly.** All of it is created by processes
  running as `zimbra` in a `zimbra:zimbra` directory, so reads succeed via the owner bit even at 0600. This
  covers `mailbox.log` and therefore **all LMTP delivery lines**.
- **`/var/log/zimbra.log` — readable in both intended configurations, but fragile.** RHEL/CentOS/Rocky/SLES:
  `zimbra:zimbra 0644`, read as owner. Ubuntu 10–24: `syslog:adm 0644`, and since `zimbra` is in **neither**
  `syslog` nor `adm` (see [D.4](#d4-journalctl)), it reads only via the **other** bit of `0644`.

> **The hazard:** `zmsyslogsetup` emits **no `$FileCreateMode` and no `$umask`**. Ubuntu's stock rsyslog ships
> `$FileCreateMode 0640`. If rsyslog ever creates `/var/log/zimbra.log` itself — file deleted, logrotate
> `create` removed, `zmfixperms` not re-run after an upgrade — the file appears at `syslog:adm 0640` and
> **`zimbra` cannot read it**. Zimbra defends only via three one-shot actions: the pre-create + `chmod 0644` in
> `zmsyslogsetup`, `zmfixperms`, and logrotate's `create 0644`. Similarly the syslog-ng destination sets
> `owner("zimbra")` but **no `perm(...)`**, so syslog-ng's default 0600 would apply on re-creation.

**TUI guidance:** probe `/var/log/zimbra.log` readability explicitly at startup and degrade gracefully
("Postfix/amavis trace unavailable") rather than assuming. It is the **only** file whose readability is
distro- and `zmfixperms`-dependent, and it is also the most important one for delivery tracing.

### D.4 `journalctl`

**Confirmed: the `zimbra` user is NOT in `systemd-journal`, and not in `adm` or `wheel` either.
`journalctl` requires root.**

The account is created in the `Zimbra/packages` repo, not `zm-build`
(`zimbra/base/zimbra-base/rpm/SPECS/base.spec:48-58`, identical in `debian/zimbra-base.postinst:26-36`):

```bash
        useradd -r -g zimbra -G tty -d /opt/zimbra -s /bin/bash zimbra
```

The only later supplementary-group addition, on MTA nodes only
(`zimbra/mta-base/zimbra-mta-base/rpm/SPECS/mta-base.spec:64`):

```bash
usermod -a -G postfix,tty zimbra
```

| Group | Type |
|---|---|
| `zimbra` | primary |
| `tty` | supplementary |
| `postfix` | supplementary, **MTA nodes only** |

**Not in:** `systemd-journal`, `adm`, `wheel`, `sudo`, `postdrop`, `mail`, `syslog`, `root`.

**The absence of evidence is itself the finding, and it was checked positively:** an org-wide GitHub code
search for `systemd-journal org:Zimbra` and `journalctl org:Zimbra` returns **zero results**, and whole-repo
greps of the packaging for `\badm\b`, `\bwheel\b` and `systemd-journal` return zero hits. Every
`useradd`/`usermod`/`groupadd` in Zimbra packaging is accounted for above. The installer never modifies groups
on a pre-existing account. **Zimbra's install scripts do not touch journal group membership at all.**

The systemd rule (from systemd's own `man/journalctl.xml`): *"only root and users who are members of a few
special groups are granted access to the system journal… Members of the groups `systemd-journal`, `adm`, and
`wheel` can read all journal files."* Concretely, `system.journal` is `0640 root:systemd-journal` with ACLs for
`adm`/`wheel` only.

**`journalctl --user` is also a dead end:** `zimbra` is created with `useradd -r`, i.e. a **system user**, and
journald's default `SplitMode=uid` gives per-user journals only to regular users — system users log to the
system journal.

**`sudo journalctl` is unavailable too.** Zimbra ships six sudoers drop-ins; the complete allowlist is
`zmstat-fd`, `zmmailboxdmgr`, `postfix`, `postalias`, `qshape.pl`, `postconf`, `postsuper`, `postcat`,
`zmqstat`, `zmmtastatus`, `amavis-mc`, `zmunbound`, `zmdnscachealign`, `/sbin/resolvconf`. **No `journalctl`,
no wildcard rule.** Zimbra actively strips any `^%zimbra` line from the main `/etc/sudoers`.

**And there is nothing Zimbra-specific in the journal anyway.** Zimbra ships **zero** systemd unit files; it
installs a SysV init script, and application logging goes to syslog facilities `local0`/`local1`.

**Fallback, in order:** read `/var/log/zimbra.log` directly (the right answer — see
[D.3](#d3-log-files-for-delivery-tracing)); then `/opt/zimbra/log/*`; treat `journalctl` as an opt-in,
root-only capability and degrade gracefully.

### D.5 Performance: what each invocation costs, and batching

#### Three JVM starts per invocation, not one

The wrappers are trivial (`zm-core-utils/src/bin/zmprov:20`):

```bash
exec `dirname $0`/zmjava com.zimbra.cs.account.ProvUtil "$@"
```

But `zmjava` is not — it runs `zmsetvars -f`, which **forces** a re-read of localconfig
([`zmjava:19-21`](https://github.com/Zimbra/zm-core-utils/blob/develop/src/bin/zmjava)), and `zmlocalconfig` is
itself a Java program that **first shells out to `java -version`**
([`zmlocalconfig:57-66`](https://github.com/Zimbra/zm-core-utils/blob/develop/src/bin/zmlocalconfig)).

**Every single `zmprov` / `zmmailbox` / `zmsoap` invocation therefore costs three JVM cold starts:**

1. `java -version` (inside `zmlocalconfig`)
2. `java … LocalConfigCLI -q -m export`
3. `java … ProvUtil` / `ZMailboxUtil`

Heap for #3 is `-Xmx256m`, `-client`, classpath `/opt/zimbra/lib/jars/*` plus every present extension dir
([`LC.java:896-898`](https://github.com/Zimbra/zm-mailbox/blob/develop/common/src/java/com/zimbra/common/localconfig/LC.java#L896)).

#### SOAP round trips before the first useful command

| Invocation | Round trips |
|---|---|
| `zmprov ga user@dom` | **2** — `AdminAuthRequest`, then the command |
| `zmprov -l ga user@dom` | **0 SOAP** (LDAP bind instead), but still 3 JVM starts |
| `zmmailbox -z -m acct <cmd>` | **4** — `AdminAuthRequest`, `GetAccountInfoRequest`, `DelegateAuthRequest`, then `BatchRequest{<cmd>Request, GetInfoRequest}` to the **mail host** |

The 4th goes to a different host, so it costs a second TLS handshake at minimum. `GetInfoRequest` is
**piggybacked** onto the first real request rather than sent separately
([`ZMailbox.java:1083-1106`](https://github.com/Zimbra/zm-mailbox/blob/develop/client/src/java/com/zimbra/client/ZMailbox.java#L1083)).

**Two free optimisations fall out of the code:**

- **Pass `-m <account-name>`, never `-m <uuid>`.** `targetBy` is chosen by `StringUtil.isUUID`; a name sets
  `ZMailbox.name` while a UUID sets `accountId`. `selectMailbox` unconditionally calls `mMbox.getName()`,
  which short-circuits when `name` is set but fires a **standalone extra `GetInfoRequest`** when only
  `accountId` is — and with `accountId` set, `wrapRequest` also declines to batch. **Name ⇒ 4 RTTs; UUID ⇒ 5.**
- **Stay one-shot.** In interactive/`-f` mode the connect banner calls `getUserRoot()` and `getSize()`, adding
  a `NoOpRequest` plus a full `GetFolderRequest` — 2 extra round trips. Amortised over a batch that is fine;
  for a single command it is pure waste (and it is what creates the mailbox — [A.1](#a1-does-zmmailbox--z--m-account-create-a-mailbox)).

#### Batching

**(a) `zmprov` — stdin or `-f`, one process, one auth.** `initProvisioning()` runs **once**, before the loop
([`ProvUtil.java:4164-4186`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L4164)).

```bash
printf 'ga user@dom\nga other@dom\n' | zmprov      # stdin
zmprov -f /path/to/cmds.txt                        # file
```

(No trailing subcommand — `args.length < 1` is the gate.)

**Output delimiter:** `console.print("prov> ")` is unconditional and goes to **stdout**
([`ProvUtil.java:3921`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L3921)),
so the literal string `prov> ` precedes each command's output and is the record separator. Errors go to stderr
prefixed `ERROR: `.

> **Exit-code trap.** Per-command failures set `errorOccursDuringInteraction`, but that flag is consulted
> **only by the explicit `exit` command**
> ([`ProvUtil.java:1160-1162`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L1160)):
> ```java
>         case EXIT:
>             System.exit(errorOccursDuringInteraction ? 2 : 0);
> ```
> On plain EOF the process exits **0 even if every command failed**. **Append a literal `exit` line to every
> batch**, or parse stderr.

**(b) `zmmailbox` — same shape.** `initMailbox()` (the whole 4-request dance) runs once
([`ZMailboxUtil.java:2893-2915`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/zclient/ZMailboxUtil.java#L2893)).
The delimiter is `mbox <account>> `. **There is no `errorOccursDuringInteraction` equivalent at all** —
`zmmailbox` in batch mode always exits 0 unless a `ServiceException` escapes `initMailbox`.

**(c) `zmprov -l`** removes the SOAP auth and the mailboxd dependency but **not** the JVM cost. Combine with
stdin batching.

**(d) `zmprov selectMailbox` / `sm` — the highest-leverage primitive.** It runs `zmmailbox` commands **inside
the existing `zmprov` process, reusing the same admin auth**
([`ProvUtil.java:1559-1578`](https://github.com/Zimbra/zm-mailbox/blob/develop/store/src/java/com/zimbra/cs/account/ProvUtil.java#L1559)):

```java
            ZMailboxUtil util = new ZMailboxUtil();
…
            util.selectMailbox(args[1], (SoapProvisioning) prov);
```

Declared `"selectMailbox", "sm", "{account-name} [{zmmailbox commands}]"`. One JVM, one `AdminAuthRequest`,
then `GetAccountInfo` + `DelegateAuth` per account on demand — you can walk many mailboxes in a single process.
**Note it carries the same mailbox-autocreation side effect as `zmmailbox` itself.**

**Not batching:** `zmprov -t` is the binary-to-file flag, not a batch flag. Multiple accounts in one `zmprov`
command are not supported. Server-side `BatchRequest` exists in the SOAP layer but is **not exposed** by either
CLI.

#### Quoting differs between one-shot and batch — a correctness issue

- **One-shot** (`zmmailbox … search 'query'`): `args = cl.getArgs()` is passed **straight** to `execute(args)`.
  The shell's quoting is the only layer. **This is the safe path.**
- **Interactive/`-f`**: the line goes through `StringUtil.parseLine`, a **second shell-like parser**
  ([`StringUtil.java:492-580`](https://github.com/Zimbra/zm-mailbox/blob/develop/common/src/java/com/zimbra/common/util/StringUtil.java#L492))
  that processes `\\`, `\n`, `\t`, `\r`, `\'`, `\"`, `\<space>` and treats both `'` and `"` as quoting. And
  `StringUtil.readLine` treats a **trailing backslash as line continuation**.

Combined with [D.2](#d2-search-query-language--quoting-and-escaping)'s requirement that a literal `"` inside a
Zimbra term be written `\"`, that is **three stacked escaping layers**.

> **Recommendation: build queries as one argv element and prefer one-shot invocation for anything containing
> operator-supplied text.** Reserve stdin batching for commands whose arguments the TUI fully controls. This
> is a direct trade-off against the batching advice above, and it should be resolved in favour of correctness.

#### Concrete guidance

1. Never fork a CLI per row — that is 3 JVM cold starts plus 2–5 round trips each.
2. For directory reads, hold one long-lived `zmprov` process, write to its stdin, split output on `prov> `.
   `SoapProvisioning` re-authenticates transparently on token expiry, so the process can stay up.
3. For mailbox reads, `sm <account> <command>` inside that same session beats spawning `zmmailbox` — but only
   for accounts that already have a mailbox.
4. Always `-m <account-name>`, never a UUID.
5. Append `exit` to every `zmprov` batch if you want a meaningful exit code.
6. Cache `zimbraMailHost` per account; it changes only on mailbox moves.
7. `zmprov -l` is only a win if you also batch.

**Timings are UNKNOWN** — no measured figures appear in official documentation. The *structure* of the cost is
established above; wall-clock depends on host CPU, disk cache, JAR count and RTT.

---

## What this research could not settle

Each item names the specific experiment. All the listed commands are read-only unless marked otherwise.

### Highest priority — these change what the tool should do

1. **Does `zmprov gmi` really create the mailbox?** The code path is unambiguous
   ([A.3](#a3-does-zmprov-gmi-provision-a-mailbox)), but this contradicts shipped behaviour in the M1
   allowlist and deserves direct confirmation before the allowlist changes.
   **Experiment:** create a disposable account, never log in. Confirm no mailbox row:
   `zmprov gqu <server> | grep <acct>` (it should list with `0`) and check `mailbox.log` is quiet. Then run
   `zmprov gmi <acct>`. Re-check: a new `mailboxId` is returned and `grep 'Creating mailbox with id' /opt/zimbra/log/mailbox.log`
   shows a fresh line naming the account. **This writes — use a disposable account.**

2. **Can `gqu` distinguish "empty mailbox" from "no mailbox row"?** `quotaUsed` is `0` in both cases
   ([A.3](#a3-does-zmprov-gmi-provision-a-mailbox)), so `gqu` cannot serve as an existence probe as-is.
   **Experiment:** compare `zmprov gqu <server>` output for a never-logged-in account against a
   logged-in-but-empty one, and cross-check against `SELECT id FROM mailbox WHERE comment='<UPPERCASE EMAIL>'`
   via `zmmetadump -m <acct> -i 1` (which errors distinctly with *"not found on this host"* when there is no
   mailbox row). If that distinction holds, `zmmetadump` is the safe existence probe.

3. **Is the `-l` COS-expansion correction right?** [C.2](#c2-does--l-expand-cos-inherited-values) says the
   tool's assumption is wrong and the COS fallback is dead code.
   **Experiment:** pick an attribute set on the COS but not the account, e.g. `zimbraMailQuota`. Compare
   `zmprov -l ga <acct> zimbraMailQuota` (expect: the COS value), `zmprov -l ga -e <acct> zimbraMailQuota`
   (expect: **no output line**), and `zmprov ga <acct> zimbraMailQuota` (expect: the COS value). If `-l`
   without `-e` prints the value, the fallback can be deleted.

4. **Does `zmmailbox gm` really clear UNREAD?** The chain is proven in source
   ([A.2](#a2-does-zmmailbox-gm-clear-the-unread-flag)) but it gates a user-visible feature.
   **Experiment:** on a disposable account, `zmmailbox -z -m <acct> search -t message "is:unread"`, note an id,
   run `zmmailbox -z -m <acct> gm <id>`, then re-run the search. The message should be gone from the results.
   Confirm on the wire with `-d` and `grep 'read="1"'`. **This writes — disposable account.**

### Format and environment

5. **Locale effects on `formatSize` and `%tD`.** `String.format` is called without a `Locale`, so a European
   locale yields `1,44 GB` and could shift date rendering.
   **Experiment:** `sudo -u zimbra locale`, then compare `zmmailbox -z -m <acct> gms` against
   `LC_ALL=C zmmailbox -z -m <acct> gms`. If they differ, set `LC_ALL=C` in the TUI's subprocess environment.

6. **`dateext` and retention for `/var/log/zimbra.log`.** Determines every rotated filename
   ([D.3](#d3-log-files-for-delivery-tracing)).
   **Experiment:** `grep -nE '^\s*(no)?dateext|^\s*rotate' /etc/logrotate.conf`; `ls -l /var/log/zimbra.log*`;
   `logrotate -d /etc/logrotate.d/zimbra 2>&1 | grep -i 'renaming\|dateext\|error\|skipping'` (`-d` is
   dry-run).

7. **Actual mode and readability of `/var/log/zimbra.log`.** The one file whose readability is fragile.
   **Experiment:** `stat -c '%U %G %a' /var/log/zimbra.log`;
   `su - zimbra -c 'head -c1 /var/log/zimbra.log >/dev/null && echo OK'`;
   `grep -rn 'FileCreateMode\|PrivDropTo' /etc/rsyslog.conf /etc/rsyslog.d/`.

8. **`zimbra` group membership**, confirming [D.4](#d4-journalctl) on this specific build (including Network
   Edition, whose build repo is private).
   **Experiment:** `id -nG zimbra` (expect `zimbra tty [postfix]`); `sudo -l -U zimbra`;
   `su - zimbra -c 'journalctl -n1'` (expect *"No journal files were found."*).

9. **Exact `zmcontrol -v` string for the target build.** The shape is code-derived; the literal depends on the
   installed package.
   **Experiment:** `su - zimbra -c '/opt/zimbra/bin/zmcontrol -v'; echo "exit=$?"`.

10. **Whether the stale `/opt/zimbra/bin/zmmsgtrace` path exists as a symlink.**
    **Experiment:** `ls -l /opt/zimbra/bin/zmmsgtrace /opt/zimbra/libexec/zmmsgtrace`.

11. **Actual `mail_item` column set for the deployed schema.** `zmmetadump` uses `SELECT *` and the DDL lives
    in `zm-db-conf`, which was not examined.
    **Experiment:** `zmmetadump -m <user@dom> -i 1 | sed -n '/\[Database Columns\]/,/^$/p'`.

12. **Whether the sudoers drop-ins are installed** — they gate `mailbox` and `mta` status accuracy in
    `zmcontrol status`.
    **Experiment:** `sudo -l -U zimbra | grep -E 'zmmailboxdmgr|zmmtastatus'`.

### Genuinely open questions

13. **Does the `zmmsgtrace` amavis line ever print?** Static analysis says never (the `$12` bug,
    [B.11](#b11-zmmsgtrace)), and an offline reproduction confirmed the hash is keyed wrongly — but not against
    real Zimbra log data.
    **Experiment:** `zmmsgtrace 2>/dev/null | grep -c 'by amavisd'` over a busy day. Expect **0**.

14. **Does Lucene's `CheckIndex` acquire a write lock?** Determines whether `zmprov vi` is truly side-effect
    free ([A.4](#a4-read-sounding-commands-that-write)).
    **Experiment:** run `zmprov vi <acct>` on a disposable account while watching
    `ls -la /opt/zimbra/index/.../ ` for a `write.lock`, and check `mailbox.log` for index warnings.

15. **`zmprov -l` with a non-LDAP ephemeral backend (SSDB).** Whether `EphemeralStore.getFactory()` is
    initialised in the `zmprov -l` JVM at all — if not, `zimbraLastLogonTimestamp` would silently vanish under
    `-l` on SSDB-backed deployments ([B.13](#b13-ldap-generalized-time), [C.3](#c3-what-else-is-lost-in--l-mode)).
    **Experiment:** on an SSDB-backed server, compare `zmprov ga <acct> zimbraLastLogonTimestamp` against
    `zmprov -l ga <acct> zimbraLastLogonTimestamp`. Check `zmprov gacf zimbraEphemeralBackendURL` first — if it
    is `ldap://default`, this is moot.

16. **CRLF normalisation between SOAP and `-l`.** XML 1.0 requires CRLF→LF normalisation, so a value stored
    with CRLF would likely arrive as LF over SOAP but CRLF via `-l`. No code was found asserting either way.
    **Experiment:** on a disposable account set `zimbraPrefOutOfOfficeReply` with an embedded CRLF, then
    compare `zmprov ga … | xxd` against `zmprov -l ga … | xxd`. **The setup step writes.**

17. **Encoding of the `# name` header for non-ASCII names.** Attribute lines are forced to UTF-8; the header
    uses the JVM default `PrintStream` encoding ([B.0](#b0-cross-cutting-facts)).
    **Experiment:** create an account with a non-ASCII display name, run `zmprov ga` under `LANG=C` and
    `LANG=en_US.UTF-8`, and diff the `# name` line bytes against the `cn:` line bytes.

18. **Whether `num:` can disagree with the printed row count for `-t message`.** `dumpSearch` silently drops
    wiki/voice/call/id hits ([B.5](#b5-zmmailbox-search)).
    **Experiment:** `zmmailbox -z -m <acct> search -t message -l 5 "in:inbox"` and compare `num:` with the row
    count.

19. **Whether Zimbra NE / Daffodil binaries match public `zm-mailbox`.** All source claims here are against the
    public repo; NE builds are not fully represented.
    **Experiment:** on each targeted build, run `zmprov gmi <acct>` on an account that already has a mailbox and
    confirm the two-line `mailboxId:` / `quotaUsed:` output verbatim.

20. **Real wall-clock timings** ([D.5](#d5-performance-what-each-invocation-costs-and-batching)).
    **Experiment:**
    ```bash
    time zmprov -l gacf zimbraLogHostname
    time zmprov gacf zimbraLogHostname
    time zmmailbox -z -m <acct> gaf
    time (for i in $(seq 20); do zmprov gacf zimbraLogHostname >/dev/null; done)
    time (for i in $(seq 20); do echo 'gacf zimbraLogHostname'; done | zmprov >/dev/null)
    zmmailbox -z -m <acct> -d gaf 2>&1 | grep -cE '<(AdminAuth|GetAccountInfo|DelegateAuth|Batch|GetInfo)Request'
    printf 'gacf zimbraLogHostname\ngacf zimbraLogHostname\nexit\n' | zmprov | cat -A | head -20
    ```
    The last two also verify the round-trip count and the `prov> ` delimiter assumption on non-tty stdin.
