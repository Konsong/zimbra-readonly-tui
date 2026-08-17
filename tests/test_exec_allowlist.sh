#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/table.sh
. "$ZRO_SRC/lib/table.sh"
# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"

it "allows every M1 read operation in both forms"
assert_ok zro_allowed zmprov ga
assert_ok zro_allowed zmprov getAccount
assert_ok zro_allowed zmprov gam
assert_ok zro_allowed zmprov getAccountMembership
assert_ok zro_allowed zmprov gc
assert_ok zro_allowed zmprov getCos
assert_ok zro_allowed zmcontrol -v

it "allows the directory reads behind the identity, list and domain screens"
assert_ok zro_allowed zmprov gdl
assert_ok zro_allowed zmprov getDistributionList
assert_ok zro_allowed zmprov gd
assert_ok zro_allowed zmprov getDomain
assert_ok zro_allowed zmprov -l gdl
assert_ok zro_allowed zmprov -l gd

it "and refuses everything that would change a domain or a list"
# Every one of these is one letter away from a read above, which is why they are
# written down here rather than left to the absence of an entry.
for sub in cd md dd rd createDomain modifyDomain deleteDomain renameDomain \
           cdl ddl adlm rdlm createDistributionList deleteDistributionList \
           addDistributionListMember removeDistributionListMember; do
  assert_fail zro_allowed zmprov "$sub"
  assert_fail zro_allowed zmprov -l "$sub"
done

it "and refuses every read whose work grows with the number of accounts"
# Class 4 does not exist in this tool. The domain screen is where the pressure to
# add one lands — an account count per domain is the obvious next field — so the
# sweeps that would answer it are refused by the gate rather than by nobody
# having written them yet.
for sub in gaa getAllAccounts gqu getQuotaUsage sa searchAccounts \
           gad getAllDomains gadl getAllDistributionLists; do
  assert_fail zro_allowed zmprov "$sub"
  assert_fail zro_allowed zmprov -l "$sub"
done

it "denies every write verb"
for sub in ca ma da dm mm mmr ef df createAccount modifyAccount deleteAccount \
           deleteMessage moveMessage markMessageRead emptyFolder addMessage; do
  assert_fail zro_allowed zmprov "$sub"
  assert_fail zro_allowed zmmailbox "$sub"
done

# The tracing binary takes every filter as a flag, and each flag IS the whole
# operation — the same shape as `zmcontrol -v`. Three filters are exposed, and
# every other filter the tool accepts must be refused: an operation nobody
# approved must not be reachable just because the binary is.
it "approves the three exposed filters of the tracing binary"
assert_ok zro_allowed zmmsgtrace --recipient
assert_ok zro_allowed zmmsgtrace --recipient 'ahmet.yilmaz@example.com'
assert_ok zro_allowed zmmsgtrace --sender
assert_ok zro_allowed zmmsgtrace --sender 'ahmet.yilmaz@example.com'
assert_ok zro_allowed zmmsgtrace --id
assert_ok zro_allowed zmmsgtrace --id 'CAabc123@example.com'

it "approves each filter on its own entry, never through another one"
# Three approvals, not one approval of "the tracing binary". The gate matches a
# whole line literally, so no filter rides in on the back of a neighbour: a
# prefix of an approved filter, a longer form of one, and two of them written as
# a single token are all refused.
assert_fail zro_allowed zmmsgtrace --send
assert_fail zro_allowed zmmsgtrace --senders
assert_fail zro_allowed zmmsgtrace --i
assert_fail zro_allowed zmmsgtrace --ids
assert_fail zro_allowed zmmsgtrace '--sender --id'
assert_fail zro_allowed zmmsgtrace --recipient--sender

it "refuses every other filter and flag of the tracing binary"
# Verbatim from the tool's own option list: the short form of each exposed
# filter, the filters this milestone does not expose, and its non-filter flags.
# The window and year options are in this list too — see the case below for what
# that does and does not mean.
#
# The short forms are refused although they name an operation that IS approved.
# An operation reaches the gate in exactly one spelling, so that reading a call
# site tells a maintainer which allowlist entry approves it without knowing the
# tracer's option table by heart.
for opt in -r -s -i --srchost -F --desthost -D --time -t \
           --year --nosort --debug --help --man; do
  assert_fail zro_allowed zmmsgtrace "$opt"
  assert_fail zro_allowed zmmsgtrace "$opt" 'ahmet.yilmaz@example.com'
done

it "the window and the year ride behind the filter as data, never as operations"
# The trace hands the gate the approved filter first and then its own arguments:
# the arrival window, the year derived from the file, and the file itself. Those
# are data in the same sense an account name is data after `zmprov ga` — computed
# by this program from a preset or a validated date and from the declared log
# inventory, never typed by an operator.
#
# So the approval is unchanged by their presence...
assert_ok zro_allowed zmmsgtrace --recipient 'ahmet\.yilmaz@example\.com'
# ...and refused when one of them is put in front, where it would be the whole
# operation: a trace with no filter, reading a file nobody approved.
assert_fail zro_allowed zmmsgtrace --time '20260728000000,20260728235959'
assert_fail zro_allowed zmmsgtrace --year '2026'
assert_fail zro_allowed zmmsgtrace /var/log/zimbra.log
assert_fail zro_allowed zmmsgtrace /var/log/zimbra.log --recipient
assert_fail zro_allowed zmmsgtrace ''
assert_fail zro_allowed zmmsgtrace 'recipient'
assert_fail zro_allowed zmmsgtrace '--recipients'

