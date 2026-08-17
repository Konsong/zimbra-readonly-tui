# Message detail — the metadata dump and the blob head, measured

- **Date:** 2026-08-17
- **Scope:** the reads issue #29 exposes — `zmmetadump -m <account> -i <item>` for the stored record, and a
  bounded read of the head of the message blob for everything the database does not hold. Also the two
  failure sentences the dump answers with, and what a `gzip -dc | head -c` pipeline really returns.
- **Method:** every command below was run on **TEST-C** (`posta.sirket.lcl`, Zimbra 9.0.0 GA FOSS, Ubuntu
  20.04) as the `zimbra` account, against the fixture account with a populated mailbox. A message carrying an
  attachment was delivered to that mailbox with `sendmail` first, because the mailbox held none and the
  attachment list is read off a MIME structure. Streams were captured **apart** — `>out 2>err` — because
  which of them carries what decides how the reader classifies a failure. Output is committed under
  `tests/fixtures/` with the addresses, subjects and host name changed and nothing else.

## 1. The dump answers on stdout, and every failure answers on stderr — MEASURED

| Command | exit | stdout | stderr |
|---|---|---|---|
| `-m <acct> -i 274` | **0** | 799 bytes, the three sections | **0 bytes** |
| `-m <acct> -i 999999` | **1** | 0 bytes | `invalid request: No such item: mbox=9, item=999999`, two blank lines, stack trace |
| `-m <acct> -i abc` | **1** | 0 bytes | the usage banner, 160 bytes |
| `-m <nosuch@…> -i 1` | **1** | 0 bytes | `invalid request: Account <address> not found on this host`, stack trace |

So a successful dump is stdout-only and every failure is stderr-only, and **all of them exit 1** — which is
why the reader classifies on the message and never on the status, the same rule the existence gate applies to
its own two sentences.

**The usage banner is a failure of this program, not of the operator.** It is what a missing or malformed
`-i` produces, and the vector is built in code: `lib/message.sh` logs it as a defect.

## 2. `not found on this host` covers two different answers, and cannot tell them apart

Both of these produce the identical sentence:

```
zmmetadump -m zimscope-yokboyle-20260817@sirket.lcl -i 1        # no such account anywhere
zmmetadump -m zimscope-fixture-ldaponly-20260731@sirket.lcl -i 1 # account exists, mailbox never created
```

```
invalid request: Account <address> not found on this host
    at com.zimbra.cs.mailbox.util.MetadataDump.lookupMailboxIdFromEmail(MetadataDump.java:193)
```

The dump reads the `mailbox` table and nothing else, so an account with no row there is indistinguishable
from an account that does not exist. The tool reports the weaker of the two — the no-mailbox code — and the
screen says in as many words that either cause produces it, pointing at the existence gate's own screen for
the difference.

**This is also why the address form of `-m` is used and never a mailbox id.** With a numeric id that lookup
is skipped entirely, and a wrong-host id falls through to a query against a table that does not exist —
answering `No such item`, which this program would report as a message that is not there.

## 3. What the dump prints on 9.0.0

Three sections, whose header constants are `public` in Zimbra's own source. The column section on this
schema, for a message (item 274):

```
[Database Columns]
  mailbox_id: 9
  id: 274
  type: 5
  parent_id: <null>
  folder_id: 2
  prev_folders: <null>
  index_id: 274
  imap_id: 274
  date: 1786971466 (Mon 2026/08/17 15:57:46 TRT)
  size: 1117
  locator: 1
  blob_digest: 5iDsvR0c7xLln34hBVGfHiF0eT6s6,qrqk6FJf,Kt+E=
  unread: 1
  flags: 2
  tags: 0
  tag_names: <null>
  sender: ZimScope Fixture
  recipients: zimscope-fixture-populated-20260731@sirket.lcl
  subject: ZimScope ekli ileti
  name: <null>
  mod_metadata: 778
  change_date: 1786971466 (Mon 2026/08/17 15:57:46 TRT)
  mod_content: 778
  uuid: <null>

[Blob Path]
/opt/zimbra/store/0/9/msg/0/274-778.msg

[Metadata]
{
  f = Bu iletide bir ek var.
  s = ZimScope Fixture <zimscope-fixture-populated-20260731@sirket.lcl>
  t = zimscope-fixture-populated-20260731@sirket.lcl
}
```

