# shellcheck shell=bash
# Input validators. Pure functions: a return status, never output.
[ -n "${ZRO_LIB_VALIDATE_LOADED:-}" ] && return 0
ZRO_LIB_VALIDATE_LOADED=1

# A DNS label: alphanumeric ends, hyphens allowed only in the middle.
ZRO_RE_LABEL='[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?'
# Local part: the conservative subset Zimbra accounts actually use.
ZRO_RE_LOCAL='[A-Za-z0-9._%+-]+'

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