it "the allowlist names exactly the three filters the tool exposes"
# Reading the list has to tell a maintainer what tracing can do. A fourth entry
# added without a ticket behind it fails here, and so does a filter approved in
# two spellings.
traces=$(zro_allow_entries | grep '^zmmsgtrace:')
assert_eq "$traces" "$(printf '%s\n%s\n%s' \
  'zmmsgtrace:--recipient' 'zmmsgtrace:--sender' 'zmmsgtrace:--id')"

# The service status read, which is the one command in the allowlist that writes.
# It is admitted as a DECLARED ARTIFACT — no domain state changes, the screen says
# what it writes, and an ADR records the judgement — and the family it belongs to
# is the reason that admission needs guarding rather than trusting.
it "approves the service status read"
assert_ok zro_allowed zmcontrol status
assert_ok zro_allowed zmcontrol -v

it "and refuses every command of that binary which changes what a service is doing"
# THE ENTRY FOR `status` IS NOT APPROVAL OF THE BINARY. Service state is domain
# state, and this is the one binary in the tool whose siblings change it — so the
# refusal is asserted here rather than left to nobody having written the call.
for form in start stop restart shutdown maintenance kill startservices \
            stopservices; do
  assert_fail zro_allowed zmcontrol "$form"
  assert_fail zro_allowed zmcontrol "$form" mailbox
done

it "and the status read in exactly one spelling"
# One operation, one spelling, as everywhere in this list: a reader of a call site
# must be able to name the entry that approves it without knowing the binary's
# option table by heart.
assert_fail zro_allowed zmcontrol --status
assert_fail zro_allowed zmcontrol -status
assert_fail zro_allowed zmcontrol status2

it "the allowlist names exactly the two things that binary may be asked"
assert_eq "$(zro_allow_entries | grep '^zmcontrol:')" \
  "$(printf '%s\n%s' 'zmcontrol:-v' 'zmcontrol:status')"

# The mail queue. Postfix puts the read and the writes in ONE binary and tells
# them apart by flag, so the flag is the whole operation and is approved the way
# `zmcontrol -v` is.
it "approves the mail queue in its listing form"
assert_ok zro_allowed postqueue -p

it "and refuses every form of it that makes the transfer agent act"
# JUDGE BY EFFECT: none of these edits a message, and every one of them changes
# what the server DOES with the queue — mail leaves, a remote host is contacted,
# bounces are generated, or an entry is gone. `-f` flushes the whole deferred
# queue, `-s` flushes one site, `-i` requeues one message, `-d` deletes.
for form in -f -s -i -d -h -H -r -F; do
  assert_fail zro_allowed postqueue "$form"
done
assert_fail zro_allowed postqueue -s example.com
assert_fail zro_allowed postqueue -i C800B104BA4
assert_fail zro_allowed postqueue -d ALL

it "and refuses the neighbouring binaries that do the same by another name"
# `postsuper` holds, releases, requeues and deletes; `mailq` is a symbolic link
# to `sendmail`, which lists the queue under -bp and SUBMITS MAIL under every
# other form of itself. Neither is on the list, so both are refused whatever a
# call site asked for.
for bin in postsuper mailq sendmail postcat postdrop postfix; do
  assert_fail zro_allowed "$bin" -p
  assert_fail zro_allowed "$bin" -d
done

it "and the structured listing form, which was decided rather than left out"
# `-j` is the better source — it carries the queue name as a field instead of as
# a marker on the id — and this tool has no JSON parser and does not grow one for
# a question the traditional form already answers. An approved form nobody calls
# would be an operation no reader of this list could reach.
assert_fail zro_allowed postqueue -j

it "the allowlist names one queue operation and nothing else"
assert_eq "$(zro_allow_entries | grep '^postqueue:')" 'postqueue:-p'

it "and the queue tool resolves under a root of its own"
# Zimbra ships its Postfix under `common`, not under `bin`. The root is declared
# per binary for the same reason the tracer's is: a tool searched for on $PATH is
# a different program answering about a different queue.
ZRO_POSTFIX_SBIN=/opt/zimbra/common/sbin
assert_out_eq "/opt/zimbra/common/sbin/postqueue" zro_bin_path postqueue

# The bounded log viewer's two binaries, and the first two in this list that are
# not Zimbra's at all. Each is a flag that IS the whole operation, so both are
# approved the way `zmcontrol -v` is.
it "approves the bounded read and the decompress-to-stdout form"
assert_ok zro_allowed tail -n
assert_ok zro_allowed tail -n 500
assert_ok zro_allowed gzip -dc
assert_ok zro_allowed gzip -dc '/var/log/zimbra.log.1.gz'

it "refuses the bare decompression command and every form of it that writes"
# JUDGE BY EFFECT, NOT BY NAME, applied outside Zimbra's own binaries. Bare gzip
# compresses IN PLACE and deletes the original; -d decompresses in place and does
# the same. Only the form that writes to stdout and leaves the file alone is
# approved, and the rest are refused by being absent rather than by a rule
# somebody has to remember.
for form in -d --decompress -f --force -r --recursive -k --keep -1 -9 \
            -c --stdout -l --list -t --test -N -S; do
  assert_fail zro_allowed gzip "$form"
  assert_fail zro_allowed gzip "$form" '/var/log/zimbra.log.1.gz'
