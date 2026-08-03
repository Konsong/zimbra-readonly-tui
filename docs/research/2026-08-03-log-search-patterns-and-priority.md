# What the audit and mailbox logs really say, and what a scan costs the server

Captured on **TEST-C** (`posta.sirket.lcl`, Zimbra 9.0.0 GA FOSS on Ubuntu 20.04) on **2026-08-03**, for
issue #32. Everything below is verbatim output with names and addresses replaced; the fixtures under
`tests/fixtures/` are the same output with the same substitutions.

The mail log was already captured for issue #24 — `docs/research/2026-08-02-mta-queue-and-log.md` holds the
four delivery outcomes and `tests/fixtures/zimbra_log_outcomes.txt` carries them. What had never been
captured is the **other two logs in the inventory**, and the search's named questions cannot key on a shape
nobody has looked at. Two of the six questions are about those files.

**Substitutions applied throughout**, extending the table in the file above with one row:

| Observed | Written as |
|---|---|
| `zimscope-fixture-populated-20260731@sirket.lcl` (the fixture account) | `mehmet.kaya@example.com` |
| `192.168.1.69` (the administrator's workstation) | `192.0.2.69` |

Everything else follows the existing table: `sirket.lcl` → `example.com`, `posta.sirket.lcl` /
`192.168.1.12` → `mail01.example.com` / `192.0.2.12`, `zimbra.auth.test@` → `ayse.demir@`, `deneme-mbx@` →
`ahmet.yilmaz@`, `yokboyle-kullanici@` → `olmayan-kullanici@`. Thread names, soap ids, account UUIDs, byte
counts and timings are **not** substituted — they are what the tool has to survive parsing.

## 1. The audit log is one shape, and a session is one field of it

Every line, without exception on this host:

```
<date> <time>,<ms> <LEVEL>  [<thread>:<url>] [<context>] security - cmd=<Command>; <fields>
```

A **successful** authentication is `INFO`, and the account it names is the one that authenticated:

```
2026-07-29 21:04:23,995 INFO  [qtp393040818-80:https://localhost:7071/service/admin/soap/AuthRequest] [ua=ZCS;soapId=4e5e1bb3;] security - cmd=Auth; account=zimbra; protocol=soap;
2026-07-29 21:12:13,515 INFO  [qtp393040818-16://localhost:8080/service/soap/BatchRequest] [name=admin@example.com;oip=192.0.2.69;ua=zclient/9.0.0_GA_4200046;soapId=4e5e1bc6;] security - cmd=Auth; account=admin@example.com; protocol=soap;
```

A **failed** one is `WARN`, carries the same `cmd=Auth`, and appends an `error=` field naming the cause:

```
2026-07-29 21:41:24,466 WARN  [...] security - cmd=Auth; account=breakglass@zimbra-local.example.com; protocol=soap; error=authentication failed for [breakglass@zimbra-local.example.com], invalid password;
2026-08-03 10:02:11,685 WARN  [...] security - cmd=Auth; account=mehmet.kaya@example.com; protocol=soap; error=authentication failed for [mehmet.kaya@example.com], external LDAP auth failed, LDAP error:  - unable to ldap authenticate: 80090308: LdapErr: DSID-0C090532, comment: AcceptSecurityContext error, data 52e, v4f7c ;
```

**No failure had ever happened on this box**, so the second one was produced on purpose:
`zmsoap -m <account> -p <wrong> AuthRequest`, once against an account that exists and once against one that
does not. The account that exists is **not locked out by it** — `zimbraPasswordLockoutEnabled` is `FALSE`
here — which is worth knowing before anybody repeats the experiment on a box where it is `TRUE`.

**`data 52e` is the Active Directory code for a bad password**, and it arrives inside the `error=` field
rather than as a Zimbra error. On a domain with `zimbraAuthMech: ad` — which this one has — every wrong
password reads as an LDAP failure, so a screen that told the operator "the directory is unreachable" from
that text would be wrong about the most ordinary failure there is.

**A session search must therefore key on `cmd=Auth;` and nothing narrower.** Level would drop the failures;
`error=` would drop the successes; and the account is a *field* on the line either way, so an address filter
applied to the same line finds both.

**`cmd=DelegateAuth` is a different command and is deliberately not matched.** It appears 45 times in one
day on this host — an administrator opening a mailbox — and no line of it was captured in full, so nothing
here claims to know its shape. `cmd=Auth` does not match it: the substring is `cmd=DelegateAuth`.

**What else lives in this file matters more than what a session looks like.** The audit log is where
`zmprov` writes what an administrator DID, and it writes the values too:

```
... security - cmd=ModifyDomain; name=sirket.lcl; zimbraAuthLdapSearchBindDn=CN=svc_zimbra_ldap ...; zimbraAuthLdapSearchBindPassword=<the AD bind password, in the clear>; zimbraAuthMech=ad;
```

That line is **not** reproduced in a fixture and is quoted here with the value removed. It is the same
hazard `zmprov gd` already has — recorded against the domain screen, which filters attributes for it — and
it arrives at this feature from the other direction: **a free-text search of the audit log can put a bind
password on the screen**, because the file has one in it and the tool prints what the file says. Nothing in
the named questions reaches it (`cmd=Auth;` does not match `cmd=ModifyDomain`), and the tool does not redact,
because redaction means deciding which of an unknown line's fields are secret. It is written down in
`docs/operations.md` instead, where the operator who chooses to search that file can read it first.

## 2. The mailbox log logs a user's error at INFO

The level distribution across five rotated days on a healthy server:

```
mailbox.log.2026-07-29.gz:  1711 INFO   39 WARN
mailbox.log.2026-07-30.gz:  1483 INFO   10 WARN
mailbox.log.2026-07-31.gz:   263 INFO   23 WARN
mailbox.log.2026-08-01.gz:   132 INFO    9 WARN
mailbox.log.2026-08-02.gz:  2379 INFO   87 WARN
```

**Not one ERROR or FATAL line exists on this host**, and every WARN is start-up noise — the same six
`no Zimbra-Extension-Class found` lines once per restart, plus a library complaining about compiled
parameter names. A "mailbox errors" question keyed on the level field would answer *nothing at all* here,
and on a busier server it would answer with a screen full of extension warnings.

What a user's failure actually looks like is **INFO**, twice over:

```
2026-08-03 10:02:13,041 INFO  [...] account - Error occurred during authentication: authentication failed for [olmayan-kullanici@example.com]. Reason: account not found.
2026-08-03 10:02:13,041 INFO  [...] SoapEngine - handler exception: authentication failed for [olmayan-kullanici@example.com], account not found
```

and the exceptions Zimbra does record arrive as a **bare stack trace with no timestamp and no level at all**:

```
com.zimbra.common.service.ServiceException: system failure: mailbox not found for account 344c2c64-...
	at com.zimbra.common.service.ServiceException.FAILURE(ServiceException.java:292) ~[zimbracommon.jar:9.0.0_GA_4200046]
	at com.zimbra.cs.service.admin.GetIndexStats.handle(GetIndexStats.java:82) ~[zimbrastore.jar:9.0.0_GA_4200046]
com.zimbra.cs.account.AccountServiceException: no such account: olmayan-kullanici@example.com
```

So the question is keyed on **three** things, one per shape observed: a level field of `ERROR` or `FATAL`
for the server that does have them, `[Ee]xception` for the traces and the handler lines, and
`Error occurred` for the sentence Zimbra writes at INFO. WARN is excluded, by the count above.

**`mailbox.log` really does carry NUL bytes**, which is why every search runs with
`-a`. Without it `grep` calls the whole file binary and prints nothing — and
"nothing" is the one answer this feature may not invent. The residue is visible
when the tool runs against the real file: bash prints `ignored null byte in input`
on stderr as it reads a matched line back, and drops the byte. A shell string
cannot hold a NUL, so there is no version of this that keeps it; the line reaches
the operator without it.

**Two consequences worth stating rather than discovering.** A stack trace matches on its header and on the
frames whose class name contains `Exception`, so a trace arrives as a few lines rather than as a block — the
search is line-based and says so. And a trace **carries no account**, so filtering this question by an
address finds the header lines that name one and drops the frames: the address filter is per line, and the
screen says that too.

## 3. Local delivery is in the mail log, and again in this one

The mail log carries the hop that means a mailbox took the message — the second queue id, `dsn=2.1.5`:

```
Aug  2 16:49:04 posta postfix/lmtp[288967]: B0CC6104BA2: to=<ayse.demir@example.com>, relay=mail01.example.com[192.0.2.12]:7025, delay=0.63, delays=0/0.02/0.08/0.53, dsn=2.1.5, status=sent (250 2.1.5 Delivery OK)
```

and the mailbox log carries the other side of the same handover:

```
2026-08-02 16:49:04,242 INFO  [LmtpServer-1] [ip=192.0.2.12;] lmtp - Delivering message: size=840 bytes, nrcpts=1, sender=ahmet.yilmaz@example.com, msgid=<delivered-1785678543@capture.example.com>
```

The named question searches the **mail log**, because that is the file whose line names the recipient and
carries the delivery status. The mailbox-log line names the *sender* and the message-id and not the
recipient, so an address filter on it would answer about the wrong person.

## 4. What a scan costs, measured

```
grep (GNU grep) 3.4          /usr/bin/grep, /bin/grep
nice (GNU coreutils) 8.30    /usr/bin/nice, /bin/nice
ionice from util-linux 2.34  /usr/bin/ionice, /bin/ionice
```

**The priority chain reaches the child, and needs no privilege.** Run as `zimbra`, the process at the end of
`nice -n 19 ionice -c 3 <command>` reports its own state as:

```
nice=19 ionice=idle
```

Class 3 is the idle disk class; an unprivileged account may put itself into it, and raising one's own
niceness has never needed a privilege. `ionice -c 3 ionice -p $$` looks like it disagrees — it prints
`none: prio 4` — but `$$` there is the *shell's* pid, not the child's, which is a trap worth recording.

**grep's three exit statuses are the whole of the tool's error handling:**

| Status | Means | What the search does with it |
|---|---|---|
| 0 | at least one line matched | the answer |
| 1 | the file was read and nothing matched | not an error, and not an empty file either |
| 2 | the file could not be opened | a **partial scan**: the file is named and the answer is marked |

Measured as `zimbra` against `/etc/shadow` for the last of them.

**Sizes on this host**, which is what a cost declaration is made of:

```
/var/log/zimbra.log          427399 bytes   4940 lines
/opt/zimbra/log/mailbox.log   69285 bytes    605 lines
/opt/zimbra/log/audit.log       184 bytes      1 line
```

plus five compressed rotations of each. A full scan of the live mail log took under 10 ms at idle priority,
which says only that this lab box has no traffic: production is the same command over three orders of
magnitude more bytes, and the declared cost is what tells the operator that before they spend it.

**The bounded viewer and this search see different things**, which is the reason the feature exists: at 4940
lines against a bounded read of 500, the delivery outcomes captured for #24 sit in the first fifth of the
file and a tail never reaches them.

## 5. The tool itself, run against this server

The modules were copied to `/tmp/zro` and driven as `root` — so every command went
through `runuser` as `zimbra`, exactly as in production — over the real logs, with
no mocks. `ZRO_NICE_BIN` pointed at a wrapper that recorded its argument vector
before running the real `nice`, which is how the priority claim was checked on a
real host rather than against a mock. Removed afterwards.

| Condition | What the tool did |
|---|---|
| Declared cost, one week | `syslog` 5 files / 590 KB, `mailbox` 4 / 181 KB, `audit` 4 / 8.6 KB — shown and confirmed before any file was opened |
| All six named questions | Every one matched real lines: 3 rejections, 13 deferrals, 3 bounces, 3 local deliveries, and the cap's worth of sessions and mailbox errors |
| Free text that is nowhere | **14** (`ZRO_E_NO_RESULT`) — a complete scan that found nothing, which is the answer this feature exists to be able to give |
| The cap, at 5 over the mail log | **30** (`ZRO_E_PARTIAL`), naming the four older files it therefore never opened |
| What the gate really ran | `nice -n 19 /usr/bin/ionice -c 3 /usr/bin/grep -a -E -m 198 'NOQUEUE: reject:' /var/log/zimbra.log` — 59 invocations, every one of them wrapped |
| Every log file, before and after | **Byte-identical.** All 16 files hashed the same after the whole run |

**The scan order was changed by this run.** Reading oldest first — which is what
the delivery trace does, so that its report runs forwards in time — meant a capped
search never opened *today's* log: the sessions question answered out of 29 July
and listed `audit.log` itself as unread. For a search that is the wrong way round,
so files are now read newest first and what a cap costs is the oldest evidence.
The second run answered from the live `audit.log` and named the two older
rotations as unscanned.

## 6. Second pass: the two questions that are about everybody, for issue #37

Same day, same method — the modules driven as `root` through `runuser`, over the
real mail log, `nice` wrapped so the vector could be recorded.

**The identifiers this server really writes** are `message-id=<...>` at the cleanup
stage, `Message-ID: <...>` in the amavis line, and `msgid=<...>` in `mailbox.log`
at delivery. Searching the **bare** identifier finds all three, which is why the
lookup unwraps a pasted value and matches it literally:

```
message-id=<20260802134903.C2131104BA8@posta.sirket.lcl>
```

| Condition | What the tool did |
|---|---|
| A real identifier, bare | **0**, one line found, from a complete 5-file scan |
| The same identifier wearing its angle brackets | **byte-identical answer** |
| An identifier that is nowhere | **14** (`ZRO_E_NO_RESULT`) — a complete scan that found nothing |
| Sender domain `sirket.lcl` | **0**, 35 lines across 5 files, pattern `from=<[^>]*@sirket\.lcl>` |
| Sender domain `nosuchdomain.invalid` | **14** — and this is the point of the pattern |
| Every reader | wrapped: `grep -a -F -m 200 <id> /var/log/zimbra.log` under `nice`/`ionice` |
| The mail log files | **byte-identical** before and after |

**A domain is found however it is typed; an identifier is not.** Measured on the
same log, over the 35 lines that domain really sent:

| Typed | Found |
|---|---|
| `sirket.lcl`, `SIRKET.LCL`, `Sirket.Lcl`, `sIRKET.lcl` | **35 lines each** |
| `NOSUCHDOMAIN.INVALID` and `nosuchdomain.invalid` | **no result** — still the envelope sender, not any mention |
| The identifier as written | found |
| The same identifier upper-cased | **no result** |

Those are opposite rules for opposite reasons, and both are the reader's own flag
rather than anything done to the operator's text. A domain is the same domain
whatever case either end wrote it in — the operator's typing *and* the sending
client's `MAIL FROM`, which Postfix logs as it was given — so folding only the
input would have fixed half the problem and left a false "nothing arrived from
there" for the other half. An identifier is a token some agent generated, so
folding it would report a different message as this one.

**`nosuchdomain.invalid` is the case that justifies the one place operator text
reaches a pattern.** That domain is all over this log — it is the destination of
the deferred test messages — but it has never *sent* anything. A whole-line match
for the domain would answer that mail arrived from it, which is the opposite of
the truth. Matching `from=<[^>]*@…>` answers **no result**, correctly, and that is
not expressible without interpolating the (validated, escaped) value into the
pattern.

## 7. What was left behind on TEST-C

- **Two failed authentications** are recorded in `audit.log` and `mailbox.log`, one against
  `zimscope-fixture-populated-20260731@` and one against an address nobody has. Nothing was locked out:
  `zimbraPasswordLockoutEnabled` is `FALSE` on that account and its status is still `active`.
- Nothing else. No configuration was touched, no message was sent, and no file was written by the capture
  itself.
