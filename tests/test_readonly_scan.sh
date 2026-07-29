#!/usr/bin/env bash
# Static guarantees. Nothing here executes the program; it reads the source and
# fails the build when the read-only claim stops being structurally true.
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"

SOURCES=("$ZRO_SRC/zimbra-ro-tui.sh" "$ZRO_SRC"/lib/*.sh)

# Comments only. Documentation may name what code may not do.
zro_scan_raw() {
  local f
  for f in "${SOURCES[@]}"; do
    sed 's/[[:space:]]*#.*$//' "$f"
  done
}

# Comments and double-quoted spans. Text inside a string is data the program
# prints, not something it runs, so an error message is free to name a command
# without that reading as a call to it.
zro_scan_code() {
  zro_scan_raw | sed 's/"[^"]*"//g'
}

raw_code=$(zro_scan_raw)
code=$(zro_scan_code)

it "contains no write subcommand in an executable position"
for verb in createAccount modifyAccount deleteAccount renameAccount \
            deleteMessage deleteConversation deleteFolder emptyFolder \
            moveMessage markMessageRead markMessageSpam addMessage \
            postRestURL recoverItem createFolder modifyFolder; do
  assert_not_contains "$code" "$verb"
done

it "contains no short write alias in an executable position"
for alias in ' dm ' ' mm ' ' mmr ' ' ef ' ' df ' ' ma ' ' da ' ' ca '; do
  assert_not_contains "$code" "zro_exec zmprov$alias"
  assert_not_contains "$code" "zro_exec zmmailbox$alias"
done

it "contains no eval or shell-string execution"
assert_not_contains "$code" "eval "
assert_not_contains "$code" "bash -c"
assert_not_contains "$code" "sh -c"
assert_not_contains "$code" '`'

it "every zro_exec call site is covered by the allowlist"
allow=$(zro_allow_entries)
calls=$(printf '%s\n' "$code" \
        | grep -oE 'zro_exec[[:space:]]+[A-Za-z0-9_-]+[[:space:]]+[^[:space:]"]+' \
        | sort -u)
uncovered=""
while IFS= read -r call; do
  [ -n "$call" ] || continue
  bin=$(printf '%s' "$call" | awk '{print $2}')
  token=$(printf '%s' "$call" | awk '{print $3}')
  case $token in
    '$'*) continue ;;   # only literal call sites are decidable here
  esac
  printf '%s\n' "$allow" | grep -qxF -- "$bin:$token" || uncovered="$uncovered $bin:$token"
done <<EOF
$calls
EOF
assert_eq "$uncovered" ""

it "found the call sites it claims to check"
assert_contains "$calls" "zro_exec zmprov ga"
assert_contains "$calls" "zro_exec zmprov gmi"
assert_contains "$calls" "zro_exec zmprov gam"
assert_contains "$calls" "zro_exec zmprov gc"
assert_contains "$calls" "zro_exec zmcontrol -v"

it "the allowlist itself names no write verb"
for verb in create modify delete remove move mark flag tag empty import post recover sync; do
  assert_not_contains "$allow" "$verb"
done

it "M1 exposes no zmmailbox operation at all"
assert_not_contains "$allow" "zmmailbox"

it "the production Zimbra path appears only as the overridable default"
assert_not_contains "$code" "/opt/zimbra/bin/"
assert_not_contains "$code" "/opt/zimbra/libexec/"
assert_eq "$(printf '%s\n' "$raw_code" | grep -c '/opt/zimbra')" "1"

it "no module calls a Zimbra binary outside the gate"
for f in "${SOURCES[@]}"; do
  body=$(sed -e 's/[[:space:]]*#.*$//' -e 's/"[^"]*"//g' "$f" \
         | grep -v 'zro_exec' | grep -v 'ZRO_ALLOW')
  assert_not_contains "$body" 'zmprov '
  assert_not_contains "$body" 'zmmailbox '
  assert_not_contains "$body" 'zmcontrol '
done

it "every library guards against being loaded twice"
for f in "$ZRO_SRC"/lib/*.sh; do
  header=$(head -n 15 "$f")
  assert_contains "$header" "shellcheck shell=bash"
  assert_contains "$header" "_LOADED"
done

zro_t_report
