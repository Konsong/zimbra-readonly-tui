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
ZRO_ALLOW='
zmprov:ga
zmprov:getAccount
zmprov:gam
zmprov:getAccountMembership
zmprov:gc
zmprov:getCos
zmprov:-l:ga
zmprov:-l:getAccount
zmprov:-l:gam
zmprov:-l:getAccountMembership
zmprov:-l:gc
zmprov:-l:getCos
zmcontrol:-v
'

zro_allow_entries() {
  printf '%s' "$ZRO_ALLOW" | grep -v '^[[:space:]]*$'
}

zro_allowed() {
  local bin=${1-} t1=${2-} t2=${3-}
  [ -n "$bin" ] || return 1
  [ -n "$t1" ] || return 1

  # -x anchors to the whole line and -F takes the needle literally, so a token
  # containing a regex metacharacter cannot widen the match.
  #
  # A token shaped like a flag is only ever approved together with the
  # subcommand behind it, because the subcommand is what decides whether the
  # command reads or writes. Everything else matches on two tokens, where any
  # further arguments are the caller's already-validated data.
  case $t1 in
    -*)
      if [ -n "$t2" ] && printf '%s' "$ZRO_ALLOW" | grep -qxF -- "$bin:$t1:$t2"; then
        return 0
      fi
      # Falls back to the two-token form for a flag that IS the whole
      # operation, such as `zmcontrol -v`. A mode-selecting flag like
      # `zmprov -l` is kept out of the list, and a test enforces that.
      printf '%s' "$ZRO_ALLOW" | grep -qxF -- "$bin:$t1"
      return $?
      ;;
  esac
  printf '%s' "$ZRO_ALLOW" | grep -qxF -- "$bin:$t1"
}

# Binary locations. Production defaults, overridable so the suite can point at
# mocks. Never write one of these paths as a literal in module code.
ZRO_ZIMBRA_BIN="${ZRO_ZIMBRA_BIN:-/opt/zimbra/bin}"
ZRO_RUNUSER="${ZRO_RUNUSER:-$(zro_first_existing /sbin/runuser /usr/sbin/runuser /bin/runuser)}"
ZRO_TIMEOUT_BIN="${ZRO_TIMEOUT_BIN:-$(zro_first_existing /usr/bin/timeout /bin/timeout)}"
ZRO_ID_BIN="${ZRO_ID_BIN:-$(zro_first_existing /usr/bin/id /bin/id)}"
ZRO_TIMEOUT="${ZRO_TIMEOUT:-60}"

zro_current_user() {
  [ -n "$ZRO_ID_BIN" ] || return "$ZRO_E_UNAVAILABLE"
  "$ZRO_ID_BIN" -un
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

zro_bin_available() {
  local bin=${1-}
  [ -n "$bin" ] || return 1
  [ -x "$ZRO_ZIMBRA_BIN/$bin" ]
}

# The only path from this program to an external command.
#
#   $1  binary name, resolved under $ZRO_ZIMBRA_BIN
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

  # The third token matters when the second one only selects a mode, so the
  # gate sees it too. For everything else it is the caller's validated data and
  # the two-token entry decides.
  if ! zro_allowed "$bin" "$token" "${1-}"; then
    zro_log error "denied by allowlist: $bin $token ${1-}"
    return "$ZRO_E_DENIED"
  fi

  if ! zro_bin_available "$bin"; then
    zro_log error "not available on this host: $ZRO_ZIMBRA_BIN/$bin"
    return "$ZRO_E_NOCAP"
  fi

  local mode
  mode=$(zro_identity_mode "$(zro_current_user)") || return "$ZRO_E_BADUSER"

  [ -n "$ZRO_TIMEOUT_BIN" ] || return "$ZRO_E_UNAVAILABLE"

  local -a argv
  argv=("$ZRO_TIMEOUT_BIN" -k 5 "$ZRO_TIMEOUT" "$ZRO_ZIMBRA_BIN/$bin" "$token" "$@")

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
