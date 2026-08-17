# shellcheck shell=bash
# The exec gate. Every external command in this program passes through here.
[ -n "${ZRO_LIB_EXEC_LOADED:-}" ] && return 0
ZRO_LIB_EXEC_LOADED=1

# The complete set of commands this program may run, as exact two-token argv
# prefixes: "<binary>:<token>". The token is positional, not semantic — it is
# whatever follows the binary, whether a subcommand (zmprov ga) or a flag
# (zmcontrol -v). Both the long and the short form of each subcommand is listed.
#
# Adding an entry here is the second of two deliberate edits required to give
# this program a new capability. Nothing outside this list can be executed, and
# tests/test_readonly_scan.sh fails the build if a call site is not covered.
# An entry may be three tokens when the second one only selects a mode.
# `zmprov -l` reads straight from LDAP instead of talking SOAP to mailboxd,
# which is what lets this tool keep working when the mailbox service is down —
# but the flag itself decides nothing about reading or writing, so it is never
# approved alone. `zmprov:-l` would let every subcommand behind it ride in free.
#
# `zmprov gmi` (getMailboxInfo) was here and has been REMOVED. Its handler,
# GetMailbox, calls MailboxManager.getMailboxByAccount(account) — the
# AUTOCREATE overload, documented as "Creates a new mailbox if one doesn't
# already exist". It is the only read-named admin handler that does; every
# sibling passes DO_NOT_AUTOCREATE and throws "mailbox not found". Reading an
# account's quota usage would therefore create a mailbox for an account that
# had none. See docs/research/2026-07-29-zimbra-cli-read-only-reference.md §A.3.
#
# `zmprov gdl` (getDistributionList) is here so that "no such account" can stop
# being this tool's answer to a distribution list. Measured on TEST-C: `ga` on a
# list fails with account.NO_SUCH_ACCOUNT, and only this read tells that apart
# from an address the directory has never heard of. It is a read in effect as
# well as in name — the handler returns the entry and its members, and the
# write-named siblings that touch a list (`adlm`, `rdlm`, `cdl`, `ddl`) are
# absent from this list and therefore refused.
#
# `zmprov gd` (getDomain) is here so that a suspended domain and an unrouted
# address can be explained without leaving the tool. It is a read in effect as
# well as in name — the handler returns the domain entry and nothing else — and
# the write-named siblings (`cd`, `md`, `dd`, `rd`) are absent from this list and
# therefore refused. What it may NOT be used for is the count of accounts in a
# domain: that is `gaa`, it is a server-wide sweep, and it is nowhere here.
#
# `zmprov gsig` (getSignatures) and `zmprov gid` (getIdentities) are here so that
# the mail settings screen can say what an account sends as and signs with. Both
# read CHILD ENTRIES of the account in the directory — a signature and a send-as
# identity are entries, not attributes, which is why no attribute list on the
# account read could have carried them.
#
# THEY OPEN NO MAILBOX, MEASURED RATHER THAN ASSUMED, and that was the question
# worth settling: a command that reads what a user composes with sounds like a
# command that reads a mailbox. On TEST-C on 2026-08-03 both were run against an
# account with no mailbox, and `zmprov gis` reported no mailbox for it before and
# after — the same control the folder reads were admitted under. `gsig` on such an
# account answers with NOTHING and exit 0, which is what makes the empty case a
# result rather than a failure on the screen above.
#
# The write-named siblings that live one letter away — `csig`, `msig`, `dsig`,
# `cid`, `mid`, `did` — are absent from this list and therefore refused. They are
# the reason these two were worth a second look: `createSignature` and
# `deleteIdentity` are one letter from the reads and change what a user sends as.
# See docs/research/2026-08-03-mail-settings-and-multiline-attributes.md.
#
# `zmprov gis` (getIndexStats) is the EXISTENCE ORACLE, and it is the only reason
# any mailbox screen can exist at all. `zmmailbox` creates a mailbox for an account
# that has none, during session setup rather than inside any subcommand, so a
# session may be opened only after a command INCAPABLE OF PROVISIONING has proven
# the mailbox is already there. This is that command: GetIndexStats passes
# DO_NOT_AUTOCREATE, and on the lab server the `mailbox` table held the same rows
# with the same ids either side of it while `mailbox.log` gained no line about
# creating one. It does not write the index either — the index directory of an
# unindexed mailbox was snapshotted with nanosecond mtimes and came back
# byte-identical.
#
# It proxies to the account's home server, and it reports a missing account and a
# missing mailbox IN DIFFERENT WORDS, which is what lets the gate answer three
# questions rather than two. See docs/adr/0003-gis-is-the-existence-oracle.md.
#
# `zimbraLastLogonTimestamp` was the cheap first layer of that oracle and is not
# here in any form, because it is not a command: an attribute cannot be an oracle,
# and that one is written by an authentication that never registers a session. The
# accounts it gets wrong are exactly the accounts the gate exists to protect.
#
# `zmprov:-l:gis` IS DELIBERATELY ABSENT, AND THAT WAS DECIDED RATHER THAN LEFT.
# LDAP mode cannot answer it at all: measured on TEST-C, `zmprov -l gis` fails with
# `invalid request: can only be used with SOAP`, because index statistics do not
# live in the directory. An entry for it would approve a call that can only ever
# fail — and it would do worse than that, because zro_prov_read reaches for LDAP
# mode on its own whenever mailboxd is unreachable: the outage this oracle cannot
# see through would arrive as a second failure instead of as itself. So the gate is
# SILENT while the mailbox service is down, the screen names that as the cause, and
# nothing behind the gate is offered meanwhile.
#
# THE FIRST FOUR SUBCOMMANDS OF THE GATED BINARY, and they are here because the
# ticket that exposes them arrived — never because that binary became reachable.
# Every one of them is refused until the existence oracle above has proven the
# mailbox was already there: the gate below admits this binary from one function
# only, and that function runs the oracle first.
#
# `gaf` (getAllFolders), `gf` (getFolder), `gfg` (getFolderGrant) and `gms`
# (getMailboxSize) are reads in effect as well as in name, measured rather than
# assumed. On TEST-C the account's row in the `mailbox` table — its change
# checkpoint, its item id checkpoint, its size checkpoint and its last SOAP access
# among them — was BYTE-IDENTICAL either side of all four, and the control is what
# makes that worth anything: a deliberate `mfg` on the same folder in the same
# session moved two of those columns immediately afterwards. See
# docs/research/2026-08-02-folders-size-and-quota.md.
#
# ONE SPELLING EACH, as everywhere in this list: the long forms `getAllFolders`,
# `getFolder`, `getFolderGrant` and `getMailboxSize` are absent although they name
# the same operations, so that reading a call site tells a maintainer which entry
# approves it.
#
# The write-named siblings that live one letter away — `df`, `ef`, `cf`, `mfg`,
# `mff`, `mfc`, `rf`, `sf`, `iuif`, `mfr` — are absent and therefore refused. So
# are `gm`, which clears the unread flag it reports on, and `gru`, which is an
# HTTP GET whose `-o` form writes a local file.
#
# `zmmailbox:gms:-v` IS A FLAG IN THE DATA POSITION, and the second entry in this
# list to be one. It is the difference between a number and a sentence: bare `gms`
# prints `formatSize`'s output, which is built with the JVM's default locale, so
# the same mailbox answers `1.44 GB` on one host and `1,44 GB` on the next — and a
# decimal comma read as a thousands separator is a mailbox reported a hundred
# times too large. `-v` prints the raw byte count, which is a number in every
# locale there is, and this program does its own formatting from it.
#
# The flag has to be approved for the position it really stands in. Measured on
# TEST-C: `zmmailbox -z -m <acct> gms -v` answers `700`, while the same flag
# written in front of the subcommand answers `700 B` — it is a different option
# there, and the gate would be approving the wrong one.
#
# THE BARE `zmmailbox:gms` ENTRY IS REQUIRED BY THE MATCHER, not by a caller. A
# data-position flag is approved UNDER the entry that approved its subcommand, so
# the subcommand has to be on the list for the flag to be reachable at all —
# exactly as `zmprov:ga` carries `zmprov:ga:-e`. The consequence is stated rather
# than left: the formatted form of this read is approved too. It is not a write
# and not a wrong number — the reader refuses any answer that is not all digits,
# so a formatted one reaches the operator as a value this program could not read.
# What keeps it from being asked for at all is that there is one call site and it
# names the flag, which the static scanner holds to.
#
# `zmmailbox:gaf:-v` IS DELIBERATELY ABSENT, AND THAT WAS DECIDED RATHER THAN
# LEFT. The verbose form of the folder listing emits the whole tree as nested
# JSON, which is easier to parse and would have to be parsed by depth; the fixed
# table this tool reads instead is one line per folder with the path last. Both
# were captured. Approving a second form of a read this tool does not make would
# be an operation nobody can reach, and the list has to stay the complete account
# of what may be run.
#
# `zmmailbox s` (search) AND `sc` (searchConv) ARE THE FIFTH AND SIXTH, and they
# arrived with the ticket that asks a mailbox where a message is — never because
# the binary was already reachable. Both are reads in effect as well as in name,
# measured rather than assumed: on TEST-C the account's row in the `mailbox` table
# was byte-identical either side of a pass of both, and the sharper control held
# too — the same four message ids answered `is:unread` before and after roughly
# forty searches and five conversation listings, and the folder listing reported
# the same unread count. See
# docs/research/2026-08-03-message-search-and-conversations.md §1.
#
# THE COMMAND THIS PAIR IS DEFINED AGAINST IS `gm`, WHICH IS NOT HERE. Message
# detail is the read that clears the unread flag it reports — `doGetMessage`
# hard-codes `setMarkRead(true)` and no flag disables it — so a mailbox is asked
# what it holds through a search, which never sets that attribute at all.
#
# `zmmailbox:s:-t` IS A FLAG IN THE DATA POSITION, and it decides which question is
# asked rather than how the answer is dressed: the search type defaults to
# CONVERSATION, so the ids in an answer without it name conversations. Both forms
# are used and both are operations — one call site asks for messages with the flag,
# one asks for conversations without it, which is the only way a conversation id
# can be obtained at all.
#
# `zmmailbox:s:-l` and `zmmailbox:sc:-l` ARE THE OUTPUT BOUND. What follows is a
# count this program declares, never operator text. The bound is on what comes
# BACK: the server examines the whole mailbox either way and says through its own
# `more:` flag whether it had more to give, which the screen passes on.
#
# `--dumpster` IS NOWHERE HERE and may not arrive: it searches deleted items in the
# dumpster, which is a different question about a different store, and an operation
# arrives with the ticket that exposes it. `-v` is absent too — it replaces the
# table with JSON, which this tool has no parser for, and approving a second form
# of a read nobody makes would be an operation nobody can reach. `-n`, `-p` and
# `-c` page a search across an interactive session that a one-shot invocation does
# not have: measured upstream, they print nothing and exit 0.
#
# The write-named siblings of these two live in the same binary and are absent from
# this list. Read off that binary's own help on 2026-08-03 rather than guessed:
# `mmr` marks a message read, `mcr` marks a whole CONVERSATION read — one keystroke
# from the listing approved here — `mms` and `mcs` mark spam, `mm` and `mc` move,
# `dm` and `dc` delete, `tm` and `tc` tag, `fm` and `fc` flag, and `am` adds a
# message. `gc`, which reads one conversation and does not set `read`, is absent
# too: the listing approved above answers the question this tool asks, and an
# operation arrives with the ticket that exposes it.
#
# `zmmetadump -m` IS MESSAGE DETAIL, AND IT IS HERE BECAUSE `gm` NEVER CAN BE. The
# read that answers "what is this message" in one command clears the unread flag on
# it, unconditionally: `doGetMessage` hard-codes `setMarkRead(true)` and no flag
# disables it. So the question is asked of the DATABASE instead, by the one Zimbra
# program that reads it directly.
#
# IT IS A READ IN EFFECT, READ FROM SOURCE RATHER THAN GUESSED AT: every statement
# in `MetadataDump` is a `SELECT` — there is no `executeUpdate`, `INSERT`, `UPDATE`
# or `DELETE` in the class — the connection is opened with `autoCommit(false)` and
# is never committed, so the pool rolls it back. It opens no mailbox session, talks
# neither SOAP nor LMTP, and needs mailboxd neither running nor stopped. `-f` is an
# INPUT option (decode metadata from a file), not an output one, and the blob path
# it prints is a computed string: the class never opens the blob. See
# docs/research/2026-07-29-zimbra-cli-read-only-reference.md §A.5 and
# docs/research/2026-08-17-message-detail.md §1.
#
# THE FLAG IS THE WHOLE OPERATION, as the tracer's filters are, and the item id
# rides behind it as DATA — which is stated rather than left, because this entry
# approves that operation entire and nothing reads the flags behind it. `-i` is what
# the item id arrives under and the binary refuses to run without it. `--dumpster`
# would read the deleted-item store, which is a different question about a different
# table, and `-f`/`-s` decode metadata this program never holds: none of the three is
# written anywhere in the tree, and tests/test_readonly_scan.sh fails the build for a
# second call site or for any of those words appearing at one.
#
# ITS ONLY HAZARD IS THAT IT WAITS FOREVER. With MySQL unreachable, `DbPool.startup`
# loops in `waitForDatabase` with no bound at all — so the wall-clock timeout every
# command in this file runs under is not a convenience here, it is the whole reason
# the screen can be offered. The expiry reaches the operator as itself, naming the
# database, rather than as a server that answered nothing.
#
# `head -c` IS THE BOUNDED READ OF A MESSAGE BLOB, and the fourth entry here that is
# not Zimbra's. It is listed for the reason `tail`, `gzip` and `grep` are: it reads
# the content an operator asked for. Two invocations of it make one blob head — the
# first asks the file what it IS, reading the two bytes a gzip stream begins with,
# and the second reads the head itself — because the store's volume decides whether
# blobs are compressed and a plain `gzip -dc` of an uncompressed blob answers
# `not in gzip format`.
#
# BOUNDED BY BYTES RATHER THAN BY LINES, which is the difference between this entry
# and `tail:-n`. A log file is lines; a message blob is a MIME stream whose base64
# part can be one enormous line, so a line bound is no bound at all there. What
# follows `-c` is a count this program declares and judges before it is used, then
# the path — which comes out of the dump's own output and is admitted against a
# strict character set and the declared store root before anything opens it.
#
# `head:-n` IS DELIBERATELY ABSENT although the binary carries it: nothing here
# reads a blob by lines, and an approved form nobody calls is an operation no reader
# of this list could reach. The bare `head` this program runs over its OWN
# temporary files — the stderr it just captured — is not on this list and does not
# belong on it, for the reason the note about `grep` gives: what decides is whose
# content it is.
#
# `zmcontrol status` IS THE ONE COMMAND IN THIS LIST THAT WRITES, and it is here
# as a DECLARED ARTIFACT rather than as an exception anybody may repeat. It starts
# and stops nothing — the guarantee is about Zimbra-managed domain state, and
# service state is part of that — but it creates the localconfig temp directory if
# it is missing, leaves temp files behind, and rewrites `/opt/zimbra/log/
# .zmcontrol.cache` on every successful directory lookup. Read from source rather
# than guessed: see docs/research/2026-07-29-zimbra-cli-read-only-reference.md
# §B.12.
#
# Three conditions hold it here and they hold TOGETHER, which is what keeps this
# from being a guarantee that widens one convenient command at a time: it changes
# no domain state, the screen that runs it says what it writes, and
# docs/adr/0005-zmcontrol-status-is-a-declared-artifact.md records the judgement.
# Remove any one of the three and the entry comes out with it.
#
# IT CAN BLOCK BEFORE ITS OWN ALARM ARMS. The command sets an alarm around each
# service it asks, but the directory lookup that runs first has none — so a hung
# LDAP master leaves it waiting with nothing to interrupt it. What bounds it is
# the wall-clock timeout every command in this file already runs under, and the
# screen reports the expiry as itself rather than as a server that answered
# nothing.
#
# `zmcontrol start`, `stop`, `restart`, `shutdown` and `maintenance` are absent and
# therefore refused. They are the reason this binary was worth a second look: it is
# the one command in the tool whose family changes service state, and the entry for
# `status` may never be read as approval of the binary.
#
# `postqueue -p` IS THE MAIL QUEUE, IN ITS LISTING FORM AND NO OTHER. Postfix puts
# the read and the writes in one binary and tells them apart by flag, so the flag
# IS the operation — approved the way `zmcontrol -v` is, with nothing following it.
#
# `-f`, `-s` and `-i` ARE NOWHERE HERE AND MAY NOT ARRIVE. The first flushes the
# whole deferred queue, the second flushes one site and the third requeues one
# message: every one of them makes the transfer agent attempt delivery NOW. That
# is not a change to a message's content and it is a change to what the server
# does with it — mail leaves, bounces are generated, a remote host is contacted —
# which is domain state by any reading that means anything. `-d` deletes. `-j` is
# the structured form of this same listing and is DELIBERATELY ABSENT: it is the
# better source, carrying the queue name as a field rather than as a marker on the
# id, and this tool has no JSON parser and does not grow one for a screen the
# traditional form already answers. Approving a second form of a read nobody makes
# would be an operation nobody can reach.
#
# ITS ACCESS-CONTROL SETTING IS NOT THIS FILE'S BUSINESS, and that is worth saying
# because the two look alike from a screen. `authorized_mailq_users` is read by
# `postqueue` itself, inside the binary, after this list has already approved the
# operation: a site that has narrowed it gets a tool that is present, executable,
# and answers `not allowed to view the mail queue` on exit 69. That is a refusal by
# the server and never an allowlist denial, and lib/queue.sh keeps them apart —
# because an allowlist denial means a defect in this program, and this one is a
# setting on the host.
#
# `zmmsgtrace` is the delivery trace. Every filter that binary takes is a flag
# which is the whole operation, so each is approved the same way `zmcontrol -v`
# is: as a two-token entry, with the operator's already-validated value following
# as data. THREE ENTRIES, ONE PER FILTER — recipient, sender and message-id are
# three different questions, and approving one may not approve another.
#
# The short forms `-r`, `-s` and `-i` are absent although they name operations
# that are approved: an operation reaches the gate in exactly one spelling, so
# that reading a call site tells a maintainer which entry above approves it
# without knowing the tracer's option table by heart.
#
# The `--srchost` and `--desthost` filters and the `--debug`, `--nosort` and
# `--man` flags are absent and therefore refused — each is an operation of its
# own, and an operation arrives with the ticket that exposes it, never because
# the binary it belongs to was already reachable.
#
# What follows the filter in an argument vector is DATA, exactly as an account
# name is data after `zmprov ga`. The arrival window (`--time`), the year
# (`--year`) and the log file being traced are all computed by this program — from
# a preset or a validated date, and from the declared log inventory — and none of
# them is text an operator typed. So they are not listed here, and listing them
# would be worse than pointless: an entry for `zmmsgtrace:--time` would approve a
# trace with no filter at all as an operation of its own. The gate still refuses
# every one of them in the leading position, which is what keeps this list the
# complete account of what may be run.
#
# `tail` and `gzip` are the first two entries here that are not Zimbra's at all.
# They serve the bounded log viewer, and they are listed rather than treated as
# infrastructure beside `timeout` and `id` for one reason: those two serve the
# gate itself, while these two READ THE CONTENT AN OPERATOR ASKED FOR. An
# operation the operator chose belongs in the list that enumerates what this tool
# can do — otherwise the thing keeping bare `gzip` out would be discipline instead
# of this list.
#
# `gzip:-dc` IS THAT DECISION EARNING ITS KEEP. Bare `gzip` compresses in place
# and DELETES the original; `gzip -d` decompresses in place and does the same. A
# write, by a command nobody thinks of as dangerous — and the guarantee's
# judge-by-effect rule applied outside Zimbra's own binaries. Neither form is
# listed, so both are refused. Only the form that writes to stdout and leaves the
# file where it was is approved.
#
# `tail:-n` is the bound itself. What follows it is the line count and then the
# file, both computed here: the file comes from the log inventory and never from
# operator text. `-f` is absent and therefore refused — it follows a growing file
# and never returns, which on a screen is a tool that has hung.
#
# `grep` IS THE LOG SEARCH, AND IT IS THE THIRD BINARY HERE THAT IS NOT ZIMBRA'S.
# It is listed for the reason `tail` and `gzip` are: it reads the content an
# operator asked for. That is also the line that keeps it OFF this list in its
# other role — the inventory and this file both run a bare `grep` over this
# program's OWN text: the tables declared here, and the stderr of a command it has
# just run. That is plumbing, exactly as `sort` and `sed` are.
#
# What decides is not the binary and not even the file, but WHOSE CONTENT it is: a
# log the operator chose is an operation and goes on this list; something this
# program wrote itself is not, and does not.
#
# `-a` IS A MODE AND IS NEVER APPROVED ALONE, the way `zmprov -l` is not. It makes
# the reader treat a file with an odd byte in it as text, which mailbox.log needs
# — measured on TEST-C, where a single byte otherwise leaves `grep` printing
# nothing at all and an operator reading that as "it never happened". A `grep:-a`
# entry would let every operation behind it ride in free, so the mode and the
# match form are approved together.
#
# TWO MATCH FORMS, AND THE DIFFERENCE IS WHOSE TEXT IT IS. `-F` matches the
# operator's own text as the literal it is, which is what lets an address carrying
# a '.' or a '+' match itself. `-E` runs a pattern this program owns and the
# operator cannot type — the named questions in lib/logsearch.sh, one per line of
# a mail log the lab server really wrote. Nothing an operator types ever reaches
# `-E`, and a test holds that true.
#
# `-m` IS THE MATCH CAP, and it is grep's own bound exactly as `-n` is tail's.
# What follows it is a count computed here, then the pattern and the file. The cap
# is on MATCHES rather than on lines read, which is the whole difference between
# this and the bounded viewer: the viewer answers from the end of one file, and a
# search that did that would answer "no record" from the newest lines of a log
# whose older ones hold the record.
#
# `-i` IS APPROVED FOR THE PATTERN FORM ONLY, and it arrived with the question
# that needs it. A DOMAIN IS CASE-INSENSITIVE — it is the same domain however it
# was typed and however the sending client wrote it into the envelope — so a
# case-sensitive search for one answers "nothing arrived from there" about mail
# that did. On the screen where an empty answer is presented as proof, that is the
# worst thing this tool can do, and it cannot be fixed by folding the operator's
# text: the log line carries whatever case the client sent.
#
# It is NOT approved for the literal form. A message-id is case-SENSITIVE — the
# tracer's own rule, and the identifier is a token some agent generated rather than
# a name — so folding case there would report a different message as this one.
#
# `-r`, `-R` and `--include` ARE NOWHERE HERE and may not arrive: each walks a
# directory, which would read files the log inventory never admitted. `-f` reads
# its patterns from a file, which is operator text becoming a pattern by another
# route. None of them writes — grep cannot — but the list is what may be ASKED,
# and a form nobody approved is a form nobody has to judge.
#
# `zmprov:ga:-e` IS AN ENTRY IN THE DATA POSITION, and it was the first. What
# follows an approved subcommand is the caller's already-validated data — but a
# flag written there is not data at all: it changes what the command does. `zmprov`
# carries `-t`, which writes binary attribute values to files under the
# localconfig temp directory and deletes whatever stood at the path first: a
# local write, performed by a read. Whether that tool's parser honours the flag
# after the subcommand as well as before it is NOT something we have measured,
# and the gate does not rest on the answer — a flag in the data position is
# refused for being absent from this list, the same way an unapproved subcommand
# is.
#
# So the temp-file form, the force-display form and whatever the next release
# adds to the tool are all refused without anyone having to judge them first.
#
# `-e` is approved because the provenance screen cannot be built without it: both
# SOAP and LDAP mode expand what a class of service provides, so an attribute
# appearing in the ordinary read proves nothing about where it was set, and this
# flag is the only thing that answers. It is approved for `ga` in that one
# spelling: not for `getAccount` and not as `--entry`.
#
# It is NOT approved behind `-l`, AND THAT WAS DECIDED RATHER THAN LEFT. The
# provenance screen's ticket asked for a second entry here and the answer is no:
# `zmprov -l ga -e` has never been run on the lab server, and this list is not
# where a command is judged by its family resemblance to one that has. What the
# three modes really do was measured for `ga`, `-l ga` and `ga -e`; the fourth
# combination is an assumption, and an assumption is not a green light.
#
# The consequence is stated rather than discovered: zro_prov_read retries every
# read against LDAP when mailboxd is unreachable, so the provenance read would be
# refused during exactly the outage the retry exists for — and refused as a
# DEFECT, which is what an allowlist denial means. So the retry asks this file
# first, through zro_ldap_form_allowed below, and a read with no approved LDAP
# form reports the outage that stopped it instead of a defect nobody committed.
# Provenance is therefore a question this tool answers through mailboxd only, and
# the day someone measures the fourth combination is the day that can change.
ZRO_ALLOW='
zmprov:ga
zmprov:getAccount
zmprov:ga:-e
zmprov:gam
zmprov:getAccountMembership
zmprov:gc
zmprov:getCos
zmprov:gdl
zmprov:getDistributionList
zmprov:gd
zmprov:getDomain
zmprov:gis
zmprov:getIndexStats
zmprov:gsig
zmprov:getSignatures
zmprov:gid
zmprov:getIdentities
zmprov:-l:ga
zmprov:-l:getAccount
zmprov:-l:gam
zmprov:-l:getAccountMembership
zmprov:-l:gc
zmprov:-l:getCos
zmprov:-l:gdl
zmprov:-l:getDistributionList
zmprov:-l:gd
zmprov:-l:getDomain
zmprov:-l:gsig
zmprov:-l:getSignatures
zmprov:-l:gid
zmprov:-l:getIdentities
zmmailbox:gaf
zmmailbox:gf
zmmailbox:gfg
zmmailbox:gms
zmmailbox:gms:-v
zmmailbox:s
zmmailbox:s:-t
zmmailbox:s:-l
zmmailbox:sc
zmmailbox:sc:-l
zmmetadump:-m
zmcontrol:-v
zmcontrol:status
zmmsgtrace:--recipient
zmmsgtrace:--sender
zmmsgtrace:--id
postqueue:-p
tail:-n
head:-c
gzip:-dc
grep:-a:-F
grep:-a:-E
grep:-a:-F:-m
grep:-a:-E:-m
grep:-a:-E:-i
'

