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

it "denies every write verb"
for sub in ca ma da dm mm mmr ef df createAccount modifyAccount deleteAccount \
           deleteMessage moveMessage markMessageRead emptyFolder addMessage; do
  assert_fail zro_allowed zmprov "$sub"
  assert_fail zro_allowed zmmailbox "$sub"
done

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
