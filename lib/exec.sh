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
ZRO_ALLOW='
zmprov:ga
zmprov:getAccount
zmprov:gmi
zmprov:getMailboxInfo
zmprov:gam
zmprov:getAccountMembership
zmprov:gc
zmprov:getCos
zmcontrol:-v
'

zro_allow_entries() {
  printf '%s' "$ZRO_ALLOW" | grep -v '^[[:space:]]*$'
}

zro_allowed() {
  local bin=${1-} token=${2-}
  [ -n "$bin" ] || return 1
  [ -n "$token" ] || return 1
  # -x anchors to the whole line and -F takes the needle literally, so a token
  # containing a regex metacharacter cannot widen the match.
  printf '%s' "$ZRO_ALLOW" | grep -qxF -- "$bin:$token"
}
