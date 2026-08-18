# shellcheck shell=bash
# What a gated read finishes with, in one place instead of three.
[ -n "${ZRO_LIB_SETTLE_LOADED:-}" ] && return 0
ZRO_LIB_SETTLE_LOADED=1

# THE CEREMONY, WRITTEN ONCE. Every read that goes through the exec gate ends the
# same four steps: keep a
# bounded prefix of what the command said where the error screen can find it,
# decide whether the status it holds is the gate's own or the command's, turn a
# command's own failure into a code this program documents, and remove the scratch
# file its error stream was captured to. Three modules carried that as three
# byte-identical copies differing in one name, which is how a rule corrected in one
# of them stayed wrong in the other two.
#
# WHAT A MODULE STILL OWNS is the part that is genuinely its own: the reader that
# turns THIS command's failure text into a code. It travels here BY NAME, and the
# order below is why — the reader reads the scratch file and this routine is what
# removes it, so the removal has to belong to one place rather than to each caller.
#
# BESIDE THE GATE, NOT INSIDE IT. The gate is the safety core, and the reason for
# keeping them apart is the one ADR-0009 gives about the allowlist: a routine shared
# by several screens is a routine that will one day be changed for a reason that has
# nothing to do with the gate. The predicate saying which codes are the gate's own
# stays with the gate for the same reason read the other way — it changes exactly
# when the gate's return set changes. ADR-0010 records that decision.
#
# Sourced after lib/exec.sh, and depends on it and on lib/core.sh.

# WHAT A FAILURE READER'S NAME LOOKS LIKE.
#
# The name is checked against this before anything is called with it, which is the
# rule ADR-0009 states for a declared table travelling as a name: one argument does
# double duty — it is the thing that runs, and it is the noun in the log line — so
# reading this file has to be enough to know what may run. Nothing here is a defence
# against an operator: no operator text reaches this argument, and could not, because
# a module names its own reader in its own source. It is a defence against an edit.
ZRO_RE_FAIL_READER='^zro_[a-z0-9_]+_fail_code$'

# WHETHER A NAME MAY BE CALLED AS A FAILURE READER, in two questions that are asked
# separately because their answers say different things to whoever reads the log: a
# name of the wrong shape is a caller passing the wrong kind of thing, and a name
# nothing answers to is a reader that was renamed or never sourced.
#
# BOTH ARE LOGGED AS DEFECTS IN THIS TOOL, in the words the tree uses for its own —
# nothing an operator did can produce either, and a maintainer reading the log needs
# the name that was refused rather than the fact that something was.
zro_settle_reader_ok() {
  local name=${1-}
  # Held in a variable because bash only reads the right-hand side of =~ as a
  # regular expression when it is unquoted.
  local re=$ZRO_RE_FAIL_READER
  if ! [[ $name =~ $re ]]; then
    zro_log error "settle defect, not the name of a failure reader: $name"
    return 1
  fi
  if ! declare -F "$name" >/dev/null 2>&1; then
    zro_log error "settle defect, no function answers to the failure reader named: $name"
    return 1
  fi
  return 0
}

# WHAT A FINISHED GATED READ COSTS THE CALLER: the code to return, printed, with the
# underlying message kept where the error screen can find it.
#
#   $1  the scratch file the command's error stream was captured to
#   $2  the status the gate returned
#   $3  the name of the module's failure reader
#
# THE MESSAGE IS ONLY REPLACED WHEN THERE IS ONE. A read the gate refused never ran,
# so the file is empty — and the sentence already in the store is the oracle's, which
# is the one an operator needs. Overwriting it with nothing would leave the screen
# reporting a bare code for the one refusal that has a real explanation.
#
# A CODE THE GATE PRODUCED TRAVELS AS ITSELF, and is never handed to the failure
# reader. Asked of lib/exec.sh rather than answered here: the gate knows which codes
# are its own, and six modules that each decided separately arrived at three
# different answers. What that cost is on the record — an allowlist denial on the
# metadata dump reached the operator as a stopped mailboxd, naming a service that
# command never talks to.
#
# So a failure reader only ever sees a command that RAN, which is what lets a reader
# stop ending with the status it was handed.
zro_settle() {
  local errfile=${1-} rc=${2-0} reader=${3-} msg mapped
  if [ "$rc" -eq 0 ]; then
    rm -f -- "$errfile"
    zro_clear_error
    printf '0'
    return 0
  fi
  msg=$(head -c 500 -- "$errfile" 2>/dev/null)
  [ -n "$msg" ] && zro_set_error "$msg"

  if zro_exec_own_code "$rc"; then
    rm -f -- "$errfile"
    printf '%s' "$rc"
    return 0
  fi

  # A REFUSED NAME STILL HAS TO ANSWER WITH A CODE, because the caller's next line
  # compares what this printed against zero. It answers with the input code and not
  # with one of the gate's three: those name a refusal that did not happen — 90 is
  # the allowlist's word, and CONTEXT.md says in as many words that it may not be
  # borrowed. The input code is what lib/message.sh already answers with when the
  # dump prints its usage banner, which is the same kind of fact: this program built
  # something wrong, the log says what, and the screen for it ends by sending the
  # operator to the tool's log. The scratch file goes either way — the reader that
  # would have read it is the one thing that did not happen.
  if ! zro_settle_reader_ok "$reader"; then
    rm -f -- "$errfile"
    printf '%s' "$ZRO_E_INPUT"
    return 0
  fi

  # THE READER IS HANDED THE FILE AND NOT THE STATUS. There is nothing left for it to
  # do with a status: the gate's own codes were answered above, and what remains is
  # the binary's exit status, which this program does not document and may not pass
  # on. Everything a reader needs is in the text.
  mapped=$("$reader" "$errfile")
  rm -f -- "$errfile"
  printf '%s' "$mapped"
}