# The rows of the list, blank lines dropped. ENUMERATION ONLY: the membership
# question below is this list's own and is not shared with anything, because the
# allowlist is the one read in this program whose refusal means exit 90 — a
# defect by definition — and a reader shared with eleven screens is a reader that
# can be changed for a reason that has nothing to do with the gate.
zro_allow_entries() {
  zro_table_entries ZRO_ALLOW
}

# Whether the list carries this entry, matched as one whole line. -x anchors to
# the whole line and -F takes the needle literally, so a token containing a regex
# metacharacter cannot widen the match.
#
# THE LIST IS FED IN ON A HEREDOC, NOT DOWN A PIPE, and that is a correctness fix
# rather than a style. `printf | grep -q` under `set -o pipefail` returns 141:
# grep exits the moment it matches, and if it wins that race the write at the
# other end of the pipe gets SIGPIPE and pipefail reports the pipeline as failed.
# The gate then refuses an operation its own list approves — exit code 90, which
# this program defines as a defect and always logs. Measured rather than reasoned:
# under load, one spurious 141 in three thousand lookups of an entry near the top
# of the list, and none at all in the same three thousand through a heredoc. It is
# rare, it is scheduling-dependent, and it gets likelier the earlier in the list an
# entry sits — which is the opposite of what a maintainer adding one would expect.
zro_allow_has() {
  grep -qxF -- "${1-}" <<EOF
$ZRO_ALLOW
EOF
}

