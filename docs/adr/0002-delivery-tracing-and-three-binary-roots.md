# Delivery tracing, and the three roots the exec gate grew

- **Status:** accepted
- **Date:** 2026-07-30
- **Resolves:** §2.2 (M5) of [`docs/superpowers/specs/2026-07-29-zimbra-readonly-tui-design.md`](../superpowers/specs/2026-07-29-zimbra-readonly-tui-design.md)
- **Affects:** M5, and the exec gate every later milestone passes through

M5 answers the question operators ask most — *did this message arrive?* — from mail
transfer agent logs, opening no mailbox. That is why §2.2 put it ahead of M2.
Delivering it turned out to require the exec gate to reach two directories it had
never reached and to approve two binaries that are not Zimbra's at all. Those are
the decisions recorded here.

## The decision

**The gate grows roots, not doors.** `zmmsgtrace` is installed in
`/opt/zimbra/libexec`, not `/opt/zimbra/bin`; `tail` and `gzip` are in `/usr/bin`.
A declared binary-to-root table in `lib/exec.sh` resolves each one, so call sites,
allowlist entries and the static scanner's two-token extraction are all unchanged.
[ADR-0001](./0001-mailbox-existence-gate.md) gave `zmmailbox` a dedicated function
because there the subcommand sat out of the allowlist's reach behind `-z -m`. Here
the first token the gate sees *is* the operation, so a second door would buy
nothing and would cost the sentence that everything external goes through
`zro_exec`.

**`gzip` is in the allowlist, and that is the point.** Bare `gzip` compresses in
place and deletes the original — a write, by a command nobody thinks of as
dangerous. Only `gzip:-dc` is listed. `gzip:-d` is not, so it is refused. This is
§8's *judge by effect, not name* applied outside Zimbra's own binaries, and the
two-token model already handles it the same way it approves `zmcontrol:-v`: a
flag that is the whole operation.

**One invocation per log file, with the year derived from that file.**
`zmmsgtrace` guesses the year once, globally, from the local clock (`:235-241`),
so a time-bounded search of a rotated log silently returns nothing. It also
re-initialises parser state per file (`:361`), which means passing it several
files never chained a message across a rotation boundary in the first place.
Invoking it once per file therefore costs no capability at all and removes the
year bug outright: `--year` comes from that file's own modification time.

**Coverage is an interval, not a date.** `logrotate` runs from `cron.daily` in the
early morning, so the file rotated on the 29th holds the 28th's lines. A file's
**coverage interval** is taken as the range between the previous file's
modification time and its own, and the **arrival window** selects every file it
intersects. Naming a file by its own date is the off-by-one this rule exists to
prevent.

**The identity rule keeps its single form.** `zmmsgtrace` has no user check and
needs only read access to the logs, and there is exactly one configuration in
which dropping to `zimbra` loses that access: if rsyslog ever creates
`/var/log/zimbra.log` itself, the file appears as `syslog:adm 0640`, which root
can read and `zimbra` cannot. We chose to **diagnose that rather than escalate
around it**. `zro_identity_mode` stays pure, with no per-binary branch; the
readability probe reports the cause, names the fix (`zmfixperms`), and the menu
entry is shown unavailable rather than failing when selected. That
misconfiguration also breaks Zimbra's own tooling, so repairing it is the correct
outcome and not a workaround.

**Operator text is escaped a third time.** Every `zmmsgtrace` filter is a Perl
regex. `ZRO_RE_LOCAL` admits `.` and `+`, so `ali+fatura@example.com` passes
validation and then fails to match itself — a silent false negative on the one
question M5 exists to answer. `zro_regex_quote` backslash-escapes the
metacharacters in our own code, which is correct however the script interpolates
the option. `\Q…\E` would have been one line, but it rests on a source line
nobody has read, and that is precisely how `gmi` got into M1.

**Only declared paths reach a shell.** `zmmsgtrace` opens compressed input as
`"@prog < '$file' |"` — the filename is interpolated into a `/bin/sh` command line
inside single quotes with no escaping. So base log names are declared in code,
only their rotation variants are globbed, and every path must match a strict
character set before it joins the **log inventory**. The environment decides
*where* the logs are (`ZRO_SYSLOG_FILE`, `ZRO_LOG_DIR`); it never decides *which*
ones are read. That is the same split as `ZRO_ZIMBRA_BIN` versus `ZRO_ALLOW`.

**Nothing is parsed that has not been captured.** The repository holds no real
`zmmsgtrace` output, and M1 shipped two production bugs from fixtures written
from memory. So M5 renders the report as it arrives and parses exactly one thing:
whether any message was found — which the exit code does not report, since it is
0 whether or not anything matched. The table view waits for captured output.

**An unread file is disclosed, never skipped.** When the arrival window selects
three files and one cannot be read, the result is a **partial scan**: the answer
is shown, a sticky banner names the files that were skipped, and the exit code is
30. Finding nothing must never be mistaken for nothing having happened.

## Considered options

