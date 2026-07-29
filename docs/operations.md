# Operator Guide

Zimbra read-only administration TUI. This guide covers installation, running,
what the current release shows, what each failure means, and — most
importantly — the verification that must happen before the tool is pointed at
real accounts.

## 1. Installation

Clone the repository anywhere readable by the `zimbra` user:

```bash
git clone https://github.com/Konsong/zimbra-readonly-tui.git
cd zimbra-readonly-tui
```

The only requirement beyond a Zimbra host is `whiptail`:

| Distribution | Package |
|---|---|
| RHEL / Rocky / AlmaLinux / CentOS | `newt` |
| Debian / Ubuntu | `whiptail` |

Nothing else is installed. The test suite has no dependencies either, which is
deliberate — it is meant to run on the production host during acceptance.

Bash 4.2 or newer is required. Every Zimbra-supported platform meets this.

## 2. Running

```bash
./zimbra-ro-tui.sh
```

Run it as `zimbra`, or as `root`. As root, every command is wrapped:

```
runuser -u zimbra -- timeout -k 5 60 /opt/zimbra/bin/zmprov ga …
```

`timeout` sits inside the wrapper on purpose: outside it, killing `runuser`
would leave the Zimbra JVM running.

Any other user is refused at startup.

### Startup failures

The tool verifies the environment before drawing a single menu, so a broken
host fails once with a clear message instead of failing later from inside a
screen.

| Message | Meaning | Fix |
|---|---|---|
| `Bash 4.2 veya uzeri gerekiyor` | interpreter below the supported floor | run with a newer bash |
| `Bu arac yalnizca zimbra veya root ile calisir` | started as some other user | `su - zimbra`, or run as root |
| `Gerekli sistem komutlari bulunamadi` | `timeout`, `id` or `runuser` missing | install `coreutils` / `util-linux` |
| `Zimbra kurulumu bulunamadi` | no Zimbra binaries at the expected path | set `ZRO_ZIMBRA_BIN` if Zimbra is installed elsewhere |
| `Zimbra servisine erisilemedi` | `zmcontrol -v` returned nothing | check `zmcontrol status`; the mailbox service may be down |
| `UTF-8 olmayan locale` | warning only | set `LANG=tr_TR.UTF-8` or `en_US.UTF-8` so the Turkish labels render at the right width |

### Environment overrides

These exist so the tool can be tested and so an unusual installation can be
accommodated. They are not needed on a standard host.

| Variable | Default | Purpose |
|---|---|---|
| `ZRO_ZIMBRA_BIN` | `/opt/zimbra/bin` | where the Zimbra binaries live |
| `ZRO_TIMEOUT` | `60` | seconds before a command is killed |
| `ZRO_LOG_FILE` | unset | when set, activity is appended here |
| `ZRO_RUNUSER`, `ZRO_TIMEOUT_BIN`, `ZRO_ID_BIN` | resolved by path | system binaries |

There is deliberately **no variable that changes the identity decision or
disables the allowlist**. A safety check with an off switch is not a safety
check.

Activity logging is off unless `ZRO_LOG_FILE` is set. It records the timestamp,
level and message — never message bodies, attachment contents or passwords.

## 3. What this release shows

Menu 1, *Hesap ve kota kontrolleri*:

- **Hesap ozeti** — display name, status, mailbox host, quota limit, COS name,
  last logon, mail aliases.
- **Kota kullanimi** — mailbox id, bytes used, quota limit, percentage full.
  Accounts with no quota are shown as `sinirsiz` rather than divided by zero.
- **Dagitim listesi uyelikleri** — the distribution lists the account belongs to.

Cancel and ESC return to the previous screen from every prompt. Nothing exits
the tool except the explicit *Cikis* entry.

### Last logon is approximate

`zimbraLastLogonTimestamp` is not written on every login. Zimbra throttles it
with `zimbraLastLogonTimestampFrequency`, which defaults to **one day**. A value
up to a day old does not mean the user has not logged in since. The screen says
so, but it is worth knowing before drawing conclusions from it.

### When the mailbox service is down

By default `zmprov` talks SOAP to `mailboxd`. If that service is stopped, or the
admin certificate no longer validates, every query fails — which is exactly the
moment you most want to look at an account.

So when the SOAP path is unreachable, the same read is retried with `zmprov -l`,
which goes straight to LDAP and needs neither. You will see this banner above
the result:

```
UYARI: mailboxd yanit vermedi; degerler LDAP uzerinden okundu.
       COS uzerinden miras alinan ayarlar eksik gorunebilir.
```

What still works, and what does not:

| Screen | With mailboxd down |
|---|---|
| Hesap ozeti | works in full |
| Dagitim listesi uyelikleri | works in full |
| Kota kullanimi | limit is shown; **usage** reads `okunamadi` |

Usage cannot be recovered from LDAP: Zimbra answers `zmprov -l gmi` with
`can only be used with SOAP`, because mailbox usage lives in the mailbox
database, not in the directory. The quota limit does come from LDAP, and when an
account inherits its limit from its COS the tool reads the COS record rather
than reporting the account as unlimited.

**Read the banner as a caveat, not as a failure.** LDAP returns what is written
on the entry. Anything Zimbra would normally compute or inherit on the way out
may be missing, so treat a degraded reading as a diagnostic aid rather than as
the authoritative account state.

When you see it, check the two usual causes:

```bash
zmcontrol status                # is the mailbox service running?
zmcertmgr viewdeployedcrt       # has the admin certificate expired?
```

