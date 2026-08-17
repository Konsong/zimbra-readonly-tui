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
| `ZRO_SYSTEM_BIN` | `/usr/bin` | where `tail`, `head`, `gzip` and `grep` live. A host that keeps one of them elsewhere — Ubuntu before the merged `/usr` ships `gzip` in `/bin` — sets this; the log screens then report the binary as unavailable rather than searching `$PATH` for it |
| `ZRO_STORE_ROOT` | `/opt/zimbra/store` | where the message blobs live. Message detail opens a file **only** if the path the record reports sits under this root; a host whose primary volume is elsewhere sets this, and an empty value refuses every blob rather than searching for one |
| `ZRO_MSG_HEAD_BYTES` | `65536` | how many bytes of a message blob the detail screen reads. The bound is in **bytes**, not lines, and it is what decides how deep into the MIME structure the attachment list can see; the screen says so |
| `ZRO_LOGVIEW_LINES` | `500` | how many lines the log viewer's bounded read is |
| `ZRO_LOGSEARCH_MATCHES` | `200` | how many matching lines one log search may print. The cap is on **matches**, never on how much of a file is read |
| `ZRO_NICE_BIN`, `ZRO_IONICE_BIN` | resolved by path | the two commands every log scan is wrapped in. Set them if this host keeps them somewhere unusual; **how far** the priority is reduced is not settable, because that is a promise this tool makes to the server rather than a preference |
| `ZRO_POSTFIX_SBIN` | `/opt/zimbra/common/sbin` | where the mail queue tool lives. Zimbra ships its Postfix under `common`, not under `bin`; a host that keeps it elsewhere sets this, and the queue screen then reports the tool as absent rather than searching `$PATH` for it |
| `ZRO_QUEUE_DETAIL_MAX` | `50` | how many queue entries the detail behind the counts may show |
| `ZRO_SEARCH_LIMIT` | `50` | how many hits one message search or conversation listing may return. The bound is on the **answer**, never on how much of the mailbox is examined: the server searches all of it and says through its own `more:` flag whether it had more to give, which the screen passes on |
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

- **Hesap karti** — every directory fact about the address, on one screen, from
  one account read: display name, status, canonical delivery address, mailbox
  host, class of service, quota limit, last logon, aliases and distribution list
  memberships, plus the security fields an incident turns on — when the password
  last changed, whether the account is locked out, whether two-factor
  authentication is enabled, and whether it holds administrative rights.

  **The two kinds of forwarding are on separate lines and are never merged.**
  `Kullanici tanimli` is the preference the account holder set themselves;
  `Yonetici tanimli` is the attribute an administrator set, which does **not**
  appear in the account holder's own client. That second line is the one an
  incident turns on, and folding it into the first would hide it from you as
  well as from them.

  **Absence is shown as absence.** Zimbra simply omits an attribute nobody set,
  so a field can read `tanimsiz` (the directory carries no such value), `yok`
  (an empty list of aliases, forwards or memberships) or `bilinmiyor` (this tool
  could not read one). None of the three is ever a default, and none of them is
  zero — an unreadable quota reads as `bilinmiyor`, never as `sinirsiz`, because
  Zimbra writes `0` to mean unlimited and an unknown limit is not no limit.

  The quota line says which read answered it. `hesap sorgusundan` means the
  account read carried the value; it does **not** mean the value is set on the
  account, because `zmprov` expands what a class of service provides in both
  modes. `COS kaydindan` means the account read carried none and the class of
  service was asked instead.
- **Deger nereden geliyor (hesap mi, devralma mi)** — for every attribute the card
  shows, whether the value is set on this account or inherited from a class of
  service. That is what decides where a change would have to be made: one of the
  two is repaired on the account, the other on a record every account sharing that
  class also reads.

  **Presence proves nothing about origin.** `zmprov` expands what a class of
  service provides in *both* SOAP and LDAP mode, so the ordinary read answers with
  the value in force and says nothing whatever about where it was set. That is why
  this is a screen of its own rather than a note on the card.

  **It reads the same entry twice**, once ordinarily and once with `zmprov ga -e`,
  which returns the attributes set on the entry itself and expands nothing. The
  difference between the two answers is the whole screen: `hesapta tanimli`,
  `devralinmis`, or `tanimsiz` for an attribute carried by **neither** read. That
  third answer is not a weaker form of the second — an attribute nobody set
  anywhere is not a value waiting on a class of service, and reporting it as
  inherited would send you to read a COS that has nothing to say about it either.

  A second *form* of the same read is a second invocation however few attributes
  it names, so **the screen says what it will spend before it spends it**. It is
  the one screen in the tool whose cost is exact: two reads, always, whatever the
  account turns out to hold.

  It shows Zimbra's attribute names rather than the card's Turkish labels — the one
  place in this tool that does — because what you do next is read or change that
  attribute somewhere this tool cannot reach, and `Kota limiti` is not a name you
  can search for.

  **It is answerable through mailboxd only.** `zmprov -l ga -e` has never been run
  on the lab server, so it is not on the allowlist; the degraded read path asks the
  allowlist before it retries, and the screen reports the outage that stopped it
  rather than being retried into a denial. See *Commands this release can run*
  below.
- **Dagitim listesi uyelikleri** — the distribution lists the account belongs to.
- **Posta ayarlari (filtre, teslim, imza)** — everything that decides what happens
  to this account's mail: whether local delivery is disabled, both kinds of
  forwarding, the aliases, a summary of each filter rule set, the send-as
  identities and the signatures.

  **It opens no mailbox.** Every fact on it lives on the account entry or on a
  child entry of it in the directory, so the screen answers in full for an account
  that has never been used — which is exactly when "why is this user's mail not
  arriving" is hardest to answer anywhere else.

  **`Yerel teslim: kapali` is the line to read first.** With it set, Zimbra leaves
  nothing in this account's own mailbox: the mailbox can be empty while every
  other screen reports a perfectly healthy account. It is normally set beside a
  forward, which is why the forwarding lines are repeated here from the account
  card rather than left one screen away — a forward with local delivery *on* is a
  copy, and a forward with local delivery *off* is the mailbox never receiving the
  message at all. An absent value reads as `tanimsiz` like every other absent
  attribute; what Zimbra does in that case is said underneath, as a fact about
  Zimbra rather than as a value nobody read.

  The filter rule sets are shown here as a **summary with a line count**, not as
  the script. The full text is the next screen.

  **It reads the account three times**, and the screen says so before it spends
  them: the entry itself, then its signatures, then its send-as identities.
  Signatures and identities are separate entries in the directory rather than
  attributes, so no attribute list on the first read could have carried them.

  **Signatures are shown with their text**, not merely by name — the question this
  answers is what a user's outgoing mail looks like, which a list of names does
  not. A signature written in **HTML** is named and measured instead of shown: it
  routinely carries an embedded image as a data URI, and that is not a footer
  anybody can read off a terminal. A long body is cut to its first few lines and
  the screen says so.

  A signature lookup that fails and an account with no signatures are **different
  answers** and are shown as different words: `yok` means this account has no
  signatures, `bilinmiyor` means nobody managed to ask. The same holds for the
  send-as identities.

  **`Gonderim kimlikleri`, never `Kimlikler`.** A Zimbra identity — a persona the
  account may send mail under — is not the *address identity* on the `Adres
  kimligi` screen, which is what the selected address turns out to be. Two
  different questions, and the labels keep them apart.
