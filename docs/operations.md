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

### Commands this release can run

The complete set, enforced centrally in `lib/exec.sh`:

```
zmprov ga        getAccount
zmprov gmi       getMailboxInfo
zmprov gam       getAccountMembership
zmprov gc        getCos
zmcontrol -v     version
```

`zmmailbox` is not on this list at all. That matters — see section 5.

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
| Does `zmmailbox -z -m <account>` create a mailbox for an account that has never logged in? | Blocks M2 | | | |
| Does `zmmailbox gm <id>` clear the unread flag on an unread message? | Blocks M2 | | | |
| Does `zmprov gmi` on an account with no mailbox return an error, or provision one? | This release | | | |

Fill these in on a disposable test account. Do not carry them over from
another installation — the answer can depend on version and configuration.

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

3. Choose one disposable test account and record its state:

   ```bash
   zmprov gmi test@example.com
   zmmailbox -z -m test@example.com getAllFolders
   ```

   Note the mailbox id, the used bytes, and the message and unread counts of one
   folder.

4. Run every screen in the tool against that account.

5. Record the same values again and confirm they are identical.

6. Answer the third row of the table in section 5 by running the tool against an
   account that has never logged in, then checking whether a mailbox now exists
   for it.

7. Only then use the tool against real accounts.

If step 5 shows any difference, stop and report it. That is exactly the failure
this tool is built to make impossible, and a difference means an assumption in
the design is wrong.
