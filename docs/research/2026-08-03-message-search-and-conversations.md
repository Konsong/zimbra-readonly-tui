# Message search and conversation listing — the query language, measured

- **Date:** 2026-08-03
- **Scope:** the two reads issue #35 exposes behind the existence gate
  ([ADR-0001](../adr/0001-mailbox-existence-gate.md)) — `zmmailbox s` and `zmmailbox sc` — and the query
  language they take.
- **Method:** every command below was run on **TEST-C** (`posta.sirket.lcl`, Zimbra 9.0.0 GA FOSS, Ubuntu
  20.04) against the fixture account with a populated mailbox, in five passes, with the account's row in the
  `mailbox` table and the account's own unread set captured before and after. Output is committed under
  `tests/fixtures/` with the addresses and subjects changed and nothing else.

## 1. Both reads change nothing, and neither marks a message read — MEASURED

The account's row in `zimbra.mailbox` was read immediately before and immediately after a pass holding one
capped search, one capped conversation listing and one unread search:

```
before  9  640  265  2458  1785697598  3  2  0
after   9  640  265  2458  1785697598  3  2  0
```

(`id, change_checkpoint, item_id_checkpoint, size_checkpoint, last_soap_access, new_messages,
index_volume_id, tracking_imap`)

Byte-identical, `change_checkpoint` and `last_soap_access` included — the same control the folder reads were
admitted under, and one already shown to be sensitive: a deliberate `mfg` in the same session moved two of
those columns on 2026-08-02
([2026-08-02-folders-size-and-quota.md](2026-08-02-folders-size-and-quota.md)).

**The read state is the sharper control here**, because it is what `gm` would have changed. Across roughly
forty searches and five conversation listings, `s -t message "is:anywhere is:unread"` answered with the same
four message ids before and after, and `gaf` reported `/Inbox` holding four unread items on both sides:

```
before  264 263 262 258      after  264 263 262 258
```

So the source reading in
[2026-07-29-zimbra-cli-read-only-reference.md](2026-07-29-zimbra-cli-read-only-reference.md) §A.4 — that
`ZSearchParams.mMarkAsRead` defaults false and neither `search` nor `searchConv` ever sets it — holds in
practice on 9.0.0.

**Bounded claim.** This says nothing about `gm`, which is not on the allowlist and whose whole purpose is the
opposite: it hard-codes `setMarkRead(true)`.

## 2. The result table's column widths are computed per page

`s` prints `num: N, more: true|false`, a blank line, two header rows, the rows, and one trailing blank line.
A page of 13 hits and a page of 5 hits from the same mailbox, minutes apart:

```
num: 13, more: false

      Id  Type   From                  Subject                                             Date
    ----  ----   --------------------  --------------------------------------------------  --------------
 1.  273  mess   ZimScope              ZimScope toplu ileti 8                              08/03/26 17:46
…
10.  263  mess   ZimScope              ZimScope "tirnakli" konu                            08/03/26 17:38
```

```
num: 5, more: true

     Id  Type   From                  Subject                                             Date
   ----  ----   --------------------  --------------------------------------------------  --------------
1.  273  mess   ZimScope              ZimScope toplu ileti 8                              08/03/26 17:46
```

**Every column moved by one character** between the two, because the index column is `%<w>.<w>s` where `w` is
the digits the largest index on *that page* needs, and the id column is `%<id_len>.<id_len>s` where `id_len`
is `max(4, longest id on that page)`. So a reader built on fixed offsets — which is what the folder listing
is read with, correctly, because its widths are literals in the format string — would be right about a page
of nine hits and wrong about a page of ten. Only the region **left of** the `From` column is
position-predictable at all, and it holds nothing but ASCII digits, a dot and the four-letter type.

`num:` is the server's own count of hits on the page, and `more:` says whether the query had more to give
than the limit allowed. A zero-hit search prints `num: 0, more: false`, a blank line, **and no header rows at
all**.

`-t message` is mandatory for message ids: without it the search type defaults to `conversation`, and the
same query then answers with conversation hits whose ids are the conversation's.

## 3. A conversation id may be negative, and that is not an id this tool can send

The conversation form of the same search, on the same mailbox:

```
1.  265  conv   ZimScope (2)          Re: ZimScope konusma                                08/03/26 17:38
2. -263  conv   ZimScope              ZimScope "tirnakli" konu                            08/03/26 17:38
```

A conversation holding **one** message is a *virtual conversation*, and Zimbra names it with the negation of
that message's id. `sc -263 "is:anywhere"` really works — commons-cli does not read `-263` as an option — and
`sc -- -263 "is:anywhere"` answers identically.

