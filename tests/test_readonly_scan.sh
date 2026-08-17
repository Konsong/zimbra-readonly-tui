#!/usr/bin/env bash
# Static guarantees. Nothing here executes the program; it reads the source and
# fails the build when the read-only claim stops being structurally true.
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/table.sh
. "$ZRO_SRC/lib/table.sh"
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

it "decides nothing by racing a builtin against a consumer that exits early"
# `printf | grep -q` under `set -o pipefail` returns 141. grep exits the moment it
# matches, and if it wins that race the write at the other end gets SIGPIPE and
# the pipeline reports failure although the answer was found. In the exec gate
# that is a spurious ALLOWLIST DENIAL — exit code 90, which this program defines
# as a defect and always logs — arriving at random, under load, on an operation
# the list plainly approves. Measured at one in three thousand lookups before the
# lookup was rewritten to take the list on a heredoc.
#
# Banned outright rather than judged case by case: a heredoc costs nothing and
# works everywhere, so there is no reading of this pattern worth keeping. The awk
# readers have the same hazard and the same fix; it cannot be checked here without
# parsing an awk program, so it is written down where they are instead.
assert_eq "$(printf '%s\n' "$code" | grep -cE '\|[[:space:]]*grep[[:space:]]+-[a-zA-Z]*q')" "0"

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
        # A subcommand behind a mode flag, as `zmprov -l ga` — and a second FLAG
        # behind one, as the search's `grep -a -F`. Both are three-token
        # operations, and the second shape arrived with the log search: a mode
        # that is never approved alone, then the form that says what is being
        # asked. Reading only the alphabetic shape left the key at two tokens,
        # which is not on the list and never can be.
        [A-Za-z]*|-*) key="$bin:$t1:$t2" ;;
        *) ;;                       # a redirection or operator: two-token key
      esac
      ;;
    *)
      # A FLAG IN THE DATA POSITION IS NOT DATA — it changes what the command
      # does, so it is looked up by name exactly as the subcommand was. The gate
      # applies this rule to the whole vector at run time; this reader sees only
      # the token the extraction above captured, and a call site that hides a
      # flag inside quotes reaches the gate and is refused there.
      case $t2 in
        -*) key="$bin:$t1:$t2" ;;
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
assert_contains "$declared" "gdl"
assert_contains "$declared" "gd"
assert_contains "$declared" "gis"

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
assert_contains "$prov_calls" "gdl"
assert_contains "$prov_calls" "gd"

it "the entry-only form is written at exactly one call site"
# A FLAG IN THE DATA POSITION IS AN OPERATION, and this one reaches the gate
# through zro_prov_read — which hands it a variable, so the generic extraction
# above cannot resolve it. What can be read here is that the flag appears once in
# the tree's executable text, behind the one subcommand approved to carry it. A
# second one would be a second operation, and it would arrive with a ticket.
entry_calls=$(printf '%s\n' "$raw_code" \
              | grep -cE 'zro_prov_read[[:space:]]+[^[:space:]]+[[:space:]]+ga[[:space:]]+-e([[:space:]]|$)')
assert_eq "$entry_calls" "1"

it "and no other flag reaches that read at all"
# The temp-file form is the one this matters for: `-t` writes binary attribute
# values to files and deletes whatever stood at the path first. The gate refuses
# it at run time; this refuses it at the only call site that could express it.
other_flags=$(printf '%s\n' "$raw_code" \
              | grep -oE 'zro_prov_read[[:space:]]+[^[:space:]]+[[:space:]]+[A-Za-z]+[[:space:]]+-[^[:space:]]*' \
              | awk '{print $4}' | sort -u | grep -v '^-e$')
assert_eq "$other_flags" ""

it "the degraded read asks the gate before it retries, rather than after"
# An allowlist denial means a defect in this program. A read whose LDAP form
# nobody approved is not one — it is a question this tool answers in one mode —
# and the difference reaches the operator during an outage, which is when it can
# least afford to look like a broken tool.
assert_contains "$code" "zro_ldap_form_allowed"

it "the list read is a read, and the write-named siblings are nowhere"
# `gdl` arrived so that a distribution list stops being answered with "no such
# account". The commands that CHANGE a list live one letter away from it, and
# none of them may be expressible: not in the allowlist, not at a call site.
for sub in adlm rdlm cdl ddl addDistributionListMember removeDistributionListMember \
           createDistributionList deleteDistributionList renameDistributionList; do
  assert_not_contains "$allow" "$sub"
  assert_not_contains "$code" "zro_exec zmprov $sub"
  assert_not_contains "$declared" " $sub "