### Commands this release can run

The complete set, enforced centrally in `lib/exec.sh`:

```
zmprov ga        getAccount                 zmprov -l ga    same, from LDAP
zmprov gmi       getMailboxInfo             (SOAP only)
zmprov gam       getAccountMembership       zmprov -l gam   same, from LDAP
zmprov gc        getCos                     zmprov -l gc    same, from LDAP
zmcontrol -v     version
```

`zmmailbox` is not on this list at all. That matters — see section 5.

`-l` is never approved on its own. An allowlist entry of `zmprov:-l` would let
every subcommand behind it through, including every write, so the flag is only
ever listed together with the subcommand it precedes.

Note that `zmprov gqu` (`getQuotaUsage`) is **not** used. It takes a server, not
an account, and returns every account on it. Per-account usage comes from `gmi`.

## 4. Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 10 | invalid input |
| 11 | account not found |
| 12 | mailbox not found |
| 13 | folder not found |
| 14 | no results |
| 20 | permission denied |
| 21 | Zimbra service unreachable |
| 22 | command timed out |
| 23 | log unreadable |
| 30 | partial bulk failure |
| 40 | operator cancelled — navigation, never a process exit status |
| 90 | **allowlist denial** |
| 91 | unsupported operating-system user |
| 92 | capability unavailable |

**Code 90 is a defect in the tool, not an operator mistake.** It means the
program attempted a command its own allowlist forbids. It is always logged.
Please report it with the logged line.

## 5. Read-only verification record

The tool is built so a write cannot be expressed, and a static test proves every
command it can run is on the allowlist. That covers commands whose *names* are
reads. It does not, by itself, settle whether a read-named Zimbra command has a
write **side effect**.

Three questions are open. The first two concern `zmmailbox`, which this release
does not use at all — they must be answered before the message-search milestone
adds it. The third concerns a command this release does use.

| Question | Milestone | How it was tested | Result | Date |
|---|---|---|---|---|
| Does `zmmailbox -z -m <account>` create a mailbox for an account that has never logged in? | Blocks M2 | not yet — this release never runs `zmmailbox` | **open** | |
| Does `zmmailbox gm <id>` clear the unread flag on an unread message? | Blocks M2 | not yet — this release never runs `zmmailbox` | **open** | |
| Does `zmprov gmi` on an account with **no** mailbox return an error, or provision one? | This release | not settled: it needs an account whose mailbox has never been created, and confirming that state without running `gmi` is the difficulty | **open** | |

Fill these in on a disposable test account. Do not carry them over from
another installation — the answer can depend on version and configuration.

The third question is the only one that touches this release. Until it is
settled, use the quota screen on accounts that have a mailbox — an account with
a last logon, or one that has received mail. The other screens never run `gmi`
and are unaffected.

### Acceptance runs

| Date | Server | What was run | Result |
|---|---|---|---|
| 2026-07-29 | production, all services healthy | All three M1 screens against a quiet test account, with `zmprov gmi` recorded before and after | `mailboxId 38131` and `quotaUsed 0` **unchanged**. A test message delivered afterwards moved `quotaUsed` to 2804 and the tool then reported `2.7 KB` — so the reading is live and accurate, and the tool changed nothing. |
| 2026-07-29 | test server, `mailboxd` stopped | All three M1 screens | Summary and membership answered in full over LDAP with the degraded-mode banner; the quota screen showed the limit and marked usage unreadable. |
| 2026-07-29 | production | Summary against an account with a recorded logon | Last logon rendered as `2026-07-28 06:40:34` from a stored `20260728064034.819Z`. |
| 2026-07-29 | production | Summary and quota against an address that does not exist | Reported `Hesap bulunamadi` together with Zimbra's own `NO_SUCH_ACCOUNT` text, and returned to the menu. |

## 6. Production acceptance

Run this sequence before using the tool against real accounts.

1. Copy the repository to the server and run the suite there:

   ```bash
   ./tests/run.sh
   ```

   It must end with `SUITE: PASS`. Nothing needs installing for this to work; if
   it does not run, stop and investigate rather than skipping it.

2. Read the allowlist in `lib/exec.sh` and confirm every entry is a read
   operation. It is nine lines. Read them.

3. Choose one test account that is **not receiving mail** during the check, and
   record its state:

   ```bash
   runuser -u zimbra -- /opt/zimbra/bin/zmprov gmi test@example.com
   ```

   Note the `mailboxId` and the `quotaUsed`.

   Use `zmprov`, not `zmmailbox`. This release never runs `zmmailbox`, and two
   open questions in section 5 concern its side effects — reaching for it to
   verify a tool that avoids it would prove nothing and risk something.

4. Run every screen in the tool against that account.

5. Record the same values again.

   **`mailboxId` must be identical.** `quotaUsed` will also be identical on a
   quiet account — but on a mailbox that is receiving mail it drifts by itself,
   and that drift is delivery, not this tool. If the account cannot be quiet,
   compare `mailboxId` and repeat the `quotaUsed` reading twice without running
   the tool in between, so you can see what the account's own noise looks like.

6. Answer the third row of the table in section 5 by running the tool against an
   account that has never logged in, then checking whether a mailbox now exists
   for it.

7. Only then use the tool against real accounts.

If step 5 shows any difference, stop and report it. That is exactly the failure
this tool is built to make impossible, and a difference means an assumption in
the design is wrong.