**This tool cannot ask either of them.** A token shaped like a flag standing in the data position is not data
to the exec gate: it is looked up in the allowlist under the subcommand that approved it, and
`zmmailbox:sc:-263` is an entry nobody can write. So the tool refuses a negative conversation id **without
running anything**, and says what it means — a conversation of one message, whose message id is the value
without its sign.

## 4. `sc` takes a query as well as a conversation id

`sc <conv-id>` alone prints the usage banner on **stdout** and exits **1** — it is not an error message and
it does not go to stderr. The two-argument form is the only one that answers:

```
$ zmmailbox -z -m <acct> sc 265 "is:anywhere"
num: 2, more: false

     Id  From                  Subject                                             Date
   ----  --------------------  --------------------------------------------------  --------------
1.  264  ZimScope              Re: ZimScope konusma                                08/03/26 17:38
2.  262  ZimScope              ZimScope konusma                                    08/03/26 17:38
```

**Five columns, not six** — the same table as the search minus `Type`, so the two are read by two readers
rather than one. `-l` and `-t` are accepted before the conversation id.

The query is the tool's own literal `is:anywhere`: a conversation may hold a message that was moved to Trash
or Junk, and the default scope would drop it from a listing that says it shows the conversation.

## 5. The failures, and what tells them apart

Captured verbatim, all on **exit 2** and all on **stderr**:

```
ERROR: mail.QUERY_PARSE_ERROR (Couldn't parse query: is:sarmasik)
ERROR: mail.NO_SUCH_FOLDER (no such folder path: //YokBoyleKlasor)
ERROR: mail.NO_SUCH_CONV (no such conversation: 999999)
ERROR: service.INVALID_REQUEST (invalid request: malformed item ID: abc)
```

An empty query is `QUERY_PARSE_ERROR` too (`Couldn't parse query:` with nothing after it), which is why the
screen refuses to run a search with no criterion rather than sending one.

The folder message carries **two** leading slashes: the server prefixes what it was given with `/`. Both
`in:Inbox` and `in:"/Inbox"` are accepted and answer identically, so a path taken from the folder listing —
which is rooted — is passed as it came.

## 6. The escaping, and why a trailing backslash is refused

Zimbra's rule, from
[2026-07-29-zimbra-cli-read-only-reference.md](2026-07-29-zimbra-cli-read-only-reference.md) §D.2: inside a
`"…"` term a literal double quote is written `\"`, backslash is **not** a general escape, and a newline
cannot appear at all. Measured against a message whose subject really is `ZimScope "tirnakli" konu`:

| Query | Result |
|---|---|
| `subject:"ZimScope \"tirnakli\" konu"` | **1 hit** — the escaped form matches the subject with the quote in it |
| `subject:"ZimScope konusma"` | 2 hits (the conversation) |
| `subject:"ZimScope konusma\"` | **2 hits, exit 0** — the backslash is silently dropped and a *different* value is searched for |
| `subject:"ZimScope konusma\" from:"zimscope-sender@invalid.example"` | **`QUERY_PARSE_ERROR`, exit 2** |
| `subject:"ZimScope konusma" from:"zimscope-sender@invalid.example"` | 2 hits |

**A trailing backslash lets the value terminate its own quoting, and what happens next depends on the rest of
the query.** Alone at the end, the lexer backtracks, treats the backslash as an ordinary character and
answers about a value the operator did not type. With another quoted criterion behind it, the closing quote
is swallowed, the criterion is eaten, and the whole query fails to parse.

Neither outcome is one this tool may pass on: the first is a silent false negative — the answer looks like an
answer — and the second reports a defect an operator cannot repair. So a value carrying a trailing backslash
is **refused before a query is built**, which is the one case the quoter cannot escape its way out of.

## 7. What the operators do, on this server

Each was run as `s -t message -l 5 "<query>"`. "parses" means exit 0 with a `num:` line.

| Query | Result |
|---|---|
| `from:"<addr>"` | 5 hits — the header sender, matched as text |
| `from:@invalid.example` | 5 hits — the leading `@` makes it a whole-domain match |
| `to:"<addr>"` | 5 hits |
| `envfrom:"<addr>"` / `envto:"<addr>"` | parses, **0 hits** — see below |
| `subject:"<text>"` | matches, phrase-wise |
| `msgid:zimscope-konusma-1@invalid.example` | **1 hit** — bare or quoted |
| `msgid:"<zimscope-konusma-1@invalid.example>"` | 0 hits — the angle brackets must come off |
| `in:inbox`, `in:"Inbox"`, `in:"/Inbox"` | 4 hits each |
| `under:"ZimScopeFixture"` | 1 hit |
| `is:read` / `is:unread` | 1 / 4 |
| `is:anywhere` | 5 — Trash and Junk included |
| `has:attachment`, `attachment:any`, `attachment:pdf`, `filename:"rapor.pdf"` | parse, 0 hits (no attachment in this mailbox) |
| `after:1785681629000` / `before:1785854429000` | 3 / 5 — epoch **milliseconds** |
| `after:1785854429000` / `before:1785681629000` | 0 / 2 — the discriminating pair |
| `date:2026-07-01` | **`QUERY_PARSE_ERROR`** |
| `date:-1d` | parses |
| `from:@invalid.example subject:"…" in:inbox is:unread` | 2 hits — criteria combine as an implicit AND |

