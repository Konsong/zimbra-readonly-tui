# The mail queue is read in its listing form only, under a root of its own

- **Status:** accepted
- **Date:** 2026-08-03
- **Extends:** [ADR-0002](./0002-delivery-tracing-and-three-binary-roots.md) — a fourth declared root, resolved the same way
- **Evidence:** [`docs/research/2026-08-02-mta-queue-and-log.md`](../research/2026-08-02-mta-queue-and-log.md), captured on the lab server
- **Affects:** the mail queue screen, and the capability vocabulary the menu marks entries from

The queue answers what neither the account screens nor the delivery trace can: a message that is neither
delivered nor lost but **still here** — waiting on a remote host that refuses, a name that does not resolve,
or an entry somebody put on hold. Reading it means admitting a binary whose **writing forms live in the same
program as its read**, which is the decision recorded here.

## The decision

**`postqueue -p` is approved, and no other form of that program is.** Postfix tells the read and the writes
apart by flag, so the flag *is* the operation and is approved the way `zmcontrol -v` is — as a whole
operation with nothing behind it. `-f` flushes the deferred queue, `-s` flushes one site, `-i` requeues one
message, `-d` deletes. None of them edits a message and every one of them **changes what the server does
with the queue**: mail leaves, a remote host is contacted, bounces are generated. That is domain state under
any reading of the word that means anything, so all four are absent from the allowlist and named in the
tests as refused. `postsuper` is not on the list at all, and neither is `mailq`, which is a symbolic link to
the mail submission program.

**`-j`, the structured form of the same listing, is deliberately absent.** It is the better source — it
carries the queue's real name as a field instead of as a marker on the id — and this tool has no JSON parser
and does not grow one for a question the traditional form already answers. An approved form with no call
site would be an operation no reader of the allowlist could reach. The day a parser exists for another
reason, this is the first thing that should use it.

**The status is read from the marker Postfix appends to the queue id**: `*` active, `!` hold, nothing at all
for everything else. The unmarked case is labelled *deferred or newly arrived* rather than *deferred*,
because this output cannot tell those two apart and picking the likely one would be the tool inventing a
fact. Both cases are captured: a listing of two deferred messages and one placed on hold is committed as a
fixture, and the same queue in the structured form confirms the marker reading.

**It resolves under `ZRO_POSTFIX_SBIN`, a fourth declared root.** Zimbra ships its Postfix under
`/opt/zimbra/common/sbin`, not under `bin`, and the tool there is set-group `postdrop`, which is why it
answers for an unprivileged account at all. A root rather than a path, resolved exactly as the other three
are, refused rather than searched for when absent: a `postqueue` found on `$PATH` would be a different
program answering about a different queue.

**Absence and refusal are two capability answers with two repairs.** A build with no mail transfer agent has
no queue tool, no queue, and no setting that would produce one — the repair is a package. A host whose
`authorized_mailq_users` does not list the `zimbra` account **has** the tool, which is present, executable
and exits 69 saying so — the repair is that setting. One screen for both would send half its readers to
repair something that is not broken.

**The refusal is learned by being refused, and remembered for the session.** That setting is read *inside*
`postqueue`, after the allowlist has already approved the operation, so there is nothing this program could
stat beforehand — and probing by running the tool on every menu redraw would spend a real listing, on a real
queue, for an operator who may never open the screen. So it is asked once, the answer is kept in a session
file, and the entry carries the mark from then on. A refusal by the host is **never** reported as an
allowlist denial, which in this program means a defect: the two send whoever reads the screen to different
files.

**Counts first, bounded detail behind them, from one reading.** On a production server this queue holds
thousands of entries and a list of thousands is not an answer. The screen renders the counts by status, then
the entries behind a keystroke, bounded and saying so. Both come from the same invocation: reading twice
would cost a second one and would let the counts disagree with the list under them, on a queue that moves
every few seconds.

## Consequences

This is the first operation in the tool whose cost is neither a directory entry, nor a mailbox, nor a log
file: one invocation asks this server about itself, whatever it holds. It arrives with **cost class 5, unit
`host`**, and the service status claims the same class. The number 4 is skipped rather than reused, because
the digit itself is refused everywhere in the declaration — a vocabulary that can name a server-wide sweep is
a vocabulary that will one day be used to offer one.

What the screen cannot yet show is recorded rather than papered over: an `active` entry was never observed on
the lab server, because an entry is active only while it is being delivered. The marker is read from the
documented format and from a `hold` entry captured beside the deferred ones, and the count for it can be
right without ever having been non-zero here.
