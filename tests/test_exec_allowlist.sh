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
assert_ok zro_allowed zmprov gmi
assert_ok zro_allowed zmprov getMailboxInfo
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
