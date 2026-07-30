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