**Reimplementing the regexes — rejected.** It gains real things: chaining across a
rotation boundary, time in queue (computed and then deliberately not printed,
`:693`), and the shell-injection hazard disappearing entirely rather than being
fenced off. Rejected because the correlation logic — queue-id keying, the
`queued as` hop chain, both the classic and `enable_long_queue_ids` forms — is the
part most likely to be subtly wrong, and owning it means owning Postfix log-format
drift forever. It would also drag `awk` into the gate for no other purpose. Note
that the report must be parsed either way, so the real choice was *which text to
parse*, not whether to write a parser.

**Escalating to root for `zmmsgtrace` — rejected.** Maximum coverage: root reads
every log in every configuration. Rejected because it puts a per-binary branch
inside the one function documented as having no off switch, and because it would
fork that unescaped `gzip` pipe as root.

**Treating `tail` and `gzip` as infrastructure — rejected.** The precedent
existed: `ZRO_TIMEOUT_BIN`, `ZRO_ID_BIN` and `ZRO_WHIPTAIL_BIN` all bypass the
allowlist today. Rejected because those three serve the gate and the screen, while
these two serve an operation the operator chose — and because the thing keeping
bare `gzip` out would become discipline instead of the list.

**`nginx.log` in the inventory — rejected for now.** Its `logrotate` stanza is the
only one carrying `delaycompress`, so `nginx.log.1` is plain text while `.2.gz`
onward are compressed, the opposite of every other file. Leaving it out keeps one
shape out of the glob and the most likely off-by-one in this area out of the code.

## Consequences

**§7.4's path assertion changes shape rather than its number.**
`test_readonly_scan.sh` required `/opt/zimbra` to appear exactly once in the tree.
Three binary roots and two log roots break that count, and raising the number
would turn a guarantee into a reminder. It becomes a form assertion instead: every
`/opt/zimbra` occurrence must sit inside a `ZRO_*` default assignment. That is
what the count was reaching for, and it survives the next root without being
edited.

**The tool grows a fourth seam.** §4.2 named three — `zro_exec`, `zro_ui_*`,
`zro_cap_*`. The log inventory is the fourth, and it is the only one whose
production default cannot be exercised by the suite at all, since no test can
create `/var/log/zimbra.log`.

**The readability probe asks `id` a second question, and that stays outside the
allowlist.** Deciding whether `zimbra` may read a file means reading the file's
owner, group and mode — `stat`, which the inventory already runs — and the groups
that account belongs to, which is `id -Gn zimbra` beside the `id -un` the identity
decision already runs. Both sit on the plumbing side of the line drawn against
`tail` and `gzip` above: what makes those two *operations* is that they read the
content an operator asked about, and this probe runs **before** an operator has
chosen anything, to decide whether the entry is offered at all. `id` is also not a
new command — this adds a flag to a binary the tool already invokes and already
documents. The probe reads no log content, reaches no Zimbra binary and opens no
mailbox, so nothing about it belongs to the set the allowlist exists to enumerate.

**What the probe cannot see, it declines to claim.** Judging by name and mode rather
than by access is what keeps the answer identical under both identities, and it costs
two blind spots: a directory the account cannot traverse (the file reads as *not
found*, and the screen names both possibilities rather than asserting the file is
absent) and a POSIX ACL widening a mode (the log reads as unreadable, so a working
host is marked unavailable). Seeing either means asking the kernel as that account,
and the one command that would — `runuser -u zimbra -- test -r` — needs `root` when
the tool is already running as `zimbra`. That is the per-binary branch inside the
identity decision this ADR rejected above, so both blind spots are recorded in
`docs/operations.md` instead.

**The table view is blocked on a capture, and ships without it.** Real
`zmmsgtrace` output must be captured from a server before any column is parsed.
This is the same class of debt as M2's `gis` experiment: hours of server work, off
the critical path, and not a milestone.

**The disclosure arrives in two steps, and the strict one ships first.** The ticket
that makes the arrival window decide which files are traced refuses the whole
operation when any selected file cannot be read, reporting code 23; the partial
scan described above — the answer plus a sticky banner and code 30 — is the ticket
that follows it. Both are honest; the first is simply stricter than it needs to be,
and it is sequenced first so that no release ever shows a report assembled from
some of the files without saying so. The same sequencing applies to the readability
probe: until it lands, an unreadable log is met inside the screen rather than
before it.

**The window, the year and the file are data, not allowlist entries.** Only
`zmmsgtrace:--recipient` is listed, and `--time`, `--year` and the log path follow
it in the argument vector the way an account name follows `zmprov ga`. All three
are computed — from a preset or a validated date, and from the log inventory — and
none is text an operator typed. Listing them would be worse than pointless: an
entry for `zmmsgtrace:--time` would approve a trace with no filter at all. The gate
still refuses each of them in the leading position, so reading the allowlist
remains the complete account of what may run.

**M5 stays independent of the existence gate.** No mailbox is opened anywhere in
this design, so ADR-0001's blocker does not reach it. §2.2 claimed M5 was free of
that constraint; this design confirms it rather than assuming it.

**Two `zmmsgtrace` defects are inherited, not fixed.** A message whose hops
straddle a rotation boundary is reported as two fragments, and the amavis summary
line is dead code upstream (`:562` reads `$12` from an 11-group regex), so no
feature may be built on it. Both are documented limits of the chosen engine.