# Every flag-shaped token in the data of an approved subcommand, held to the
# allowlist under the entry that approved that subcommand. Non-flag data is not
# examined here and never was: it is the caller's, and validating it is the
# caller's business.
#
#   $1  the entry that approved the operation, as the prefix a flag extends
#   $@  the data following it
#
# THE DATA IS READ BECAUSE A FLAG IN IT IS NOT DATA — see the note above
# ZRO_ALLOW for what one of them does. The only thing keeping one out today is
# that no validator in this program admits a leading dash: that is the author
# remembering, and this is the structure refusing.
#
# Every position is read, not just the first. The account name comes first and
# the attribute list after it, so a rule that looked only at the token straight
# after the subcommand would leave every position behind it open.
zro_data_flags_approved() {
  local prefix=${1-} arg
  shift
  for arg in "$@"; do
    case $arg in
      -*) zro_allow_has "$prefix:$arg" || return 1 ;;
    esac
  done
  return 0
}

zro_allowed() {
  local bin=${1-} t1=${2-} t2=${3-}
  [ -n "$bin" ] || return 1
  [ -n "$t1" ] || return 1
  shift 2

  # A token shaped like a flag is only ever approved together with the
  # subcommand behind it, because the subcommand is what decides whether the
  # command reads or writes.
  case $t1 in
    -*)
      if [ -n "$t2" ] && zro_allow_has "$bin:$t1:$t2"; then
        # A subcommand read from LDAP rather than through mailboxd. What follows
        # it is data, and it is read exactly as the data after a bare subcommand
        # is: the mode flag changed where the answer comes from, not what may
        # stand behind it.
        shift
        zro_data_flags_approved "$bin:$t1:$t2" "$@"
        return $?
      fi
      # Falls back to the two-token form for a flag that IS the whole
      # operation, such as `zmcontrol -v`. A mode-selecting flag like
      # `zmprov -l` is kept out of the list, and a test enforces that.
      #
      # ITS DATA IS NOT READ FOR FLAGS, and that is a deliberate limit rather
      # than an oversight. The tracer takes its arrival window and its year as
      # flags AFTER the filter — both computed here, from a preset and from the
      # log inventory — so a rule applied here would refuse every trace this
      # tool makes. The cost is that `tail -n 500 <file> -f` would pass this
      # gate: what keeps it from being written is the log viewer building its
      # own vector out of the inventory, which is the position this rule was
      # written to stop relying on. Closing it means approving each trace flag
      # as a third token, and that is a ticket of its own.
      zro_allow_has "$bin:$t1"
      return $?
      ;;
  esac
  zro_allow_has "$bin:$t1" || return 1
  zro_data_flags_approved "$bin:$t1" "$@"
}

