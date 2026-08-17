# shellcheck shell=bash
# The declared tables this program reads, and the one reader that takes them
# apart. Runs nothing, opens no file, and names no Zimbra concept.
[ -n "${ZRO_LIB_TABLE_LOADED:-}" ] && return 0
ZRO_LIB_TABLE_LOADED=1

# A DECLARED TABLE is a newline-separated list of "<key>:<field>[:<field>...]"
# rows held in a ZRO_ variable. What it declares is the whole of what can be
# reached through it: a key absent from the table is REFUSED, never resolved
# against a default. Eleven are declared across this tree and read through the
# accessors below, and this file is the only thing that takes one apart.
#
# Two more lists are ENUMERATED through it and looked up by nothing here: the
# allowlist and the low-priority list in lib/exec.sh. Both answer a membership
# question rather than a lookup, and both keep that answer to themselves — see
# docs/adr/0009 for why the one read whose refusal means exit 90 does not share a
# reader with eleven screens. A third, ZRO_SEARCH_PROMPTS, is keyed but declares
# where one entry ends rather than how many fields it has, so it is not one of
# these either and lib/search.sh reads it alone.
#
# Five rules were re-derived at every reader this replaces, and each of them was
# a defect somewhere first:
#
#   THE TABLE IS FED IN ON A HEREDOC, NEVER DOWN A PIPE INTO A READER THAT CAN
#   EXIT EARLY. `printf | grep -q` under `set -o pipefail` returns 141 when the
#   reader wins the race, which in the exec gate is a spurious allowlist denial —
#   exit 90, which this program defines as a defect and always logs. Measured at
#   one in three thousand lookups before the allowlist was rewritten this way.
#
#   A KEY IS MATCHED AS QUOTED LITERAL TEXT. Unquoted, a key carrying a glob
#   character could borrow another row's fields.
#
#   A BLANK LINE IS NOT A ROW. Four tables are written between newlines so that
#   the first row does not sit on the assignment line; the rest are not. One rule
#   covers both, and in bash it costs no external process at all.
#
#   THE LAST FIELD TAKES THE REMAINDER. Labels are operator-facing Turkish and
#   really do carry colons — `address:Adres (ornek: ali@ornek.com)`. A reader
#   that cut at every colon would truncate one.
#
#   AN ABSENT FIELD IS A REFUSAL, NOT AN EMPTY VALUE. A row short of a field is a
#   defect in the declaration, and answering it with an empty string hands that
#   defect to a screen to render.
#
# THE TABLE TRAVELS AS A NAME, NOT AS A VALUE. lib/logsearch.sh carried the
# opposite rule while it held the only generic reader in this tree, on the
# grounds that nothing generic should have to know which declarations exist —
# and that was right for what it did. It stops being right at zro_table_root
# below, which logs its own refusals because a root that quietly resolves to
# nothing reaches the operator as a greyed-out menu entry or an empty answer. A
# log line that cannot name the declaration to edit is a log line that sends a
# maintainer looking, so one argument does double duty: it is the table, and it
# is the noun in the message.
#
# The name is checked against ZRO_[A-Z0-9_]* before it is expanded, and so is
# every root name a table declares. That is what makes reading THIS file enough
# to know the indirect expansions below are safe, without auditing sixteen call
# sites to prove that no operator text reaches one.
#
# IT COSTS EVERY TABLE AN SC2034 DIRECTIVE, and that is the honest price of the
# convention rather than an oversight: a declaration nothing expands directly
# reads to ShellCheck as a variable nobody uses. The directive is written above
# each table with the reason on it, so a maintainer adding the thirteenth is told
# what to write instead of discovering it from a red build.

# Whether a word may be handed to an indirect expansion. Indirect expansion, not
# a nameref: namerefs are bash 4.3 and the floor is 4.2.
zro_table_name_ok() {
  local name=${1-}
  case $name in
    ZRO_[A-Z0-9_]*) ;;
    *) return 1 ;;
  esac
  case $name in
    *[!A-Z0-9_]*) return 1 ;;
  esac
  return 0
}

# The rows of a declared table, blank lines dropped.
#
# A NAME THAT IS NOT SET AT ALL IS REFUSED, not answered with no rows. A table
# name is written in code and nowhere else, so a name that resolves to nothing is
# a typo — and answered with an empty list it becomes a menu with no entries or a
# gate that refuses every operation, neither of which reads as the mistake it is.
zro_table_entries() {
  local name=${1-} table line
  zro_table_name_ok "$name" || return "$ZRO_E_INPUT"
  [ -n "${!name+set}" ] || return "$ZRO_E_INPUT"
  table=${!name-}
  while IFS= read -r line; do
    # A line holding one non-blank character is a row; the complement of the
    # `grep -v` this replaces, in the shell, with no process to start.
    case $line in
      *[![:space:]]*) printf '%s\n' "$line" ;;
    esac
  done <<EOF
