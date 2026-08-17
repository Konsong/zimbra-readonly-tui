# Message detail is the metadata dump plus a bounded blob head, and it stands outside the existence gate

- **Status:** accepted
- **Date:** 2026-08-17
- **Answers:** [ADR-0007](./0007-the-query-is-built-and-a-negative-id-is-refused.md), whose consequence read
  "`gm` stays off the allowlist and message detail stays unbuilt". It stays off the allowlist; this is what
  was built instead.
- **Does not extend:** [ADR-0001](./0001-mailbox-existence-gate.md). This is the first mailbox question in the
  tool that is **not** behind the gate, and the reason is below.
- **Evidence:** [`docs/research/2026-08-17-message-detail.md`](../research/2026-08-17-message-detail.md),
  captured on the lab server, and
  [`docs/research/2026-07-29-zimbra-cli-read-only-reference.md`](../research/2026-07-29-zimbra-cli-read-only-reference.md)
  §A.5, read from source
- **Affects:** the allowlist gains one Zimbra binary and one system binary, `ZRO_STORE_ROOT` becomes the
  fifth declared root, and `lib/message.sh` is the first module that opens a file Zimbra told it about

The read that answers "what is this message" in one call is `zmmailbox gm`, and it **clears the unread flag on
the message it reports**: `doGetMessage` hard-codes `setMarkRead(true)` and no flag disables it. Asking a
mailbox to describe a message would therefore change the mailbox, which is the guarantee this tool exists to
keep. The question is worth answering all the same — an operator holding an id from a search wants the folder,
the size, the date, the addresses and whether there is an attachment — so it is asked somewhere else.

## The decision

**The record comes from the metadata dump, which reads the database and not a mailbox.** `zmmetadump -m
<address> -i <item>` connects to MySQL over JDBC: no `SoapProvisioning`, no `ZMailbox`, no mailboxd. Every
statement in the class is a `SELECT`, the connection is opened with `autoCommit(false)` and is never
committed, and the `[Blob Path]` it prints is a computed string it never opens. Read from source rather than
inferred, and the failure shapes were then measured.

**It needs no existence gate, and that is a consequence of what it reads rather than an exemption.** The gate
exists because `zmmailbox` provisions a mailbox during session setup for an account that has none. The dump
opens no session: an account with no row in the `mailbox` table is answered with `Account … not found on this
host`, which is the fact the gate would have established, obtained without the read that could create one.
So this screen asks the oracle nothing and costs nothing for it — the only mailbox screen in the tool that
does not, and the cost note says so where every other one says the opposite.

**One sentence covers two answers, and the weaker one is reported.** That same message is what the dump says
for an address the directory has never heard of *and* for an account whose mailbox was never created —
measured both ways. It reads the mailbox table and nothing else, so this program may not invent the
difference: the code is the no-mailbox one, and the screen says either cause produces it and points at the
existence screen, which answers in the directory's terms.

**The address form of `-m` is used and a mailbox id never is.** Given a number, the dump skips the lookup
that decides whether the mailbox is on this host, and a wrong-host id then falls through to a query against a
table that does not exist — answering `No such item`, which this tool would report as a message that is not
there.

**The wall-clock timeout is not optional here, and the expiry is reported as itself before any text is
read.** With the database unreachable, `DbPool.startup` loops in `waitForDatabase` with **no bound at all** —
measured with `mysqld` stopped: four retries in 22 seconds, one every five, until the clock killed it. Every
command in this tool already runs under `ZRO_TIMEOUT`; on this screen that clock is the difference between a
tool that says so and a tool that hangs.

**That measurement also decided where the failure text comes from and which reader may touch it.** The retries
arrive on **stdout** and stderr stays **empty** — the reverse of every other failure this binary has — so a
failure that said nothing on stderr borrows the head of stdout, or the one screen with something useful to say
would show nothing. And the shared Zimbra-error reader is **not consulted for this command**: every pattern it
matches belongs to the SOAP path, while this text is a `DbPool` exception carrying a JDBC URL, so reading it
through that mapper would answer a stopped database with the screen that names `mailboxd` and `zmcertmgr`.
Anything this module does not recognise is reported as the service it really needs — the database — and the
screen says in as many words that mailboxd is not part of this read.

**Everything the database does not hold comes from a bounded read of the head of the blob**, and the bound is
in BYTES. A log file is lines and a message is a MIME stream whose base64 part is routinely one line of
megabytes, so `head -c` is the reader and `tail -n`'s bound would have been no bound. What the head yields is
the raw headers, the From, To and Cc, and the MIME structure the attachment list is read off — and the bound
is disclosed, because past it an attachment nobody listed is an absence nobody claimed.