done

it "the domain read is a read, and the write-named siblings are nowhere"
# `gd` arrived so that a suspended domain and an unrouted address can be
# explained. The commands that CHANGE a domain live one letter away from it, and
# none of them may be expressible: not in the allowlist, not at a call site.
for sub in cd md dd rd createDomain modifyDomain deleteDomain renameDomain; do
  assert_not_contains "$allow" "zmprov:$sub"
  assert_not_contains "$code" "zro_exec zmprov $sub"
  assert_not_contains "$declared" " $sub "
done

it "no read whose work grows with the account count is expressible anywhere"
# CLASS 4 DOES NOT EXIST IN THIS TOOL, asserted rather than left to nobody having
# written one. The domain screen is where the pressure to add one lands: an
# account count per domain is the obvious next field, and answering it means a
# sweep of a directory holding more than 100,000 entries.
for sub in gaa getAllAccounts gqu getQuotaUsage searchAccounts \
           gad getAllDomains gadl getAllDistributionLists; do
  assert_not_contains "$allow" "zmprov:$sub"
  assert_not_contains "$code" "zro_exec zmprov $sub"
  assert_not_contains "$declared" " $sub "
done

it "the allowlist itself names no write verb in a position that could be one"
# ASKED OF THE TOKENS, never of the whole entry: the mail transfer agent's own
# programs are all named `post...`, so a search over the line reports the queue
# tool's listing flag as a write verb. What may be ASKED of a binary is the rule
# worth keeping, and the binary names answer for themselves in the case below.
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  tokens=${entry#*:}
  for verb in create modify delete remove move mark flag tag empty import post recover sync; do
    assert_not_contains "$tokens" "$verb"
  done
done <<EOF
$allow
EOF

it "and the queue tool is the one binary whose name carries such a word"
# Written out rather than patterned away. It is approved for its listing flag
# alone; `postsuper`, which holds, requeues and deletes, is not on the list at
# all, and neither is `mailq`, which is a link to the mail submission program.
assert_eq "$(printf '%s\n' "$allow" | sed 's/:.*//' | sort -u | grep -c '^post')" "1"
assert_not_contains "$allow" "postsuper"
assert_not_contains "$allow" "mailq"
assert_not_contains "$allow" "sendmail"

it "the allowlist exposes the mailbox binary as six reads and nothing else"
# AN OPERATION ARRIVES WITH THE TICKET THAT EXPOSES IT, never because the binary
# it belongs to became reachable. The gate shipped with nothing behind it; the
# folder, size and quota screens brought four reads, the message search brought
# the fifth and the conversation listing the sixth, and reading this list is still
# how a maintainer learns what may be asked of a mailbox.
assert_eq "$(printf '%s\n' "$allow" | grep '^zmmailbox:')" \
  "$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s' \
     'zmmailbox:gaf' 'zmmailbox:gf' 'zmmailbox:gfg' 'zmmailbox:gms' 'zmmailbox:gms:-v' \
     'zmmailbox:s' 'zmmailbox:s:-t' 'zmmailbox:s:-l' 'zmmailbox:sc' 'zmmailbox:sc:-l')"

it "and none of them is a command that writes, whatever it is named"
# The write-named siblings live one letter away from every one of these. `gm` is
# the one that is not write-named and is a write all the same: it clears the
# unread flag on the message it reports. Judge by effect, not by name.
#
# MATCHED AS WHOLE ENTRIES, never as text inside one: `zmmailbox:gm` is a
# substring of the approved `zmmailbox:gms`, and a rule that read it as one would
# fail on the entry it exists to protect while saying nothing about the command it
# is looking for.
for sub in df ef cf csf cm rf mfg mff mfc mfch mfu mfr iuif am dm mm mmr gm gru sf \
           deleteFolder emptyFolder createFolder renameFolder modifyFolderGrant \
           addMessage getMessage syncFolder emptyDumpster; do
  if printf '%s\n' "$allow" | grep -qxF -- "zmmailbox:$sub"; then
    zro_t_fail "a command that writes a mailbox is on the allowlist: zmmailbox:$sub"
  else
    zro_t_pass
  fi
done

it "every mailbox read names its subcommand literally, and the allowlist approves it"
# The same rule the tracer's filters live by, for the same reason: this call site
# passes a variable for the ACCOUNT, so a reader can only decide it if the
# subcommand beside it is written out. What that buys is the thing the guarantee
# rests on — reading lib/store.sh proves which questions this tool can ask of a
# mailbox, without running it.
mbox_calls=$(printf '%s\n' "$raw_code" | grep -oE 'zro_mbox_run[[:space:]].*' | sort -u)
assert_contains "$mbox_calls" "gaf"
uncovered=""
seen_keys=""
while IFS= read -r call; do
  [ -n "$call" ] || continue
  # EVERY POSITION IS READ, NOT JUST THE FIRST ONE BEHIND THE SUBCOMMAND, which is
  # the same rule the exec gate applies at run time. The search asks for its type
  # with one flag and its bound with another, so a reader that stopped at the first
  # would leave the second checked by nobody until it ran.
  #
  # Globbing is off around the split: a call site is source text, and a token in it
  # must not be matched against the files in this directory.
  set -f
  # shellcheck disable=SC2206
  toks=(${call#zro_mbox_run})
  set +f
  sub=${toks[1]-}
  case $sub in ''|-*) continue ;; esac
  key="zmmailbox:$sub"
  printf '%s\n' "$allow" | grep -qxF -- "$key" || uncovered="$uncovered [$key]"
  i=2
  while [ "$i" -lt "${#toks[@]}" ]; do
    case ${toks[i]} in
      # A FLAG IN THE DATA POSITION IS NOT DATA. The size read asks for raw bytes
      # with one and the search asks for its type with another; each is held to
      # the list under the entry that approved the subcommand, exactly as
      # `zmprov ga -e` is.
      -*) key="zmmailbox:$sub:${toks[i]}"
          seen_keys="$seen_keys$key
"
          printf '%s\n' "$allow" | grep -qxF -- "$key" || uncovered="$uncovered [$key]" ;;
    esac
    i=$((i + 1))
  done
done <<EOF
$mbox_calls
EOF
assert_eq "$uncovered" ""

it "and the reader above really sees every flag, not just the first"
# The extraction is only as good as what it matches, and a call site written in a
# shape it cannot split would be checked by nobody while passing quietly. So the
# flags that exist today are asked for by name — and one of them, the search's
# bound, stands SECOND in the data, which is exactly the position the reader this
# replaced could not see.
for key in zmmailbox:gms:-v zmmailbox:s:-t zmmailbox:s:-l zmmailbox:sc:-l; do
  if zro_t_has_line "$seen_keys" "$key"; then
    zro_t_pass
  else
    zro_t_fail "the call-site reader did not find [$key]; a flag it cannot see is a flag nobody checks"
  fi
done

it "and no mailbox read hands the gate a subcommand this reader cannot resolve"
# The exemption above is only as good as the extraction, and a call site holding
# its subcommand in a variable would be invisible to it: matched by nothing,
# checked by nobody. So one fails the build HERE rather than passing quietly.
unresolved=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  printf '%s' "$line" \
    | grep -qE 'zro_mbox_run[[:space:]]+[^[:space:]]+[[:space:]]+[A-Za-z]' \
    || unresolved="$unresolved [$line]"
done <<EOF
$(printf '%s\n' "$raw_code" | grep 'zro_mbox_run[[:space:]]')
EOF
assert_eq "$unresolved" ""

it "and the size read is asked for in the raw form at the only call site it has"
# The bare `zmmailbox:gms` entry exists because the matcher needs the subcommand
# on the list before a flag under it can be approved — so the locale-formatted
# form of this read is approved as a side effect. What keeps it from being ASKED
# FOR is here: one call site, and it names the flag. A second call site without it
# would be a screen reading a size whose decimal separator depends on the server's
# locale, and this is what fails the build for it.
assert_contains "$mbox_calls" "gms -v"
assert_eq "$(printf '%s\n' "$mbox_calls" | awk '$3 == "gms"' | wc -l)" "1"
assert_eq "$(printf '%s\n' "$mbox_calls" | awk '$3 == "gms" && $4 != "-v"' | wc -l)" "0"

it "and every approved mailbox read has a call site, in exactly one spelling"
# The two sets are held equal in both directions, as the tracer's filters are. An
# approved read with no call site is an operation that reads as available and can
# never answer; a second spelling of one that has a call site is an approval a
# reader of the list would have to count rather than read.
assert_eq "$(printf '%s\n' "$mbox_calls" | awk '{print $3}' | sort -u)" \
          "$(printf '%s\n' "$allow" | sed -n 's/^zmmailbox:\([^:]*\).*$/\1/p' | sort -u)"

# ------------------------------------------------------------ message detail --
#
# THE READS THAT REPLACE `gm`. Message detail is asked of the DATABASE and of the
# blob on disk, because the one command that answers it in a single call clears the
# unread flag it reports. The dump hands the gate a flag that IS the operation and
# then an account and an id this program validated, so the generic extraction above
# cannot decide that call site — exactly as it cannot decide the tracer's filters —
# and the operation is checked here instead.
it "every metadata dump call site names the approved operation"
dump_calls=$(printf '%s\n' "$raw_code" \
             | grep -oE 'zro_exec[[:space:]]+zmmetadump[[:space:]]+[^[:space:]]+' \
             | sort -u)
assert_contains "$dump_calls" "zro_exec zmmetadump -m"
unapproved=""
while IFS= read -r call; do
  [ -n "$call" ] || continue
  op=$(printf '%s' "$call" | awk '{print $3}')
  printf '%s\n' "$allow" | grep -qxF -- "zmmetadump:$op" || unapproved="$unapproved [$op]"
done <<EOF
$dump_calls
EOF
assert_eq "$unapproved" ""

it "and there is exactly one of them, in the module that owns it"
# The entry approves that operation entire and the gate reads no flag behind a flag,
# so what keeps the item id the only thing riding there is that there is one call
# site and a reader can see all of it.
assert_eq "$(printf '%s\n' "$raw_code" | grep -cE 'zro_exec[[:space:]]+zmmetadump')" "1"
assert_eq "$(zro_strip_comments "$ZRO_SRC/lib/message.sh" \
             | grep -cE 'zro_exec[[:space:]]+zmmetadump')" "1"

it "and the forms of that binary this tool does not ask for are written nowhere"
# `--dumpster` reads the deleted-item store — a different question about a different
# table — while `-f` and `-s` decode metadata this program never holds. None of them
# writes, and none of them is an operation anybody here has judged.
for form in --dumpster -f -s -h --help; do
  assert_not_contains "$code" "zro_exec zmmetadump $form"
done
assert_not_contains "$code" "--dumpster"

it "the blob head is read in the bounded form and no other"
# THREE CALL SITES, ALL IN THE MODULE THAT OWNS THEM: the two bytes that say whether
# the file is a gzip stream, the bounded read of a plain blob, and the bounded read
# behind the decompression. `head -n` is absent from the allowlist and from the tree —
# a message is a MIME stream whose base64 part is one enormous line, so a line bound
# is no bound there.
head_calls=$(printf '%s\n' "$raw_code" \
             | grep -oE 'zro_exec[[:space:]]+head[[:space:]]+[^[:space:]]+' \
             | sort -u)
assert_eq "$head_calls" "zro_exec head -c"
assert_eq "$(printf '%s\n' "$raw_code" | grep -cE 'zro_exec[[:space:]]+head')" "3"
assert_eq "$(zro_strip_comments "$ZRO_SRC/lib/message.sh" \
             | grep -cE 'zro_exec[[:space:]]+head')" "3"
for form in -n --lines -f --follow --bytes; do
  assert_not_contains "$code" "zro_exec head $form"
done
assert_not_contains "$code" "zro_exec cat"

it "the message module opens no mailbox session at all"
# THE REASON THIS SCREEN NEEDS NO EXISTENCE GATE, asserted rather than described: it
# never reaches the binary that would create a mailbox, so there is nothing for the
# oracle to protect. `gm` and `gru` are refused by the allowlist as well; this is
# what stops them being written.
message=$(zro_scan_file "$ZRO_SRC/lib/message.sh")
assert_not_contains "$message" "zro_mbox_run"
assert_not_contains "$message" "zmprov"
assert_not_contains "$message" "gm "
assert_not_contains "$message" "gru "

# ------------------------------------------------------------ bulk queries --

it "a bulk query reaches the directory only through the reader every screen uses"
# THE SCREEN THAT EXISTS INSTEAD OF A SERVER-WIDE SWEEP, held to what makes it
# one. It runs the same read as the account card, once per address the operator
# supplied, and it reaches it through zro_prov_read — so it inherits the declared
# subcommand set, the degraded-read path and the allowlist without a second route
# to any of them.
bulk=$(zro_scan_file "$ZRO_SRC/lib/bulk.sh")
assert_not_contains "$bulk" "zro_exec"
assert_not_contains "$bulk" "zmmailbox"
assert_not_contains "$bulk" "zro_mbox_run"

it "and every read it makes names its subcommand literally, and it is a read"
# One call site per question, each naming `ga`. A bulk query that could hand the
# reader a variable would be a screen whose subcommand nobody can read out of this
# file — which is the whole reason ZRO_PROV_READS exists for the one place that
# does.
# Read with the quoted spans already removed, which is what leaves the subcommand
# standing where the missing-account code used to be: `zro_prov_read  ga`.
assert_eq "$(printf '%s\n' "$bulk" | grep -cE 'zro_prov_read[[:space:]]+ga[[:space:]]')" "2"
assert_eq "$(printf '%s\n' "$bulk" | grep -cE 'zro_prov_read')" "2"

it "and no read whose work grows with the account count is expressible in it"
# The refusal this whole screen is built around, asserted where somebody would
# reach for the shortcut: the questions it answers are exactly the ones a
# server-wide sweep would answer faster.
#
# `sa` is absent from this list and cannot be added to it: 'sa' is also how this
# program abbreviates an hour on a Turkish screen, and a scan that reads
# single-quoted text as code would report the estimate as a directory search. The
# allowlist refuses the subcommand, and the tree-wide case above refuses it in an
# executable position; this list is the module-local half.
for sweep in gqu getQuotaUsage gaa getAllAccounts searchAccounts; do
  assert_not_contains "$bulk" " $sweep "
done

it "and the batch mode that would run commands from a file is written nowhere"
# `zmprov -f` reads command LINES from a file, which would put what runs outside
# the allowlist's view — the same objection that forbids evaluating strings as
# commands. A bulk query pays a JVM start per account instead, and this is what
# keeps that decision from being quietly reversed by whoever next finds the screen
# slow.
assert_not_contains "$code" "zro_exec zmprov -f"
assert_not_contains "$code" "zmprov --file"
assert_not_contains "$code" "zro_exec zmprov -c"

it "the one path an operator types is validated before anything opens it"
# Every other file this tool reads comes from the declared log inventory. This one
# is named by an operator, so the admission is a validator of its own and the
# module may not open anything it did not judge.
assert_contains "$bulk" "zro_validate_list_path"
assert_eq "$(printf '%s\n' "$bulk" | grep -cE '(^|[^_])cat --')" "1"
for prefix in /usr /bin /sbin /var /opt /etc; do
  assert_not_contains "$bulk" "$prefix"
done

it "the mail queue is read in one form, at one call site"
# THE WRITING FORMS LIVE IN THE SAME BINARY, which is what makes this worth
# checking statically as well as at the gate: `-f` flushes the deferred queue,
# `-s` flushes one site, `-i` requeues one message and `-d` deletes. Reading
# lib/queue.sh must prove which of them this tool can ask for, without running it.
assert_contains "$calls" "zro_exec postqueue -p"
assert_eq "$(printf '%s\n' "$raw_code" | grep -cE 'zro_exec[[:space:]]+postqueue')" "1"
for form in -f -s -i -d -h -H -r -j; do
  assert_not_contains "$code" "zro_exec postqueue $form"
done

it "and the neighbouring programs that act on a queue are named nowhere at all"
# `postsuper` holds, releases, requeues and deletes; `mailq` is a link to the
# mail submission program. Neither is on the allowlist, and neither may be
# written at a call site either — the gate would refuse them, and a line that
# tried is a line somebody meant to run.
for bin in postsuper mailq sendmail postfix postdrop; do
  assert_not_contains "$code" "zro_exec $bin"
done

it "the queue module reaches no Zimbra binary, and no second path to its own"
queue=$(zro_scan_file "$ZRO_SRC/lib/queue.sh")
assert_eq "$(printf '%s\n' "$queue" | grep -cE 'zro_exec')" "1"
assert_not_contains "$queue" "zmprov"
assert_not_contains "$queue" "zmmailbox"
assert_not_contains "$queue" "zmcontrol"

it "the service status is asked for once, and nothing else of that binary is"
# The one command in this tool that WRITES, and the one binary here whose family
# changes service state. The entry that approves `status` may never become a call
# site for `stop`.
assert_contains "$calls" "zro_exec zmcontrol status"
assert_eq "$(printf '%s\n' "$raw_code" | grep -cE 'zro_exec[[:space:]]+zmcontrol[[:space:]]+status')" "1"
for verb in start stop restart shutdown maintenance kill; do
  assert_not_contains "$code" "zro_exec zmcontrol $verb"
done

it "and the module that asks for it reaches nothing else"
svc=$(zro_scan_file "$ZRO_SRC/lib/service.sh")
assert_eq "$(printf '%s\n' "$svc" | grep -cE 'zro_exec')" "1"
assert_not_contains "$svc" "zmprov"
assert_not_contains "$svc" "zmmailbox"
assert_not_contains "$svc" "postqueue"

it "and the module that makes them reaches no directory command of its own"
# The quota screen reads the account entry too, and it does it through the account
# module's own reader rather than by reaching for a second path to zmprov.
store=$(zro_scan_file "$ZRO_SRC/lib/store.sh")
assert_not_contains "$store" "zro_exec"
assert_not_contains "$store" "zmprov"
assert_not_contains "$store" "zmmailbox"

it "and neither does the module that searches one"
# The same rule for the same reason, and one more that belongs to this module
# alone: message detail is the read that clears the unread flag it reports, so the
# file that asks a mailbox what it holds may not name it. `gm` and `gru` are
# refused by the allowlist as well; this is what stops them being written at all.
search=$(zro_scan_file "$ZRO_SRC/lib/search.sh")
assert_not_contains "$search" "zro_exec"
assert_not_contains "$search" "zmprov"
assert_not_contains "$search" "zmmailbox"
for sub in 'gm ' 'gru ' 'mm ' 'mmr ' 'tm ' 'dm '; do
  assert_not_contains "$search" "zro_mbox_run \$acct $sub"
done

it "the mailbox binary is named in the gate's own file and nowhere else"
# THE STRUCTURAL HALF OF THE EXISTENCE GATE. A module that could write the binary's
# name could open a session without the oracle having run, and the oracle is the
# only thing standing between this tool and creating a mailbox it was asked to
# describe. So the name is a declaration in one file, read from a variable
# everywhere else, and a second literal anywhere in the tree fails the build.
#
# Comments and double-quoted spans are stripped first, as everywhere in this file:
# documentation and operator text may name the binary, because neither runs.
for f in "${SOURCES[@]}"; do
  case $f in
    */lib/exec.sh) continue ;;
  esac
  assert_not_contains "$(zro_scan_file "$f")" "zmmailbox"