# Whether this file approves a read taken from LDAP instead of through mailboxd.
#
#   $1  the subcommand
#   $@  the data that would follow it
#
# ASKED BEFORE THE RETRY IS MADE, never discovered as a denial. The degraded read
# path exists so that this tool keeps working when the mailbox service does not,
# and it reaches for LDAP mode on its own — but an allowlist denial means a defect
# in this program, and a read whose LDAP form nobody approved is not one. It is a
# question this tool answers in one mode, which is a fact about the list above and
# belongs to whoever is reading it.
#
# `zmprov` is named here rather than taken as an argument because `-l` is that
# binary's mode flag and nothing else in the tool has one. A second binary with a
# mode of its own would arrive with its own ticket, as every operation here does.
zro_ldap_form_allowed() {
  local sub=${1-}
  [ -n "$sub" ] || return 1
  shift
  zro_allowed zmprov -l "$sub" "$@"
}

# Binary locations. Production defaults, overridable so the suite can point at
# mocks. Never write one of these paths as a literal in module code. Which
# binary resolves under which root is declared in ZRO_BIN_ROOTS below.
ZRO_ZIMBRA_BIN="${ZRO_ZIMBRA_BIN:-/opt/zimbra/bin}"
# The tracing binary is installed here, not under bin. An upstream mapping
# (zmrcd) still names the bin path and it is stale, which is exactly why the root
# is declared per binary instead of guessed.
ZRO_ZIMBRA_LIBEXEC="${ZRO_ZIMBRA_LIBEXEC:-/opt/zimbra/libexec}"
# The third root, and the first outside the Zimbra tree: where the system
# binaries the log viewer runs are installed. A ROOT rather than a path per
# binary, because that is what the gate resolves against — and declared here
# rather than written at the call site, so that reaching a new directory stays
# something a reader can see in one place.
#
# A host that keeps one of them somewhere else — Ubuntu before the merged /usr
# ships gzip in /bin — overrides this. It fails visibly if it is wrong: the gate
# reports the binary as unavailable on this host rather than falling back to a
# search of $PATH, which is the same refusal every other root gets.
ZRO_SYSTEM_BIN="${ZRO_SYSTEM_BIN:-/usr/bin}"
# The fourth root, and the second inside the Zimbra tree: where the mail transfer
# agent's own programs are installed. Zimbra ships its Postfix under `common`
# rather than under `bin`, and the queue tool is set-group `postdrop` there —
# which is why it answers for an unprivileged account at all.
#
# A DECLARATION RATHER THAN A SEARCH, exactly as the tracing binary's root is. A
# host that keeps them elsewhere overrides this and fails visibly if the override
# is wrong: the gate reports the binary as unavailable on this host rather than
# falling back to $PATH, where a `postqueue` earlier in it would be a different
# program answering about a different queue.
ZRO_POSTFIX_SBIN="${ZRO_POSTFIX_SBIN:-/opt/zimbra/common/sbin}"
ZRO_RUNUSER="${ZRO_RUNUSER:-$(zro_first_existing /sbin/runuser /usr/sbin/runuser /bin/runuser)}"
ZRO_TIMEOUT_BIN="${ZRO_TIMEOUT_BIN:-$(zro_first_existing /usr/bin/timeout /bin/timeout)}"
ZRO_ID_BIN="${ZRO_ID_BIN:-$(zro_first_existing /usr/bin/id /bin/id)}"
ZRO_TIMEOUT="${ZRO_TIMEOUT:-60}"
# The two wrappers that make a scan yield to the mail server. Plumbing, beside
# timeout and runuser and for the same reason ADR-0002 gives: they are this
# program's own conduct rather than an operation an operator chose, so they are
# absent from the allowlist — which stays the complete account of what may be RUN,
# not of how this program agrees to behave while running it.
ZRO_NICE_BIN="${ZRO_NICE_BIN:-$(zro_first_existing /usr/bin/nice /bin/nice)}"
ZRO_IONICE_BIN="${ZRO_IONICE_BIN:-$(zro_first_existing /usr/bin/ionice /bin/ionice)}"