Four facts the reader rests on:

- A null column prints the literal **`<null>`**, and the query is `SELECT *`, so which columns exist at all
  depends on the schema version. A column that is absent and a column that is null are different facts and
  reach the operator as different words — `bilinmiyor` and `tanimsiz`.
- **`[Blob Path]` is absent when `blob_digest` is null.** Item 2 — the Inbox folder — was dumped as the
  control and printed `[Database Columns]` and `[Metadata]` and no blob path at all.
- The two timestamp columns print `<epoch> (<formatted>)`, and the formatted half is built in the **JVM's
  default timezone** (`TRT` here) in Java's own field order. The tool takes the number and formats it itself,
  for the reason the mailbox size is asked for as a raw byte count.
- **`[Metadata]` carries the message FRAGMENT under the key `f`** — the preview text Zimbra cuts out of the
  body. That is the whole reason this section is not rendered: showing it would be displaying the body under
  another name. The tool's reader stops at the section boundary, so a key there cannot answer as a column
  either.

`flags: 2` on the message with an attachment and `flags: 0` on the messages without one is the only
observation this capture has about that column, which is not enough to decode a bitmask. The number is shown
as the server holds it and the screen says it is undecoded; `unread` is a column of its own and needs no
decoding.

## 4. The blobs on this host are uncompressed, and the volume is what decides

```
   Volume id: 1
        name: message1
        type: primaryMessage
        path: /opt/zimbra/store
  compressed: false
     current: true
```

`head -c 2` of a real blob answers `52 65` (`Re`, from `Return-Path:`), and `gzip -dc` of it answers
`not in gzip format`. Compression is therefore a **per-volume** setting rather than a property of the store,
so the tool asks each file what it is — two bytes — instead of assuming either.

Blob mode is `-rw-r----- zimbra zimbra`, so the account every command in this tool runs as can read it.

## 5. A stored blob is CRLF, and folds its headers both ways — MEASURED

The first bytes of a blob, and the line that ends its header block:

```
R e t u r n - P a t h :   < … >  \r \n  R e c e i v e d :   f r o m …
Content-Type: multipart/mixed; boundary="ZIMSCOPE-SINIR-1"\r$
Date: Mon, 17 Aug 2026 15:57:46 +0300 (+03)\r$
\r$
--ZIMSCOPE-SINIR-1\r$
```

28 carriage returns in the first 1200 bytes. So every reader in `lib/message.sh` strips one trailing
carriage return per line, and "the headers end at an empty line" is true of the file the tool actually opens
rather than of an idealised one.

The same blob folds one `Received` header with a **space** and the next with a **tab**, which is what the
fixture keeps and what the unfolding case in `tests/test_message.sh` is written against.

## 6. `gzip -dc | head -c` under pipefail: 141 is an ordinary answer — MEASURED

| Pipeline | rc |
|---|---|
| 5 MB stream, `head -c 120` | **141** |
| 5 MB stream, `head -c 65536` | **141** |
| 1117-byte stream, `head -c 65536` | **0** |
| 1117-byte stream, `head -c 120` | **0** |
| a file that is **not** gzip, `head -c 65536` | **1** |
| the same, **without** pipefail | **0** |

The bounded reader having had its fill kills the decompression with SIGPIPE, which the shell reports as 141;
a stream that fits inside the pipe buffer finishes before the reader closes it and answers 0. **Neither is a
failure**, and the case that is one stays distinguishable at 1 — which is also why `pipefail` is set at all:
without it, a file that could not be decompressed arrives as an empty head, and an empty head is the one
answer that reader may not invent.

## 7. The database stopped: it retries every five seconds, forever, on STDOUT — MEASURED

`mysql.server stop`, then the dump under a 22-second clock:

```
[exit 124]
stdout bytes: 7828   stderr bytes: 0
retry lines: 4
```

