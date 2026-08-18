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
# A domain the directory does not hold. Its own code rather than NO_RESULT,
# because it is an ANSWER an operator acts on — mail for an address in a domain
# this server does not host was never going to arrive here, and that ends the
# search in Zimbra rather than continuing it.
ZRO_E_NO_DOMAIN=15
# Environment
ZRO_E_PERM=20
ZRO_E_UNAVAILABLE=21
ZRO_E_TIMEOUT=22
ZRO_E_NO_LOG=23
# A stored message file this tool was pointed at and could not read. Beside the log
# that cannot be read, and for the same reason it is not folded into it: the two name
# different files with different repairs, and neither is a query that found nothing.
# It is the code a blob read ends on when the failure is not one of the gate's own —
# a file the store no longer has, or one the account every command runs as cannot
# open — so no undocumented status from `head` or `gzip` reaches a caller.
ZRO_E_NO_BLOB=24
# Partial. The operation ran and answered, but not from everything it was meant to
# read: a delivery trace whose arrival window selected a log file it could not open,
# or a bulk read that could not reach every account. Never returned without saying
# so on the screen as well — an answer assembled from some of its sources reads
# exactly like a complete one.
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

# The clock, behind a variable like every other binary path, and for the reason
# CLAUDE.md gives: that is what makes it mockable. zro_log above calls date bare,
# because a log line's stamp is only ever read by a human. Every other date in
# this program produces a value that reaches a command line and decides whether a
# trace finds anything at all — the year stamped on a rotated log, the bounds of
# an arrival window — so those go through this.
ZRO_DATE_BIN="${ZRO_DATE_BIN:-$(zro_first_existing /usr/bin/date /bin/date)}"

# What an absolute timestamp looks like in a given format, as LOCAL WALL CLOCK.
# The one place this program asks the clock about a moment: the log inventory
# derives a file's year through it, the arrival window renders its bounds, and the
# delivery trace builds the tracer's own time option. Each caller still judges the
# answer it got — a year is four digits, a trace bound is fourteen — because those
# are different guarantees, but none of them repeats how to reach the clock or how
# to refuse a timestamp that is not one.
#
#   $1  a date format, without its leading '+'
#   $2  an absolute timestamp in seconds
zro_clock_fmt() {
  local fmt=${1-} ts=${2-} out
  [ -n "$fmt" ] || return "$ZRO_E_INPUT"
  case $ts in ''|*[!0-9]*) return "$ZRO_E_INPUT" ;; esac
  [ -n "$ZRO_DATE_BIN" ] || return "$ZRO_E_UNAVAILABLE"
  out=$("$ZRO_DATE_BIN" -d "@$ts" "+$fmt" 2>/dev/null) || return "$ZRO_E_UNAVAILABLE"
  [ -n "$out" ] || return "$ZRO_E_UNAVAILABLE"
  printf '%s' "$out"
}

# The separator every pair this program passes between functions travels on. A
# function answers with a status, so two values have to share one line — the log
# inventory's timestamp-and-path pairs and the arrival window's two bounds alike.
# One constant rather than one per module: two names for one character is how a
# producer and a consumer end up splitting on different things.
ZRO_TAB=$'\t'

# HOW MUCH OF THE UNDERLYING FAILURE MESSAGE IS KEPT, in bytes. Every screen that
# explains a failure prints this tool's own reading of it and, under that, the words
# the command itself printed — and this is the bound on the second, so that a stack
# trace cannot push the explanation off the screen it is the explanation for. Every
# site that reads a scratch file holding a command's error stream applies it, and so
# do the two that report a list of log files instead, because that list is assembled
# out of what those commands said. One bound rather than the eleven copies of a
# number this replaces is what keeps one screen from being quietly more talkative
# than another.
#
# THE NUMBER WAS CHOSEN AND NEVER MEASURED. Nothing in this tree records where 500
# came from, no document states it, and no screen was ever rendered against a wider
# or a narrower one to see which read better. What this name preserves is that every
# screen keeps the SAME amount; what it does not preserve is any claim that this
# amount is the right one. Whoever changes it is overturning a default nobody
# checked, not a finding — and now changes it in one place rather than eleven.
ZRO_ERROR_KEEP_BYTES=500

# The last underlying failure message, kept in a file rather than a variable.
# Menu code runs operations inside command substitution, so a variable set in
# that subshell would never reach the caller — the operator would be left with
# a bare exit code instead of what the command actually said.
ZRO_ERROR_FILE="${ZRO_ERROR_FILE:-${TMPDIR:-/tmp}/zro-error.$$}"

# THE BOUND IS NOT APPLIED HERE, and that is deliberate. Two callers — the delivery
# trace and the log search — bound what the command said and then APPEND the list of
# log files they could not open, because the one thing those two screens may never do
# is let a skipped file go unmentioned. A bound enforced in this function would let a
# long message from the command spend the whole budget and cut that disclosure off
# the end, which turns a bound into a silence. So the bound belongs to the part that
# came from a command, and each caller applies it to that part before adding its own.
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

# The two files above outlive a subshell on purpose, and a later module needing
# one of its own needs it for exactly the same reason: menu code runs operations
# inside command substitution, so anything the session has to remember across one
# cannot be a variable. They are removed at exit by name, so a module that adds
# one REGISTERS IT rather than being known to this file — which is what keeps this
# module, which depends on nothing, from having to know what a mailbox is.
ZRO_SESSION_FILES=("$ZRO_ERROR_FILE" "$ZRO_MODE_FILE")

# Registered at load time, in the shell that sources the module. Anywhere else it
# would be an append made inside a subshell, which is the very failure the file
# being registered exists to avoid.
zro_session_file() {
  [ -n "${1-}" ] || return "$ZRO_E_INPUT"
  ZRO_SESSION_FILES+=("$1")
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
  for f in ${ZRO_SESSION_FILES[@]+"${ZRO_SESSION_FILES[@]}"}; do
    [ -e "$f" ] && rm -f -- "$f"
  done
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