done

it "and inside that file only as declarations, never as something run"
# What may name it there is the binary's own declaration and the table entries
# about it. What may not is a call: the gate builds its vector from the declared
# name, so a literal appearing in executable position would be a second path to
# the same binary — and the one that skipped the caller check.
gate_lines=$(printf '%s\n' "$(zro_scan_file "$ZRO_SRC/lib/exec.sh")" | grep 'zmmailbox')
assert_contains "$gate_lines" "zmmailbox"
undeclared=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case $line in
    ZRO_GATED_BIN=zmmailbox) ;;
    zmmailbox:*) ;;
    *) undeclared="$undeclared [$line]" ;;
  esac
done <<EOF
$gate_lines
EOF
assert_eq "$undeclared" ""

it "and no call site anywhere hands it to the exec gate by name"
assert_eq "$(printf '%s\n' "$code" | grep -cE 'zro_exec[[:space:]]+zmmailbox')" "0"

it "it reaches the exec gate through one call site, in the file that owns the gate"
# The call site is dynamic — the binary arrives as the declared name — so the
# generic extraction above cannot decide it, exactly as it cannot decide the
# tracer's filters. What is decided here instead is that there is ONE of them, and
# that it is in the module the exec gate names as the only permitted caller. A
# second call site would be a second path to a binary that provisions, and it would
# be invisible to every other case in this file.
# SC2016: the dollar sign is the point. This pattern is looking for the literal
# text of a call site, not expanding the variable that call site names.
# shellcheck disable=SC2016
GATE_SITE='zro_exec[[:space:]]+"\$ZRO_GATED_BIN"'
gate_sites=$(printf '%s\n' "$raw_code" | grep -cE "$GATE_SITE")
assert_eq "$gate_sites" "1"
assert_eq "$(zro_strip_comments "$ZRO_SRC/lib/mailbox.sh" | grep -cE "$GATE_SITE")" "1"