# WHICH BINARIES RUN AT REDUCED PRIORITY, declared here rather than decided at a
# call site. A per-call switch is a switch a caller can forget, and the caller who
# forgets is the one scanning 700 MB of mail log on a server that is already
# struggling — which is the moment this exists for. So it is a property of the
# binary, read by the gate, and no module can express a scan that runs any other
# way.
#
# BOTH READERS, not just the searcher. `gzip -dc` is what a compressed rotated log
# is read through, and decompressing 78 MB is the same disk and the same processor
# whether a search or the bounded viewer asked for it.
#
# THE CONSEQUENCE IS STATED RATHER THAN DISCOVERED: on a host without these two
# commands, the viewer's COMPRESSED files stop being readable as well — the gate
# refuses rather than reading them at ordinary priority. Its plain files are
# unaffected, and the screen behind that refusal says so and names the repair. The
# alternative was leaving the biggest read this tool makes outside the promise it
# makes about every other one.
#
# `tail` IS DELIBERATELY ABSENT. It reads the end of one file and returns; there is
# nothing there to yield. An entry for it would be priority as a habit rather than
# as an answer to a cost, and this table is meant to be read as the second.
ZRO_LOW_PRIORITY='
grep
gzip
'

# Enumeration only, as the allowlist's is, and for the same reason: the
# membership question below stays here. This list carries no colon at all — a row
# IS a binary name — so it is enumerated through lib/table.sh and looked up by
# nothing there.
zro_low_priority_bins() {
  zro_table_entries ZRO_LOW_PRIORITY
}

