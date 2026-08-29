# shellcheck shell=bash
# The one reader a BUILT LIST's position goes through. Runs nothing, opens no
# file, names no Zimbra concept, and never sees the array whose position it
# judges.
[ -n "${ZRO_LIB_LIST_LOADED:-}" ] && return 0
ZRO_LIB_LIST_LOADED=1

# A DECLARED LIST is a menu whose entries are the keys of a declaration, so what
# comes back is a KEY and the module that declares it refuses one nobody
# declared. A BUILT LIST is a menu this program assembled at run time out of the
# server's or the file system's answer — a mailbox's folders, a search's
# conversations, a log's files. There is no declaration to judge the answer
# against, so what comes back is a POSITION, and this is where a position is
# judged. Three screens draw one; nothing else in this tree indexes an array with
# an operator's answer.
#
# WHY IT IS HERE RATHER THAN AT THE THREE CALL SITES. It was at all three, eight
# lines each, byte for byte the same, all three documented and the first two
# naming the others by name — and the third copy was written anyway. What settles
# it is not the duplication: it is that the rule those three copies stated was
# WRONG, identically, in all three. Two values passed it and neither could be
# evaluated by the line it was protecting:
#
#   08 ON A LIST OF EIGHT OR MORE. [!0-9] does not match it. `[` reads it as
#      decimal 8 and agrees it is in range. Then ${paths[08 - 1]} is evaluated
#      with bash's base detection, where a leading zero means octal and 8 is not
#      an octal digit: "value too great for base". The screen is abandoned
#      mid-answer, which an operator sees as the list vanishing under them.
#      Zimbra's default folder set is twelve entries, so every real mailbox is
#      long enough.
#
#   AN INTEGER WIDER THAN 64 BITS. `[` cannot parse it, reports an error, and
#      returns FALSE for both comparisons — so the guard does not refuse, it
#      falls through, and `set -u` then finds the subscript below it unset and
#      takes the whole shell down.
#
# Neither is reachable through whiptail, because this program writes the menu
# tags itself. That is the point rather than the defence: this guard exists
# precisely because what comes back from a screen is not trusted, and a guard
# correct only while the menu keeps writing its own tags is correct by the
# assumption it was written in order not to make.
#
# WHAT IS ADMITTED IS NINE CHARACTERS: [1-9] and at most eight more digits. The
# last arm is ten question marks, so a tenth is refused. What survives is a
# decimal integer this shell can evaluate, and that is the whole of what makes
# the range check below it total — and what lets that check be one-sided, because
# the arm carrying the octal hazard carries zero out with it.
#
# THE ARRAY DOES NOT TRAVEL. The caller writes `path=${paths[i]}` itself. A
# reader that took the array by name would save that one line and cost the
# property lib/table.sh bought: ${!ref} resolves name[i] and name[@], but
# #name[@] is a fatal expansion error, so the count cannot be reached that way at
# the 4.2 floor — and zro_table_name_ok admits only ZRO_[A-Z0-9_]*, which
# `paths` and `ids` are not. Admitting lowercase locals means a second, looser
# name predicate, and then reading one file is no longer enough to know every
# indirect expansion in this tree is safe. See
# docs/adr/0015-a-built-list-is-judged-by-position.md.
#
# WHAT STAYS AT THE CALL SITE. Each screen keeps its own statement of what it
# guarantees — that no value from the screen becomes an argument, that no id
# comes from the screen, that the viewer stays bounded to the inventory. Those
# are three different promises to three different operators, and they are how
# this rule reaches whoever reads one screen. Only the mechanism moved here.
#
# AND THE EMPTY LIST DOES NOT MOVE HERE AT ALL. A folder listing that names no
# folder is a defect and is logged as one; a log with no files is ordinary and
# gets its own screen; a conversation list with no rows returns silently. Three
# right answers, and folding them in would make one wrong one.

# WHETHER A VALUE MAY REACH ARITHMETIC AT ALL: the admission the header sets out,
# asked of BOTH values this reader is handed and therefore written once. Nine
# characters, [1-9] and at most eight more digits; the last arm is ten question
# marks, so a tenth is refused. It also refuses zero, which is what lets the range
# check below carry no lower bound.
#
# The reader above it exists because one rule was written three times. Writing
# this one twice, ten lines apart, would be the same fault in the same file.
zro_list_evaluable() {
  case ${1-} in
    ''|*[!0-9]*|0*|??????????*) return 1 ;;
  esac
  return 0
}

# The 0-based index of an operator's answer in a list of $2 entries, or a refusal.
#
#   $1  what the screen handed back
#   $2  how many entries the list has, as ${#arr[@]} at the call site
#   $3  the noun that names this list in the log — "folder list" and its two
#       siblings
#
# THE MINUS ONE IS PART OF THE RULE and travels with it: a menu counts from one
# because that is what an operator counts from, and the array under it starts at
# zero.
#
# ALL THREE REFUSALS ARE LOGGED HERE rather than by the caller, for the reason
# zro_table_root logs its own three: the caller is not the only one, and a log
# line that cannot say WHICH list refused sends a maintainer looking. Two of the
# three messages are the ones the three screens wrote, unchanged to the byte; the
# third reports a defect that had nowhere to be said before this reader existed.
zro_list_position() {
  local answer=${1-} count=${2-} noun=${3-}

  # A COUNT IS NOT OPERATOR INPUT. It is ${#arr[@]} at every call site, so a
  # value that is not a count means a caller reached this reader with a list
  # nobody can pick from — an empty one included, which each screen answers in
  # its own way before it gets here. That is a defect in this program and is said
  # as one, because a maintainer reading "denied" would read it as something the
  # operator typed and leave it alone. It is judged FIRST because it is this
  # reader's own precondition: the comparison below cannot be trusted until the
  # value on its right is one this shell can evaluate.
  if ! zro_list_evaluable "$count"; then
    zro_log error "list defect, not a count of the $noun: $count"
    return "$ZRO_E_INPUT"
  fi

  if ! zro_list_evaluable "$answer"; then
    zro_log error "denied, not a position in the $noun: $answer"
    return "$ZRO_E_INPUT"
  fi

  # ONE-SIDED, because zro_list_evaluable already refused everything below one. A
  # second comparison here would be a lower bound that never fires, and a dead
  # arm in the one place this rule is written is an arm the next reader cannot
  # tell from a live one.
  if [ "$answer" -gt "$count" ]; then
    zro_log error "denied, position outside the $noun: $answer"
    return "$ZRO_E_INPUT"
  fi

  printf '%s' "$((answer - 1))"
}