- **Filtre kurallarinin tam metni** — both filter rule sets in full, incoming and
  outgoing, exactly as the directory carries them.

  **Nothing is truncated and nothing is tidied.** A rule set is one attribute
  holding a whole script, and `zmprov` prints its remaining lines raw, with nothing
  marking them as continuations — so a reader that took the rest of the matching
  line would show the first rule and hide every rule under it. Blank lines and the
  `#` lines that name each rule are preserved, because that is what makes the text
  match rule-for-rule against what the web client shows the account holder.
- **Mailbox var mi** — whether the account has a mailbox at all. Three answers,
  three screens: the mailbox is there; the account has none *yet*, meaning it is
  provisioned and has never been logged into or delivered to; or there is no such
  account.

  **An account with no mailbox is a result, not an error.** A mailbox is created
  on first login or first delivery, not when the account is, so an account that
  answers `mailboxu yok` is one nobody has used. The screen says so, and it says
  out loud that this tool will not create one: opening a mailbox that is not
  there is exactly how it would be created.

  This screen is the **existence gate** every later mailbox screen is built on.
  It runs one command — `zmprov gis`, which asks for index statistics and throws
  rather than provisioning — and it **remembers a yes for the session**. Asking a
  second time about the same account costs nothing. A *no* is never remembered,
  because the next message delivered to that account makes it wrong.
- **Kota kullanimi** — the limit the account is subject to, the bytes the mailbox
  is actually holding, and the proportion between them. An unlimited quota is
  said in words rather than divided into, and a limit this tool could not read is
  `bilinmiyor` and never `sinirsiz` — Zimbra writes `0` to mean unlimited, and an
  unknown limit is not no limit.

  The limit comes from the directory and the usage from the mailbox, and the
  screen says which is which. Usage was absent from this screen for one release
  and the command that used to report it is still nowhere in this tool — what
  answers now, and why the whole-server quota command was not taken instead, is
  *How usage came back* in section 5.
- **Mailbox boyutu** — the size of the whole mailbox, in bytes and in readable
  form. Both, always: the readable form is what you read and the byte count is
  what you can check against a quota or a previous reading.
- **Klasorler** — every folder with its path, its item count and its unread
  count, plus the totals.

  **`Oge` is not `ileti`.** The column Zimbra prints under *Msg Count* is the
  folder's **item** count: contacts in a contacts folder, appointments in a
  calendar. Five of the folders every mailbox is created with are not message
  folders at all.
- **Klasor detayi** — one folder, chosen from that listing, with the one fact the
  listing cannot show: how many **bytes** the folder is holding. It also says
  whether the folder is shared, without naming who — the folder record carries
  grantees as identifiers, and the sharing screen is what answers in names.
- **Klasor paylasimlari** — who may reach one folder: the permission letters, the
  kind of grantee, and the grantee. **Every grant is shown**, whatever kind it
  names — a `public` grant covers anyone with the link and names nobody, which is
  why its grantee column reads `(herkes)`.

  The last two screens offer the folder listing first and then the folder, so
  each costs **two** queries; the screen says so before it runs. Opening a second
  folder without leaving the list does not re-read it.

  **A folder the listing offers and the server then refuses** gets a screen of
  its own naming both causes. The likeliest is not a typing mistake: a search
  folder, a mountpoint and a feed each carry a parenthesised decoration *inside*
  the path column — the query, the owner, the URL — and none of that is part of
  the path. This tool cannot tell such a row from a folder whose name really ends
  in brackets, so it offers both and refuses to guess.

  **Every one of these five refuses before it opens anything** if the account has
  no mailbox. What you get then is the existence gate's own screen — the account
  is provisioned and has never been used — rather than a failure box.
- **Ileti arama** — where a message is, asked of the mailbox itself: sender,
  sender domain, recipient, envelope sender, envelope recipient, subject,
  Message-ID, a day, a day range, attachment name, attachment type, read or
  unread, one folder, and the whole mailbox. Criteria combine with **and**, and
  however many you set, the search is **one** query.

  **You do not type a query.** You pick a criterion from a list and give it a
  value; the tool writes the query and shows it above the answer, so what was
  asked can be checked against what came back.

  **The `Kimden` column is not an address.** The server prints a display name
  there and cuts it at twenty characters without saying so, so two people can
  appear under one string and no address can be recovered from it. The subject is
  cut at fifty the same way. Both cuts are Zimbra's, not this tool's.

  **An empty result is a result**, and it is drawn as one rather than as a
  failure. Two things make an empty answer mean less than it looks like: the
  default scope **leaves out Trash and Junk** until you add the *Butun mailbox*
  criterion, and the two envelope criteria answered nothing at all on the
  laboratory server even for messages whose envelope was exactly the address
  searched for — the screen says so before you use them.

  **A value may not end in a backslash.** In Zimbra's query language a trailing
  backslash closes the quoting the tool put around your value: measured, the
  server then either searches for something else and says nothing about it, or
  refuses the whole query. The tool refuses the value instead, which is the one
  case escaping cannot fix.
- **Konusma arama ve konusmadaki iletiler** — the same criteria, asked for
  **conversations** rather than messages, and then one conversation opened to
  list the messages in it. The listing is made with `is:anywhere`, so a message
  moved to Trash or Junk still appears in the conversation it belongs to.

  It costs one query for the search and **one more for each conversation you
  open**; the screen says so before it runs.

  **A conversation id beginning with a minus holds exactly one message.** Zimbra
  names such a conversation with the negation of that message's id. This tool
  will not put a value beginning with a minus on a command line — it would be
  read as an option — so that row is answered from what is already on the screen,
  without a query: the message is the one you just picked, and its id is the
  value without its sign.