# Whether this binary's work is heavy enough to be made to wait for the server's.
# Matched as one whole line, the way the allowlist is, and fed in on a heredoc for
# the same measured reason: `printf | grep -q` reports a spurious failure when the
# reader wins the race, and here that would be a scan that quietly ran at ordinary
# priority.
zro_runs_low_priority() {
  local bin=${1-}
  [ -n "$bin" ] || return 1
  grep -qxF -- "$bin" <<EOF
$ZRO_LOW_PRIORITY
EOF
}

# HOW FAR REDUCED, as literals rather than as overridable variables. The level and
# the class are a promise this tool makes to the server it is diagnosing, and a
# variable holding them would be the off switch that promise may not have — the
# same rule lib/capability.sh states about the account every command runs as.
#
# Nineteen is the lowest processor priority there is, and class 3 is the idle disk
# class: a scan gets the disk when nothing else wants it. Both are settable by an
# unprivileged account — measured on TEST-C as the zimbra user, where the child
# really reported `nice=19` and `ionice=idle`. Raising the niceness of one's own
# child never needs a privilege; lowering it would.
ZRO_NICE_LEVEL=19
ZRO_IONICE_CLASS=3

zro_current_user() {
  [ -n "$ZRO_ID_BIN" ] || return "$ZRO_E_UNAVAILABLE"
  "$ZRO_ID_BIN" -un
}

