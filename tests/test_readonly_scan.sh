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
#
# A '#' begins a comment at the start of a line or after whitespace, and NOWHERE
# ELSE. Cutting at every '#' instead truncates a line in the middle of a parameter
# expansion — ${var#prefix}, ${#var} — or of an arithmetic base like 10#$n, and a
# line cut in half can end inside an unclosed quote. That throws the quote
# tracking below out of step for every file after it, which is how a scan of a
# tree with nothing wrong in it reported a literal path in executable position.
zro_strip_comments() {
  sed -e 's/^[[:space:]]*#.*$//' -e 's/\([[:space:]]\)#.*$/\1/' "$1"
}

zro_scan_raw() {
  local f
  for f in "${SOURCES[@]}"; do
    zro_strip_comments "$f"
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

# One file, read exactly the way the whole tree is. Every per-file case goes
# through this: repeating the comment rule per case is how two of them below were
# left reading a '#' the tree's own scan had stopped treating as a comment.
zro_scan_file() {
  zro_strip_comments "$1" | zro_strip_dquotes
}

raw_code=$(zro_scan_raw)
code=$(zro_scan_code)

it "the scan's own view of the tree closes every quote it opens"
# The scanner is only as good as its quote tracking, and that tracking runs across
# the WHOLE tree as one stream: one unbalanced quote and every file after it is
# read inside out — strings surviving into 'code', real statements vanishing from
# it. Both directions are silent, so the parity is asserted rather than trusted.
assert_eq "$(( $(printf '%s' "$raw_code" | tr -cd '"' | wc -c) % 2 ))" "0"

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

# gmi is the only read-named admin handler that auto-creates a mailbox, so it
# may not be declared a read anywhere in the tree.
it "declares no subcommand that creates a mailbox"
assert_not_contains "$declared" "gmi"
assert_not_contains "$code" "zro_exec zmprov gmi"
assert_not_contains "$code" "getMailboxInfo"

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
assert_contains "$prov_calls" "gam"

it "the allowlist itself names no write verb"
for verb in create modify delete remove move mark flag tag empty import post recover sync; do
  assert_not_contains "$allow" "$verb"
done

it "the allowlist exposes no mailbox binary at all"
# Not an M1 statement any more: M5 traces delivery from logs precisely so that
# the question can be answered without a mailbox, which is what keeps the
# existence gate out of it.
assert_not_contains "$allow" "zmmailbox"

# The delivery trace hands the gate a literal filter followed by a variable
# holding the operator's already-validated value. The generic extraction above
# cannot decide a call site whose token after a flag is dynamic, so the filter is
# checked here instead: every tracing call site must name a filter the allowlist
# approves.
#
# This is why the three filters are written out one per line in lib/delivery.sh
# instead of reaching the gate through a variable. A single dynamic call site
# would be undecidable to this reader, and what it decides is the whole point:
# reading the source proves that nothing can ask the tracer a question nobody
# approved.
it "every delivery trace call site names an approved filter"
trace_calls=$(printf '%s\n' "$raw_code" \
              | grep -oE 'zro_exec[[:space:]]+zmmsgtrace[[:space:]]+[^[:space:]]+' \
              | sort -u)
assert_contains "$trace_calls" "zro_exec zmmsgtrace --recipient"
assert_contains "$trace_calls" "zro_exec zmmsgtrace --sender"
assert_contains "$trace_calls" "zro_exec zmmsgtrace --id"
unapproved=""
while IFS= read -r call; do
  [ -n "$call" ] || continue
  filter=$(printf '%s' "$call" | awk '{print $3}')
  printf '%s\n' "$allow" | grep -qxF -- "zmmsgtrace:$filter" || \
    unapproved="$unapproved [$filter]"
done <<EOF
$trace_calls
EOF
assert_eq "$unapproved" ""

it "and every approved filter has a call site, in exactly one spelling"
# The two sets are held equal in both directions. An approved filter with no
# call site is an operation that reads as available and can never answer; a
# second spelling of one that already has a call site is an approval a reader of
# the allowlist would have to count rather than read.
assert_eq "$(printf '%s\n' "$trace_calls" | grep -c 'zmmsgtrace')" \
          "$(printf '%s\n' "$allow" | grep -c '^zmmsgtrace:')"

# The bounded log viewer hands the gate a literal flag followed by a variable —
# the line count, then the path the inventory listed. The generic extraction
# above cannot decide a call site whose token after a flag is dynamic, so the
# operation is checked here instead, exactly as the trace's filters are.
it "every log viewer call site names an operation the allowlist approves"
viewer_calls=$(printf '%s\n' "$raw_code" \
               | grep -oE 'zro_exec[[:space:]]+(tail|gzip)[[:space:]]+[^[:space:]]+' \
               | sort -u)
assert_contains "$viewer_calls" "zro_exec tail -n"
assert_contains "$viewer_calls" "zro_exec gzip -dc"
unapproved=""
while IFS= read -r call; do
  [ -n "$call" ] || continue
  bin=$(printf '%s' "$call" | awk '{print $2}')
  op=$(printf '%s' "$call" | awk '{print $3}')
  printf '%s\n' "$allow" | grep -qxF -- "$bin:$op" || unapproved="$unapproved [$bin:$op]"
done <<EOF
$viewer_calls
EOF
assert_eq "$unapproved" ""

it "and every approved system operation has a call site, in exactly one spelling"
assert_eq "$(printf '%s\n' "$viewer_calls" | grep -c 'zro_exec')" \
          "$(printf '%s\n' "$allow" | grep -c '^\(tail\|gzip\):')"

it "no in-place decompression is expressible anywhere in the tree"
# THE POINT OF APPROVING ONLY ONE FORM. Bare gzip and gzip -d replace the file
# and delete the original — a write, by a command nobody suspects — and the
# neighbours below do the reading job under another name, outside the one entry
# a maintainer reads. The gate refuses all of them; this says they are not
# written down either.
assert_not_contains "$code" "gunzip"
assert_not_contains "$code" "zcat"
assert_not_contains "$code" "zless"
assert_not_contains "$code" "zgrep"
# Matched to the end of the token, so that the approved -dc is not read as this.
assert_eq "$(printf '%s\n' "$code" | grep -cE 'gzip[[:space:]]+-d([^c]|$)')" "0"
assert_eq "$(printf '%s\n' "$code" | grep -cE 'gzip[[:space:]]+[^-]')" "0"

it "the log viewer writes no path of its own"
# Every path it reads comes from the log inventory, and every binary it runs is
# resolved under a root declared in lib/exec.sh. A literal path here would be a
# file this tool could read that the inventory never admitted, and a system
# binary root nobody could override.
logview=$(zro_scan_file "$ZRO_SRC/lib/logview.sh")
for prefix in /usr /bin /sbin /var /opt /etc; do
  assert_not_contains "$logview" "$prefix"
done

it "the log viewer reaches no Zimbra binary and no mailbox"
assert_not_contains "$logview" "zmmailbox"
assert_not_contains "$logview" "zmprov"
assert_not_contains "$logview" "zmmsgtrace"

it "the delivery trace names no mailbox binary and no directory command"
# M5's independence from the existence gate, asserted rather than assumed.
delivery=$(zro_scan_file "$ZRO_SRC/lib/delivery.sh")
assert_not_contains "$delivery" "zmmailbox"
assert_not_contains "$delivery" "zmprov"

# §7.4, reshaped. This was a count: /opt/zimbra had to appear exactly once in the
# tree. Three binary roots and two log roots break that count, and raising the
# number would turn a guarantee into a reminder. What the count was reaching for
# is that the production path is never reachable except through a variable the
# operator can override — so that is what is asserted, and it survives the next
# root without being edited.
#
# The log inventory brought a second prefix with it: the primary mail log is
# written by the syslog daemon and lives outside the Zimbra tree, so the rule is
# applied to every production prefix rather than to the one that came first.
zro_scan_literal_paths() {
  local prefix=$1 esc line name literal=""
  # The prefix is interpolated into a sed pattern whose delimiter is '/'.
  esc=$(printf '%s' "$prefix" | sed 's|/|\\/|g')
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # The backreference is the point of the pattern: the name being assigned and
    # the name being defaulted have to be the same variable, or setting it in the
    # environment overrides nothing.
    name=$(printf '%s\n' "$line" \
           | sed -n 's/^[[:space:]]*\(ZRO_[A-Z0-9_]*\)="\${\1:-'"$esc"'[^"]*}"[[:space:]]*$/\1/p')
    [ -n "$name" ] || literal="$literal [$line]"
  done <<EOF
$(printf '%s\n' "$raw_code" | grep -F -- "$prefix")
EOF
  printf '%s' "$literal"
}

it "every production path is an overridable default and nothing else"
for prefix in /opt/zimbra /var/log; do
  # The assertion has something to check.
  assert_contains "$(printf '%s\n' "$raw_code" | grep -F -- "$prefix")" "$prefix"
  assert_eq "$(zro_scan_literal_paths "$prefix")" ""
  # Every occurrence sits inside a double-quoted default, so once quoted spans
  # are stripped the path is gone entirely. A literal path anywhere in executable
  # position fails both this and the assertion above.
  assert_not_contains "$code" "$prefix"
done

inventory=$(zro_scan_file "$ZRO_SRC/lib/inventory.sh")

it "the log inventory declares no proxy log"
# The proxy log's rotation configuration is the only one that delays compression,
# so its most recent rotated file is plain text while every other file's is
# already gzipped. Excluding it keeps that inversion out of the code entirely.
assert_not_contains "$inventory" "nginx"

it "the log inventory reaches no binary and no mailbox"
# Building the inventory is a question about names and timestamps. Asking Zimbra
# anything would make it something else, and would put it behind the existence
# gate this milestone is independent of.
assert_not_contains "$inventory" "zmmailbox"
assert_not_contains "$inventory" "zmprov"
assert_not_contains "$inventory" "zro_exec"

# A capability probe RUNS NOTHING. It asks the allowlist whether an operation is
# approved and tests whether the binary is installed, which is how a menu entry is
# marked unavailable before an operator selects it. That is why it is exempt from
# the rule below — and it is exempt only because what it names is checked here
# instead, against the same list the gate reads.
#
# A probe naming an operation nobody approved would grey out a menu entry for a
# question this tool may not ask, and the operator would read that as a program
# this host does not have rather than as a refusal.
it "every capability probe names an operation the allowlist approves"
probes=$(printf '%s\n' "$raw_code" \
         | grep -oE 'zro_cap_op_available[[:space:]]+[A-Za-z0-9_-]+[[:space:]]+[^[:space:];]+' \
         | sort -u)
assert_contains "$probes" "zro_cap_op_available zmmsgtrace --recipient"
unapproved=""
while IFS= read -r probe; do
  [ -n "$probe" ] || continue
  bin=$(printf '%s' "$probe" | awk '{print $2}')
  t1=$(printf '%s' "$probe" | awk '{print $3}')
  printf '%s\n' "$allow" | grep -qxF -- "$bin:$t1" || unapproved="$unapproved [$bin:$t1]"
done <<EOF
$probes
EOF
assert_eq "$unapproved" ""

it "and every capability probe is one that reader could resolve"
# The exemption is only as good as the extractor above, and a probe handing the
# query a variable would be invisible to it: dropped from the rule below, matched by
# nothing above, approved by neither. So a call site this reader cannot resolve fails
# the build HERE rather than passing quietly — which is the same friction CLAUDE.md
# asks for when a new capability is added.
#
# Resolvable means both tokens are literal: a binary name, then a subcommand or a
# flag. Anything quoted or expanded fails the pattern.
unresolved=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  printf '%s' "$line" \
    | grep -qE 'zro_cap_op_available[[:space:]]+[A-Za-z0-9_-]+[[:space:]]+[A-Za-z0-9_-]' \
    || unresolved="$unresolved [$line]"
done <<EOF
$(printf '%s\n' "$raw_code" | grep 'zro_cap_op_available[[:space:]]')
EOF
assert_eq "$unresolved" ""

it "no module calls a Zimbra binary outside the gate"
# Capability probes are dropped along with the gate's own call sites, and for the
# same reason the allowlist itself is: naming a binary is not running one. What they
# name is held to the allowlist by the case above.
for f in "${SOURCES[@]}"; do
  body=$(zro_scan_file "$f" | grep -v 'zro_exec' | grep -v 'ZRO_ALLOW' \
         | grep -v 'zro_cap_op_available')
  assert_not_contains "$body" 'zmprov '
  assert_not_contains "$body" 'zmmailbox '
  assert_not_contains "$body" 'zmcontrol '
  assert_not_contains "$body" 'zmmsgtrace '
done

it "every library guards against being loaded twice"
for f in "$ZRO_SRC"/lib/*.sh; do
  header=$(head -n 15 "$f")
  assert_contains "$header" "shellcheck shell=bash"
  assert_contains "$header" "_LOADED"
done

zro_t_report