done

it "and refuses every other spelling of the approved decompression"
# One operation, one spelling. A neighbouring command that would do the same
# thing is not approved by the entry that approves this one.
assert_fail zro_allowed gzip '-dc -f'
assert_fail zro_allowed gzip -dcf
assert_fail zro_allowed gzip -cd
assert_fail zro_allowed gzip '/var/log/zimbra.log.1.gz'
assert_fail zro_allowed gzip ''
assert_fail zro_allowed gunzip -c
assert_fail zro_allowed gunzip -dc
assert_fail zro_allowed zcat '/var/log/zimbra.log.1.gz'
assert_fail zro_allowed zless '/var/log/zimbra.log.1.gz'

it "refuses every form of the bounded read but the one that bounds it"
# -f follows a growing file and never returns, which on this screen is a tool
# that hangs; -c bounds by bytes and would cut a line in half. Neither is the
# operation this milestone exposes.
for form in -c --bytes -f --follow -F --lines --quiet -q -s --retry --pid; do
  assert_fail zro_allowed tail "$form"
done
assert_fail zro_allowed tail '/var/log/zimbra.log'
assert_fail zro_allowed tail '+100'
assert_fail zro_allowed tail ''
assert_fail zro_allowed head -n
assert_fail zro_allowed cat '/var/log/zimbra.log'
assert_fail zro_allowed less '/var/log/zimbra.log'

it "approves the bounded head of a message blob, in bytes"
# THE THIRD SYSTEM READER, and it bounds by BYTES where the log viewer bounds by
# lines. A message blob is a MIME stream whose base64 part is routinely one line of
# megabytes, so a line bound is no bound at all there.
assert_ok zro_allowed head -c
assert_ok zro_allowed head -c 2 '/opt/zimbra/store/0/9/msg/0/274-778.msg'
assert_ok zro_allowed head -c 65536 '/opt/zimbra/store/0/9/msg/0/274-778.msg'

it "and refuses every other form of it, the line bound included"
# `-n` is not approved because nothing here reads a blob by lines, and an approved
# form nobody calls is an operation no reader of the list could reach. `-f` follows a
# growing file and never returns, which on a screen is a tool that has hung.
for form in -n --lines -f --follow -q --quiet -v --verbose -z --bytes; do
  assert_fail zro_allowed head "$form"
  assert_fail zro_allowed head "$form" '/opt/zimbra/store/0/9/msg/0/274-778.msg'
done
assert_fail zro_allowed head '/opt/zimbra/store/0/9/msg/0/274-778.msg'
assert_fail zro_allowed head ''
assert_fail zro_allowed head -c2
assert_fail zro_allowed cat '/opt/zimbra/store/0/9/msg/0/274-778.msg'
assert_fail zro_allowed dd 'if=/opt/zimbra/store/0/9/msg/0/274-778.msg'

it "the allowlist names one bounded read, one bounded head and one decompression"
# Read as the tracing filters are: a fourth system operation added without a
# ticket behind it fails here, and so does a second spelling of one of these.
assert_eq "$(zro_allow_entries | grep -E '^(tail|head|gzip):')" \
  "$(printf '%s\n%s\n%s' 'tail:-n' 'head:-c' 'gzip:-dc')"

# ------------------------------------------------------------- the log search --
#
# The third system binary. Its mode flag is approved only together with a match
# form, for the reason `zmprov -l` is never approved alone.

it "approves the log search in the two match forms it exposes"
assert_ok zro_allowed grep -a -F
assert_ok zro_allowed grep -a -E
assert_ok zro_allowed grep -a -F 'ali+fatura@example.com' '/var/log/zimbra.log'
assert_ok zro_allowed grep -a -E 'status=(deferred|bounced)' '/var/log/zimbra.log'

it "and the cap that bounds what a search prints"
assert_ok zro_allowed grep -a -F -m 200 'ali@example.com' '/var/log/zimbra.log'
assert_ok zro_allowed grep -a -E -m 200 'NOQUEUE: reject:' '/var/log/zimbra.log'

it "a search mode alone approves nothing"
# The same rule the LDAP mode flag lives by. Were `-a` approvable on its own,
# every form behind it — the directory walkers among them — would ride in free.
assert_fail zro_allowed grep -a
assert_fail zro_allowed grep -a 'alpha'
assert_fail zro_allowed grep -a -r
assert_fail zro_allowed grep -a -f

it "and a match form without it approves nothing either"
# One operation, one spelling: the form the tool really runs carries both tokens,
# so a vector missing the mode is a vector nobody in this program writes.
assert_fail zro_allowed grep -F
assert_fail zro_allowed grep -E
assert_fail zro_allowed grep -F -a
assert_fail zro_allowed grep 'alpha' '/var/log/zimbra.log'
assert_fail zro_allowed grep ''

