# Zimbra Read-Only Administration TUI

A tool an administrator points at a production Zimbra server to answer questions
about it, under a guarantee that asking changes nothing. This file is the
glossary: what the words mean here, and which words to avoid.

## The guarantee

**Read-only**:
The property that running this tool leaves no change to Zimbra-managed domain
state. It is a claim about effect, never about a command's name.
_Avoid_: safe, non-destructive, passive

**Domain state**:
Everything Zimbra manages on an operator's behalf — mailbox contents, item
flags, folders, the existence of a mailbox, directory entries, COS records,
service state. Changing any of it breaks the guarantee.
_Avoid_: data, server state

**Incidental artifact**:
Something a server or tool writes as a by-product of being asked a question —
an audit or access log line, a scratch file, a process cache. Disclosed in the
documentation, but outside the guarantee.
_Avoid_: side effect (too broad — it also covers real writes)

**Declared artifact**:
An incidental artifact a command writes **inside Zimbra's own tree** rather than
to a log — `zmcontrol status` rewrites `.zmcontrol.cache` and leaves temp files.
Admitted only when three things hold together: it changes no domain state, the
screen that runs the command says what it writes, and an ADR records the
judgement. Three conditions, because the alternative is a guarantee that widens
one convenient command at a time. There is exactly one, and
[ADR-0005](docs/adr/0005-zmcontrol-status-is-a-declared-artifact.md) is its
record; the tests hold the screen to the second condition, so an operation cannot
keep the admission after losing the disclosure.
_Avoid_: harmless write, cache write

**Autocreating read**:
A command whose name and output present it as a query, but which provisions
domain state that was absent. `zmprov gmi` and any `zmmailbox` session on an
account with no mailbox are the known cases.
_Avoid_: unsafe read, lazy creation

**Data position**:
Where a command line carries the caller's already-validated values — the account
name, the attribute list, the log file the inventory admitted — everything after
the **subcommand** the allowlist approved. A flag standing there is **not** data:
it changes what the command does, so it is looked up by name like any other
operation and refused when the list does not carry it. An entry that approves a
flag as the whole operation — the tracer's filters, the bounded read — approves
that operation entire, and the data behind it is read by nobody.
_Avoid_: arguments, options, the rest of the command

## Accounts and mailboxes

**Account**:
A directory entry describing a person's identity, quota, class of service and
membership. It exists as soon as it is provisioned and is readable without ever
touching a mailbox.
_Avoid_: user, mailbox, address

**Mailbox**:
The message store belonging to an account — created on first login or first
delivery, not when the account is. An account may have none, and that is the
whole reason the existence gate exists.
_Avoid_: account, inbox

**Home host**:
The server that holds an account's mailbox. Commands that reach a mailbox may
proxy to it; commands that read the local database cannot.
_Avoid_: mail host, mailbox server

**Operator**:
The administrator running this tool. Distinct from the account holder whose
data is being read.
_Avoid_: user, admin

## The existence gate

**Existence gate**:
The precondition that a mailbox is proven to exist before any command that
would touch it is run. It refuses in every direction it cannot answer.
_Avoid_: existence check, pre-flight

**Existence oracle**:
A command used as evidence for the gate. To qualify it must be incapable of
provisioning a mailbox itself. **An attribute is not an oracle.**
`zimbraLastLogonTimestamp` was tried and refuted: it is written by an
authentication that need never register a session, so it is set on accounts that
have no mailbox ([ADR-0003](docs/adr/0003-gis-is-the-existence-oracle.md)).
_Avoid_: probe, prober — a probe asks about this host, never about a mailbox

**Decisive oracle**:
An oracle that answers both ways — it can prove a mailbox exists and prove it
does not.
_Avoid_: strong evidence, reliable probe

**One-sided oracle**:
An oracle that can only ever prove a mailbox exists, never that it does not. Its
evidence is exactly as conclusive as a decisive oracle's; it simply has nothing
to say about the accounts it does not cover.
_Avoid_: weak evidence, partial proof