it "and the caller the exec gate permits is a function that really exists"
# The permitted caller is compared by name at run time, so a rename that missed one
# of the two would not fail anything — it would quietly refuse every mailbox
# operation, or quietly permit whatever function now carries the old name.
assert_contains "$(zro_scan_file "$ZRO_SRC/lib/exec.sh")" "ZRO_GATE_OWNER=zro_mbox_run"
assert_contains "$(zro_scan_file "$ZRO_SRC/lib/mailbox.sh")" "zro_mbox_run()"

it "the existence oracle is declared with no LDAP form"
# `zmprov -l gis` fails with "can only be used with SOAP" — index statistics are
# not in the directory. TWO INDEPENDENT REFUSALS, because they answer different
# questions: absence from the LDAP-capable set is what stops the degraded read
# path ASKING, and absence from the allowlist is what would refuse it if something
# did. An entry for it would approve a call that can only ever fail, and would turn
# the outage the gate cannot see through into a second failure on top of it.
assert_not_contains "$allow" "zmprov:-l:gis"
ldap_reads=$(printf '%s\n' "$raw_code" | sed -n "s/^ZRO_LDAP_READS='\(.*\)'/\1/p")
assert_contains "$ldap_reads" " ga "
assert_not_contains "$ldap_reads" " gis "