it "refuses every form of the search that would read what the inventory did not admit"
# `-r` and `-R` walk a directory; `--include` and `--exclude` choose files by name;
# `-f` takes its patterns from a file, which is operator text becoming a pattern by
# another route. None of them writes — this binary cannot — and all of them read
# something nobody declared, which is the same objection.
for form in -r -R --recursive -f --file --include --exclude --exclude-dir -d -D -Z; do
  assert_fail zro_allowed grep -a "$form"
  assert_fail zro_allowed grep -a -F "$form" 'x' '/var/log/zimbra.log'
  assert_fail zro_allowed grep -a -E "$form" 'x' '/var/log/zimbra.log'
done

it "and the neighbouring programs that search by another name"
for bin in egrep fgrep zgrep zegrep rgrep ack ripgrep rg awk sed perl; do
  assert_fail zro_allowed "$bin" -a -F 'x'
  assert_fail zro_allowed "$bin" -F 'x'
done

it "and the case-folded form of the pattern search, which is one question's rule"
# A DOMAIN IS CASE-INSENSITIVE and an identifier is not, so the fold is approved
# for the pattern form and refused for the literal one. Approving it for both would
# make a message-id search report a different message as this one.
assert_ok zro_allowed grep -a -E -i 'from=<[^>]*@example\.com>' '/var/log/zimbra.log'
assert_ok zro_allowed grep -a -E -i -m 200 'from=<[^>]*@example\.com>'
assert_fail zro_allowed grep -a -F -i 'ali@example.com'
assert_fail zro_allowed grep -a -F -i -m 200 'ali@example.com'

it "the allowlist names exactly the searches the tool exposes"
# The equality that keeps the list the complete account of what may be asked of
# this binary: a third match form, or a second spelling of one of these, fails
# here rather than passing as an ordinary new entry.
assert_eq "$(zro_allow_entries | grep -E '^grep:')" \
  "$(printf '%s\n%s\n%s\n%s\n%s' \
     'grep:-a:-F' 'grep:-a:-E' 'grep:-a:-F:-m' 'grep:-a:-E:-m' 'grep:-a:-E:-i')"

# -------------------------------------------- the priority the gate imposes --

it "every binary declared to run at reduced priority is one this list names"
# The declaration is about HOW this program agrees to behave, not about what may
# run — so it may never become a second, quieter allowlist. A name here that the
# list above does not carry would be exactly that.
unlisted=""
while IFS= read -r bin; do
  [ -n "$bin" ] || continue
  found=""
  while IFS= read -r entry; do
    case $entry in
      "$bin":*) found=1; break ;;
    esac
  done <<INNER
$(zro_allow_entries)
INNER
  [ -n "$found" ] || unlisted="$unlisted [$bin]"
done <<EOF
$(zro_low_priority_bins)
EOF
assert_eq "$unlisted" ""

it "and the readers that scan a whole log are the ones declared"
# The searcher and the decompression, which are what a scan really spends. The
# bounded read is deliberately absent: it reads the end of one file and returns.
assert_ok zro_runs_low_priority grep
assert_ok zro_runs_low_priority gzip
assert_fail zro_runs_low_priority tail
assert_fail zro_runs_low_priority zmprov
assert_fail zro_runs_low_priority ''

it "and the declaration is matched whole, never as a prefix"
assert_fail zro_runs_low_priority gre
assert_fail zro_runs_low_priority 'grep:-a'
assert_fail zro_runs_low_priority 'gzip -dc'

it "allows the LDAP-mode reads as three-token prefixes"
assert_ok zro_allowed zmprov -l ga
assert_ok zro_allowed zmprov -l gam
assert_ok zro_allowed zmprov -l gc

it "a mode flag alone approves nothing"
# This is the whole reason entries can be three tokens. If -l were approvable
# on its own, every subcommand behind it would ride in free.
assert_fail zro_allowed zmprov -l
assert_fail zro_allowed zmprov -l ma
assert_fail zro_allowed zmprov -l da
assert_fail zro_allowed zmprov -l deleteAccount
assert_fail zro_allowed zmprov -l gmi

it "the allowlist contains no bare mode-flag entry"
entries=$(zro_allow_entries)
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  case $entry in
    zmprov:-*)
      case $entry in
        zmprov:-*:*) zro_t_pass ;;
        *) zro_t_fail "bare mode flag would approve everything behind it: $entry" ;;
      esac
      ;;
  esac
done <<EOF
$entries
EOF

it "a two-token entry still matches when a third argument follows"
assert_ok zro_allowed zmprov ga 'ahmet.yilmaz@example.com'
assert_ok zro_allowed zmprov gam 'ahmet.yilmaz@example.com'
assert_ok zro_allowed zmprov ga 'ahmet.yilmaz@example.com' zimbraMailQuota displayName

# ------------------------------------------- a flag in the data position ------
#
# What follows an approved subcommand is the caller's already-validated data. That
# was read as "and therefore harmless", and it is not: a flag written there is not
# data at all, it changes what the command DOES. Nothing in this program can
# produce one today — the attribute list is a fixed array and every validator
# rejects a leading dash — but that is the author remembering rather than the
# structure refusing.
#
# So the gate reads the data too. A token shaped like a flag must be named in the
# allowlist under the entry that approved the subcommand, or the operation is
# refused for being absent from the list, exactly as an unapproved subcommand is.

