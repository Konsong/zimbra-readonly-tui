# shellcheck shell=bash
# Exit codes, logging, temporary files. Depends on nothing.
#
# SC2034 is disabled for the whole file: defining constants that other modules
# consume is precisely this module's job, so "appears unused" is expected here
# and nowhere else.
# shellcheck disable=SC2034

[ -n "${ZRO_LIB_CORE_LOADED:-}" ] && return 0
ZRO_LIB_CORE_LOADED=1

# Success
ZRO_E_OK=0
# Input and lookup
ZRO_E_INPUT=10
ZRO_E_NO_ACCOUNT=11
ZRO_E_NO_MAILBOX=12
ZRO_E_NO_FOLDER=13
ZRO_E_NO_RESULT=14
# Environment
ZRO_E_PERM=20
ZRO_E_UNAVAILABLE=21
ZRO_E_TIMEOUT=22
ZRO_E_NO_LOG=23
# Bulk
ZRO_E_PARTIAL=30
# Navigation. Never becomes a process exit status.
ZRO_E_CANCEL=40
# Safety. Any of these is a defect, not operator error.
ZRO_E_DENIED=90
ZRO_E_BADUSER=91
ZRO_E_NOCAP=92

# Activity logging is off unless the administrator sets ZRO_LOG_FILE.
ZRO_LOG_FILE="${ZRO_LOG_FILE:-}"

zro_log() {
  local level=$1
  shift
  local line
  line="$(date '+%Y-%m-%dT%H:%M:%S%z') [$level] $*"
  printf '%s\n' "$line" >&2
  if [ -n "$ZRO_LOG_FILE" ]; then
    printf '%s\n' "$line" >>"$ZRO_LOG_FILE" 2>/dev/null || true
  fi
}

# Prints the first argument that is an executable file. Used to resolve system
# binaries explicitly instead of trusting PATH.
zro_first_existing() {
  local p
  for p in "$@"; do
    if [ -x "$p" ]; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

# The last underlying failure message, kept in a file rather than a variable.
# Menu code runs operations inside command substitution, so a variable set in
# that subshell would never reach the caller — the operator would be left with
# a bare exit code instead of what the command actually said.
ZRO_ERROR_FILE="${ZRO_ERROR_FILE:-${TMPDIR:-/tmp}/zro-error.$$}"

zro_set_error() {
  ( umask 077; printf '%s\n' "$1" >"$ZRO_ERROR_FILE" ) 2>/dev/null || true
}

zro_clear_error() {
  ( umask 077; : >"$ZRO_ERROR_FILE" ) 2>/dev/null || true
}

zro_last_error() {
  [ -f "$ZRO_ERROR_FILE" ] || return 0
  cat -- "$ZRO_ERROR_FILE" 2>/dev/null
}

# Which path answered the last read: soap or ldap. Same file-backed reason as
# the error message above. It matters to the operator, because LDAP does not
# expand values a COS provides.
ZRO_MODE_FILE="${ZRO_MODE_FILE:-${TMPDIR:-/tmp}/zro-mode.$$}"

# Degrading is sticky for the duration of an operation. A screen that made
# three reads, one of which fell back to LDAP, is an LDAP answer as a whole —
# reporting the mode of whichever read happened to run last would hide that.
zro_set_mode() {
  [ "$(zro_mode)" = ldap ] && return 0
  ( umask 077; printf '%s' "$1" >"$ZRO_MODE_FILE" ) 2>/dev/null || true
}

zro_reset_mode() {
  ( umask 077; printf 'soap' >"$ZRO_MODE_FILE" ) 2>/dev/null || true
}

zro_mode() {
  [ -f "$ZRO_MODE_FILE" ] || { printf 'soap'; return 0; }
  cat -- "$ZRO_MODE_FILE" 2>/dev/null
}

ZRO_TMPFILES=()

zro_tmpfile() {
  local f
  f=$(umask 077; mktemp "${TMPDIR:-/tmp}/zro.XXXXXXXX") || return 1
  ZRO_TMPFILES+=("$f")
  printf '%s' "$f"
}

zro_cleanup() {
  local f
  # Bash before 4.4 treats "${arr[@]}" on an empty array as an unbound variable
  # under `set -u`; the ${arr[@]+...} guard keeps this safe on the 4.2 floor.
  for f in ${ZRO_TMPFILES[@]+"${ZRO_TMPFILES[@]}"}; do
    [ -e "$f" ] && rm -f -- "$f"
  done
  ZRO_TMPFILES=()
  [ -e "$ZRO_ERROR_FILE" ] && rm -f -- "$ZRO_ERROR_FILE"
  [ -e "$ZRO_MODE_FILE" ] && rm -f -- "$ZRO_MODE_FILE"
  return 0
}

zro_human_bytes() {
  local n=$1
  case $n in
    ''|*[!0-9]*) return "$ZRO_E_INPUT" ;;
  esac
  if [ "$n" -lt 1024 ]; then
    printf '%s B' "$n"
    return 0
  fi
  local units=(KB MB GB TB PB)
  local unit value=$n scaled=0
  for unit in "${units[@]}"; do
    scaled=$(( value * 10 / 1024 ))
    value=$(( value / 1024 ))
    if [ "$value" -lt 1024 ]; then
      printf '%s.%s %s' "$value" "$(( scaled % 10 ))" "$unit"
      return 0
    fi
  done
  printf '%s.%s PB' "$value" "$(( scaled % 10 ))"
}
