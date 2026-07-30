# shellcheck shell=bash
# Input validators, and the quoting that has to follow them. Pure functions: the
# validators answer with a return status and never print; the quoter prints the
# text it was given, escaped, and is the one function here that has output.
[ -n "${ZRO_LIB_VALIDATE_LOADED:-}" ] && return 0
ZRO_LIB_VALIDATE_LOADED=1

# A DNS label: alphanumeric ends, hyphens allowed only in the middle.
ZRO_RE_LABEL='[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?'
# Local part: the conservative subset Zimbra accounts actually use.
ZRO_RE_LOCAL='[A-Za-z0-9._%+-]+'

# Metacharacters, in the order they are cheapest to read: the escape character
# first, then the anchors, then everything that quantifies or groups. The set
# covers Perl and POSIX alike, plus '/', which is not a metacharacter but is the
# usual match delimiter and costs nothing to escape.
ZRO_RE_META='\^$.|?*+()[]{}/'

# Escapes text so a regular-expression engine reads it as the literal it is.
#
# This is a THIRD escaping layer, alongside shell safety — which the exec gate
# provides by passing argv arrays and never building a string — and the
# query-language quoting a later milestone owes. It exists because every filter
# the delivery tracer accepts is a Perl regular expression, while the address
# validator admits '.' and '+': 'ali+fatura@example.com' passes validation and
# then, used unescaped as a pattern, fails to match itself. That is a silent
# false negative on the one question a delivery trace exists to answer.
#
# The escaping is done here rather than by wrapping the value in the target
# language's own quoting construct. That would be one line, but it depends on how
# the tracer interpolates the option — a source line nobody in this project has
# read. An unverified assumption is not a green light.
zro_regex_quote() {
  local s=${1-} out='' i c
  for (( i = 0; i < ${#s}; i++ )); do
    c=${s:i:1}
    # Substring test by parameter expansion: if removing everything up to and
    # including this character changes the set, the set contained it. A case
    # pattern cannot be built from a variable, and a bracket expression holding
    # both ']' and '\' is the kind of thing that is wrong for years.
    if [ "${ZRO_RE_META#*"$c"}" != "$ZRO_RE_META" ]; then
      out="$out\\$c"
    else
      out="$out$c"
    fi
  done
  printf '%s' "$out"
}

# A local wall-clock date and time, as 'YYYY-MM-DD HH:MM' or with seconds. The
# only operator text in this program that is not an address, and the only input
# the explicit arrival range accepts — a preset computes its bounds from numbers
# the program already had, so it never comes through here.
#
# THE TIME PART IS REQUIRED, and that is a decision rather than an oversight.
# Admitting a bare date would give an operator who typed the same day into both
# ends a window of zero width: a search that reads every log it was asked to and
# finds nothing, which is exactly the answer this feature exists to stop being
# ambiguous. Guessing midnight for one end and the end of the day for the other
# is a rule nobody would remember. Refusing is visible, and the whole-day case is
# what the presets are for.
#
# Shape and ranges only. Whether the day exists — 2026-02-30 is shaped like a
# date and is not one — is left to the calendar the clock already carries, in
# zro_win_epoch. A table of month lengths and leap rules here would be one more
# thing to be wrong about, and it would disagree with the program that ultimately
# reads the value.
ZRO_RE_DATETIME='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}(:[0-9]{2})?$'

zro_validate_datetime() {
  local t=${1-}
  [ -n "$t" ] || return "$ZRO_E_INPUT"
  [ "${#t}" -le 19 ] || return "$ZRO_E_INPUT"

  # Held in a variable because bash only reads the right-hand side of =~ as a
  # regular expression when it is unquoted.
  local re=$ZRO_RE_DATETIME
  [[ $t =~ $re ]] || return "$ZRO_E_INPUT"

  # Fields by position, which the pattern above has already fixed. '10#' is not
  # decoration: '08' is a valid hour and an invalid octal number, and without it
  # this function would refuse eight o'clock with an arithmetic error.
  local y=${t:0:4} mo=${t:5:2} d=${t:8:2} h=${t:11:2} mi=${t:14:2} s=${t:17:2}
  [ "$((10#$y))" -ge 1970 ] || return "$ZRO_E_INPUT"
  [ "$((10#$mo))" -ge 1 ] && [ "$((10#$mo))" -le 12 ] || return "$ZRO_E_INPUT"
  [ "$((10#$d))" -ge 1 ] && [ "$((10#$d))" -le 31 ] || return "$ZRO_E_INPUT"
  [ "$((10#$h))" -le 23 ] || return "$ZRO_E_INPUT"
  [ "$((10#$mi))" -le 59 ] || return "$ZRO_E_INPUT"
  [ -z "$s" ] || [ "$((10#$s))" -le 59 ] || return "$ZRO_E_INPUT"
  return 0
}

zro_validate_domain() {
  local d=${1-}
  [ -n "$d" ] || return "$ZRO_E_INPUT"
  [ "${#d}" -le 253 ] || return "$ZRO_E_INPUT"

  # At least two labels and an alphabetic TLD of two or more characters.
  # The pattern is held in a variable because bash only treats the right-hand
  # side of =~ as a regex when it is unquoted, and building it inline makes the
  # quoting rules easy to get wrong.
  local re="^${ZRO_RE_LABEL}(\.${ZRO_RE_LABEL})*\.[A-Za-z]{2,}$"
  [[ $d =~ $re ]] || return "$ZRO_E_INPUT"

  # No individual label may exceed 63 characters. Walked with parameter
  # expansion rather than IFS splitting, which would be sensitive to globbing.
  local rest=$d label
  while [ -n "$rest" ]; do
    label=${rest%%.*}
    [ "${#label}" -le 63 ] || return "$ZRO_E_INPUT"
    [ "$label" = "$rest" ] && break
    rest=${rest#*.}
  done
  return 0
}

zro_validate_email() {
  local e=${1-}
  [ -n "$e" ] || return "$ZRO_E_INPUT"
  [ "${#e}" -le 320 ] || return "$ZRO_E_INPUT"

  # A value starting with '-' would be read as a flag by any CLI it reaches.
  case $e in -*) return "$ZRO_E_INPUT" ;; esac

  # Split on the last '@'. Reassembling and comparing rejects anything with a
  # different number of separators than exactly one.
  local local_part=${e%@*}
  local domain_part=${e##*@}
  [ "$local_part@$domain_part" = "$e" ] || return "$ZRO_E_INPUT"

  [ -n "$local_part" ] || return "$ZRO_E_INPUT"
  [ "${#local_part}" -le 64 ] || return "$ZRO_E_INPUT"
  local re="^${ZRO_RE_LOCAL}$"
  [[ $local_part =~ $re ]] || return "$ZRO_E_INPUT"

  zro_validate_domain "$domain_part" || return "$ZRO_E_INPUT"
  return 0
}
