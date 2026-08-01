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

**Autocreating read**:
A command whose name and output present it as a query, but which provisions
domain state that was absent. `zmprov gmi` and any `zmmailbox` session on an
account with no mailbox are the known cases.
_Avoid_: unsafe read, lazy creation

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
provisioning a mailbox itself.
_Avoid_: probe, prober

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
administrative deletion.
_Avoid_: verified account, known-good account

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

## Reduced service

Three unrelated things degrade, so they carry different names.

**Degraded read**:
An answer obtained from the directory because the mailbox service was
unreachable. It is about **where the answer came from**, and its cost is that
mailbox-derived facts are unavailable.
_Avoid_: fallback mode, LDAP mode

**One-sided gate**:
The existence gate running with a one-sided oracle only. It is about **which
accounts can be served**, and its cost is that some accounts holding real
mailboxes are refused.
_Avoid_: degraded gate, partial gate

**Partial scan**:
A trace answered from fewer log files than the arrival window selected, because
one could not be read. It is about **how much of the evidence was seen**, and its
cost is that finding nothing stops being proof that nothing happened.
_Avoid_: incomplete result, silent skip