- **Ileti detayi (kayit ve basliklar)** — one message, asked for by the **id** the
  search screen prints: the folder it is filed in, its size, its date, its subject,
  whether it is unread, the path of the file it is stored in, and then — from the
  beginning of that file — the raw headers, the From, To and Cc addresses, and the
  list of MIME parts with their file names.

  **The message body is not shown**, and this screen does not read it. Nor does it
  show the dump's `[Metadata]` section: that section carries the *fragment*, which is
  preview text Zimbra cuts out of the body, so showing it would be displaying the
  body under another name.

  **It marks nothing read, which is the whole reason it is built this way.** The one
  Zimbra command that answers this question in a single call — `zmmailbox gm` — clears
  the unread flag on the message it reports, unconditionally, with no flag to prevent
  it. So the record is read straight from the mailbox database and the headers from
  the file on disk, and neither of those touches the message.

  **It is the one mailbox screen that costs no existence gate.** It opens no mailbox
  session at all, so there is nothing for the gate to protect: it costs the record
  read plus two reads of the file — three in all, four if the file is compressed —
  and the screen says so before it runs.

  **An id belongs to one mailbox.** Ids are unique per mailbox, so an id taken from
  one account's search results names nothing, or names something else, in another
  account's. The screen says that when the id is not there, because it is the
  likeliest cause and it is not a typing mistake.

  **`Mailbox bu sunucuda yok` means two things and says so.** The dump reads the
  mailbox table and nothing else, so the same sentence covers an address the
  directory has never heard of *and* an account whose mailbox has never been created.
  Which of the two it is comes from the **Mailbox var mi** screen, which asks the
  directory.

  **A timeout here is about the database, not about a slow mailbox.** The dump
  connects to MySQL directly and, if the database does not answer, retries forever
  with no bound of its own — so the tool's own clock is what ends it, and the screen
  names that rather than reporting a server that said nothing.

  The **flags** column is shown as the number the server holds. It is a bitmask
  whose bits this tool has not measured, so it is not decoded; `unread` is a column
  of its own and is reported in words.
- **Dagitim listesi karti** — who receives mail sent to this address, who owns the
  list, and who may send to it: the three facts a message rejected by a list is
  explained by. Members, owners and send permissions all live on the list's own
  entry — the last two as access control entries rather than as fields of their
  own — so one read answers all three questions, plus one read per **distinct**
  grantee to turn an identifier into an address.

  **An empty send permission means the opposite of what an empty anything else
  means.** Zimbra enforces that right only when somebody holds it, so a list nobody
  was granted it on accepts mail from everyone; the line reads *kisitlama yok
  (herkes gonderebilir)* rather than `yok`. This is the one line on the card that
  states Zimbra's rule instead of reporting a measurement — the lab server carries
  no MTA, so no message can be sent to a list on it at all. The fields above it
  report only what the directory holds.

  **Unless the list carries a grant this tool did not recognise, and a denial is
  exactly that.** Measured on the lab server: a denial is written as the right's
  own name with a leading minus, so it is neither of the two rights the card groups
  and it appears under *Diger yetkiler* instead. The send line then reads
  *belirsiz* and the screen says in as many words not to read it as "no
  restriction" — a list whose only send grant is a denial is a restricted list, and
  the sentence underneath is the one place the card could have described it as an
  open one. Nothing is dropped for not being understood, so a right a later Zimbra
  release adds lands there too rather than vanishing.

  Grantees are stored as identifiers. Twenty are named; past that they are shown as
  the identifier the directory holds and the screen says so, because a list with
  fifty owners is otherwise fifty invocations on a screen nobody expected to wait
  for. **None is ever omitted.** A `pub` grant names no entry at all — it is a fixed
  sentinel — so it is said in words instead of looked up.

  Members are read from the directory. A list that is a member of this one appears
  under its own address and is not opened, and the screen says so. The entry reads
  `BU ADRES LISTE DEGIL` for an address that is not a list.
- **Alan adi karti** — the domain of the selected address: its status, its type in
  the directory's own word, its catch-all, and the class of service accounts
  created in it get by default. The domain is derived from the address and never
  asked for.

  **It is the only directory screen that still answers for an address the directory
  has never heard of.** Every address carries a domain, so when the account read has
  nothing to say this one still answers whether this server carries that domain's
  mail at all. The two traces answer for such an address too, but they answer from
  the transfer agent's log rather than from the directory.

  Status is where a delivery problem often turns out to end: a domain that is not
  `active` has its mail blocked by Zimbra itself, and the screen says so rather than
  leaving you to look further down the delivery path. A catch-all shown as `yok` is
  a real answer and not an unread one — nothing inherits a catch-all — and it means
  mail to an address that does not exist in this domain is delivered nowhere. A
  domain type this tool does not recognise is shown **as it stands**, because it is
  a fact the directory carries and a newer Zimbra than this tool is not a value
  nobody could read.

  It costs one read, plus one more to name the class of service the first one
  answers with an opaque id. **Its five attributes are requested by name**, and here
  that is not only about cost: an unfiltered `zmprov gd` answered with 111 lines on
  the lab server, and among them, in the clear, the bind password of the directory
  the domain authenticates against. A screen is a thing an operator takes a
  screenshot of.

  **The account count is deliberately absent, and the screen says so** where
  somebody who came for the number will read it. Counting the entries in a domain on
  a server carrying more than 100,000 accounts is a server-wide sweep, and this tool
  has no operation whose work grows with the number of accounts.
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
- **Log arama (dosyalarin tamaminda)** — described below.
- **Mail kuyrugu (bekleyen iletiler)** — described below.
- **Servis durumu** — described below.

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

*Log arama (dosyalarin tamaminda)*:

- The other half of the viewer above, and the opposite trade. Pick a **question**
  — rejected, deferred or bounced mail, local delivery, account sessions, mailbox
  errors — or search **free text**, choose a window, and every log file that
  window covers is read **from its first line to its last**.

**This is the one screen in the tool where finding nothing means something.** The
viewer reads the end of a file, so an absence there is only an absence in the last
five hundred lines. Here every selected file is read whole, so *kayit yok* on a
complete scan means the thing did not happen in those files — and the screen says
which files those were. On the lab server the delivery outcomes sit in the first
fifth of the mail log: a bounded read does not reach them, and this does.

**Two of the questions are about everybody**, not about the selected address:

- *Ileti kimligi sunucudan gecti mi* — whether one message passed through this
  server at all. It searches the **mail log**, which writes the identifier twice
  per message — `message-id=<X>` where Postfix cleans it up and `Message-ID: <X>`
  in the amavis line — so the **bare** identifier is what is searched, and it finds
  both. Paste it with or without its angle brackets. (`mailbox.log` writes the same
  identifier a third way, `msgid=<X>`, for a message delivered locally; that is a
  second record of a subset rather than a second source, and the free-text door
  reaches it.) Matched **case-sensitively**, as the prompt says: an identifier is a
  token some agent generated, not a name.
- *Bu alan adindan mail geldi mi* — whether anything arrived from a domain,
  matched on the **envelope sender** (`from=<…@domain>`) rather than anywhere on
  the line. Mail *to* that domain is not in the answer, and the screen says so:
  the captured rejection carries a recipient at one domain on the same line as a
  sender at another, so a whole-line match would report the two as the same thing.
  Matched **without regard to case**, because a domain is the same domain however
  it was typed and however the sending client wrote it — the opposite rule from
  the identifier above, and for the opposite reason.

Asked per account, each would be a query per mailbox and a gate check per account.
Asked of the log they are **one scan** of the window's files, and they open no
mailbox — which is why they are here and a server-wide sweep is nowhere.

**You never type a pattern.** The named questions carry patterns this tool owns,
each keyed on a line a real server really wrote — a rejection has the literal
`NOQUEUE` where every other line carries a queue id; local delivery is the `lmtp`
hop rather than the first `status=sent`, which only means amavis took it; a
session is `cmd=Auth` because that is on a successful login and a failed one
alike. Free text is matched **literally**, so `ali+fatura@example.com` matches
itself instead of being read as a pattern with a quantifier in it.

**One value does reach a pattern, and only one**: the sending domain, because
*arrived from* is a fact about one field of the line and no whole-line match can
express it. Two things make that safe and they hold together — the value is
validated as a domain first, which admits letters, digits, dots and hyphens and
nothing else, and it is escaped second, so `mail.example.com` cannot also match
`mailXexample.com`. A message-id, by contrast, is matched literally like free
text.

**The message-id question is not the delivery trace.** *Teslim takibi: ileti
kimligine gore* asks `zmmsgtrace` to assemble a message's hops into a report and
is the better answer where it can run. This one reads the log itself and shows
every line carrying the identifier as it was written — which is what answers on a
host with no tracing binary, and what shows the lines the tracer does not parse.

**A window is required and there is no unbounded range.** It chooses *files*, not
lines: nothing here parses a timestamp, so the files it selects are read end to
end and the answer can carry lines from a little either side of the range. The
screen says so, because an operator who read it as a line filter would think the
tool had ignored them.

**The cost is declared and confirmed before anything is read** — how many files
and how many bytes, from the same selection the scan then uses. The number is the
size on disk; a compressed rotation is several times that once opened, and the
screen says so rather than inventing a multiplier. This is cost class 3 made
visible: the decision to spend it is yours, at a moment when you can still decline.

**Scans yield to the mail server.** Every reader runs at the lowest processor
priority and in the idle disk class, so a search for a problem does not deepen the
problem it is looking for. That is imposed by the gate rather than by this screen,
so no operation can be written that scans any other way — and a host without
`nice` and `ionice` gets the entry marked `KULLANILAMAZ` rather than a scan that
quietly competes with delivery.

**The output is capped, not the input** — two hundred matching lines by default.
Reaching the cap is disclosed in the answer and in the screen's title, together
with the files the scan therefore never opened. That is the difference between
"this did not happen" and "I stopped looking", and the screen is not allowed to
blur it.

A file that could not be read makes the answer a **partial scan**: the answer that
could be found is shown, under a banner naming the files that were missed and
`zmfixperms`, and the title carries the warning too. Nothing found in a partial
scan is reported as the partial scan it is and never as an empty result.

**Searching `audit.log` can show you a password.** Not one this tool reads or
stores — one Zimbra itself wrote there. `zmprov` records administrative changes in
that file with their values, so a domain modified with an external directory bind
password has that password in the clear in the log. None of the named questions
matches such a line, but free text searches whatever you type, and the tool prints
what the file says without editing it. Treat the audit log the way you would treat
the file itself.

*Mail kuyrugu (bekleyen iletiler)*:

- What is waiting to be delivered on this server, answered **counts first**: how
  many entries the queue holds, and how many of them are waiting, held, or being
  delivered right now. The detail behind those numbers is one keystroke away and
  is **bounded** — fifty entries by default.

**The queue is read and nothing else.** `postqueue -p` lists; the forms of the
same program that flush the queue, flush one site, requeue one message or delete
one are **not on the allowlist and never will be**. Every one of them makes the
transfer agent act — mail leaves, a remote host is contacted, bounces are
generated — which is a change to what the server does with your mail even though
no message is edited. If you need to flush a queue, do it from a shell,
deliberately, as yourself.

**The status comes from the marker Postfix puts on the queue id**: `*` is being
delivered now, `!` is held, and an id with no marker is waiting — deferred, or
just arrived and not yet picked up. The screen says so, because those last two
cannot be told apart in this output and guessing between them would be this tool
inventing a fact.

**Reading the queue costs one invocation whatever it holds.** A queue of ten
thousand entries and an empty one cost the same; what a large queue would cost is
the *screen*, which is why the counts come first and the list is bounded. The
detail is rendered from the listing already in hand, so opening it does not query
the server again — and the two screens cannot disagree about a queue that moved
between them.

An empty queue is an **answer**, not a failure, and says so — with the reminder
that an empty queue does not mean nothing was lost: a message that has already
left the queue is a question for the delivery trace and the logs.

*Servis durumu*:

- Which of this server's services are running and which are not, one line per
  service, with the counts above them. A stopped service is the only thing on the
  screen in upper case, because it is what you came to find.

**This is the one screen in the tool whose command writes something**, and it
says so in the same box as its answer. `zmcontrol status` starts and stops
nothing, and changes no account, mailbox, folder, flag or setting — but it
rewrites `.zmcontrol.cache` inside Zimbra's own tree and leaves temporary files
behind. That makes it a **declared artifact**, admitted under three conditions
that hold together: no domain state changes, the screen says what it writes, and
[ADR-0005](adr/0005-zmcontrol-status-is-a-declared-artifact.md) records the
judgement. Remove any one of the three and the operation comes out with it.

**It can block, and what ends it is this tool's timeout.** The command asks the
directory server before it asks anything else and has no alarm of its own around
that step, so an unresponsive LDAP leaves it waiting indefinitely. The wall-clock
bound every command here runs under is what cuts it, and the screen reports the
expiry as itself — naming the directory as the place to look — rather than as a
server that answered nothing.

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