it "approves the entry-only form of the account read"
# The provenance screen's whole question: was this value SET on the account, or
# does the account inherit it. Both modes expand what a class of service provides
# — measured, not assumed — so presence in the ordinary read proves nothing and
# `-e` is the only thing that answers.
assert_ok zro_allowed zmprov ga -e
assert_ok zro_allowed zmprov ga -e 'ahmet.yilmaz@example.com'
assert_ok zro_allowed zmprov ga -e 'ahmet.yilmaz@example.com' zimbraMailQuota

it "and in exactly one spelling, on exactly one subcommand"
# Read as the tracer's filters are: an operation reaches the gate in one
# spelling, so that a maintainer reading a call site knows which entry approves
# it. The long spelling of the flag and the long spelling of the subcommand are
# refused although they name the same operation.
assert_fail zro_allowed zmprov ga --entry
assert_fail zro_allowed zmprov getAccount -e
for sub in gam getAccountMembership gc getCos gdl getDistributionList gd getDomain; do
  assert_fail zro_allowed zmprov "$sub" -e
done

it "refuses the form of the account read that writes files"
# THE ONE THIS RULE EXISTS FOR. `-t` writes binary attribute values to files
# under the localconfig temp directory, and deletes whatever was at the path
# first: a local write, performed by a read, reachable today only because nothing
# happens to put a dash in the data.
for form in -t --temp; do
  assert_fail zro_allowed zmprov ga "$form"
  assert_fail zro_allowed zmprov ga "$form" 'ahmet.yilmaz@example.com'
done

it "refuses the force-display form, and every other flag of that read"
# -fd prints attributes a second time and lowercased, which is a different answer
# to the operator's question rather than a dangerous one. It is refused for the
# same reason as the rest: it is absent from the list, and what is absent is
# refused whether or not anyone has judged it.
for form in -fd --forcedisplay -v --verbose -d --debug -a -l -e2 -; do
  assert_fail zro_allowed zmprov ga "$form"
  assert_fail zro_allowed zmprov ga "$form" 'ahmet.yilmaz@example.com'
done

it "refuses a flag wherever in the data it stands, not only first"
# The account name comes first and the attribute list after it, so a rule that
# looked only at the token straight after the subcommand would leave every
# position behind it open.
assert_fail zro_allowed zmprov ga 'ahmet.yilmaz@example.com' -t
assert_fail zro_allowed zmprov ga 'ahmet.yilmaz@example.com' zimbraMailQuota -t
assert_fail zro_allowed zmprov gam 'ahmet.yilmaz@example.com' -t

it "a flag behind the mode flag must be approved as well"
# The three-token form approves a subcommand READ FROM LDAP, and the data after
# it is read exactly as the data after a bare subcommand is. The entry-only form
# is approved in one spelling and this is not it: a second entry would have to be
# written down before an operator could ask this question during an outage.
assert_ok zro_allowed zmprov -l ga 'ahmet.yilmaz@example.com'
assert_ok zro_allowed zmprov -l ga 'ahmet.yilmaz@example.com' zimbraMailQuota
assert_fail zro_allowed zmprov -l ga -t
assert_fail zro_allowed zmprov -l ga -t 'ahmet.yilmaz@example.com'
assert_fail zro_allowed zmprov -l ga -e
assert_fail zro_allowed zmprov -l ga 'ahmet.yilmaz@example.com' -t

it "and the data of a flag that IS the whole operation is left alone"
# The tracer takes its arrival window and its year as flags AFTER the filter, and
# both are computed by this program from a preset and the log inventory. The rule
# is about the token following a SUBCOMMAND, where a flag decides what the
# command does; a two-token flag entry already approves one operation entire.
assert_ok zro_allowed zmmsgtrace --recipient 'ahmet.yilmaz@example.com' \
  --time '20260728000000,20260728235959' --year '2026' '/var/log/zimbra.log'
assert_ok zro_allowed zmmsgtrace --id 'CAabc123@example.com' --year '2026'
assert_ok zro_allowed tail -n 500 '/var/log/zimbra.log'
assert_ok zro_allowed gzip -dc '/var/log/zimbra.log.1.gz'
assert_ok zro_allowed zmcontrol -v

it "the allowlist names exactly eight flags in a data position"
# Eight entries, and each arrived with the ticket that needs it: the entry-only
# account read, the raw-byte form of the mailbox size, the type and the bound of
# the message search, the bound of the conversation listing, the match cap on each
# of the log search's two match forms, and the case fold on the one question whose
# value is a domain. A ninth added without a ticket behind it fails here — which is
# the same friction the list itself exists to impose.
#
# The search's TYPE is the one of these that changes the QUESTION rather than the
# shape of the answer: without it the server searches conversations, and the ids it
# prints then name conversations rather than messages.
#
# The two caps are one decision written twice, because `-F` and `-E` are two
# operations: what the cap does behind a literal match and behind a pattern this
# program owns is the same thing, and approving it for one may not approve it for
# the other.
#
# Both shapes a data-position flag can take are read: a third token behind a
# subcommand, and a fourth behind a mode flag and its subcommand. Reading only
# the first would let `zmprov:-l:ga:-t` be added in silence, which is the entry a
# maintainer would reach for first.
data_flags=$(zro_allow_entries | grep -E '^[^:]+:[^-][^:]*:-|^[^:]+:-[^:]*:[^:]*:')
assert_eq "$data_flags" "$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
  'zmprov:ga:-e' 'zmmailbox:gms:-v' 'zmmailbox:s:-t' 'zmmailbox:s:-l' 'zmmailbox:sc:-l' \
  'grep:-a:-F:-m' 'grep:-a:-E:-m' 'grep:-a:-E:-i')"