it "and the gate consults no attribute in place of it"
# `zimbraLastLogonTimestamp` was the cheap first layer of an earlier oracle and is
# refuted: an authentication that registers no session stamps it and creates no
# mailbox, so it is set on precisely the accounts that have none. It stays on the
# account card as an operational fact; what it may never be is evidence, and the
# gate not naming it at all is how that is kept true rather than remembered.
assert_not_contains "$(zro_scan_file "$ZRO_SRC/lib/mailbox.sh")" "LastLogon"

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
# ASKED OF ALL THREE READERS RATHER THAN OF THE VIEWER'S TWO. The bounded head of a
# message blob arrived with the message detail screen and is the third; an approved
# operation with no call site is one that reads as available and can never answer,
# and a second spelling of one that has a call site is an approval a reader of the
# list would have to count rather than read.
system_calls=$(printf '%s\n' "$raw_code" \
               | grep -oE 'zro_exec[[:space:]]+(tail|head|gzip)[[:space:]]+[^[:space:]]+' \
               | sort -u)
assert_eq "$(printf '%s\n' "$system_calls" | grep -c 'zro_exec')" \
          "$(printf '%s\n' "$allow" | grep -c '^\(tail\|head\|gzip\):')"

# The log search hands the gate a mode flag, a match form, and then a cap and a
# pattern this program computed. The generic extraction above resolves the
# operation, but the equality below is what holds the two match forms to being the
# only two — the same rule the tracer's filters live by.
it "every log search call site names an operation the allowlist approves"
search_calls=$(printf '%s\n' "$raw_code" \
               | grep -oE 'zro_exec[[:space:]]+grep[[:space:]]+-a[[:space:]]+-[A-Za-z]' \
               | sort -u)