**The mail queue entry carries the same mark for two causes of its own**, and
they have nothing in common:

- **The queue tool is not on this build.** No mail transfer agent, so no queue and
  no setting that would produce one. The repair is a package, and the screen says
  where the tool was looked for.
- **This host refuses the read.** The tool is there and Postfix's own
  `authorized_mailq_users` does not list the `zimbra` account. The repair is that
  setting — the screen names it and its permissive default — and the tool does not
  escalate around it, exactly as it does not read an unreadable log as `root`.

The second can only be learned by being refused: that setting is read *inside*
`postqueue`, so there is nothing this tool could stat beforehand. It asks once,
remembers the refusal for the session, and marks the entry from then on rather
than charging you for the same refusal twice.

**The log search entry carries the mark for one cause, and it is not about a
log.** `nice` or `ionice` is missing, so this host cannot run a scan the way this
tool promises to run one — at the lowest processor priority and in the idle disk
class. The repair is a package (`coreutils` and `util-linux`), or pointing
`ZRO_NICE_BIN` and `ZRO_IONICE_BIN` at wherever they live. The scan is **refused
rather than run at ordinary priority**: a search that competes with delivery on a
struggling mail server is not the operation you were offered. Which log files are
readable is not asked here at all — that is answered file by file by the scan
itself and disclosed as a partial scan, exactly as the viewer answers it.

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
UYARI: mailboxd yanit vermedi; degerler dogrudan LDAP uzerinden okundu.
       Dizinde tutulmayan bilgiler bu ekranda gorunmez.
```

What still works, and what does not:

| Screen | With mailboxd down |
|---|---|
| Hesap karti | works in full |
| Deger nereden geliyor (hesap mi, devralma mi) | **refused** — the entry-only read has no approved LDAP form |
| Dagitim listesi uyelikleri | works in full |
| Posta ayarlari (filtre, teslim, imza) | works in full — all three reads have an approved LDAP form |
| Filtre kurallarinin tam metni | works in full |
| Dagitim listesi karti | works in full |
| Alan adi karti | works in full |
| Mailbox var mi | **refused**, with the cause named |
| Every screen behind the existence gate | **refused** by the gate, before anything is opened |

Every directory screen that has an approved LDAP form keeps working, and all but
one of them has. The exception is provenance, and it is refused for a reason of
its own rather than by the gate: `zmprov -l ga -e` has never been measured, so it
is not on the allowlist, and this tool does not add an entry on a family
resemblance. Asking the allowlist before the retry is what makes that a reported
outage instead of an allowlist denial — which would be logged as a defect in the
middle of an ordinary incident.

**The one screen that cannot is the existence gate, and that is called a silent
gate.** Its oracle speaks SOAP and has no LDAP form at all — `zmprov -l gis`
answers `invalid request: can only be used with SOAP`, because index statistics
are not in the directory. So while `mailboxd` is unreachable the gate cannot
establish anything about any account, and it refuses instead of guessing:

```
Mailbox sorusu yanitlanamiyor
```

**Read that as a refusal, never as an absence.** An outage reported as "this
account has no mailbox" would be the most damaging sentence this tool could
produce, so it is not a sentence the tool can produce: the gate distinguishes a
message it recognises from a question it could not ask, and only the first is an
answer.

**It costs you nothing you could otherwise have had.** Every command behind the
gate reaches the same service, so with `mailboxd` down none of them could have
answered either. The screen says this too, because a bare refusal during the
incident the tool exists to diagnose reads as a broken tool.

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
zmprov ga -e     entry-only account read    (no LDAP form — see below)
zmprov gam       getAccountMembership       zmprov -l gam   same, from LDAP
zmprov gc        getCos                     zmprov -l gc    same, from LDAP
zmprov gdl       getDistributionList        zmprov -l gdl   same, from LDAP
zmprov gd        getDomain                  zmprov -l gd    same, from LDAP
zmprov gis       getIndexStats              (no LDAP form — see below)
zmprov gsig      getSignatures              zmprov -l gsig  same, from LDAP
zmprov gid       getIdentities              zmprov -l gid   same, from LDAP
zmmailbox gaf    getAllFolders              behind the existence gate
zmmailbox gf     getFolder                  behind the existence gate
zmmailbox gfg    getFolderGrant             behind the existence gate
zmmailbox gms -v getMailboxSize, raw bytes  behind the existence gate
zmmailbox s      search                     behind the existence gate; -t message for
                                            messages, no -t for conversations, -l bounds
                                            how many hits come back
zmmailbox sc     searchConv                 behind the existence gate; the messages of one
                                            conversation, -l bounds them
zmmetadump -m    the stored record of one item, read straight from the mailbox
                 database; NOT behind the existence gate, because it opens no session
zmcontrol -v     version
zmcontrol status service status — THE ONE ENTRY HERE THAT WRITES; see below
zmmsgtrace --recipient                      delivery trace by recipient
zmmsgtrace --sender                         delivery trace by sender
zmmsgtrace --id                             delivery trace by message-id
postqueue -p                                the mail queue, listing form ONLY
tail -n                                     the log viewer's bounded read
head -c                                     the bounded head of a message blob, in BYTES
gzip -dc                                    decompress a rotated log or a compressed
                                            message blob TO STDOUT
grep -a -F                                  the log search, matching text LITERALLY
grep -a -E                                  the log search, with a pattern THIS TOOL owns
grep -a -F -m / grep -a -E -m               the cap on how many matches are printed
```

**Two of these have no LDAP form, and in both cases that was decided rather than
left out.** `zmprov -l gis` cannot answer at all — index statistics are not in
the directory — and `zmprov -l ga -e` has never been run on the lab server, so it
is not written down here on the strength of resembling one that has. The tool
asks the allowlist *before* it retries a read against LDAP, so a question it can
only answer through `mailboxd` reports the outage that stopped it rather than an
allowlist denial, which would mean a defect nobody committed.

**`gsig` and `gid` read child entries, not attributes.** A signature and a send-as
identity are entries of their own in the directory below the account, which is why
no attribute list on the account read could have carried them and why the mail
settings screen costs three reads instead of one. Both were measured against an
account with **no mailbox** on 2026-08-03: they answered, and `zmprov gis` still
reported no mailbox for that account afterwards — the same control the folder
reads were admitted under. `csig`, `msig`, `dsig`, `cid`, `mid` and `did` are one
letter away, change what a user sends as, and are absent from the list and
therefore refused. See
[`docs/research/2026-08-03-mail-settings-and-multiline-attributes.md`](research/2026-08-03-mail-settings-and-multiline-attributes.md).

