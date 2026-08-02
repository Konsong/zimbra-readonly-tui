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
# `zmprov:ga:-e` IS AN ENTRY IN THE DATA POSITION, and the only one. What follows
# an approved subcommand is the caller's already-validated data — but a flag
# written there is not data at all: it changes what the command does. `zmprov`
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
# It is NOT approved behind `-l`, and that has a consequence worth stating rather
# than discovering: zro_prov_read retries every read against LDAP when mailboxd
# is unreachable, so a provenance screen written on top of it would be refused
# during exactly the outage the retry exists for — and refused as a defect, which
# is what an allowlist denial means. The screen's ticket decides that
# deliberately, and pays for a second entry here if the answer is yes.
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
zmcontrol:-v
zmmsgtrace:--recipient
zmmsgtrace:--sender
zmmsgtrace:--id
tail:-n
gzip:-dc
'

zro_allow_entries() {
  printf '%s' "$ZRO_ALLOW" | grep -v '^[[:space:]]*$'
}

# Whether the list carries this entry, matched as one whole line. -x anchors to
# the whole line and -F takes the needle literally, so a token containing a regex
# metacharacter cannot widen the match.
zro_allow_has() {
  printf '%s' "$ZRO_ALLOW" | grep -qxF -- "${1-}"
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
ZRO_RUNUSER="${ZRO_RUNUSER:-$(zro_first_existing /sbin/runuser /usr/sbin/runuser /bin/runuser)}"
ZRO_TIMEOUT_BIN="${ZRO_TIMEOUT_BIN:-$(zro_first_existing /usr/bin/timeout /bin/timeout)}"
ZRO_ID_BIN="${ZRO_ID_BIN:-$(zro_first_existing /usr/bin/id /bin/id)}"
ZRO_TIMEOUT="${ZRO_TIMEOUT:-60}"

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
ZRO_BIN_ROOTS='
zmprov:ZRO_ZIMBRA_BIN
zmcontrol:ZRO_ZIMBRA_BIN
zmmsgtrace:ZRO_ZIMBRA_LIBEXEC
tail:ZRO_SYSTEM_BIN
gzip:ZRO_SYSTEM_BIN
'

zro_bin_root_entries() {
  printf '%s' "$ZRO_BIN_ROOTS" | grep -v '^[[:space:]]*$'
}

# Prints the absolute path of a binary under its declared root, and fails when
# the binary declares no root or the root it names is empty. Failure is never a
# fallback: there is no default root to resolve against.
#
# Both failures are logged here rather than by the caller, because the gate is
# not the only caller: zro_bin_available answers the capability probe, and an
# undeclared root would otherwise reach the operator as a greyed-out menu entry
# reading like a program this host does not have. Neither condition is something
# an operator did, so both are logged the way any other defect is.
zro_bin_path() {
  local bin=${1-} entry var=''
  [ -n "$bin" ] || return 1

  while IFS= read -r entry; do
    # Quoted, so the comparison is literal text exactly as in the allowlist: a
    # name carrying a glob character cannot borrow another binary's root.
    case $entry in
      "$bin":?*) var=${entry#*:}; break ;;
    esac
  done <<EOF
$(zro_bin_root_entries)
EOF
  if [ -z "$var" ]; then
    zro_log error "denied, no root declared for binary: $bin"
    return 1
  fi

  # Indirect expansion, not a nameref: namerefs are bash 4.3 and the floor is
  # 4.2. The name comes from the table above, never from anything an operator
  # typed, and the guard above is what keeps an empty name out of it.
  local root=${!var-}
  if [ -z "$root" ]; then
    zro_log error "denied, root variable is empty: $var"
    return 1
  fi
  printf '%s/%s' "$root" "$bin"
}

zro_bin_available() {
  local path
  path=$(zro_bin_path "${1-}") || return 1
  [ -x "$path" ]
}

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

  local -a argv
  argv=("$ZRO_TIMEOUT_BIN" -k 5 "$ZRO_TIMEOUT" "$path" "$token" "$@")

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