assert_contains "$search_calls" "zro_exec grep -a -F"
assert_contains "$search_calls" "zro_exec grep -a -E"
unapproved=""
while IFS= read -r call; do
  [ -n "$call" ] || continue
  form=$(printf '%s' "$call" | awk '{print $4}')
  printf '%s\n' "$allow" | grep -qxF -- "grep:-a:$form" || unapproved="$unapproved [$form]"
done <<EOF
$search_calls
EOF
assert_eq "$unapproved" ""

it "and the search reaches the gate in those forms and no other"
# THREE call sites in the whole tree, all in the function that owns them: the
# literal form, the pattern form, and the pattern form with case folded for the one
# question whose value is a domain. A fourth would be a form nobody approved, or
# the same form written twice — and the second is how a maintainer reading the list
# stops being able to tell what may be run.
assert_eq "$(printf '%s\n' "$raw_code" | grep -cE 'zro_exec[[:space:]]+grep')" "3"
assert_eq "$(zro_strip_comments "$ZRO_SRC/lib/logsearch.sh" \
             | grep -cE 'zro_exec[[:space:]]+grep')" "3"

it "and the case fold is written on the pattern form alone"
# Approving it for the literal form would let a message-id search report a
# different message as this one. The gate refuses it there; this says it is not
# written down either.
assert_not_contains "$code" "zro_exec grep -a -F -i"
assert_eq "$(printf '%s\n' "$raw_code" | grep -cE 'zro_exec[[:space:]]+grep[[:space:]]+-a[[:space:]]+-E[[:space:]]+-i')" "1"