**`zmmailbox` is on this list as six reads, and every one of them is refused
until the existence gate has answered.** That binary creates a mailbox for an
account that has none during session setup, so a single function owns its whole
argument prefix, the exec gate refuses the binary from any other caller, and a
static test fails the build if another call site so much as names it. The gate
shipped with nothing behind it and these six arrived afterwards, each with the
ticket that exposes it — an operation is never approved because the binary it
belongs to became reachable.

**The search reads a mailbox and marks nothing read**, which is the question that
decides whether it may be here at all. `zmmailbox gm` — message detail — clears
the unread flag on the message it reports, and it is nowhere in this tool. `s` and
`sc` were measured on 2026-08-03: the account's row in the `mailbox` table was
byte-identical either side of both, and the same four message ids answered
`is:unread` before and after roughly forty searches and five conversation
listings. See
[`docs/research/2026-08-03-message-search-and-conversations.md`](research/2026-08-03-message-search-and-conversations.md).

**The four reads that arrived before the search were measured the same way**, and
this paragraph is about those four rather than about all six. On the lab server
the account's row in the `mailbox` table was byte-identical either side of all
four — change checkpoint, size checkpoint and last SOAP access included — while a
deliberate grant write in the same session moved two of those columns at once,
which is what makes the measurement worth anything. See
[`docs/research/2026-08-02-folders-size-and-quota.md`](research/2026-08-02-folders-size-and-quota.md).

**`gms` is approved with `-v` and used no other way.** Without it the command
prints a string built with the JVM's default locale — `1.44 GB` on one host,
`1,44 GB` on the next — and a decimal comma read as a thousands separator is a
mailbox reported a hundred times too large. `-v` prints the raw byte count, which
is a number in every locale there is, and this tool does its own formatting. The
flag stands **after** the subcommand, which is where it was measured to work; in
front of it, it is a different option and the answer is still the formatted
string.

The write-named siblings that live one letter from these — `df`, `ef`, `cf`,
`mfg`, `rf`, `sf` — are absent and therefore refused, and so is `gm`: it is not
write-named and it **clears the unread flag** on the message it reports, which is
the *judge by effect, not by name* rule doing its work inside a binary this tool
now reaches.

**`zmmetadump` is how message detail is answered without opening a message**, and it
is the one command here that talks to the mailbox **database** rather than to a
service. Read from source: every statement in `MetadataDump` is a `SELECT`, the
connection is opened with `autoCommit(false)` and never committed, it opens no
mailbox session, and the blob path it prints is a computed string it never opens.
`-f` and `-s` are *input* options that decode metadata this tool never holds, and
`--dumpster` reads the deleted-item store: none of the three is on the list, and a
static test fails the build if any of them is written at a call site.

Two consequences worth knowing before you use that screen. It is **not** behind the
existence gate — it cannot create anything, so there is nothing to gate — and it has
**no timeout of its own**: with the database unreachable it retries forever, so
`ZRO_TIMEOUT` is what ends it and the screen names the database. See
[ADR-0008](adr/0008-message-detail-is-the-dump-and-a-bounded-blob-head.md) and
[`docs/research/2026-08-17-message-detail.md`](research/2026-08-17-message-detail.md).

**`head -c` bounds by BYTES where `tail -n` bounds by lines**, and that is not a
preference: a message blob is a MIME stream whose base64 part is routinely one line
of megabytes, so a line bound would be no bound. It is used twice per message — two
bytes to ask whether the file is a gzip stream, then the head itself — and the path
it is given comes out of the dump's own output, so it is checked against a strict
character set and against `ZRO_STORE_ROOT` before anything opens it. `head -n` is
absent from the list on purpose: nothing here reads a blob by lines.

`zmcontrol -v` runs **once per session**, at startup. Its answer is shown on the
main menu, which is returned to after every operation, so re-reading it there
would cost a JVM start per screen.

**`zmcontrol status` is the one command on this list that writes**, and it is
admitted as a **declared artifact** rather than as an exception anybody may
repeat. It starts and stops nothing and changes no account, mailbox, folder, flag
or setting — but it creates the localconfig temp directory when it is missing,
leaves temp files there, and rewrites `/opt/zimbra/log/.zmcontrol.cache` on every
successful directory lookup. Three conditions admit it and they hold together: no
domain state changes, the screen that runs it says what it writes, and
[ADR-0005](adr/0005-zmcontrol-status-is-a-declared-artifact.md) records the
judgement. `start`, `stop`, `restart`, `shutdown` and `maintenance` are absent and
therefore refused — this is the one binary here whose family changes service
state, and the entry for `status` is not approval of the binary.

It is also the one command with **no timeout of its own where it needs one**: the
directory lookup it makes first has no alarm around it, so a hung LDAP master
would leave it waiting indefinitely. `ZRO_TIMEOUT` is what ends it, and the screen
says so instead of reporting a server that answered nothing.

**`postqueue` is approved in its listing form and no other.** Postfix puts the
read and the writes in one binary and tells them apart by flag, so the flag *is*
the operation: `-f` flushes the deferred queue, `-s` flushes one site, `-i`
requeues one message and `-d` deletes — each of them makes the transfer agent act,
which is a change to what the server does with your mail. None is on the list, and
neither is `postsuper`, which holds, releases and deletes, nor `mailq`, which is a
link to the mail submission program. `-j`, the structured form of the same
listing, is deliberately absent too: it is the better source, and this tool has no
JSON parser and does not grow one for a question the traditional form answers.

It resolves under **`ZRO_POSTFIX_SBIN`**, its own declared root, because Zimbra
ships its Postfix under `common` rather than under `bin`. A tool searched for on
`$PATH` would be a different program answering about a different queue.

**Postfix's own access-control setting can refuse the read, and that is not an
allowlist denial.** `authorized_mailq_users` is consulted inside `postqueue`,
after this list has approved the operation; a site that has narrowed it gets a
tool that is present, executable, and exits 69 saying the `zimbra` account may not
view the queue. The tool reports that as the host refusing — naming the setting
and its permissive default, `static:anyone` — and never as code 90, which in this
program means a defect. The two send you to different files, so they are kept
apart.

`tail`, `head`, `gzip` and `grep` are the only entries here that are not Zimbra's.
They are on this list rather than treated as plumbing beside `timeout` and `id`,
because those two serve the tool itself while these four read the content an operator
asked for — and because the thing keeping bare `gzip` out would otherwise be
discipline instead of this list.

