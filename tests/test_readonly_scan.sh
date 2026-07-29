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

# Removes double-quoted spans, tracking the quote state ACROSS lines. A
# line-based `sed s/"[^"]*"//g` cannot do this, and the operator-facing messages
# in this program are multi-line Turkish text: the middle lines carry no quotes
# at all and read exactly like code, which produced a false alarm the first time
# a message named a Zimbra command.
#
# Runs after comment stripping, so it never has to reason about a quote inside
# a comment.
zro_strip_dquotes() {
  awk '
    BEGIN { inq = 0 }
    {
      out = ""
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "\\") {
          if (!inq) { out = out c; if (i + 1 <= n) out = out substr($0, i + 1, 1) }
          i++
          continue
        }
        if (c == "\"") { inq = !inq; continue }
        if (!inq) { out = out c }
      }
      print out
    }
  '
}

# Comments and double-quoted spans. Text inside a string is data the program
# prints, not something it runs, so an error message is free to name a command
# without that reading as a call to it.
zro_scan_code() {
  zro_scan_raw | zro_strip_dquotes
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

it "every literal zro_exec call site is covered by the allowlist"
allow=$(zro_allow_entries)
# Extracted from code with the quotes still on. A quoted or variable token
# marks a call site no static reader can resolve; those are skipped here and
# accounted for by the two checks below instead.
calls=$(printf '%s\n' "$raw_code" \
        | grep -oE 'zro_exec[[:space:]]+[A-Za-z0-9_-]+[[:space:]]+[^[:space:]]+([[:space:]]+[^[:space:]]+)?' \
        | sort -u)
uncovered=""
while IFS= read -r call; do
  [ -n "$call" ] || continue
  bin=$(printf '%s' "$call" | awk '{print $2}')
  t1=$(printf '%s' "$call" | awk '{print $3}')
  t2=$(printf '%s' "$call" | awk '{print $4}')

  case $t1 in
    '"'*|'$'*) continue ;;          # dynamic: not decidable here
  esac

  key="$bin:$t1"
  case $t1 in
    -*)
      case $t2 in
        '"'*|'$'*) continue ;;      # dynamic subcommand behind a mode flag
        [A-Za-z]*) key="$bin:$t1:$t2" ;;
        *) ;;                       # a redirection or operator: two-token key
      esac
      ;;
  esac
  printf '%s\n' "$allow" | grep -qxF -- "$key" || uncovered="$uncovered $key"
done <<EOF
$calls
EOF
assert_eq "$uncovered" ""

it "found the call sites it claims to check"
assert_contains "$calls" "zro_exec zmcontrol -v"

# zro_prov_read is the one function that hands the gate a variable, so that it
# can retry a read against LDAP without four copies of the same logic. The
# guarantee is preserved one level up: the set of values the variable may hold
# is declared, and every caller names its subcommand literally.
it "the one dynamic gate call declares the subcommands it may pass"
declared=$(printf '%s\n' "$raw_code" | sed -n "s/^ZRO_PROV_READS='\(.*\)'/\1/p")
assert_contains "$declared" "ga"
assert_contains "$declared" "gam"
assert_contains "$declared" "gc"
assert_contains "$declared" "gmi"

it "every declared read subcommand is on the allowlist"
for sub in $declared; do
  printf '%s\n' "$allow" | grep -qxF -- "zmprov:$sub" || \
    zro_t_fail "declared read subcommand is not allowlisted: zmprov:$sub"
done
zro_t_pass

it "no declared read subcommand is a write verb"
for sub in $declared; do
  case $sub in
    ca|ma|da|dm|mm|mmr|ef|df|create*|modify*|delete*|remove*|move*|mark*|empty*|add*)
      zro_t_fail "write subcommand declared as a read: $sub" ;;
    *) zro_t_pass ;;
  esac
done

it "every zro_prov_read call site names its subcommand literally"
prov_calls=$(printf '%s\n' "$raw_code" \
             | grep -oE 'zro_prov_read[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+' \
             | sort -u)
bad=""
while IFS= read -r call; do
  [ -n "$call" ] || continue
  sub=$(printf '%s' "$call" | awk '{print $3}')
  case $sub in
    [A-Za-z]*) ;;
    *) bad="$bad [$sub]" ;;
  esac
  case " $declared " in
    *" $sub "*) ;;
    *) bad="$bad [$sub]" ;;
  esac
done <<EOF
$prov_calls
EOF
assert_eq "$bad" ""
assert_contains "$prov_calls" "ga"
assert_contains "$prov_calls" "gmi"

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
  body=$(sed 's/[[:space:]]*#.*$//' "$f" | zro_strip_dquotes \
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