$table
EOF
}

# The declared keys, in the order they are declared.
zro_table_keys() {
  local entries entry
  entries=$(zro_table_entries "${1-}") || return "$ZRO_E_INPUT"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    printf '%s\n' "${entry%%:*}"
  done <<EOF
$entries
EOF
}

# The whole row a key declares, or a refusal. Every lookup below goes through
# this, so a key nobody declared has one answer everywhere.
zro_table_entry() {
  local name=${1-} key=${2-} entries entry
  [ -n "$key" ] || return "$ZRO_E_INPUT"
  entries=$(zro_table_entries "$name") || return "$ZRO_E_INPUT"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    # Quoted, so the comparison is literal text exactly as declared. A row
    # carrying no colon at all is not a match for anything: the suite refuses
    # one outright, and a reader that accepted it would answer a key with a
    # line that declares nothing.
    case $entry in
      "$key":*) printf '%s' "$entry"; return 0 ;;
    esac
  done <<EOF
$entries
EOF
  return "$ZRO_E_INPUT"
}

# Everything from the nth field after the key to the end of the row, verbatim —
# colons and all. This is the primitive: the last field of every table in this
# tree is a label that may carry anything, so taking the remainder is the
# ordinary case and cutting a single field is the special one.
zro_table_rest() {
  local name=${1-} key=${2-} n=${3-} entry i=0
  case $n in
    ''|*[!0-9]*) return "$ZRO_E_INPUT" ;;
  esac
  [ "$n" -ge 1 ] || return "$ZRO_E_INPUT"
  entry=$(zro_table_entry "$name" "$key") || return "$ZRO_E_INPUT"
  while [ "$i" -lt "$n" ]; do
    case $entry in
      *:*) entry=${entry#*:} ;;
      *) return "$ZRO_E_INPUT" ;;
    esac
    i=$((i + 1))
  done
  [ -n "$entry" ] || return "$ZRO_E_INPUT"
  printf '%s' "$entry"
}

# The nth field after the key, cut at the next colon. Empty is a refusal for the
# reason the header gives: a row short of a field is a defect, and an empty
# string is that defect handed to a screen to render.
zro_table_field() {
  local rest
  rest=$(zro_table_rest "${1-}" "${2-}" "${3-}") || return "$ZRO_E_INPUT"
  rest=${rest%%:*}
  [ -n "$rest" ] || return "$ZRO_E_INPUT"
  printf '%s' "$rest"
}

# A table whose first field is "<ROOT VARIABLE NAME>[/<path under it>]", resolved
# to an absolute base path. Two tables are declared this way — the binary roots
# in lib/exec.sh and the log inventory in lib/inventory.sh — and the value names
# a VARIABLE rather than a path, so every root stays overridable after the file
# declaring it has been sourced. The suite points them at its fixtures that way.
#
# Failure is never a fallback: there is no default root to resolve against.
#
# ALL THREE REFUSALS ARE LOGGED HERE rather than by the caller, because the
# caller is not the only one. The exec gate resolves a binary this way and so
# does the capability probe, and an undeclared root would otherwise reach the
# operator as a greyed-out menu entry reading like a program this host does not
# have. An inventory that quietly resolves to nothing reaches them as an empty
# answer, which is the one thing a log screen may not produce. None of the three
# is something an operator did, so all three are logged the way any other defect
# in this program is.
zro_table_root() {
  local name=${1-} key=${2-} spec var under='' root
  if ! spec=$(zro_table_rest "$name" "$key" 1); then
    zro_log error "denied, no root declared in $name: $key"
    return "$ZRO_E_INPUT"
  fi

  var=${spec%%/*}
  case $spec in
    */*) under="/${spec#*/}" ;;
  esac

  if ! zro_table_name_ok "$var"; then
    zro_log error "denied, root declared in $name is not a variable name: $spec"
    return "$ZRO_E_INPUT"
  fi

  root=${!var-}
  if [ -z "$root" ]; then
    zro_log error "denied, root variable is empty: $var"
    return "$ZRO_E_INPUT"
  fi
  printf '%s%s' "$root" "$under"
}