The bare `head` this tool runs over its **own** temporary files — the stderr of a
command it has just run — is not on the list and does not belong there, for the same
reason: what decides is whose content it is.

**`grep` is on this list in the role where it reads a log, and off it in the role
where it does not.** The tool also runs a bare `grep` over strings it is already
holding — its own tables, its own output — and that is plumbing, exactly as `sort`
and `sed` are. What decides is not the binary but what it reads: a log file the
operator chose is an operation, and an operation belongs on the list that
enumerates them.

**`-a` is a mode and is never approved alone**, the way `zmprov -l` is not. It
makes the reader treat a file with an odd byte in it as text, which `mailbox.log`
needs — one byte otherwise leaves `grep` printing nothing at all, which an operator
would read as *it never happened*. **`-F` matches your text as the literal it is**;
**`-E` runs a pattern this tool owns and you cannot type.** Nothing an operator
types ever reaches `-E`, and a test drives every screen to prove it. **`-m` is the
cap** on how many matches are printed — grep's own bound, exactly as `-n` is
tail's, so a search never holds a whole log's matches in this server's memory.

`-r`, `-R` and `--include` walk a directory and would read files the log inventory
never admitted; `-f` takes its patterns from a file, which is operator text
becoming a pattern by another route. None of them writes — `grep` cannot — and all
of them are absent, because this list is what may be *asked*.

**Two commands wrap every scan and neither is on this list**: `nice -n 19` and
`ionice -c 3`. They are plumbing beside `timeout` and `runuser` — this program's
own conduct rather than an operation you chose — and they are declared in
`lib/exec.sh` as a property of the binaries that scan, so no module can express a
scan that runs without them. A host missing either refuses the scan rather than
running it at ordinary priority. Measured on the lab server as the `zimbra`
account: the child really reports `nice=19` and `ionice=idle`, and neither needs a
privilege.

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

`zmmailbox` is on this list only as the four reads above, and reaching any of
them means passing the existence gate first. That matters — see section 5.

`-l` is never approved on its own. An allowlist entry of `zmprov:-l` would let
every subcommand behind it through, including every write, so the flag is only
ever listed together with the subcommand it precedes.

**A flag written after an approved subcommand is not data, and must be approved
too.** What follows a subcommand is normally the caller's already-validated
values — an account name, a list of attributes — and those reach the command
unread. A flag there is different: it changes what the command does. `zmprov`
carries `-t`, which writes binary attribute values to files under the localconfig
temp directory and deletes whatever stood at the path first — a local write
performed by a read. So the gate holds every flag-shaped token after a
subcommand to the same list, in every position rather than only the first, and
does not depend on where that tool's own parser happens to accept the flag.
Exactly one is approved — `zmprov ga -e`, which reads only the attributes set on
the entry itself — and every other form is refused for being absent from the
list, including any a future release brings with it.

This rule covers the tokens after a **subcommand**. Where the allowlist approves
a flag as the whole operation — `tail -n`, `gzip -dc`, the three tracer filters —
that entry approves the operation entire, and what follows is not re-read: the
trace passes its arrival window and its year as flags of their own, and every one
of them is built by this tool from a preset and from the log inventory.

Note that `zmprov gqu` (`getQuotaUsage`) is **not** used and is not on this list.
It takes a server, not an account, and returns every account on it — a
server-wide sweep, which this tool does not have in any form. Per-account usage
comes from `zmmailbox gms -v`, behind the existence gate.

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

Three questions were asked on 2026-07-29, back when this tool used `zmmailbox` not
at all: two about that binary, which it now reaches behind the existence gate, and
one about a command it already used.

All three were answered by reading the `zm-mailbox` source, and
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

### The oracle the existence gate rests on

A fourth question follows from the first: if every `zmmailbox` call can create a
mailbox, what may be trusted to prove one already exists? It was answered on
2026-08-02, from the `zm-mailbox` source and then by experiment on a live
Zimbra 9.0.0 server, and recorded in
[`docs/research/2026-08-02-existence-gate-settled.md`](research/2026-08-02-existence-gate-settled.md).

| Question | Answer |
|---|---|
| Does `zmprov gis` provision a mailbox for an account that has none? | **No.** `GetIndexStats` passes `DO_NOT_AUTOCREATE`. The `mailbox` table held the same five rows with the same ids either side of the run, and `mailbox.log` gained no `Creating mailbox with id` line. |
| Does it write the search index it reports on? | **No.** The index directory of an unindexed mailbox was snapshotted with nanosecond mtimes before and after: byte-identical, directory mtime included. |
| Does it answer for an account homed on another server? | **Yes.** It extends `AdminDocumentHandler`, declares `TARGET_ACCOUNT_PATH` and does not override `proxyIfNecessary()`, so the request is proxied to the account's home host. |
| Is `zimbraLastLogonTimestamp` evidence that a mailbox exists? | **No — this was believed and is refuted.** A SOAP `AuthRequest` sent with no `<context>` header, or with `<nosession/>`, stamps the attribute and creates no mailbox. The accounts that gets wrong are exactly the provisioned-but-never-used population the gate protects. The attribute stays on the account card as an operational fact and decides nothing. |

The four outcomes the gate classifies — mailbox present, mailbox absent, account
absent, and the LDAP-mode refusal — were captured from that server verbatim and
are committed as the fixtures the tests run against. All three failures exit `2`,
which is why the gate reads Zimbra's message and never its exit status.

**One claim is bounded rather than closed.** Whether `gis` would *create* an
index directory that was absent could not be observed: every mailbox on the test
server already owns one, created with the mailbox, and no state is known that
produces a mailbox without it.

### How usage came back

Per-account quota **usage** was removed from the quota screen once, and it is
back. The command that used to report it, `zmprov gmi`, creates a mailbox for an
account that has none, so a read-only tool cannot run it — and it is still
nowhere in this tool.

What answers now is `zmmailbox gms -v`, the mailbox's own size, run **behind the
existence gate**: a command incapable of provisioning proves the mailbox is
already there, and only then is a session opened on it. An account with no
mailbox is therefore answered by the gate, with the screen that says a mailbox is
created on first login or first delivery — not with a usage figure of zero, which
would be a different and wrong claim.

`zmprov gqu <server>` was named here as the safe replacement and has **not** been
taken. It creates nothing, but its argument is a server: on a box carrying more
than 100,000 mailboxes it reads every account to answer about one, and this tool
has no operation whose work grows with the number of accounts.

