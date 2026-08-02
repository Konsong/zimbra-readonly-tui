# shellcheck shell=bash
# The selected address: the one address a session is about.
#
# An operator answering "what is going on with this user" asks a dozen questions
# about a single address. Asking for it once and carrying it is not really about
# the typing — at a JVM start per invocation, re-running is the cost that matters
# — it is about reading one account's answer believing it is another's. So the
# address is chosen once, every account-scoped screen reads it instead of asking
# again, and lib/ui.sh puts it on the frame of every screen until it changes.
[ -n "${ZRO_LIB_SELECTION_LOADED:-}" ] && return 0
ZRO_LIB_SELECTION_LOADED=1

# THE variable, and a plain one — unlike the last error and the read mode in
# lib/core.sh, which live in files because module code writes them from inside
# command substitution, where an assignment dies with the subshell. This one is
# written only by menu code running in the main shell.
#
# lib/ui.sh reads it. That is the one thing that module knows about the rest of
# this program, and it is deliberate: a title that carries the address only when
# a screen remembers to ask for it is a title that will one day not carry it.
ZRO_SELECTED="${ZRO_SELECTED:-}"

zro_sel_address() {
  printf '%s' "$ZRO_SELECTED"
}

zro_sel_have() {
  [ -n "$ZRO_SELECTED" ]
}

# Refuses anything that is not an address, and says so out loud. The prompt has
# already judged what it collected, so a refusal here is a defect in a caller
# rather than something an operator typed — and the reason to check twice is the
# blast radius: a value that reached this far unjudged would be carried into
# every command of the session rather than into one.
zro_sel_set() {
  local value=${1-}
  if ! zro_validate_email "$value"; then
    zro_log error "not an address, selection refused: $value"
    return "$ZRO_E_INPUT"
  fi
  ZRO_SELECTED=$value
}

zro_sel_clear() {
  ZRO_SELECTED=""
}