**The blob path is validated before anything opens it, against a character set and against a declared root.**
It arrives in another program's OUTPUT rather than from an operator, which is precisely why it is judged: it
must be absolute, hold nothing outside `[A-Za-z0-9._/-]`, carry no parent-directory component, and sit under
`ZRO_STORE_ROOT`. That root is declared like every other one in this tool — production default, overridable,
**refused rather than searched for when it is empty** — and a path that fails admission is refused with the
path named on the screen. Refusing is visible; opening a file nobody declared is not.

**The file is asked what it is before it is read.** Whether blobs are compressed is a per-volume setting, so
the tool reads the two bytes a gzip stream begins with and then reads the head either directly or through
`gzip -dc` — the one form that writes to stdout and leaves the file where it was. Bare `gzip` and `gzip -d`
both replace the file and delete the original, and both are absent from the allowlist. The alternative to the
two-byte probe — running `gzip -dc` and reading the failure — was rejected: on an uncompressed blob it answers
`not in gzip format`, a failure this program would then have to tell apart from a blob it really cannot read.

**The bounded read of a compressed blob judges its answer, not its exit status.** Under `pipefail` the reader
having had its fill closes the pipe on `gzip`, and how that arrives is a property of the **build**: measured on
three hosts, the lab server and WSL report the SIGPIPE as 141, while the CI runner's `gzip` catches it, prints
`gzip: stdout: Broken pipe` and exits non-zero itself. Normalising 141 alone left every compressed blob larger
than the bound reading as unreadable on the third — green on two machines, red on CI's first run. What
distinguishes the two cases is not a number: a decompression that really failed yields **no bytes at all**, so
a non-empty head is taken as the answer it is and an empty one stays a failure. `pipefail` remains, because it
is what makes the empty case visible rather than a silently successful empty read.

**The body is not displayed, and that rules out the dump's third section as well.** `[Metadata]` carries the
message FRAGMENT under the key `f` — the preview text Zimbra cuts out of the body — so only the column
section and the blob path are read out of the dump at all. In the blob, the header block is shown and each
part is reported by what it says about itself; the bytes between a part's headers and the next boundary are
skipped without being looked at.

**Nothing is decoded that has not been measured.** `flags` is a bitmask, and one observation — `2` on the one
message here that carries an attachment — is not a decoding. The number is shown as the server holds it and
the screen says it is undecoded. `unread` is a column of its own and is the one state this screen names. A
file name written in RFC 2231's encoded form is shown as the header wrote it rather than decoded.

## Consequences

**The allowlist gains two binaries, and each is one operation.** `zmmetadump:-m` is a flag that IS the whole
operation, as the tracer's filters are, so the item id rides behind it as data that the gate reads for
nobody — stated rather than left, and held by a static test to exactly one call site with `--dumpster`, `-f`
and `-s` written nowhere in the tree. `head:-c` is the fourth non-Zimbra binary here and is listed for the
reason `tail`, `gzip` and `grep` are: it reads the content an operator asked for. `head:-n` is deliberately
absent.

**One new exit code, and no undocumented status leaves the module.** `24` is a stored message file that could
not be read. `head` answers 1 for a file that is not there and `gzip` answers 1 for a stream it cannot
decompress; neither is a code `lib/core.sh` defines, and a caller switching on one would be reading a number
nobody documented — so the gate's own codes pass through and everything else becomes 24, the shape
`lib/logview.sh` already gives its own failures.

**A compressed blob is read at reduced priority, and a host without `nice` and `ionice` cannot read one.**
`gzip` is declared low-priority in `lib/exec.sh`, so the promise that whole-file reads yield to the mail
server holds here too — and the refusal that comes with it is the same one the log viewer already discloses
for its compressed files. An uncompressed blob is unaffected.

**The screen costs three invocations, or four for a compressed blob**, and declares the multiple: the dump,
the two-byte probe, and the bounded read. It pays no gate.

**The search screen still does not lead here.** Every row of a message search carries the id this screen is
reached with, and the operator types it: wiring the table to this screen is a ticket of its own, and one that
would have to decide what a row picked from a *conversation* listing means. What the search screen's own
comment used to say — that there is no screen behind it — is now false and has been corrected rather than
left.

**`gm` remains off the allowlist and is now unnecessary as well as unsafe.** The two sources between them
answer everything it would have, minus the body, which is out of scope — and the day someone wants the body
is the day this ADR has to be reopened rather than the allowlist quietly widened.