it "and no form of it that walks a directory is written anywhere"
# `-r`, `-R` and `--include` would read files the log inventory never admitted, and
# `-f` takes its patterns from a file, which is operator text becoming a pattern by
# another route. The gate refuses all of them; this says they are not written down
# either.
for form in -r -R --recursive --include --exclude --exclude-dir; do
  assert_not_contains "$code" "zro_exec grep -a -F $form"
  assert_not_contains "$code" "zro_exec grep -a -E $form"
  assert_not_contains "$code" "grep $form"
done
for bin in egrep fgrep zgrep zegrep rgrep; do
  assert_not_contains "$code" "zro_exec $bin"
done

it "the log searcher writes no path of its own"
# Every path it reads comes from the log inventory, and every binary it runs is
# resolved under a root declared in lib/exec.sh — the same rule the viewer lives
# by, and for the same reason.
logsearch=$(zro_scan_file "$ZRO_SRC/lib/logsearch.sh")
for prefix in /usr /bin /sbin /var /opt /etc; do
  assert_not_contains "$logsearch" "$prefix"
done

it "the log searcher reaches no Zimbra binary and no mailbox"
assert_not_contains "$logsearch" "zmmailbox"
assert_not_contains "$logsearch" "zmprov"
assert_not_contains "$logsearch" "zmmsgtrace"