**Proven account**:
An account whose mailbox the gate has established exists. Proof is monotonic in
practice — a mailbox appears on first use and disappears only by deliberate
administrative deletion — so it is **kept for the session and an absence never
is**. The next delivered message falsifies a no, and an operator who has just
sent a test message must not be told a stale one.
_Avoid_: verified account, known-good account

## Inside a mailbox

**Folder listing**:
Every folder of one mailbox with its path, its item count and its unread count,
read in one command behind the [existence gate](#the-existence-gate). Hierarchy
lives in the **path** and nowhere else: the listing is flat, depth-first from the
root, and a folder path is what every later question about a folder is asked
with.
_Avoid_: folder tree, mailbox contents — nothing here opens a message

**Item count**:
What a folder holds, counted in items rather than messages. A contacts folder
counts contacts and a calendar counts appointments, so five of the folders every
mailbox is created with are not message folders at all. Zimbra prints the column
as `Msg Count`, which is the reason this term exists.
_Avoid_: message count, mail count

**Path decoration**:
A parenthesised suffix Zimbra appends **inside** the path column for a search
folder, a mountpoint or a feed — the query, the `owner:remoteId`, the URL. It is
not part of the path, and it cannot be told from a folder whose name really ends
in brackets. So nothing strips it: the row is offered as it came, and a path the
server then refuses gets a screen naming both causes. Refusing to open a folder
is visible; opening the wrong one is not.
_Avoid_: suffix, annotation

**Folder grant**:
One access control entry on a folder: permission letters, the kind of grantee,
and the grantee. Distinct from a [grant](#domains-and-lists) on a distribution
list — different command, different table, different rights — and read the same
way in the one respect that matters: **nothing is dropped for not being
recognised**, because a card that showed only the grantee kinds this tool knows
would report a folder shared with a whole domain as a folder shared with nobody.
A `public` grant names nobody, and that empty grantee is the answer rather than a
value nobody read.

**Two words on screen, because they are two things.** A folder's grants reach the
operator as `paylasim` and a distribution list's as `yetki`, each used throughout
its own screen and never mixed inside one: an operator looking at a folder is
asking who can see it, and an operator looking at a list is asking who may act on
it.
_Avoid_: share, permission — a share is what a grant produces

**Quota usage**:
What a mailbox is actually holding, read from the mailbox itself behind the gate
and expressed against the **limit** the directory carries. The two come from
different places and the screen says which is which. Usage has no meaning for an
account with no mailbox: that account is answered by the gate, never with a zero.
_Avoid_: quota (that is the limit), disk usage

**Raw byte count**:
A size as a number rather than as a formatted string. The formatted form is built
with the JVM's default locale — `1.44 GB` on one host, `1,44 GB` on the next — so
a reader that took the digits out of it would report a mailbox a hundred times
too large on every Turkish, German or French server. Every size this tool shows
is formatted here, from a count of bytes, and an answer that is not all digits is
[unreadable](#asking-about-an-address) rather than parsed.
_Avoid_: size string, human-readable size — the second is what this is not

## Searching a mailbox

**Search criterion**:
One question a search may be narrowed by — a sender, a subject, a day, a folder —
declared with the operator it becomes and the kind of value it takes. The operator
chooses criteria and supplies values; **nothing an operator types becomes an
operator**, so a query cannot be silently mistyped into a different one. Criteria
combine as *and*: an answer is what satisfies all of them.
_Avoid_: filter, search term — a filter is a tracer flag, and a term is what a
criterion becomes

**Built query**:
The one string a set of criteria turns into, in Zimbra's own query language, sent
as a single element of an argument vector and **shown on the screen above its own
answer**. It is the only thing an operator can check a result against, and on the
day a criterion means something other than its label promised, the only thing that
would show it.
_Avoid_: search string, filter expression

**Query quoting**:
Wrapping a value so the query language reads it as the value it is: a literal
double quote becomes `\"` and **nothing else is escaped**, because a backslash is
an ordinary character there. The third escaping layer, beside the shell safety the
[exec gate](#the-guarantee) provides by passing argument arrays and the pattern
escaping a [delivery trace](#delivery-tracing) needs. A value that would
**terminate its own quoting** — one ending in a backslash — is refused rather than
escaped: it either searches for something else in silence or takes the criterion
behind it down with it, and refusing is the only one of the three that is visible.
_Avoid_: escaping (alone — say which layer), sanitising

**Bounded result**:
An answer capped at a fixed number of hits, where the **search itself was not
bounded**: the server examined the whole mailbox and reported through its own flag
that it had more to give. The opposite trade from a [bounded
read](#delivery-tracing), and a different thing again from a [match-bounded
scan](#searching-logs) — nothing went unread, so a capped answer is not a
[partial scan](#reduced-service) and is never disclosed as one.
_Avoid_: truncated result, and **page** as a name for it — a page is the thing
Zimbra prints, whose column widths it computes from the rows on that one page, and
that meaning is the reason the word may not also mean this one

**Display sender**:
What the result table prints in its sender column: a **display name**, cut at
twenty characters with nothing marking the cut. It is not an address and no
address can be recovered from it — two people can appear under one string — which
is why every screen showing one says so.
_Avoid_: sender, from address — both are what this is not

**Virtual conversation**:
Zimbra's name for a conversation holding **one** message: the negation of that
message's id. It is a real id the server accepts and one this tool will not send —
a value beginning with a dash standing in the [data position](#the-guarantee) is
looked up in the allowlist like any other flag, and no list can carry an entry per
id. So it is answered without running anything, in the words that make it a result:
the conversation holds one message, and the operator is already looking at it.
_Avoid_: single-message conversation (as an id), fake conversation

## One message

**Stored record**:
What the mailbox database holds about one item: the folder it is filed in, the
flags, the size, the date, the subject as the server indexed it, and the path of
the file the message itself is in. It is read **without opening the message** —
the command that would open one marks it read — and it is not the message: a
record answers where a message is and what it weighs, never what it says.
_Avoid_: message detail (that is the screen), metadata (that is one section of
the dump)

**Metadata dump**:
The read the stored record comes from, and the only read in this tool that talks
to the mailbox database **directly**. Every statement in it is a select, its
connection is never committed, and it opens no mailbox session — which is why it
is the one mailbox question that stands outside the [existence
gate](#the-existence-gate) rather than behind it. It has no timeout of its own
and retries **every five seconds, forever**, when the database is unreachable, so
the wall-clock timeout is what ends it and the screen names the database rather
than reporting a server that answered nothing. Its retries arrive on **stdout**
with stderr empty — the opposite way round from every other failure it has — which
is why the screen still has the command's own sentence to show.
_Avoid_: metadata read, dump (alone — a dump of what?)

**Fragment**:
The preview text Zimbra cuts out of a message's body and keeps in the dump's
metadata section, under a one-letter key. It is **body text under another name**,
and it is the reason that section is not rendered at all: a screen showing it
would be displaying the body while claiming not to.
_Avoid_: preview, snippet, summary

**Blob**:
The file one message is stored in, whole, exactly as it arrived — headers, MIME
structure and body in one RFC 822 stream. It is Zimbra's own word. A blob is
**CRLF** and its headers fold with a space or a tab, so it is read as the file it
is rather than as an idealised one.
_Avoid_: message file, EML, raw message

**Blob path**:
Where a blob is, as the [metadata dump](#one-message) computed it. It arrives in
another program's **output** rather than from an operator, and that is exactly why
it is validated before anything opens it: absolute, nothing outside
`[A-Za-z0-9._/-]`, no parent-directory component, and under the declared
[store root](#one-message). A path that fails is refused **with the path named on
the screen** — refusing is visible, and opening a file nobody declared is not.
_Avoid_: file path, blob name

**Store root**:
The declared root every blob this tool opens must sit under. A production default
in a variable an operator can override, like every other root here, and
**refused rather than searched for** when it is empty: there is no second place to
look, and following whatever the dump printed is what the declaration exists to
prevent. It reaches the operator as `blob koku`, on the one screen that has to name
it — the screen that refused a path for sitting outside it.
_Avoid_: store path, mail store, volume (a volume is Zimbra's record, this is a
directory)

**Blob head**:
The beginning of a blob, read with the bound applied by the command that reads
it, and bounded in **bytes** rather than in lines — the difference from a
[bounded read](#delivery-tracing) of a log, and it is not cosmetic: a message's
base64 part is routinely one line of megabytes, so a line bound is no bound at
all. What it answers is the raw headers, the addresses and the MIME structure. The
bound is stated, because past it an attachment nobody listed is an absence nobody
claimed.
_Avoid_: preview, excerpt, first lines

**MIME part**:
One section of a multipart message, reported by **what it says about itself** —
its type, its disposition and its file name — and never by anything between its
headers and the next boundary. A part with a file name, or one the message itself
calls an attachment, is counted as an attachment; a plain-text signature is
introduced by a line that looks exactly like a boundary and is not one, so a part
that says nothing about itself is listed as nothing.
_Avoid_: attachment (that is one thing a part can be), section

## Delivery tracing

**Delivery trace**:
The reconstructed path of a message through the mail transfer agent, assembled
from log lines rather than from anything a mailbox holds. It answers whether a
message arrived and where it stopped, and opens no mailbox.
_Avoid_: message trace, log search

**Log inventory**:
The set of log files this tool will read: base names declared in code, plus the
rotation variants of those names found on disk, each admitted only if its path
matches a strict character set. Nothing outside it is ever read.
_Avoid_: log files, log paths

**Coverage interval**:
The span of time whose lines a rotated log file holds, taken as the range between
the previous file's modification time and its own. Rotation runs in the early
morning, so a file's lines mostly predate its own timestamp — naming a file by
its own date is the off-by-one this term exists to prevent.
_Avoid_: log date, file date

**Bounded read**:
Reading only the last part of a log file, with the bound applied by the command
that reads it rather than after the whole file is in hand. It is what makes a
file of any size safe to open, and it is stated on screen: an operator who reads
a bounded read as the whole file draws a conclusion from an absence nobody
claimed.
_Avoid_: tail (as a noun), preview, excerpt

**Message-id**:
The identifier a mail agent stamps on a message and every log of its hops
carries. It is the one trace filter matched **case-sensitively**, and the one
whose value is not an address — so it has a validator of its own, permissive in
character set and strict about being a single value. A header wraps it in angle
brackets; the tracer records it without them.
_Avoid_: message id (as two words), header id

**Arrival window**:
The time range a trace is restricted to, compared against when a message
**arrived**. A message that arrived before the window and was delivered inside it
falls outside the window.
_Avoid_: time range, delivery window

## The server itself

**Mail queue**:
What the transfer agent is still holding: messages that are neither delivered nor
lost. It is read with the **listing form** of the queue tool and no other — the
forms that flush, requeue, hold or delete live in the same program, and every one
of them makes the server act. Read once per screen, answered as counts first.
_Avoid_: outbox, spool (that is the directory, not the answer)

**Queue status marker**:
The character the queue tool appends to a queue id: `*` being delivered now, `!`
held, and **nothing at all** for everything else. The unmarked case is named
*deferred or newly arrived*, because this output cannot tell those two apart and
naming the likelier one would be inventing a fact.
_Avoid_: queue state, flag — a flag is a message attribute, and this is not one

**Refused by the host**:
An operation the tool ran, was permitted to run, and the server declined —
`authorized_mailq_users` not naming the account every command runs as. It is a
setting on the host with a repair of its own, and it is never reported as an
allowlist denial, which in this program means a defect in the tool.
_Avoid_: denied, permission error — *denied* is the allowlist's word and may not
be borrowed

**Service status**:
Which of this server's services are running, asked of `zmcontrol status` — the
one operation in the tool whose command writes, admitted as a
[declared artifact](#the-guarantee). It reports service state and **changes
none**: the rest of that binary's family is refused.
_Avoid_: health check, uptime

## Host capabilities

**Capability**:
A fact about the host this tool is pointed at — a binary's presence, a version, a
file's readability — observed once per session and used to decide whether an
operation is offered before an operator selects it. It is never a safety check:
the exec gate refuses on its own terms, and the guarantee rests on the gate alone.
_Avoid_: feature flag, precondition, support check

**Probe**:
The act of asking the host one capability question. A probe asks about the host;
evidence about a mailbox is an oracle's. The two words do not cross.
_Avoid_: check, detection

**Refusal reason**:
The single word naming why a capability refused, or that none did. Each answer
names a different repair; a cause an operator would repair the same way as another
does not earn one of its own.
_Avoid_: error code, status, failure reason

## Reduced service

Three unrelated things degrade, so they carry different names.

**Degraded read**:
An answer obtained from the directory because the mailbox service was
unreachable. It is about **where the answer came from**, and its cost is that
mailbox-derived facts are unavailable.
_Avoid_: fallback mode, LDAP mode

**Silent gate**:
The existence gate unable to answer at all, because its oracle speaks SOAP and
the mailbox service is unreachable. It is about **whether any account can be
served**, and its cost is that every mailbox operation is refused until the
service returns. Not reported as a failure: the commands behind the gate would be
equally unusable, so the screen names the cause instead.
_Avoid_: one-sided gate — this design has no one-sided oracle; gate failure

**Partial scan**:
An answer assembled from less than the arrival window selected. It is about **how
much of the evidence was seen**, and its cost is always the same: finding nothing
stops being proof that nothing happened. Two things produce one — a file that
could not be read, and a [match-bounded scan](#searching-logs) that hit its cap
before the last file was opened. They are different sentences on the screen and
the same fact to a caller, so both are disclosed and both report the partial code.
_Avoid_: incomplete result, silent skip

## Cost

Production is one server carrying more than 100,000 mailboxes. Read-only was
never the whole risk: a command that changes nothing can still be a production
event. These words exist so that cost is decided when an operation is designed
rather than discovered when it runs.

**Cost class**:
What an operation costs at production scale, declared as one of five. Class 1 is
a directory read about one account, domain or list. Class 2 is a read inside one
mailbox. Class 3 is a log scan, whose size is the window's, not the server's.
Class 5 is a question this server is asked about **itself** — the mail queue, the
service status — one invocation, and one server to ask however large the
directory on it grows. Class 4 is a server-wide sweep — and class 4 **does not
exist in this tool**. Its number is skipped rather than reused, because the digit
is refused everywhere the declaration is read.
A class names what the work grows with, never how long it takes. It is declared
beside the operation, in the one list the menu is built from, so that an
operation cannot arrive without one; the classes an operation may claim are their
own declaration, and the two are held equal in both directions. **A class no
operation claims is not declared** — class 2 arrived with the existence gate,
which is the first operation to make one, and class 4 waits for nothing, because
a vocabulary that can name a sweep is a vocabulary that will one day be used to
offer one.

**Cost unit**:
What a class's cost is counted in, declared with the class: an **entry** for
class 1, a **mailbox** for class 2, a **file** for class 3, a **host** for
class 5 — where the work grows with what the server itself is doing, the services
installed or the messages queued, and never with the number of accounts. A
screen's cost can
then be checked against the units its own answer named — the entries a record
points at, the files a window covers — rather than against a number written down
beside it. The mailbox and the entry are deliberately different units: a
directory read answers for an account that has never been used, and a class 2
read is the question of whether there is anything there to read.

One invocation usually buys one unit, and three screens show why that is a habit
rather than the rule. [Provenance](#asking-about-an-address) reads ONE entry
TWICE, because the difference between the expanding read and the entry-only one
is the question it asks. It is class 1 all the same: what its work grows with is
entries, and one account costs a fixed two reads however large the directory
around it gets. The two screens that open one [folder](#inside-a-mailbox) do the
same thing a class down: the listing they offer a folder from and the folder
itself are two reads of one mailbox. [Message detail](#one-message) pays THREE for
one mailbox — the stored record, the two bytes that say whether the blob is
compressed, and the blob head — and four when it is, and it is the one class 2
screen that pays no gate at all, because it opens no mailbox session to be gated.
**A screen that pays a multiple declares the
multiple**, and the suite asserts reads-per-unit rather than a total — so a screen
that reached for a second entry still fails against the unit it claimed. The
[existence
gate](#the-existence-gate) runs the other way: one mailbox costs one read the
first time and **none at all** afterwards, because a proof is kept for the
session. That is the only screen whose exact cost is sometimes zero, and it says
so before it runs.
_Avoid_: bound, budget — the unit is what is counted, not a ceiling on it
_Avoid_: performance, expensive — both invite a judgement call where a class is a
rule

**Server-wide sweep**:
A command whose work grows with the number of accounts on the server:
`zmprov gqu`, `gaa -v`, an unbounded `sa`. Refused by design, not bounded and
offered. Where one would have answered — bulk quota, bulk status — the tool asks
the operator for the list of accounts instead.
_Avoid_: bulk query (that is the screen, not the hazard), full scan

**Declared cost**:
What a screen says before it reads anything. For class 3 that is how many files
and how many bytes: an operator about to spend two minutes of the mail server's
disk is entitled to know before it starts, not after. For class 1 it is normally
that the number of queries depends on what the account turns out to name — except
on [provenance](#asking-about-an-address), which is the one screen that can be
exact, and says so, because paying twice for one entry is the reason it is a
screen an operator chooses rather than a field on the card.
_Avoid_: warning, confirmation

## Asking about an address

**Selected address**:
The address the session is currently about, chosen once and carried in every
screen title until it is changed. Every account-scoped operation reads it rather
than asking again — because at two seconds per invocation, retyping is not the
cost that matters, re-running is. It names **what the session is about, never
what a screen filtered on**: a server-wide screen carries it too, and every
report names its own subject on its own first line.
_Avoid_: current user, context account

**Address identity**:
What an address turns out to *be* — an account, an alias and the account behind
it, a distribution list, a resource, or nothing at all. Answered before any
account-scoped screen runs, because `zmprov ga` on a distribution list fails with
`no such account`, and an operator who reads that as "the address does not exist"
goes on to look in the wrong place.
_Avoid_: lookup, account check

**Absent from the directory**:
The identity outcome where every read answered and none of them found anything —
not an account, not an alias, not a resource, not a list. It is **a result, not a
failure**: it is returned as success, and it is the one outcome a query that
could not run may never be reported as. Distinguishing the two is the whole point
of resolving an address at all.
_Avoid_: not found, no such account — the second is a sentence about one read

**Unidentified**:
A selected address whose identity could not be established, because the reads
that would have answered failed. It is a fact about this program, not about the
address: nothing is marked from it, every screen is still offered, and each
refuses on its own terms.
_Avoid_: unknown address, unresolved — an unresolved address sounds like one that
has no answer, and this is one whose answer nobody got

**Operation scope**:
What an operation needs before it can run, as one of three. `account` needs the
selected address to *be* an account — an alias and a resource are accounts, a
list is not. `address` needs an address of any kind: mail to a list appears in
the transfer agent's log under the list's own address, so a delivery trace
answers there as well. `server` needs no address at all.
_Avoid_: category, requires-address — the second collapses the first two, which
is exactly the distinction that keeps a trace available on a list address

**Provenance**:
Whether an attribute is set on the entry or inherited from its class of service.
Only `zmprov ga -e` distinguishes them — `-l` expands COS values exactly as SOAP
does, so a value's presence proves nothing about where it came from. Asked as a
separate screen rather than on the card, because it costs a second invocation.

**Three answers, not two.** The entry-only read cannot answer alone: an attribute
missing from it is either inherited or set nowhere at all, and those are different
facts. So the entry is read in both forms and the difference is the answer — in
both is `hesapta tanimli`, in the expanding read only is `devralinmis`, in neither
is [unset](#asking-about-an-address) and never `devralinmis`.

**Answerable through mailboxd only.** `zmprov -l ga -e` has never been measured, so
it is not on the allowlist, and the degraded read path asks the gate before
retrying rather than having the retry refused as a defect. During a mailbox
service outage this is the one question the tool declines to answer.
_Avoid_: source, origin

**Account card**:
The one screen carrying every directory fact about the selected address, drawn
from a single account read. It is named for what it is — a complete record, not a
selection from one — which is why the attributes it displays are requested
together: a JVM start costs the same for five as for twenty-five, and a field
that arrived with a query of its own would be a field nobody added.
_Avoid_: account summary, account details — a summary implies something was left
out, and what this screen leaves out is only what a second invocation would cost

**Unset**:
An attribute the directory does not carry. `zmprov` omits it entirely rather than
returning it empty, so an account asked for sixteen attributes and answering with
nine is the ordinary case. It reaches the operator as `tanimsiz`, or as `yok`
where the field is a list — aliases, forwarding and memberships are never
inherited, so an absent attribute there means the list is empty. **Never rendered
as a default and never as zero**: Zimbra writes `zimbraMailQuota: 0` to mean
unlimited, and an unknown limit is not no limit.
_Avoid_: empty, null, missing — missing is what an unreadable value is

**Unreadable**:
A value this tool could not obtain or could not parse — a quota nothing answered
for, a timestamp in a shape the reader does not accept, a membership lookup that
failed. It reaches the operator as `bilinmiyor`, and it is deliberately a
different word from unset: one is a fact about the account, the other is a fact
about this program, and they call for different actions.
_Avoid_: unknown attribute, error — an error is something a screen reports, this
is something a field says

## What happens to an account's mail

**Mail settings**:
Everything that decides where an account's mail goes and what it is sent with —
the [filter rule sets](#what-happens-to-an-accounts-mail), local delivery, the
aliases, the [send-as identities](#what-happens-to-an-accounts-mail) and the
signatures. All of it lives on the account entry or on a child entry of it, so
**none of it needs a mailbox**: it answers in full for an account that has never
been used, which is exactly when the question is hardest to answer anywhere else.
_Avoid_: preferences, mail config — the first is one attribute prefix out of
several, and half of these are not preferences at all

**Filter rule set**:
The rules an account's mail is run through, incoming or outgoing. It is **one
attribute holding a whole script** rather than one attribute per rule, so it is
read, shown and reasoned about as a single multi-line value — and a rule set
shown as its first line is not a short answer but a wrong one: the rule that
files invoices is visible and the rule underneath it that discards a sender is
not.
_Avoid_: filters (as a count), sieve — the second is the language it is written
in, which an operator reading the screen never has to know

**Continuation line**:
A line of a value that is not its first. `zmprov` prints them raw, with nothing
marking them as belonging to the value above, and all three of the things that
would identify them by shape are wrong: a continuation may be **blank**, it may
begin with **`#`** — every rule in a filter is introduced by a comment — and it
may read exactly like an attribute line, measured in a captured signature whose
value carries `Tel: 0212 000 00 00`. So what ends a value is **declared**: the
reader is given the attribute list the read asked for, and a line begins a new
attribute only when it begins one of those.
_Avoid_: wrapped line, folded line — LDIF folds with a leading space and this
does not

**Local delivery**:
Whether Zimbra leaves a copy in this account's own mailbox. Disabled, mail goes
only where a forward sends it — and the mailbox stays empty while every other
screen reports a healthy account, which is why it is read beside the forwarding
addresses rather than a screen away. Absent means the attribute is
[unset](#asking-about-an-address) like any other; what Zimbra does in that case
is a fact about Zimbra and is said as one.
_Avoid_: delivery disabled (as a state), mailbox delivery

**Send-as identity**:
A persona an account may send mail under: a from-address, a display name and
optionally a reply-to. It is a child entry in the directory, not an attribute.
**Never called an identity alone**, because this tool already has one — an
[address identity](#asking-about-an-address) is what a selected address turns out
to be — and two concepts sharing one noun is how a screen ends up answering the
wrong question under the right label. Zimbra creates one named `DEFAULT` with the
account itself, carrying the account's own address; the screen says which one
that is, so it is not read as a persona somebody chose to make.
_Avoid_: identity, persona, alias — an alias is an address, and this is a way of
writing one

**Signature**:
A footer an account can sign a message with, held as a child entry with a name and
a body. The **plain-text body is shown**, because the question an operator arrives
with is what a user's outgoing mail looks like and a list of names does not answer
it. An **HTML** signature is named and measured rather than shown: it routinely
carries an embedded image as a data URI, so the markup is not a footer anybody can
read off a terminal. A body is shown to a fixed number of lines and the bound is
disclosed, as every bound in this tool is. An account with **no signatures answers
with no output and success** — a result, and one that reaches the operator as
`yok` rather than as the word this tool keeps for a question nobody could ask.
_Avoid_: footer, sig

## Domains and lists

**Domain**:
The directory entry for a mail domain this server carries. It holds the status
that decides whether mail is delivered to the domain at all, the type, the
catch-all and the default class of service — and it is read for the domain part
of the selected address, never asked for separately, because every address has
one and an address that is nowhere in the directory still has a domain.
_Avoid_: site, tenant, organisation

**Catch-all address**:
Where mail for an address that does not exist in a domain is delivered. It names
a **domain**, not a mailbox — Zimbra refuses anything else — and a domain that
carries none does not deliver such mail at all. Absent reaches the operator as
`yok` rather than `tanimsiz`: nothing is inherited here, so the empty case is an
answer to the question rather than a value nobody could read.
_Avoid_: default mailbox, fallback address

**Distribution list**:
An address that delivers to several others. It is not an account, and an account
read on one fails with `no such account` — which is what
[address identity](#asking-about-an-address) exists to stop being this tool's
answer. Its members, its owners and who may send to it all live on the one
directory entry, so one read answers all three.
_Avoid_: group, mailing list, alias

**Grant**:
One access control entry on a list: a grantee, the kind of thing the grantee is,
and the right it holds. Two rights are grouped by name — `ownDistList` is an
owner, `sendToDistList` is send permission — and **everything else is kept
verbatim rather than dropped**. A **denial** is why: it is written as the right's
own name with a leading minus, so it is not either grouped right, and a card that
showed only what it understood would report a restricted list as an open one. An
**empty** send permission means anyone may send — the opposite of what an empty
list of anything else means — and only where the entry carries no ungrouped grant
to contradict it.
_Avoid_: permission, ACL — and never `right` for the whole entry: the right is
one field of it

**Grantee**:
Whoever a grant is made to. The directory records it as an identifier, so naming
it costs one read per **distinct** grantee — bounded, and every grantee is still
shown: past the bound they appear by identifier and the screen says so.
_Avoid_: user, owner — an owner is one thing a grantee can be

## Searching logs

**Canned search**:
A named question whose pattern the **tool** owns — rejected mail, deferred mail,
bounced mail, local delivery, session activity, mailbox errors. The operator
chooses the question and supplies at most an address. Nothing an operator types
becomes a pattern, so no question can be silently mistyped into a different one.
_Avoid_: preset, filter — a preset is an arrival window, a filter is a tracer flag

**Match-bounded scan**:
Reading a log file in full and stopping after a fixed number of matches. The
opposite trade from a bounded read: coverage is complete and the **output** is
what is capped. It is the answer to a search, where a bounded read is the answer
to a listing — because a search that quietly examined only the newest lines
reports an absence nobody bounded.

Reaching the cap ends the scan where it had got to, so the files not yet opened
are never read. That makes a capped answer a [partial scan](#reduced-service) and
it is disclosed as one. Files are read **newest first** for that reason alone: the
cap has to fall on the oldest evidence rather than on today's, which is what an
operator asking what just happened actually meant.
_Avoid_: grep, bounded search — the bound is on matches, and saying which one
matters is the whole point

**Server-wide question**:
A question about everybody, answered from the logs in one scan: has this
message-id passed through the server, has anything arrived from this domain.
It is the opposite of a [server-wide sweep](#cost) and must never be confused
with one — a sweep's work grows with the number of accounts, and this work grows
with the window the operator chose. Asking either of them per account would be
the sweep; asking them of the log is one pass that opens no mailbox.
The sending-domain one is the **single exception** to the rule beside it that
nothing an operator types becomes a pattern: *arrived from* is a fact about one
field of the line, so the domain — validated as a domain, then escaped — is
interpolated into a pattern the tool owns. A message-id is matched literally like
any other typed value.
_Avoid_: global search, bulk query — a bulk query runs against a list the
operator supplied, and this asks about nobody in particular

**Reduced priority**:
The lowest processor priority and the idle disk class, which every log scan runs
under. Imposed by the exec gate as a property of the binaries that scan rather
than chosen per call, so no operation can be written that scans without it: a tool
for diagnosing a struggling mail server may not compete with it for the disk. A
host that cannot do it is refused the operation rather than given an
ordinary-priority scan.
_Avoid_: nice (as a verb), throttling, rate limit