# zmprov gmi maps to the admin GetMailboxRequest, whose handler calls
# MailboxManager.getMailboxByAccount(account) — the AUTOCREATE overload,
# documented as "Creates a new mailbox if one doesn't already exist".
# GetMailbox is the ONLY read-named admin handler that does this; every sibling
# passes DO_NOT_AUTOCREATE and throws "mailbox not found" instead.
#
# A command that creates a mailbox cannot sit in the allowlist of a tool whose
# claim is that a write cannot be expressed. See docs/research/.
it "denies the one read-named command that creates a mailbox"
assert_fail zro_allowed zmprov gmi
assert_fail zro_allowed zmprov getMailboxInfo
assert_fail zro_allowed zmprov -l gmi

# ------------------------------------------------------ the existence oracle --

it "approves the read the existence gate is built on, in both spellings"
# GetIndexStats passes DO_NOT_AUTOCREATE where GetMailbox one letter away does
# not: the same question asked of a mailbox that is not there throws instead of
# provisioning. Both spellings are real — the server's own help line reads
# `getIndexStats(gis)` — and this list carries both, as it does for every other
# zmprov read.
assert_ok zro_allowed zmprov gis
assert_ok zro_allowed zmprov gis 'ahmet.yilmaz@example.com'
assert_ok zro_allowed zmprov getIndexStats
assert_ok zro_allowed zmprov getIndexStats 'ahmet.yilmaz@example.com'

it "and refuses its LDAP form, which was decided rather than left out"
# `zmprov -l gis` fails with `invalid request: can only be used with SOAP`,
# measured on the lab server and captured as a fixture: index statistics are not
# in the directory. An entry would approve a call that can only ever fail — and
# the degraded read path reaches for LDAP mode on its own, so it would turn the
# outage this oracle cannot see through into a second failure on top of it. The
# gate is silent while the mailbox service is down, and the screen says so.
assert_fail zro_allowed zmprov -l gis
assert_fail zro_allowed zmprov -l gis 'ahmet.yilmaz@example.com'
assert_fail zro_allowed zmprov -l getIndexStats
assert_fail zro_ldap_form_allowed gis 'ahmet.yilmaz@example.com'

it "and refuses the flags it would otherwise carry into the data position"
for form in -t --temp -e -fd -v -a; do
  assert_fail zro_allowed zmprov gis "$form"
  assert_fail zro_allowed zmprov gis 'ahmet.yilmaz@example.com' "$form"
done

# ------------------------------------------- the reads behind the gate ------
#
# The gate arrived with no operation behind it, deliberately, and four arrived
# afterwards with the tickets that expose them. BEING ON THIS LIST IS NOT BEING
# REACHABLE: the exec gate refuses this binary from every caller but the one that
# owns the existence oracle, and that check runs before the list is consulted at
# all. What the list decides is which questions that one caller may ask.

it "approves the four reads the folder, size and quota screens are built on"
assert_ok zro_allowed zmmailbox gaf
assert_ok zro_allowed zmmailbox gaf 'ahmet.yilmaz@example.com'
assert_ok zro_allowed zmmailbox gf 'ahmet.yilmaz@example.com' '/Inbox'
assert_ok zro_allowed zmmailbox gfg 'ahmet.yilmaz@example.com' '/Inbox'
assert_ok zro_allowed zmmailbox gms 'ahmet.yilmaz@example.com'

it "and the raw-byte form of the size read, which is a flag in the data position"
# The default form is built with the JVM's default locale: the same mailbox reads
# `1.44 GB` on one host and `1,44 GB` on the next, and a decimal comma taken for a
# thousands separator is a mailbox reported a hundred times too large. The flag is
# approved where it really stands — after the subcommand, which is the position
# measured to produce the raw count.
assert_ok zro_allowed zmmailbox gms 'ahmet.yilmaz@example.com' -v
assert_ok zro_allowed zmmailbox gms -v

it "and each of them in exactly one spelling"
# Read as the tracer's filters are: an operation reaches the gate in one spelling,
# so a maintainer reading a call site knows which entry approves it.
for sub in getAllFolders getFolder getFolderGrant getMailboxSize; do
  assert_fail zro_allowed zmmailbox "$sub"
done
assert_fail zro_allowed zmmailbox gms --verbose
assert_fail zro_allowed zmmailbox gaf -v
assert_fail zro_allowed zmmailbox gf -v '/Inbox'

it "and refuses every other subcommand of that binary"
# `gm` is the one here that is not write-NAMED. It clears the unread flag on the
# message it reports — doGetMessage hard-codes setMarkRead(true) and no flag
# disables it — so it is a write in effect, which is the only test this list
# applies. `gru` is an HTTP GET whose -o form writes a local file, and `sf`
# fetches a remote feed INTO the folder.
for sub in gm getMessage gru sf search gc gmi gfr emptyDumpster whoami noOp a; do
  assert_fail zro_allowed zmmailbox "$sub"
