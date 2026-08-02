#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
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

it "the allowlist names one bounded read and one decompression, and nothing else"
# Read as the tracing filters are: a fourth system operation added without a
# ticket behind it fails here, and so does a second spelling of one of these.
assert_eq "$(zro_allow_entries | grep -E '^(tail|gzip):')" \
  "$(printf '%s\n%s' 'tail:-n' 'gzip:-dc')"

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

it "the allowlist names exactly two flags in a data position"
# Two entries, and each arrived with the ticket that needs it: the entry-only
# account read, and the raw-byte form of the mailbox size. A third added without a
# ticket behind it fails here — which is the same friction the list itself exists
# to impose.
#
# Both shapes a data-position flag can take are read: a third token behind a
# subcommand, and a fourth behind a mode flag and its subcommand. Reading only
# the first would let `zmprov:-l:ga:-t` be added in silence, which is the entry a
# maintainer would reach for first.
data_flags=$(zro_allow_entries | grep -E '^[^:]+:[^-][^:]*:-|^[^:]+:-[^:]*:[^:]*:')
assert_eq "$data_flags" "$(printf '%s\n%s' 'zmprov:ga:-e' 'zmmailbox:gms:-v')"

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

it "the allowlist names exactly the four reads that binary exposes"
# Reading the list has to tell a maintainer what may be asked of a mailbox. A
# fifth entry added without a ticket behind it fails here, and so does a second
# spelling of one of these.
assert_eq "$(zro_allow_entries | grep '^zmmailbox:')" "$(printf '%s\n%s\n%s\n%s\n%s' \
  'zmmailbox:gaf' 'zmmailbox:gf' 'zmmailbox:gfg' 'zmmailbox:gms' 'zmmailbox:gms:-v')"

it "and the binary it names is the one the gate refuses from a foreign caller"
# Two declarations that have to agree, and nothing else holds them together: the
# name the gate compares against and the name these entries stand under.
assert_eq "$ZRO_GATED_BIN" "zmmailbox"
assert_eq "$(printf '%s\n' "${ZRO_GATED_PREFIX[@]}")" "$(printf -- '-z\n-m')"

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

it "the allowlist itself contains no write verb"
entries=$(zro_allow_entries)
for verb in create modify delete remove move mark flag tag empty import post recover sync; do
  assert_not_contains "$entries" "$verb"
done

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