**Dates are sent as epoch milliseconds and nothing else.** The absolute form is parsed with the request
locale's `DateFormat.SHORT` falling back to `mm/dd/yyyy`; ISO is not accepted at all. A number of
milliseconds means the same thing in every locale, which is the same reason the mailbox size is asked for as
a raw byte count. §8 settles what a *day* means to the two operators that take one.

**The envelope criteria are the one measured gap.** `envfrom:` and `envto:` parse and are refused by nothing,
and on this server they matched nothing at all — including for messages whose envelope sender and recipient
were exactly the values searched for, delivered through this server's own MTA minutes earlier. So an empty
answer from those two is not evidence the envelope was different; it is consistent with the fields never
having been indexed here. The screen says so, because an empty result presented as proof is the worst thing a
search screen can do.

## 8. The day boundary, and why `date:` is not used

Asked because a code review pointed out that the tool was sending an operator nobody had run. The mailbox
holds 13 messages: 11 on 3 August and 2 on 31 July, local time.

| Query | Hits | What it settles |
|---|---|---|
| `is:anywhere` | 13 | the reference |
| `after:<midnight opening 3 Aug>` | **11** | `after:` compares the INSTANT — a range starting on the 3rd keeps the 3rd |
| `before:<midnight opening 3 Aug>` | **2** | and loses nothing of the days before it |
| `after:<3 Aug 00:00> before:<4 Aug 00:00>` | **11** | midnight to midnight is exactly one day |
| `after:<31 Jul 00:00> before:<3 Aug 00:00>` | 2 | and exactly three days is exactly the days named |
| `date:<midnight opening 3 Aug>` | **0** | |
| `date:<3 Aug 12:00>` | **0** | |
| `date:<midnight opening 31 Jul>` | **0** | |

**`date:` is documented as equality over the whole day and does not behave as one for a numeric value.** Pure
digits are read as an instant, and equality against one millisecond matches nothing — silently, on exit 0, on
a day holding eleven messages. So the single-day criterion is **not** `date:`; it is written as the bounded
pair the first four rows prove, `after:<midnight> before:<next midnight>`, and `date:` appears nowhere in the
tool. A criterion that quietly finds nothing is the exact failure this screen is built to avoid.

**The day boundary needed asking at all** because `after:` truncating its value to the END of the day it
falls in was a live possibility, and under that reading a range starting on 3 August would have dropped every
message of 3 August without saying so. It does not: the instant is compared as given.

## 9. The attachment values the menu offers

Also asked because of the review: five of the seven were offered without ever having been run. No message in
this mailbox carries an attachment, so what is being measured is that each parses and what `none` means.

| Query | Hits |
|---|---|
| `attachment:any`, `:pdf`, `:word`, `:excel`, `:ppt`, `:image`, `:text` | 0 each, exit 0 |
| `has:attachment` | 0 |
| `attachment:none` | **13** — every message in the mailbox |

`none` is therefore a real value with the meaning its label claims — messages with no attachment — and not a
word the parser tolerates and ignores. What is still unmeasured is whether the type names match the right
MIME types when an attachment does exist; the mailbox has none to try it on, and the screen claims only that
the criterion was sent.

## 10. What this did not settle

1. **Whether `envfrom:`/`envto:` ever match on a Zimbra where the envelope is indexed.** The criteria are
   offered because the ticket asks for them and the query language accepts them; what is disclosed is that
   this server answered nothing through them.
2. **Whether the quoted form of a domain (`from:"@example.com"`) is still a domain match.** Not measured, and
   not needed: a validated domain carries no character that needs quoting, so the tool builds the bare form
   the measurement covers.
3. **Whether `num:` can exceed the printed row count under `-t message`.** The hits that `dumpSearch` drops
   are wiki, voice, call and id hits, and none of them can be returned for a message search. The screen
   compares the two anyway and says so when they differ, which costs nothing and would make the day it
   happens visible.