done

it "and every command that would change a mailbox, though the binary is listed"
# Each lives one letter away from an approved read, which is why they are written
# down rather than left to the absence of an entry.
for sub in df ef cf csf cm rf mfg mff mfc mfch mfu mfr iuif am dm mm mmr \
           deleteFolder emptyFolder createFolder renameFolder modifyFolderGrant \
           addMessage deleteMessage moveMessage markFolderRead syncFolder; do
  assert_fail zro_allowed zmmailbox "$sub"
done

it "and the prefix the binary really takes approves nothing on its own"
# `zmmailbox:-z:-m` would approve everything behind it, which is what `zmprov:-l`
# is kept off this list for. The prefix belongs to the exec gate, which puts it
# back only after the allowlist has read the subcommand in a position it can see.
assert_fail zro_allowed zmmailbox -z
assert_fail zro_allowed zmmailbox -z -m
assert_fail zro_allowed zmmailbox -m 'ahmet.yilmaz@example.com'
assert_fail zro_allowed zmmailbox -z -m 'ahmet.yilmaz@example.com'

it "the allowlist names exactly the six reads that binary exposes"
# Reading the list has to tell a maintainer what may be asked of a mailbox. A
# seventh entry added without a ticket behind it fails here, and so does a second
# spelling of one of these.
assert_eq "$(zro_allow_entries | grep '^zmmailbox:')" \
  "$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
     'zmmailbox:gaf' 'zmmailbox:gf' 'zmmailbox:gfg' 'zmmailbox:gms' 'zmmailbox:gms:-v' \
     'zmmailbox:s' 'zmmailbox:s:-t' 'zmmailbox:s:-l' 'zmmailbox:sc' 'zmmailbox:sc:-l')"

it "and the two that read messages are approved for the forms this tool really sends"
# The search asks for messages with the type flag and for conversations without
# it, and both are bounded. The conversation listing takes its id and this
# program's own query as data behind its bound.
assert_ok zro_allowed zmmailbox s -t message -l 50 'in:inbox'
assert_ok zro_allowed zmmailbox s -l 50 'in:inbox'
assert_ok zro_allowed zmmailbox sc -l 50 '265' 'is:anywhere'

it "and refuses the forms it does not"
# `--dumpster` searches the deleted-item store, `-v` replaces the table with JSON
# this tool has no parser for, and the paging flags need an interactive session a
# one-shot invocation does not have. None of them is on the list, so each is an
# operation nobody has to judge.
assert_fail zro_allowed zmmailbox s --dumpster 'in:inbox'
assert_fail zro_allowed zmmailbox s -v 'in:inbox'
assert_fail zro_allowed zmmailbox s -t message -v 'in:inbox'
assert_fail zro_allowed zmmailbox s -n
assert_fail zro_allowed zmmailbox sc -t message -l 50 '265' 'is:anywhere'
assert_fail zro_allowed zmmailbox search -t message -l 50 'in:inbox'
assert_fail zro_allowed zmmailbox searchConv -l 50 '265' 'is:anywhere'

it "and a conversation id that carries a sign is refused as the flag it looks like"
# Zimbra names a conversation holding one message with the NEGATION of that
# message's id. The CLI would take it; this gate cannot, because a token shaped
# like a flag in the data position is looked up in the list — and no list can carry
# an entry per id. lib/validate.sh refuses it before anything runs, and this is
# what would refuse it if that ever stopped.
assert_fail zro_allowed zmmailbox sc -l 50 '-263' 'is:anywhere'

it "and the binary it names is the one the gate refuses from a foreign caller"
# Two declarations that have to agree, and nothing else holds them together: the
# name the gate compares against and the name these entries stand under.
assert_eq "$ZRO_GATED_BIN" "zmmailbox"
assert_eq "$(printf '%s\n' "${ZRO_GATED_PREFIX[@]}")" "$(printf -- '-z\n-m')"

# --------------------------------------------------------- the metadata dump --
#
# THE READ MESSAGE DETAIL IS BUILT ON, and the reason it exists at all: `gm` answers
# the same question in one call and clears the unread flag while doing it. This one
# reads the database directly — every statement a select, the connection never
# committed — and opens no mailbox session, so it is the one mailbox question in this
# tool that stands outside the existence gate.

it "approves the metadata dump of one item of one mailbox"
assert_ok zro_allowed zmmetadump -m
assert_ok zro_allowed zmmetadump -m 'ahmet.yilmaz@example.com' -i 274

it "and refuses every other form of that binary"
# `--dumpster` reads the deleted-item store, which is a different question about a
# different table; `-f` and `-s` decode metadata this program never holds; `-i` alone
# is a dump with no mailbox named. Each is refused for being absent from the list,
# which is what keeps it an operation nobody has to judge.
for form in --dumpster -f -s -h --help -i --mailboxId --itemId; do
  assert_fail zro_allowed zmmetadump "$form"
  assert_fail zro_allowed zmmetadump "$form" 'ahmet.yilmaz@example.com'
done
assert_fail zro_allowed zmmetadump 'ahmet.yilmaz@example.com'
assert_fail zro_allowed zmmetadump ''

