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

it "denies a binary that is not on the list at all"
assert_fail zro_allowed zmmailbox search
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