# The groups an account belongs to, space separated on one line.
#
# Beside zro_current_user because it is the same binary asked the other identity
# question this program has, and it bypasses the allowlist for the same reason:
# identity is this program's own plumbing rather than an operation an operator
# chose. Nothing about it reaches Zimbra or a mailbox.
#
# The account is named by this program and never by an operator, so no value an
# operator typed reaches this argument. It answers about an account other than the
# one running the tool on purpose: whether the account every command runs as can
# read a file is not a question about who started the tool.
zro_user_groups() {
  [ -n "$ZRO_ID_BIN" ] || return "$ZRO_E_UNAVAILABLE"
  [ -n "${1-}" ] || return "$ZRO_E_INPUT"
  "$ZRO_ID_BIN" -Gn "$1"
}

# Pure: the identity decision is a function of the user name alone, and has no
# environment override. A safety check must not have an off switch, so mocking
# happens one level down, at $ZRO_ID_BIN.
zro_identity_mode() {
  case ${1-} in
    zimbra) printf 'direct' ;;
    root)   printf 'runuser' ;;
    *)      return "$ZRO_E_BADUSER" ;;
  esac
}

# Where each allowlisted binary lives, as "<binary>:<root variable name>". The
# gate resolves a binary under the root declared here and nowhere else: a binary
# absent from this table is refused, not resolved against a default. Reaching a
# new directory is therefore a declaration a reader can see, never a consequence
# of where a program happens to be installed.
#
# The value is the NAME of the variable, not its value. The root is read when the
# gate runs, which is what keeps every root overridable after this file has been
# sourced — the suite points them at its mocks.
#
# This table says where a binary lives; it never says whether it may run. That
# stays with ZRO_ALLOW, so reading the allowlist still tells a maintainer
# everything this tool can execute, and a test holds the two sets equal. The
# gate's own tools — timeout, id, runuser — are absent from both: they serve this
# function rather than an operation the operator chose.
#
# SC2034: read by NAME through lib/table.sh, never expanded here — which is what
# keeps the log line able to say which declaration a refusal came from.
# shellcheck disable=SC2034
ZRO_BIN_ROOTS='
zmprov:ZRO_ZIMBRA_BIN
zmmailbox:ZRO_ZIMBRA_BIN
zmmetadump:ZRO_ZIMBRA_BIN
zmcontrol:ZRO_ZIMBRA_BIN
zmmsgtrace:ZRO_ZIMBRA_LIBEXEC
postqueue:ZRO_POSTFIX_SBIN
tail:ZRO_SYSTEM_BIN
head:ZRO_SYSTEM_BIN
gzip:ZRO_SYSTEM_BIN
grep:ZRO_SYSTEM_BIN
'

zro_bin_root_entries() {
  zro_table_entries ZRO_BIN_ROOTS
}

# Prints the absolute path of a binary under its declared root, and fails when
# the binary declares no root or the root it names is empty. Failure is never a
# fallback: there is no default root to resolve against.
#
# The refusals and the log lines that go with them belong to zro_table_root,
# which names THIS table in the message — lib/table.sh says why a table travels
# as a name. They are logged there rather than by a caller because the gate is
# not the only caller: zro_bin_available answers the capability probe, and an
# undeclared root would otherwise reach the operator as a greyed-out menu entry
# reading like a program this host does not have.
#
# What stays here is the one thing the generic reader cannot know: a binary
# lives AT its root, under its own name, so the name is appended. The log
# inventory declares its path suffix inside the table instead, which is why that
# reader has nothing of its own to add.
zro_bin_path() {
  local bin=${1-} root
  [ -n "$bin" ] || return "$ZRO_E_INPUT"
  root=$(zro_table_root ZRO_BIN_ROOTS "$bin") || return "$ZRO_E_INPUT"
  printf '%s/%s' "$root" "$bin"
}

zro_bin_available() {
  local path
  path=$(zro_bin_path "${1-}") || return 1
  [ -x "$path" ]
}

# ------------------------------------------------ the binary behind the gate --
#
# One binary in this program may not be reached by whoever wants it. It CREATES A
# MAILBOX for an account that has none — during session setup rather than inside
# any subcommand, so no choice of subcommand avoids it — which means a session may
# be opened only after the oracle above has proven the mailbox was already there.
#
# Two facts about it are declared here rather than left to a caller, because both
# are things a caller could forget once and never be told about.
#
# ITS VECTOR DOES NOT BEGIN WITH ITS OPERATION. What it really takes is
# `-z -m <account> <subcommand>`, which puts the subcommand fourth — out of reach
# of the two- and three-token prefix model this list is built on, and an entry
# like `zmmailbox:-z:-m` would approve everything behind it, which is exactly what
# `zmprov:-l` is kept out of the list for. So a caller hands the gate the
# SUBCOMMAND in the token position and the account behind it, where the allowlist
# reads both, and the layout below is what turns that back into the vector the
# binary needs. The allowlist sees an operation; the binary gets its prefix; and
# no module writes `-z` or `-m` at all.
#
# ONE FUNCTION MAY REACH IT. An oracle is worth nothing if a screen can open a
# session without running it, so this binary is refused from every caller but the
# function that owns the gate — and refused BEFORE the allowlist is consulted,
# because who is asking and what is approved are different questions. The day an
# operation behind the gate is approved is the day a bypass would otherwise start
# reading as an ordinary allowlist denial.
#
# Literals rather than overridable variables, for the reason lib/capability.sh
# gives about the account every command runs as: a safety check may not have an
# off switch. Nothing here says where the binary lives — that is the root table
# above, which now carries an entry for it because the first operations behind the
# gate arrived. The two facts stay apart all the same: the table says where a
# binary is, the allowlist says what may be asked of it, and the check below says
# who may ask.
ZRO_GATED_BIN=zmmailbox
ZRO_GATED_PREFIX=(-z -m)
ZRO_GATE_OWNER=zro_mbox_run

