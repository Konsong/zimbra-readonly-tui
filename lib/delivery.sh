# shellcheck shell=bash
# Delivery tracing: what the mail transfer agent's log says about a message.
#
# Nothing here opens a mailbox. The trace is assembled by the tracing tool from
# log lines alone, so the existence gate is not involved and this is safe on an
# account that has never logged in.
[ -n "${ZRO_LIB_DELIVERY_LOADED:-}" ] && return 0
ZRO_LIB_DELIVERY_LOADED=1

# How the tracing tool introduces each message it found, at the start of a line.
# Recipient blocks and hop lines below it are indented, so an anchored match
# counts messages and not their contents.
#
# THIS IS THE ONE DEPENDENCY on the report's internal shape in this milestone,
# and it is deliberately the only one: the tool exits successfully whether or not
# anything matched, so the report itself is the sole source for the answer.
# Everything else is rendered as it arrives.
#
# RE-VERIFY THIS AGAINST OUTPUT CAPTURED FROM A REAL SERVER. It comes from the
# tool's print statements as documented in
# docs/research/2026-07-29-zimbra-cli-read-only-reference.md §B.11, read out of
# the source; no capture exists in this repository yet. M1 shipped two production
# bugs from output that had been described rather than captured, and the suite
# agreed with both descriptions. A parsed table view of the report waits on the
# same capture.
ZRO_TRACE_MESSAGE_PREFIX='Message ID '

# How many messages a report introduces. Pure: text in, a number out.
zro_trace_message_count() {
  local n
  # grep exits 1 when it counts nothing, which is not a failure here.
  n=$(printf '%s\n' "${1-}" | grep -c "^$ZRO_TRACE_MESSAGE_PREFIX") || n=0
  printf '%s' "$n"
}

# Maps a failed trace to a documented exit code, or passes the tool's own status
# through when it recognises nothing. Same shape as zro_prov_fail_code in
# lib/account.sh, and for the same reason: an operator who is shown a bare status
# has to reproduce the command by hand to learn what went wrong.
#
# A log the tool cannot open is the one failure worth naming. It dies with
# "unable to open file" on stderr and no exit status of its own, so the message is
# the only signal there is. That text comes from the tool's source as documented
# in docs/research/2026-07-29-zimbra-cli-read-only-reference.md §B.11 rather than
# from a capture, which is why the match lives here alone and stays this narrow.
zro_trace_fail_code() {
  local errfile=$1 rc=$2
  if grep -q 'unable to open file' "$errfile" 2>/dev/null; then
    printf '%s' "$ZRO_E_NO_LOG"
    return 0
  fi
  printf '%s' "$rc"
}

# Traces delivery for one recipient address in the current primary log.
#
# The arrival window, the rotated files behind it and the other filters the tool
# accepts all belong to later tickets. Here the tool reads the single file it
# defaults to, which is why the header below says so: an operator must never read
# "nothing found" as "nothing arrived" when only today's log was searched.
zro_trace_recipient() {
  local addr=${1-}
  zro_validate_email "$addr" || return "$ZRO_E_INPUT"

  # Third escaping layer. The gate already keeps this out of a shell, and the
  # validator has already refused anything that is not an address — but every
  # filter this tool takes is a regular expression, so an address carrying a
  # quantifier would otherwise fail to match itself.
  #
  # Escaped but deliberately NOT anchored. Anchoring would need to be right about
  # what the tool matches the pattern against, and nobody here has read that; get
  # it wrong and every trace silently finds nothing, which is the one failure this
  # screen may not have. Unanchored, the cost runs the other way and is visible:
  # an address that is a substring of another can pull in a neighbour's message,
  # and the report shown below names every recipient it matched. Anchoring waits
  # on the same capture as the table view.
  local pattern
  pattern=$(zro_regex_quote "$addr")

  local err out rc=0
  err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"
  out=$(zro_exec zmmsgtrace --recipient "$pattern" 2>"$err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    # Whatever the tool said, so an unreadable log reaches the operator as its
    # own cause rather than as a bare exit code.
    zro_set_error "$(head -c 500 -- "$err" 2>/dev/null)"
    local mapped
    mapped=$(zro_trace_fail_code "$err" "$rc")
    rm -f -- "$err"
    return "$mapped"
  fi
  rm -f -- "$err"
  zro_clear_error

  local count
  count=$(zro_trace_message_count "$out")
  [ "$count" -gt 0 ] || return "$ZRO_E_NO_RESULT"

  printf 'Alici          : %s\n' "$addr"
  printf 'Bulunan ileti  : %s\n' "$count"
  printf 'Taranan log    : guncel birincil mail logu\n'
  printf '                 (rotasyona girmis eski loglar bu surumde taranmiyor)\n'
  printf '\n'
  # Unmodified, on purpose: what follows is what the server said. Reformatting it
  # would risk dropping something nobody has looked at yet.
  printf '%s\n' "$out"
}