it "and the flag that IS the operation carries its data, as the tracer's filters do"
# What follows is the account and the item id, both computed or validated here: an
# address the validator admitted and digits. A two-token flag entry approves one
# operation entire, so the id rides behind it as data — which is why there is exactly
# one call site for this operation and a static test holds it to that.
assert_ok zro_allowed zmmetadump -m 'ahmet.yilmaz@example.com' -i 1
assert_fail zro_allowed zmmetadump -i 274 -m 'ahmet.yilmaz@example.com'

it "the allowlist names one dump operation and nothing else"
assert_eq "$(zro_allow_entries | grep '^zmmetadump:')" 'zmmetadump:-m'

it "and it resolves under the same root as the other Zimbra binaries"
# Upstream installs it in bin beside zmprov, and the root is declared rather than
# searched for: a binary found on $PATH would be a different program reading a
# different database.
ZRO_ZIMBRA_BIN=/opt/zimbra/bin
assert_out_eq "/opt/zimbra/bin/zmmetadump" zro_bin_path zmmetadump

it "denies a binary that is not on the list at all"
assert_fail zro_allowed zmsoap ga
assert_fail zro_allowed bash -c
assert_fail zro_allowed sh -c
assert_fail zro_allowed rm -rf

it "does not match on a prefix or a substring"
assert_fail zro_allowed zmprov g
assert_fail zro_allowed zmprov gam2
assert_fail zro_allowed zmprov 'ga extra'
assert_fail zro_allowed zmpro ga
assert_fail zro_allowed zmprovX ga

it "treats the token as literal text, not a pattern"
assert_fail zro_allowed zmprov '.a'
assert_fail zro_allowed zmprov 'g.'
assert_fail zro_allowed 'zmprov' '*'

it "rejects empty arguments"
assert_fail zro_allowed "" ga
assert_fail zro_allowed zmprov ""
assert_fail zro_allowed

# The write verbs, in one place. Both cases below read this list; two copies is
# how one of them would come to ban a word the other allows.
ZRO_T_WRITE_VERBS='create modify delete remove move mark flag tag empty import post recover sync'

it "the allowlist itself contains no write verb in a position that could be one"
# READ ON THE TOKENS, NOT ON THE WHOLE ENTRY, and that changed when the mail
# transfer agent arrived: every one of its programs is named `post...`, so a
# search over the whole line reports `postqueue:-p` — a listing flag — as a write
# verb. What has to stay meaningful is the rule about what may be ASKED of a
# binary, so it is asked of the tokens. The binary names are held to their own
# rule below rather than folded in here, because a widened pattern that stopped
# failing is indistinguishable from one that never applied.
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  tokens=${entry#*:}
  for verb in $ZRO_T_WRITE_VERBS; do
    assert_not_contains "$tokens" "$verb"
  done
done <<EOF
$(zro_allow_entries)
EOF

it "and names no binary whose own name says it writes, but the one it declares"
# The exception is written out rather than pattern-matched away. `postqueue` is
# approved for its listing flag alone — the flushing, requeueing and deleting
# forms are refused above, and `postsuper` is not on this list at all — so the
# word in its name says nothing about what this tool may ask of it.
while IFS= read -r bin; do
  [ -n "$bin" ] || continue
  case $bin in
    postqueue) zro_t_pass; continue ;;
  esac
  for verb in $ZRO_T_WRITE_VERBS; do
    assert_not_contains "$bin" "$verb"
  done
done <<EOF
$(zro_allow_entries | sed 's/:.*//' | sort -u)
EOF

it "every allowlisted binary declares the root it resolves under"
# There is no default root. A binary the allowlist names and the root table does
# not is refused at the gate, which would make it an operation that reads as
# approved and can never run.
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  assert_ok zro_bin_path "${entry%%:*}"
done <<EOF
$(zro_allow_entries)
EOF

it "the root table names no binary the allowlist does not"
# The table decides where a binary lives, never whether it may run. Reading the
# allowlist must still tell a maintainer everything this tool can execute.
allow=$(zro_allow_entries)
roots=$(zro_bin_root_entries)
assert_contains "$roots" ":"        # the loop below has something to check
unlisted=""
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  bin=${entry%%:*}
  found=""
  # Compared as literal text, for the same reason the gate does: a name is never
  # allowed to widen into a pattern, not even in a test.
  while IFS= read -r listed; do
    case $listed in
      "$bin":*) found=1; break ;;
    esac
  done <<INNER
$allow
INNER
  [ -n "$found" ] || unlisted="$unlisted [$bin]"
done <<EOF
$roots
EOF
assert_eq "$unlisted" ""

it "every root declaration names an overridable variable, never a path"
# The value in the table is a variable NAME. A path written here would be a root
# the operator cannot override and the suite cannot point at its mocks.
bad=""
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  var=${entry#*:}
  case $var in
    ZRO_[A-Z0-9_]*) case $var in *[!A-Z0-9_]*) bad="$bad [$entry]" ;; esac ;;
    *) bad="$bad [$entry]" ;;
  esac
done <<EOF
$(zro_bin_root_entries)
EOF
assert_eq "$bad" ""

it "every allowlist entry is a binary:token pair"
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  case $entry in
    *:*) zro_t_pass ;;
    *)   zro_t_fail "malformed allowlist entry: $entry" ;;
  esac
done <<EOF
$(zro_allow_entries)
EOF

zro_t_report
