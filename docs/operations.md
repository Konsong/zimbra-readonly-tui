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
| `Gerekli sistem komutlari bulunamadi` | one of `timeout`, `id`, `runuser`, `date`, `stat` is missing — the message names it. Without `date` there is no arrival window and no year for a rotated log; without `stat` there is no log inventory | install `coreutils` / `util-linux` |
| `Zimbra kurulumu bulunamadi` | no Zimbra binaries at the expected path | set `ZRO_ZIMBRA_BIN` if Zimbra is installed elsewhere |
| `Zimbra servisine erisilemedi` | `zmcontrol -v` returned nothing | check `zmcontrol status`; the mailbox service may be down |
| `UTF-8 olmayan locale` | warning only | set `LANG=tr_TR.UTF-8` or `en_US.UTF-8` so the Turkish labels render at the right width |

One failure is worth naming here even though it happens inside a screen rather
than at startup:

| Message | Meaning | Fix |
|---|---|---|
| `Log okunamiyor` (exit 23) | a log file the arrival window selected could not be opened, or the window found no log file at all — usually the syslog file is owned `syslog:adm` because rsyslog created it. **Nothing was scanned**, which is not the same answer as "no records" | `zmfixperms`; the same misconfiguration breaks Zimbra's own tooling, so repairing it is the right outcome rather than reading the log as root |

### Environment overrides

These exist so the tool can be tested and so an unusual installation can be
accommodated. They are not needed on a standard host.

| Variable | Default | Purpose |
|---|---|---|
| `ZRO_ZIMBRA_BIN` | `/opt/zimbra/bin` | where the Zimbra binaries live |
| `ZRO_ZIMBRA_LIBEXEC` | `/opt/zimbra/libexec` | where `zmmsgtrace` lives |
| `ZRO_SYSTEM_BIN` | `/usr/bin` | where `tail` and `gzip` live. A host that keeps one of them elsewhere — Ubuntu before the merged `/usr` ships `gzip` in `/bin` — sets this; the log viewer then reports the binary as unavailable rather than searching `$PATH` for it |
| `ZRO_LOGVIEW_LINES` | `500` | how many lines the log viewer's bounded read is |
| `ZRO_SYSLOG_FILE` | `/var/log/zimbra.log` | the primary mail log — Postfix, amavis and auth |
| `ZRO_LOG_DIR` | `/opt/zimbra/log` | where Zimbra's own logs live |
| `ZRO_TIMEOUT` | `60` | seconds before a command is killed |
| `ZRO_LOG_FILE` | unset | when set, **this tool's** activity is appended here — unrelated to the two above |
| `ZRO_RUNUSER`, `ZRO_TIMEOUT_BIN`, `ZRO_ID_BIN`, `ZRO_STAT_BIN`, `ZRO_DATE_BIN` | resolved by path | system binaries |

The two log variables decide **where** the logs are, never **which** ones are
read. The base names — the mail log, `mailbox.log` and `audit.log` — are declared
in code, and only the rotation variants of those names are looked for on disk.
Pointing `ZRO_LOG_DIR` somewhere else moves the search; it cannot widen it, and a
path carrying anything outside `[A-Za-z0-9._/-]` is refused rather than read.

There is deliberately **no variable that changes the identity decision or
disables the allowlist**. A safety check with an off switch is not a safety
check.

Activity logging is off unless `ZRO_LOG_FILE` is set. It records the timestamp,
level and message — never message bodies, attachment contents or passwords.

## 3. What this release shows

### The selected address

There is **one menu**, and its first entry is the address. Choose it once and
every screen after it is about that address: it is carried in the title of every
box the tool draws, and no other screen asks for it again. Entries that need an
address come first in the list, the ones that are about the server come after.

Choosing an account operation with nothing selected asks for the address and then
**continues to the operation you chose** — you do not pick the entry twice. The
entry itself reads *Adres sec* until there is one and *Adresi degistir*
afterwards, and changing it offers the current address ready to edit, so
comparing two accounts is a keystroke rather than a restart.

