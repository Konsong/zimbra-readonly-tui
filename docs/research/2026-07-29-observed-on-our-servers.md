# Observed Zimbra behaviour — measured, not documented

- **Date:** 2026-07-29
- **Scope:** everything in this file was seen on the project's own Zimbra servers. Nothing here is inferred from documentation.
- **Companion:** `2026-07-29-zimbra-cli-read-only-reference.md` records what Zimbra's *sources* say. Where the two disagree, this file describes what actually happened, and the disagreement is worth investigating.

Hostnames, account names and addresses are replaced with placeholders. Formats,
field names, byte counts and timings are verbatim.

## Why this file exists

Milestone M1 shipped two wrong readings to a production screen, both from the
same cause: the output formats in `tests/fixtures/` were **written from memory
instead of captured**. The test suite then validated the invention rather than
reality — 612 assertions passed while the number on the screen was wrong.

So facts about Zimbra now get written down when they are *observed*, with the
conditions they were observed under.

## Servers

| Label | State during observation |
|---|---|
| **PROD** | Production. All services healthy. |
| **TEST-A** | Test. `mailboxd` running, but the admin SSL certificate no longer validates. |
| **TEST-B** | Test. `mailboxd` **stopped** (`zmmailboxdctl is not running`); `ldap`, `mta`, `proxy` running. |

Both test servers share LDAP with production, so LDAP-backed reads return real
directory data even on TEST-B.

## 1. Output formats

### `zmprov gmi <account>` — two lines, and the field is `quotaUsed`

```
mailboxId: 26446
quotaUsed: 508385755
```

Observed on PROD. **This is the format that broke M1.** The fixture had assumed a
single comma-joined line with the field named `used`, so the parser found
nothing and displayed `0 B` for a mailbox holding 485 MB.

A single-line `mailboxId: N, used: N` shape is reported to exist on older
builds; **we have not seen it**. The tool accepts both, and the guard that keeps
`used` from matching inside `quotaUsed` is what makes that safe.

### Generalized time carries fractional seconds

```
zimbraLastLogonTimestamp: 20260728064034.819Z
```

Observed on PROD. **This is the second thing that broke M1.** The validator
required exactly fourteen digits and an optional `Z`, so it rejected every real
value and every account displayed a last logon of `-`.

Not every attribute carries the fraction — which attributes do is still an open
question for the documentary research.

### `zmprov ga` — header line, then `attr: value`

```
# name user@example.com
displayName: Ad Soyad
zimbraAccountStatus: active
zimbraCOSId: e00428a1-0c00-11d9-836a-000d93afea2a
zimbraLastLogonTimestamp: 20260728064034.819Z
zimbraMailHost: mail01.example.com
zimbraMailQuota: 0
```

A multi-valued attribute repeats its name on further lines; five mail aliases
appeared as five `zimbraMailAlias:` lines. The leading `# name` line is not an
attribute and must not be parsed as one.

### `zmprov gam` — one address per line, no header

```
bilgi-islem@example.com
tum-personel@example.com
```

An account belonging to no list produces **empty output with exit status 0** —
not an error. The tool reports that as "no results", which is a different
outcome from a failure and is displayed differently.

### `zmprov gc <cos>` — same shape as `ga`

```
# name default
cn: default
zimbraMailQuota: 0
```

`zimbraMailQuota: 0` means unlimited. Both the account and its COS carried `0`
on the accounts we looked at, so **we still have no case that distinguishes an
explicitly-set quota from an inherited one**. The tool falls back to the COS
value when the account carries none, which is correct either way.

## 2. Failure output

Each of these is now a fixture, captured verbatim.

