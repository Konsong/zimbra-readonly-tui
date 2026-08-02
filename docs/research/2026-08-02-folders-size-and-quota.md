# Folders, mailbox size and quota usage — the four reads behind the gate

- **Date:** 2026-08-02
- **Scope:** the first operations approved behind the existence gate
  ([ADR-0001](../adr/0001-mailbox-existence-gate.md),
  [ADR-0003](../adr/0003-gis-is-the-existence-oracle.md)), for issue #34.
- **Method:** every command below was run on **TEST-C** (`posta.sirket.lcl`, Zimbra 9.0.0 GA FOSS,
  Ubuntu 20.04) against the fixture account with a populated mailbox, in one pass, with the account's row in
  the `mailbox` table captured before and after. Output is committed under `tests/fixtures/` with the
  addresses changed and nothing else.

## 1. The four reads change nothing — MEASURED, with a control

`gaf`, `gaf -v`, `gms`, `gms -v`, `gf /Inbox`, `gf /`, `gfg /Inbox` and two reads of paths that do not exist
were run in that order. The account's row in `zimbra.mailbox` was read immediately before the first and
immediately after the last:

```
before  9  259  700  200  0  0  1785446989  0  0  NULL  0
after   9  259  700  200  0  0  1785446989  0  0  NULL  0
```

(`id, item_id_checkpoint, size_checkpoint, change_checkpoint, tracking_sync, tracking_imap,
last_soap_access, new_messages, idx_deferred_count, highest_indexed, itemcache_checkpoint`)

**Byte-identical, `last_soap_access` included** — so a `zmmailbox` session opened on a mailbox that already
exists writes nothing to that row, not even the access stamp. `mailbox.log` gained no
`Creating mailbox with id` line either: the count of them was 1 before and 1 after.

**The control is what makes that worth anything.** In the same session, immediately afterwards, three
deliberate `mfg` grants were written to `/Inbox` and revoked again. The same row then read:

```
after the writes   9  259  700  300  0  0  1785692994  0  0  NULL  0
```

`change_checkpoint` moved 200 → 300 and `last_soap_access` moved with it. The measurement was therefore
sensitive to exactly the kind of change it was looking for, and saw none from the reads.

**Bounded claim.** This says nothing about a mailbox that does **not** exist: the gate is what stands between
these reads and that case, and ADR-0001 records why no `zmmailbox` invocation may be used to find out.

## 2. `gms` and the locale hazard — the reason `-v` is on the allowlist

| Command | Output |
|---|---|
| `zmmailbox -z -m <acct> gms` | `700 B` |
| `zmmailbox -z -m <acct> gms -v` | `700` |
| `zmmailbox -z -v -m <acct> gms` | `700 B` |

Two things settled here, both by experiment rather than by reading the option table:

- **The flag belongs after the subcommand.** Written in front of it, `-v` is a different option and the
  answer is still the formatted string. So the allowlist approves `zmmailbox:gms:-v` — a flag in the data
  position, the second entry in that list to be one — and the exec gate holds it to the entry that approved
  the subcommand.
- **The default form is locale-dependent.** `formatSize` builds its string with the JVM's default locale, so
  the same mailbox reads `1.44 GB` on one host and `1,44 GB` on the next. A parser that took the digits it
  found would report 1.44 GB as 144 GB on a Turkish, German or French server. The tool asks for the raw
  count, formats it itself with integer arithmetic, and **refuses** any answer that is not all digits — the
  fixture `zmmailbox_gms_synthetic_locale.txt` is that refusal's test, and it is marked synthetic because
  TEST-C has no non-English locale installed to produce one.

## 3. `gaf` — a fixed-width table whose columns come from a format string

```
        Id  View      Unread   Msg Count  Path
----------  ----  ----------  ----------  ----------
         1  unkn           0           0  /
        13  cont           0           0  /Emailed Contacts
         2  mess           1           1  /Inbox
       257  unkn           0           1  /Projeler
```

`%10.10s  %4.4s  %10d  %10d  %s` — so the path starts at column 42 and everything before it is at a known
offset. That is what the reader uses, and it has to: **`/Emailed Contacts` ships with every mailbox Zimbra
creates**, so a reader that split rows on whitespace would be wrong about a standard folder on the first
account it saw.

Three facts that would have been guessed wrong:

- **`Msg Count` is the folder's ITEM count**, not its message count. A contacts folder counts contacts there
  and a calendar counts appointments. The screen labels the column `Oge` and says so.
- **`View` is truncated to four characters** (`mess`, `cont`, `appo`, `docu`, `task`, `unkn`).
- **Hierarchy is only in the path.** Traversal is depth-first from the user root with no indentation, and the
  first row is the root itself, path `/`.

### The decoration, and why no rule strips it

A search folder, a mountpoint and a feed each get a parenthesised suffix **inside** the path column — the
query, the `owner:remoteId`, the URL. None of it is part of the path, and it cannot be told apart from a
folder whose name really ends in brackets: `/Rapor (2026)` is a legal folder name.

So this tool invents no stripping rule. Every row is listed and offered; a path the server then refuses comes
back as `unknown folder` and gets a screen naming both possible causes. Refusing to open a folder is visible;
opening the wrong one would not be. TEST-C has no mountpoint or search folder, so
`zmmailbox_gaf_synthetic_decorated.txt` is marked synthetic and follows the shape the source documents.

## 4. `gf` — JSON, five spaces per level, one key per line

`gf <path>` prints the folder as JSON with no `-v` needed. `gf /` prints the **whole tree**, every child
nested under `subFolders`, which is why the reader takes a key only at the top level's own indentation: at any
other rule, asking about the root would answer with a child's name, path and size.

```
     "defaultView": "message",
     "grants": [],
     "id": "2",
     "itemCount": 1,
     "path": "/Inbox",
     "size": 353,
     "unreadCount": 1,
```

`size` here is the folder's own byte count — the one fact the listing cannot show, and the reason this screen
exists at all. `grants` is `[]` for an unshared folder and opens an array for a shared one, which answers
*whether* without printing the grantee UUIDs it carries instead of names.

## 5. `gfg` — a second fixed-width table, and a different one

```
Permissions      Type  Display
-----------  --------  -------
          r   account  yeni.kullanici@example.com
         rw     group  tum-personel@example.com
          r    public
```

`%11.11s  %8.8s  %s`. A folder with no grants prints the two header lines, nothing else, and **exits 0** —
which is an answer, not an empty read. A `public` grant carries an empty `Display`: it names nobody, and that
is the fact rather than a value nobody read.

The grantee kinds seen were `account`, `group` and `public`; `cos`, `domain`, `all`, `guest` and `key` exist
in the command's own usage line and were not exercised. **Nothing is dropped for not being recognised** — a
card that showed only the kinds it knows would report a folder shared with a whole domain as a folder shared
with nobody.

## 6. What a missing folder says

```
$ zmmailbox -z -m <acct> gf /YokBoyleKlasor
ERROR: zclient.CLIENT_ERROR (unknown folder: /YokBoyleKlasor)   (exit 2)
$ zmmailbox -z -m <acct> gfg /YokBoyleKlasor
ERROR: zclient.CLIENT_ERROR (unknown folder: /YokBoyleKlasor)   (exit 2)
```

Classified on the message and never on the status, for the reason the existence gate gives about its own two
sentences: this binary exits 2 for a folder that is not there and for everything else it fails at.

## 7. Quota usage

The populated fixture account carries `zimbraMailQuota: 5368709120` (5 GB) and a mailbox holding 700 bytes.
Usage is the size read above; the limit is the account entry's, through the same reader the account card uses.
**`zmprov gqu` is not used and is not on the allowlist**: it takes a server rather than an account and answers
for every account on it, which on a server carrying more than 100,000 mailboxes is the class 4 sweep this tool
does not have.

An account with **no** mailbox never reaches any of this: the gate answers first, and the screen it produces
is the existence gate's own — a result, not a failure.

## What this leaves open

| Question | What would settle it |
|---|---|
| Does `gaf` decorate a mountpoint's path exactly as the source says? | A mountpoint on the lab server. TEST-C has none, and creating one needs two mailboxes and a share. |
| What do the remaining grantee kinds (`cos`, `domain`, `all`, `guest`, `key`) print in the `Type` column? | Grants of each kind on a lab folder. The reader passes them through unread, so the answer changes a screen's wording rather than its behaviour. |
| Does `gfg` ever print a denial, the way a distribution list's `zimbraACE` does with a leading minus? | Not producible with `mfg`, whose only negative form is `none` — which removes the grant rather than denying it. |