# The only path from this program to an external command.
#
#   $1  binary name, resolved under the root it declares in $ZRO_BIN_ROOTS
#   $2  the token that follows it (subcommand or flag)
#   $@  already-validated arguments, passed as separate argv elements
#
# Nothing here builds a string. There is no eval, no `sh -c`, and no path a
# caller can take to run something the allowlist does not name.
zro_exec() {
  if [ $# -lt 2 ]; then
    # Worded without naming this function: the static scanner extracts call
    # sites by matching the name followed by two words, and a message that
    # looks like a call would read as one.
    zro_log error "denied: the exec gate needs a binary and a token"
    return "$ZRO_E_DENIED"
  fi
  local bin=$1 token=$2
  shift 2

  # WHO IS ASKING, BEFORE WHAT IS APPROVED. Reaching the gated binary from
  # anywhere but the function that owns the existence gate is a BYPASS, not an
  # unapproved operation, and the two have to arrive in the log as different
  # sentences: a maintainer sent to check the allowlist about a call that skipped
  # the oracle would read the wrong file and find nothing wrong with it.
  if [ "$bin" = "$ZRO_GATED_BIN" ]; then
    if [ "${FUNCNAME[1]-}" != "$ZRO_GATE_OWNER" ]; then
      zro_log error \
        "denied, the gated binary is reachable only through the existence gate, not from: ${FUNCNAME[1]-top level}"
      return "$ZRO_E_DENIED"
    fi
    # The account it is about stands first in the data, which is where the layout
    # below takes it from. Refused rather than defaulted: a vector missing it
    # would run the binary against whatever the subcommand happened to be.
    if [ $# -lt 1 ]; then
      zro_log error "denied, the gated binary needs the account it is about"
      return "$ZRO_E_DENIED"
    fi
  fi

  # THE WHOLE VECTOR IS OFFERED TO THE GATE, not just the first two tokens. The
  # third one decides when the second only selects a mode, and every token after
  # an approved subcommand is read for a flag that would change what the command
  # does. The denial names the vector for the same reason: a defect log that
  # stopped at the first argument would leave the next reader guessing which
  # token was refused.
  if ! zro_allowed "$bin" "$token" "$@"; then
    zro_log error "denied by allowlist: $bin $token $*"
    return "$ZRO_E_DENIED"
  fi

  # An allowlisted binary with no declared root is a defect in this file rather
  # than something the operator did, so it is refused like any other denial and
  # never resolved against a default. The reason is logged where the declaration
  # is read, so every caller reports it and not just this one.
  local path
  path=$(zro_bin_path "$bin") || return "$ZRO_E_DENIED"

  if [ ! -x "$path" ]; then
    zro_log error "not available on this host: $path"
    return "$ZRO_E_NOCAP"
  fi

  local mode
  mode=$(zro_identity_mode "$(zro_current_user)") || return "$ZRO_E_BADUSER"

  [ -n "$ZRO_TIMEOUT_BIN" ] || return "$ZRO_E_UNAVAILABLE"

  # THE FIXED PREFIX, PUT BACK WHERE THE BINARY EXPECTS IT. The allowlist has
  # already read this vector with the subcommand in the token position, which is
  # the whole reason the two orders differ — and the account it names has been
  # read there as data, so the flag rule above saw it exactly as it sees an
  # account name after `zmprov ga`.
  local -a argv
  argv=("$ZRO_TIMEOUT_BIN" -k 5 "$ZRO_TIMEOUT")

  # INSIDE THE CLOCK, NOT AROUND IT. Both wrappers exec through to what follows,
  # so the process timeout is watching is still the one doing the work — and the
  # order keeps the timeout guarantee exactly where every existing case asserts
  # it, immediately inside the privilege wrapper.
  #
  # A host without them refuses the operation rather than running it at ordinary
  # priority. That is the same refusal the missing clock gets below, and it is the
  # honest one: this program promises that a scan yields, and a scan that cannot
  # yield is not the operation the operator was offered.
  if zro_runs_low_priority "$bin"; then
    if [ -z "$ZRO_NICE_BIN" ] || [ -z "$ZRO_IONICE_BIN" ]; then
      zro_log error "cannot run at reduced priority: nice or ionice is not on this host"
      return "$ZRO_E_UNAVAILABLE"
    fi
    argv+=("$ZRO_NICE_BIN" -n "$ZRO_NICE_LEVEL" "$ZRO_IONICE_BIN" -c "$ZRO_IONICE_CLASS")
  fi
  argv+=("$path")
  if [ "$bin" = "$ZRO_GATED_BIN" ]; then
    argv+=("${ZRO_GATED_PREFIX[@]}" "$1")
    shift
  fi
  argv+=("$token" "$@")

  if [ "$mode" = runuser ]; then
    [ -n "$ZRO_RUNUSER" ] || return "$ZRO_E_UNAVAILABLE"
    # timeout goes INSIDE the wrapper: killing runuser from outside would leave
    # the Zimbra JVM running.
    argv=("$ZRO_RUNUSER" -u zimbra -- "${argv[@]}")
  fi

  local rc=0
  "${argv[@]}" || rc=$?
  # GNU timeout reports expiry as 124; the operator sees our documented code.
  # SC2153: ZRO_E_TIMEOUT comes from lib/core.sh, which the entry point sources
  # before this module, so ShellCheck cannot see it from here.
  # shellcheck disable=SC2153
  if [ "$rc" -eq 124 ]; then
    rc=$ZRO_E_TIMEOUT
  fi
  return "$rc"
}