```
2026-08-17 17:14:43,498 [main] WARN : Could not establish a connection to the database.  Retrying in 5 seconds.
com.zimbra.common.service.ServiceException: system failure: getting database connection
	at com.zimbra.cs.db.DbPool.waitForDatabase(DbPool.java:243) [zimbrastore.jar:9.0.0_GA_4200046]
	at com.zimbra.cs.db.DbPool.startup(DbPool.java:234) [zimbrastore.jar:9.0.0_GA_4200046]
	at com.zimbra.cs.mailbox.util.MetadataDump.main(MetadataDump.java:366) [zimbrastore.jar:9.0.0_GA_4200046]
Caused by: java.sql.SQLException: invalid database address: jdbc:mysql://127.0.0.1:7306/zimbra
```

Three things this settles, and all three changed the code:

- **The hang is real and the clock is what ends it.** `DbPool.waitForDatabase` retried
  four times in 22 seconds and would have gone on; the `timeout` wrapper reported 124,
  which the gate turns into this tool's own timeout code.
- **The explanation is on STDOUT and stderr is EMPTY** — the reverse of every other
  failure this binary has (§1). A reader that only kept stderr would leave the one
  screen with something useful to say showing nothing at all, so a failure with an
  empty stderr borrows the head of stdout.
- **Nothing in that text is what the shared Zimbra-error reader looks for.** Its
  patterns are the SOAP path's — `zclient.IO_ERROR`, `SERVICE_UNAVAILABLE`, an expired
  certificate — and this is a `DbPool` exception carrying a JDBC URL. So that reader is
  not consulted for this command at all: an unrecognised dump failure is reported as
  the *database* being unreachable, and the timeout is reported as itself before any
  text is read. Reading it through the shared mapper would have answered a stopped
  database with the screen that names `mailboxd` and `zmcertmgr`.

`mysql.server start` afterwards, and the box was verified back: `mysqladmin status`
answered, the dump of 274 printed its columns, and `zmprov gis` answered for the
account.

## 8. The screen itself, run against the real binaries — MEASURED

The finished module was shipped to that server and driven directly
(`ZRO_SOURCED_ONLY=1 ZRO_UI_BACKEND=stub`, as the `zimbra` account), reading one
message with an attachment, one without, one item that has no blob, an id the mailbox
does not hold, an account with no mailbox row, a compressed blob and a path outside
the store root. Two controls were taken either side of the whole pass:

```
unread before  258 262 263 264 266 267 268 269 270 271 272 273 274 275
unread after   258 262 263 264 266 267 268 269 270 271 272 273 274 275

mailbox row before  9  779  275  11857  1785697598
mailbox row after   9  779  275  11857  1785697598
```

(`id, change_checkpoint, item_id_checkpoint, size_checkpoint, last_soap_access`)

**The unread set is the control that matters here**, because clearing that flag is
exactly what `gm` would have done: the two messages the screen displayed in full — 274
and 262 — are both still in it. The `mailbox` row is byte-identical too, `last_soap_access`
included, which is unsurprising for a read that never talks to mailboxd and is worth
recording because it is the same control the folder reads were admitted under.

The store was untouched: the blob's modification time stayed at its delivery instant
(`15:57:46.495264029`) and its checksum did not move. The compressed copy read through
`gzip -dc` was byte-identical afterwards and still there, and `/etc/shadow`, offered
as a blob path, was refused with code 90 and a logged line naming it.

## 9. What this leaves open

| Question | What would settle it |
|---|---|
| Do the `flags` bits mean what Zimbra's `Flag` class says? | A message per state — flagged, replied, forwarded, draft — dumped and compared. Nothing is decoded until then. |
| Does a compressed volume change the blob path's shape? | A volume with `compressed: true` on a lab box. The reader does not depend on the name, only on the two bytes. |
| What does a message with revisions dump? | A draft saved repeatedly. The current item prints first, so the readers answer about it; the revisions are read by nobody. |
| Does an RFC 2231 encoded file name (`name*=utf-8''…`) appear in practice? | Real mail from a client that writes them. It is shown as the header wrote it rather than decoded. |