If you ran an earlier build of this tool against an account that had never
logged in and had no mailbox, **that account may now have an empty mailbox that
this tool created.** Ask about the account rather than about the server:
`zmprov gis <account>` answers `mailbox not found` for an account that has none,
and that is the whole check.

**Do not decide it from the count of `Creating mailbox with id` lines in
`mailbox.log`.** That count moves on a live server for reasons that have nothing
to do with this tool — a delivery creates a mailbox, and Zimbra's own spam and
ham training accounts are created by the trainer at 22:00. Measured on the lab
server: the count rose by two during a session in which this tool created
nothing. (`mailbox.log` also carries a byte that makes `grep` treat it as binary,
so read it with `grep -a` or you will see nothing at all.)

### Message detail, without the command that would have marked it read

The second row of the table above — `zmmailbox gm` clears the unread flag on the
message it reports — closed one door and left the question behind it open. It was
answered on 2026-08-17, from the `zm-mailbox` source and then by measurement on the
lab server, and recorded in
[`docs/research/2026-08-17-message-detail.md`](research/2026-08-17-message-detail.md)
and [ADR-0008](adr/0008-message-detail-is-the-dump-and-a-bounded-blob-head.md).

| Question | Answer |
|---|---|
| Is `zmmetadump` read-only? | **Yes, and strictly.** Every statement in `MetadataDump` is a `SELECT` — there is no `executeUpdate`, `INSERT`, `UPDATE` or `DELETE` in the class — the connection is opened with `autoCommit(false)` and never committed, so the pool rolls it back. `-f` is an *input* option, not an output one. |
| Does it open a mailbox session, or need one? | **No.** It connects to MySQL over JDBC: no `SoapProvisioning`, no `ZMailbox`, and mailboxd neither running nor stopped matters. So it cannot provision a mailbox, and it is the one mailbox question in this tool that is not behind the existence gate. |
| Does it read or copy the message itself? | **No.** The `[Blob Path]` section prints a *computed path string*; the class never opens the blob. What opens it is this tool's own bounded read, and only the head of it. |
| What does it answer for an account with no mailbox? | `Account … not found on this host` — **the same sentence** as for an address the directory has never heard of. Measured both ways, on the lab account that deliberately has no mailbox. The tool reports the weaker of the two and the screen says either cause produces it. |
| Can it hang? | **Yes, forever.** With the database unreachable, `DbPool.startup` loops in `waitForDatabase` with no bound. `ZRO_TIMEOUT` is what ends it, and the screen names the database. |
| Is the message body reachable from what this screen reads? | Only through two doors, and both are shut. The dump's `[Metadata]` section carries the **fragment** — preview text cut out of the body — and is not rendered at all; the blob's parts are reported by their own headers, and the bytes between a part's headers and the next boundary are skipped without being read. |

The blob itself was measured too, because the parser depends on it: a stored blob is
**CRLF**, it folds one header with a space and the next with a tab, and the primary
volume on that server reports `compressed: false` — so compression is a per-volume
setting and each file is asked what it is, two bytes, rather than assumed to be
either.

### Acceptance runs

| Date | Server | What was run | Result |
|---|---|---|---|
| 2026-07-29 | production, all services healthy | All three M1 screens against a quiet test account, with `zmprov gmi` recorded before and after | `mailboxId 38131` and `quotaUsed 0` **unchanged**. A test message delivered afterwards moved `quotaUsed` to 2804 and the tool then reported `2.7 KB` — so the reading is live and accurate, and the tool changed nothing. |
| 2026-07-29 | test server, `mailboxd` stopped | All three M1 screens | Summary and membership answered in full over LDAP with the degraded-mode banner; the quota screen showed the limit and marked usage unreadable. |
| 2026-07-29 | production | Summary against an account with a recorded logon | Last logon rendered as `2026-07-28 06:40:34` from a stored `20260728064034.819Z`. |
| 2026-07-29 | production | Summary and quota against an address that does not exist | Reported `Hesap bulunamadi` together with Zimbra's own `NO_SUCH_ACCOUNT` text, and returned to the menu. |
| 2026-08-02 | lab (Zimbra 9.0.0 FOSS) | All five mailbox screens against an account with a populated mailbox: folders, size, quota, one folder, one folder's grants | Answered from the real binaries. 15 folders including `/Emailed Contacts` and two nested ones, 700 bytes against a 5 GB limit rendered as `%1'den az`, `/Inbox` 353 bytes, no grants. A path that does not exist returned code 13 with Zimbra's own `unknown folder` text. |
| 2026-08-02 | lab (Zimbra 9.0.0 FOSS) | The same three of those screens against an account that is provisioned and has never been used | All three refused with code 12 before opening anything, and afterwards that account **still had no mailbox**: `zmprov gis` answered `mailbox not found` and the `mailbox` table held no row for its id. **The gate held.** An address in no directory returned code 11. |
| 2026-08-02 | lab (Zimbra 9.0.0 FOSS) | Nested folders, created on the fixture account to settle how the listing prints them | The path column starts at the same offset for a nested folder as for a top-level one — **no indentation, hierarchy only in the path** — and `zmmailbox gf` took the full path back unchanged, spaces and all. Had it been indented, every mailbox with subfolders would have answered `unknown folder`. |
| 2026-08-17 | lab (Zimbra 9.0.0 FOSS) | The message detail screen against the real binaries: a message with an attachment, one without, the Inbox folder's own record, an id the mailbox does not hold, an account with no mailbox row, a compressed blob, and a path outside the store root | Every case answered as designed — the attachment listed as `application/pdf … fatura.pdf`, the single-part message reported as having no parts, the folder's record drawn with no blob path, code 14 for the absent id, code 12 with Zimbra's own `not found on this host` text, and code 90 for `/etc/shadow`. **The unread set was identical before and after** — the two messages the screen displayed in full are still in it — and the account's `mailbox` row was byte-identical, `last_soap_access` included. The blob's modification time and checksum did not move, and the compressed copy read through `gzip -dc` was unchanged and still there. |

## 6. Production acceptance

Run this sequence before using the tool against real accounts.

1. Copy the repository to the server and run the suite there:

   ```bash
   ./tests/run.sh
   ```

   It must end with `SUITE: PASS`. Nothing needs installing for this to work; if
   it does not run, stop and investigate rather than skipping it.

2. Read the allowlist in `lib/exec.sh` and confirm every entry is a read
   operation. It is one table, and short enough to read in full — do that rather
   than counting it, and read `gzip:-dc` twice: it is the one entry whose
   neighbouring spellings write.

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