it "every scan this tool can express runs at reduced priority"
# The promise is kept by the gate, so what has to be true here is that the gate is
# the only place it is decided: a module reaching for the priority wrappers itself
# would be a scan that could be written without them.
#
# READ WITH COMMENTS STRIPPED AND QUOTES LEFT ON, unlike almost everything else in
# this file, and looking for the EXPANSION rather than the name. A variable is
# nearly always read inside double quotes, so the quote-stripping reader would find
# no mention of these two anywhere and pass without checking anything — while the
# bare name legitimately appears in an operator-facing message, which tells
# somebody where to point them and reads nothing at all. The '$' is what tells a
# read from a mention.
#
# Two files may read them: the gate, which builds the wrapper, and the capability
# module, which asks whether this host has them before an operator spends a search
# finding out.
#
# SC2016: the dollar sign is the point. These are the literal text of a read, not
# variables to expand — the same reason the gate call site above is written this
# way.
# shellcheck disable=SC2016
for f in "${SOURCES[@]}"; do
  case $f in
    */lib/exec.sh|*/lib/capability.sh) continue ;;
  esac
  body=$(zro_strip_comments "$f")
  assert_not_contains "$body" '$ZRO_NICE_BIN'
  assert_not_contains "$body" '$ZRO_IONICE_BIN'
done

it "and the two files that may read them are the gate and the probe"
# The exemption above is only worth anything if it is checked: without this, a
# third file could be added to that case list and nothing would notice.
# shellcheck disable=SC2016
assert_contains "$(zro_strip_comments "$ZRO_SRC/lib/exec.sh")" '$ZRO_NICE_BIN'
# shellcheck disable=SC2016
assert_contains "$(zro_strip_comments "$ZRO_SRC/lib/capability.sh")" '$ZRO_NICE_BIN'

it "and the binaries declared to run that way are the ones that scan a whole file"
gate=$(zro_scan_file "$ZRO_SRC/lib/exec.sh")
assert_contains "$gate" "ZRO_LOW_PRIORITY"
assert_eq "$(zro_low_priority_bins)" "$(printf '%s\n%s' 'grep' 'gzip')"

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
#
# `zro_allowed` is dropped on the same terms and is the clearest case of it: it is
# the question "would this be approved", asked so that the degraded read path can
# decline to make a call rather than have one refused. A line that ASKS about a
# binary is the opposite of a line that runs one.
for f in "${SOURCES[@]}"; do
  body=$(zro_scan_file "$f" | grep -v 'zro_exec' | grep -v 'ZRO_ALLOW' \
         | grep -v 'zro_cap_op_available' | grep -v 'zro_allowed')
  assert_not_contains "$body" 'zmprov '
  assert_not_contains "$body" 'zmmailbox '
  assert_not_contains "$body" 'zmmetadump '
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