| Condition | Server | Output |
|---|---|---|
| Account does not exist | PROD | `ERROR: account.NO_SUCH_ACCOUNT (no such account: nobody@example.com)` |
| `mailboxd` stopped | TEST-B | `ERROR: zclient.IO_ERROR (invoke Connection refused, server: localhost) (cause: java.net.ConnectException Connection refused)` |
| Admin certificate invalid | TEST-A | `ERROR: zclient.IO_ERROR (invoke PKIX path validation failed: java.security.cert.CertPathValidatorException: validity check failed, server: localhost) (cause: javax.net.ssl.SSLHandshakeException PKIX path validation failed…)` |
| `gmi` in LDAP mode | TEST-B | `ERROR: service.INVALID_REQUEST (invalid request: can only be used with SOAP)` |

The two `IO_ERROR` cases are what a broken SOAP path looks like. They are
indistinguishable at the exit-status level from an ordinary failure, which is
why the tool classifies on the message text.

## 3. `zmprov -l` (LDAP mode)

Measured on **TEST-B, with `mailboxd` stopped** — so these are answers obtained
while the SOAP path was genuinely dead.

| Command | Result |
|---|---|
| `zmprov -l ga <account> <attrs…>` | **works** — returned status, host, COS id, quota, display name |
| `zmprov -l gam <account>` | **works** — returned 11 distribution lists |
| `zmprov -l gc <cos> cn zimbraMailQuota` | **works** |
| `zmprov -l gmi <account>` | **refuses**: `can only be used with SOAP` |

So account, membership and COS data survive an outage; **mailbox usage does
not**, because it lives in the mailbox database rather than the directory.

`zimbraMailHost` on TEST-B pointed at the production mailbox host, confirming
that `-l` reads shared directory data rather than anything local.

**Not established:** whether `-l` expands values inherited from a COS. Our test
accounts had the same value on both the account and its COS, so the reading is
consistent with either answer.

## 4. Timing

Measured with `time`, as `root`, through the full `runuser -u zimbra -- timeout …`
wrapper the tool uses:

| Command | Wall clock |
|---|---|
| `zmprov ga` (SOAP, failing fast on TEST-A) | 2.4 s |
| `zmprov ga` (SOAP, failing fast on TEST-B) | 1.9 s |
| `zmprov -l ga` (LDAP, TEST-B) | 2.3 s |

Roughly **two seconds per invocation**, dominated by JVM start rather than by
the query. LDAP mode is not meaningfully faster than SOAP for a single read.

A screen that makes two calls therefore costs four to five seconds, which is why
the tool draws a non-blocking notice before running one.

## 5. Read-only evidence

On **PROD**, against a quiet test account:

```
before:   mailboxId: 38131   quotaUsed: 0
          → all three M1 screens run
after:    mailboxId: 38131   quotaUsed: 0
```

Unchanged. A test message delivered afterwards moved `quotaUsed` to `2804`, and
the tool then reported `2.7 KB`.

Those two observations together are the evidence worth keeping: the readings are
**live and accurate**, and the tool **changed nothing**. Either one alone would
have been weak — an unchanged value could mean the tool reads nothing at all.

## 6. Still open

| Question | Why it is awkward | What would settle it |
|---|---|---|
| Does `zmprov gmi` provision a mailbox for an account that has one in LDAP but none in the mailbox database? | Confirming "no mailbox yet" without running `gmi` is the difficulty. An account that does not exist at all returns `NO_SUCH_ACCOUNT` and never reaches the mailbox path, so that case answers nothing. | Create a throwaway account, query the mailbox table directly (`select id from mailbox where comment='…'`), run `gmi`, query again. Best done on a test server with `mailboxd` running. |
| Does `zmmailbox -z -m <account>` create a mailbox? | Blocks M2. Not testable on TEST-A or TEST-B, where `zmmailbox` cannot reach `mailboxd` at all. | Same experiment, substituting `zmmailbox -z -m <account> getMailboxSize`. |
| Does `zmmailbox gm <id>` clear the unread flag? | Blocks M2. | On a disposable account: deliver a message, confirm it is unread, run `gm`, check the flag again. |
| Does `-l` expand COS-inherited values? | Our sample cannot distinguish. | Read an account whose quota differs from its COS quota, in both modes. |

Neither of the `zmmailbox` questions affects the current release: `zmmailbox` is
not in the allowlist at all.