The address is on the frame because whiptail keeps a title on the border while
the text inside scrolls: it is the one part of a long answer that cannot be
pushed out of view. Reading one account's answer believing it is another's is
what that prevents. An address too long for the border is shortened with a
trailing `..`; what the tool searches for is always the whole address.

**The frame says what the session is about, not what the screen filtered on.**
The screens that are about the server carry the address too — a log listing and
a message-id trace are titled with it although neither was restricted to it.
That is deliberate: the address is the session's subject, and every report names
its own subject on its own first line (`Ileti kimligi  : …`, and the log
viewer's header naming the file and the bound). A title is orientation; the
report is the claim.

### About the selected address

- **Hesap ozeti** — display name, status, mailbox host, quota limit, COS name,
  last logon, mail aliases.
- **Kota kullanimi** — mailbox id, bytes used, quota limit, percentage full.
  Accounts with no quota are shown as `sinirsiz` rather than divided by zero.
- **Dagitim listesi uyelikleri** — the distribution lists the account belongs to.
- **Teslim takibi: bu adrese gelenler** — asks for an arrival window, then shows
  what the mail transfer agent's log says about messages **for** that address. No
  mailbox is opened, so this is safe on an account that has never logged in.
- **Teslim takibi: bu adresten gidenler** — the same trace, filtered by sender:
  whether a user's outbound message actually left.

### About the server

- **Teslim takibi: ileti kimligine gore** — the same trace, filtered by
  message-id, for when you are holding a bounce report or a forwarded header and
  an address is too broad a question. It is the one trace that asks you to type
  something, because an identifier is not an address.
- **Log dosyalari (son satirlar)** — described below.

All three traces ask for an arrival window and answer in the same report. The
only differences are the filter, the label on the report's first line, and the
two notes below.

**The message-id match is case-sensitive; the other two are not.** That is
`zmmsgtrace`'s own rule, and it is stated on the prompt and repeated on the
`Sonuc yok` screen, because an identifier retyped in the wrong case produces an
empty result that reads as proof the message never arrived.

**The angle brackets a header carries are removed before the search.** What you
have in hand reads `Message-ID: <CAabc123@example.com>`; `zmmsgtrace` records the
identifier without its delimiters, so a filter carrying them would match nothing.
Paste either form of the identifier — but only the identifier: the whole header
line is refused as invalid input rather than searched for and never found.

*Log dosyalari (son satirlar)*:

- Pick a log — the mail log, `mailbox.log`, or `audit.log` — then pick one of its
  files from a list, and read the last lines of it. This is where the lines the
  delivery trace does not parse live, `mailbox.log`'s account of what LMTP did
  with a message above all.

**You never type a path.** The first screen offers the logs this tool declares,
the second offers that log's files by position, and a position is what comes
back. That is what keeps a glob, a symbolic link or an oddly named neighbour from
turning this screen into a general-purpose file reader — and the reader refuses a
path the inventory does not list even so, so neither check rests on the other.

**Only the last lines are read** — a **bounded read**, five hundred lines by
default, with the bound applied by the command that reads the file rather than
afterwards. Opening a multi-hundred-megabyte mail log therefore neither hangs the
tool nor exhausts the server's memory. The screen says so above the lines,
because a bounded read taken for a whole file is an absence nobody claimed: what
you are not seeing may simply be further up.

The file list is newest first and each entry carries the file's **last written**
time, not a date from its name. Rotation runs in the early morning, so
`zimbra.log.1` holds the day before its own date — the same reason the arrival
window is compared against a coverage interval.

**Compressed rotated files are readable**, decompressed to standard output; the
file on disk is left exactly as it was. See the note on `gzip` in section 3.

A file that cannot be read names the file, the cause and `zmfixperms`. An **empty
file** is answered as empty and never as unreadable: one says the server wrote
nothing there, the other says nothing could be learned at all. A log that is not
on this host at all is its own screen for the same reason.

The viewer is offered whether or not delivery tracing is available here. The two
read the same files, but tracing needs `zmmsgtrace` and the primary mail log,
while this screen can still show `mailbox.log` on a host that has neither.

Cancel and ESC return to the previous screen from every prompt and from every
screen. The main menu is the one place where there is no previous screen: leaving
it there leaves the tool, as the explicit *Cikis* entry does.

### When the entry reads `KULLANILAMAZ`

Two things have to be true before a delivery trace can answer anything, and both
are checked once per session, before the menu is drawn:

- **`zmmsgtrace` is installed.** Upstream packaging puts it in
  `/opt/zimbra/libexec`; an upstream mapping still names the `bin` path and that
  mapping is stale, so a build which differs shows up here instead of as an error
  from inside a screen.
- **The primary mail log is readable by the `zimbra` account.** It is the only file
  in the inventory whose readability depends on the distribution and on whether
  `zmfixperms` has been run since the last upgrade.

When either is false all three trace entries read `... - KULLANILAMAZ`, and
selecting one says which of the two it is, names the file it is talking about,
and names the repair — a missing
binary and an unreadable log get different messages, because a version difference
is not a permission and `zmfixperms` would be the wrong advice for it. You learn
this before spending a search on it rather than after.

**Read access is judged for the `zimbra` account, never for you.** Every command
runs as `zimbra` — see section 2 — so a log that `root` can read and `zimbra`
cannot is a log no trace can read, and a check of your own access would pass on
exactly the configuration worth catching. If `rsyslog` created
`/var/log/zimbra.log` itself, the file is owned `syslog:adm` with mode `0640`,
which is that configuration. The tool **diagnoses it rather than escalating around
it**: it will not read the file as `root`, because the same ownership breaks
Zimbra's own tooling, so repairing it is the right outcome rather than a
workaround. The answer is the same whether you started the tool as `zimbra` or as
`root`.

The probe reads the file's owner, group and mode, and the groups the `zimbra`
account belongs to. **Two things it cannot see**, both recorded rather than
compensated for — seeing either means asking the kernel *as* that account, and the
command that would do it needs `root` when the tool is already running as `zimbra`,
which is the per-identity branch this design deliberately does without:

- **A directory on the way to the file that cannot be traversed.** The file then
  reads as *not found*, so the screen says so and names both possibilities — the
  file may be absent, or its directory may be closed to the account. It does not
  claim the file does not exist.
- **A POSIX ACL granting `zimbra` read on a file whose mode refuses it.** That reads
  as unreadable, so a host where tracing would in fact work is marked unavailable.
  The screen names the file and says the decision was made from ownership and mode
  alone, so an operator who has set an ACL can see what was judged. `zmfixperms`
  would replace such an ACL rather than preserve it.

Both answers are remembered for the session. A binary removed, or a permission
repaired, while the tool is open is not noticed until it is restarted. Nothing is
ever *run* on the strength of a stale answer: the exec gate still refuses a binary
it cannot resolve, and the trace still discloses a log it could not open.

### The arrival window, and why it says "varis"

The window is offered as four presets — last hour, last 24 hours, yesterday as a
whole calendar day, last 7 days — plus an explicit range typed as
`YYYY-MM-DD HH:MM`. The presets compute their bounds in code, so the common
questions cost no typing and cannot be mistyped; only the explicit range is
validated as text, and a malformed value is refused rather than repaired.

**The window is compared against the message's arrival time, not its delivery
time.** A message that arrived at 23:59 and was delivered at 00:02 is found by
yesterday's window, not by today's. Every screen says so, because reading it the
other way turns "not in this window" into "never arrived".

You never name a log file. The tool works out which files the window covers from
their modification times, so you do not have to know that rotation runs in the
early morning — the file rotated on the 29th holds the 28th's afternoon — or that
the most recent rotated file is already compressed.

**One invocation of `zmmsgtrace` per file, each with that file's own year.** The
tool guesses the year once from the local clock, which makes a time-bounded search
of a rotated log return nothing at all, silently. Deriving it per file removes
that. One residual is inherent and remains: a file rotated on 1 January carries
the new year for lines written on 31 December.

**The count is per file, and summed.** The report lists every file it read with how
many messages were found in it, and the total is the sum. It cannot be the number
of distinct messages: `zmmsgtrace` re-initialises per file, so a message whose hops
straddle a rotation is introduced once in each file and counted in both. The screen
says so whenever more than one file was read. Telling those apart would mean
parsing the report further, and no output from a real server has been captured to
parse against.

**If some of the selected files cannot be read, you get the answer plus an
account of what was missed.** That is a **partial scan**: the report is shown
under a banner naming every file that was skipped and what `zmmsgtrace` said
about each, the screen title reads `EKSIK TARAMA` so the disclosure stays on the
frame while the report scrolls, and the exit code is 30. An empty answer from a
partial scan is still reported as partial — never as `Sonuc yok` — because
finding nothing must never be mistaken for nothing having happened.

**If none of them can be read, the search is refused** with `Log okunamiyor`
(exit 23) and no report at all: nothing was scanned, so there is no answer to
qualify. The usual cause is ownership on the log file, which breaks Zimbra's own
tooling too — both screens name `zmfixperms` for that reason.

A timeout, or any failure other than a file the tracer could not open, still
refuses the whole search. Those say nothing about which files were covered, so no
honest partial answer can be assembled from them.

Timestamps are **local wall clock throughout**, with no timezone or
daylight-saving arithmetic anywhere — the log lines being read carry neither a
zone nor a year. A window spanning a daylight-saving change is therefore an hour
wider or narrower than its label. That is documented rather than corrected: the
underlying tool has no zone handling either, and compensating on one side of that
would invent a precision the other side does not have.

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
| Kota limiti | works in full |

Every screen keeps working, because none of them needs the mailbox service any
more.

**Read the banner as a caveat, not as a failure.** `zmprov` expands values
inherited from a COS in *both* modes, so those are not what LDAP mode costs.
What it costs is anything held outside the directory — mailbox facts above all.

When you see it, check the two usual causes:

```bash
zmcontrol status                # is the mailbox service running?
zmcertmgr viewdeployedcrt       # has the admin certificate expired?
```

### Commands this release can run

The complete set, enforced centrally in `lib/exec.sh`:

```
zmprov ga        getAccount                 zmprov -l ga    same, from LDAP
zmprov gam       getAccountMembership       zmprov -l gam   same, from LDAP
zmprov gc        getCos                     zmprov -l gc    same, from LDAP
zmcontrol -v     version
zmmsgtrace --recipient                      delivery trace by recipient
zmmsgtrace --sender                         delivery trace by sender
zmmsgtrace --id                             delivery trace by message-id
tail -n                                     the log viewer's bounded read
gzip -dc                                    decompress a rotated log TO STDOUT
```

`zmcontrol -v` runs **once per session**, at startup. Its answer is shown on the
main menu, which is returned to after every operation, so re-reading it there
would cost a JVM start per screen.

`tail` and `gzip` are the only entries here that are not Zimbra's. They are on
this list rather than treated as plumbing beside `timeout` and `id`, because
those two serve the tool itself while these two read the content an operator
asked for — and because the thing keeping bare `gzip` out would otherwise be
discipline instead of this list.

**`gzip -dc` is approved and nothing else about `gzip` is.** Bare `gzip`
compresses in place and deletes the original; `gzip -d` decompresses in place and
does the same. Both are writes, by a command nobody thinks of as dangerous, and
both are refused with code 90 — the *judge by effect, not by name* rule in
section 5 applied outside Zimbra's own binaries. `gunzip`, `zcat` and `zless` are
absent for the same reason and a static test proves none of them is written down
anywhere in the tree.

`tail -f` is absent too: it follows a growing file and never returns, which on a
screen is a tool that has hung. The line count and the file follow `-n` as data —
the count is this tool's own bound and the file comes from the log inventory.

`zmmsgtrace` is installed in `/opt/zimbra/libexec`, not in `bin` — an upstream
mapping still names the `bin` path and it is stale. That is why each allowlisted
binary declares the directory it resolves under instead of sharing one root.

**One entry per filter**, because recipient, sender and message-id are three
different questions and approving one may not approve another. The short forms
`-r`, `-s` and `-i` are absent although they name approved operations: an
operation reaches the gate in exactly one spelling, so reading a call site tells
you which entry approves it. The `--srchost` and `--desthost` filters and the
`--debug`, `--nosort` and `--man` flags are absent and therefore refused: each is
an operation of its own and arrives with the ticket that exposes it, not because
the binary is already reachable.

The arrival window (`--time`), the year (`--year`) and the log file follow the
filter as **data**, exactly as an account name follows `zmprov ga`. All three are
computed by this tool — from a preset or a validated date, and from the declared
log inventory — and none is text an operator typed. They are not listed, and
listing them would be worse than pointless: an entry for `zmmsgtrace:--time` would
approve a trace with no filter at all. Put any of them in the leading position and
the gate refuses it.

Every filter that binary takes is a **Perl regular expression**, so every value is
escaped before it is passed — not just the recipient. Without that,
`ali+fatura@example.com` — a valid address — would be read as a pattern and fail
to match itself, reporting no delivery record for a message that has one. A
message-id carries more metacharacters than an address does, so it needs this
more, not less.

The trace reads the log files the operator's arrival window covers — the file
being written and the rotated files behind it — one invocation per file. See *The
arrival window* in section 3 for what that means when a file cannot be read.
Nothing in the trace opens a mailbox, so the existence gate in section 5 is not
involved.

`zmprov gmi` was on this list and has been removed — it creates mailboxes. See
section 5.

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
| 30 | partial result — some of the sources could not be read |
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

All three were answered on 2026-07-29 by reading the `zm-mailbox` source, and
**all three came back on the unsafe side**. Full citations are in
[`docs/research/2026-07-29-zimbra-cli-read-only-reference.md`](research/2026-07-29-zimbra-cli-read-only-reference.md).

| Question | Answer | Consequence |
|---|---|---|
| Does `zmmailbox -z -m <account>` create a mailbox for an account that has never logged in? | **Yes.** `zmmailbox` never sets `noSession`, and `Session.register()` resolves the mailbox through the auto-creating overload. No `zmmailbox` invocation — not even `noOp` — can serve as an existence probe. | M2 must treat every `zmmailbox` call as capable of creating a mailbox. |
| Does `zmmailbox gm <id>` clear the unread flag? | **Yes.** `doGetMessage` hard-codes `params.setMarkRead(true)` and the client emits `read="1"` unconditionally. No CLI flag disables it. `GetMsg` is one of only two handlers in the service tree that declare themselves not read-only. | Message detail in M2 cannot use `gm`. |
| Does `zmprov gmi` on an account with **no** mailbox provision one? | **Yes.** `GetMailbox.handle()` calls `getMailboxByAccount(account)`, the `AUTOCREATE` overload. It is the only read-named admin handler that does; every sibling passes `DO_NOT_AUTOCREATE` and throws `mailbox not found`. | **`zmprov gmi` was removed from the allowlist.** See below. |

**All three have since been confirmed on a live Zimbra 9.0.0 server**, each by
checking the `mailbox` table before and after and by Zimbra's own
`Creating mailbox with id …` log lines. The runs are recorded in
[`docs/research/2026-07-29-observed-on-our-servers.md`](research/2026-07-29-observed-on-our-servers.md)
§6, including one attempt that was invalid and had to be repeated.

One qualification worth knowing: an account that does **not** exist in Zimbra's
directory is safe — `zmprov` fails at the account lookup and never reaches the
mailbox code. An account present only in Active Directory and not synced into
Zimbra is therefore also safe. The population at risk is accounts that exist in
Zimbra's directory but have never logged in or received mail.

### Why usage is no longer shown

Per-account quota **usage** has been removed from the quota screen. The only
command that reports it, `zmprov gmi`, creates a mailbox for an account that has
none — so a read-only tool cannot run it. The quota limit, the mailbox host and
everything on the summary screen are unaffected, and all still work.

The safe replacement is `zmprov gqu <server>`, which joins LDAP accounts against
mailbox ids already known to the server and creates nothing. Its argument is a
server rather than an account, so it belongs with the bulk quota overview rather
than with a single-account lookup, and it arrives with that milestone.

If you ran an earlier build of this tool against an account that had never
logged in and had no mailbox, **that account may now have an empty mailbox that
this tool created.** Check `mailbox.log` for `Creating mailbox with id` lines
around the times you used it.

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
   operation. It is eighteen lines. Read them — and read `gzip:-dc` twice: it is
   the one entry whose neighbouring spellings write.

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
