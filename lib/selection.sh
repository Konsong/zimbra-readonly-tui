# shellcheck shell=bash
# The selected address: the one address a session is about.
#
# An operator answering "what is going on with this account" asks a dozen
# questions about a single address. Asking for it once and carrying it is not
# really about the typing — at a JVM start per invocation, re-running is the cost
# that matters — it is about reading one account's answer believing it is
# another's. So the address is chosen once, every account-scoped screen reads it
# instead of asking again, and lib/ui.sh puts it on the frame of every screen
# until it changes.
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
#
# Emptied rather than taken from the environment, unlike most declarations here.
# The environment is where an override belongs when it names a path or a bound;
# this is a value every command of the session is about, and admitting one nobody
# judged would be the check below with a way around it.
ZRO_SELECTED=""

# WHAT THAT ADDRESS TURNED OUT TO BE, as the record lib/identity.sh builds and
# reads. Opaque here on purpose: this module's job is that the session remembers
# one answer about one address, and the shape of the answer belongs to the module
# that asks for it.
#
# Empty means the question has not been answered — either nothing is selected, or
# resolution could not run. It never means the address is nothing: an identity
# nobody could establish and an address that is nowhere are different facts, and
# the only one of them that may mark a menu entry is the second.
ZRO_SELECTED_IDENTITY=""

zro_sel_address() {
  printf '%s' "$ZRO_SELECTED"
}

zro_sel_have() {
  [ -n "$ZRO_SELECTED" ]
}

zro_sel_identity() {
  printf '%s' "$ZRO_SELECTED_IDENTITY"
}

zro_sel_have_identity() {
  [ -n "$ZRO_SELECTED_IDENTITY" ]
}

zro_sel_set_identity() {
  ZRO_SELECTED_IDENTITY=${1-}
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
  # A new address is an unanswered question. Cleared HERE rather than by the
  # caller, because an identity left over from the previous address is the exact
  # failure the selected address exists to prevent, one level further in: a menu
  # marked for one account while the session is about another.
  ZRO_SELECTED_IDENTITY=""
}

zro_sel_clear() {
  ZRO_SELECTED=""
  ZRO_SELECTED_IDENTITY=""
}
