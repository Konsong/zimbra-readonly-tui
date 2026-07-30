# shellcheck shell=bash
# The arrival window: the time range a delivery trace is restricted to, compared
# against when a message ARRIVED. Reads no file, runs no Zimbra binary, and opens
# no mailbox.
[ -n "${ZRO_LIB_WINDOW_LOADED:-}" ] && return 0
ZRO_LIB_WINDOW_LOADED=1

# Split the same way lib/inventory.sh is split, and for the same reason.
#
# The PRESETS are pure: a name, the current time and the start of the current day
# in, two absolute timestamps out. Nothing here asks what time it is, so the
# arithmetic an operator's "yesterday" turns on is testable for the price of two
# numbers instead of a frozen clock.
#
# The CLOCK is thin: four calls to date, which decide nothing.
#
# EVERYTHING IS LOCAL WALL CLOCK, with no timezone and no daylight-saving
# arithmetic anywhere. That is a decision, not an omission. The tracer reads
# syslog lines carrying neither a zone nor a year and stamps them with the local
# year it is handed, so compensating on this side would be inventing a precision
# the other side does not have. The visible cost is that a window spanning a
# daylight-saving change is an hour wider or narrower than its label; that is
# documented in docs/operations.md rather than corrected.

# Pairs travel as one TAB-separated line, as they do out of the log inventory:
# a function returns a status, so two numbers have to share one line of output.
ZRO_WIN_TAB=$'\t'

# The presets, as ids. Their labels are the screen's business and are Turkish;
# their arithmetic is here and is a name.
#
# SC2034: read by the screen that offers them and by the suite that walks them,
# neither of which ShellCheck can see from this file.
# shellcheck disable=SC2034
ZRO_WIN_PRESETS='hour day yesterday week'

# One preset's window.
#
#   $1  preset id
#   $2  now, an absolute local timestamp in seconds
#   $3  the start of the local day that $2 falls in
#
# Pure. Both timestamps are inputs precisely so that this function can be asked
# about a day it is not, which is what makes the yesterday case cheap to check.
zro_win_preset() {
  local name=${1-} now=${2-} day_start=${3-} start end
  case $now in ''|*[!0-9]*) return "$ZRO_E_INPUT" ;; esac
  case $day_start in ''|*[!0-9]*) return "$ZRO_E_INPUT" ;; esac
  [ "$day_start" -le "$now" ] || return "$ZRO_E_INPUT"

  case $name in
    hour) start=$((now - 3600));   end=$now ;;
    day)  start=$((now - 86400));  end=$now ;;
    week) start=$((now - 604800)); end=$now ;;
    # The only preset that names a CALENDAR day rather than a rolling span, and
    # the only one that needs to know where today began. 'now - 86400' would
    # answer "this time yesterday", which is not what an operator asking about
    # yesterday means: at 16:00 it would miss yesterday morning entirely and
    # reach into today instead.
    yesterday) start=$((day_start - 86400)); end=$((day_start - 1)) ;;
    *) return "$ZRO_E_INPUT" ;;
  esac

  # A window reaching before the epoch is a clock this program cannot reason
  # about, not a search worth running.
  [ "$start" -ge 0 ] || return "$ZRO_E_INPUT"
  printf '%s%s%s' "$start" "$ZRO_WIN_TAB" "$end"
}

# --- the clock: thin ------------------------------------------------------

zro_win_now() {
  [ -n "$ZRO_DATE_BIN" ] || return "$ZRO_E_UNAVAILABLE"
  local out
  out=$("$ZRO_DATE_BIN" '+%s' 2>/dev/null) || return "$ZRO_E_UNAVAILABLE"
  case $out in ''|*[!0-9]*) return "$ZRO_E_UNAVAILABLE" ;; esac
  printf '%s' "$out"
}

# Where the local day holding a timestamp began.
#
# Computed by subtracting the wall-clock time of day, rather than by formatting a
# date and handing it back to a parser: nothing this program printed is re-read as
# input. On the day a daylight-saving change falls, this lands an hour either side
# of local midnight — see the note at the top of this file.
zro_win_day_start() {
  local ts=${1-} hms h m s rest
  case $ts in ''|*[!0-9]*) return "$ZRO_E_INPUT" ;; esac
  [ -n "$ZRO_DATE_BIN" ] || return "$ZRO_E_UNAVAILABLE"

  hms=$("$ZRO_DATE_BIN" -d "@$ts" '+%H %M %S' 2>/dev/null) || return "$ZRO_E_UNAVAILABLE"
  h=${hms%% *}
  rest=${hms#* }
  m=${rest%% *}
  s=${rest##* }
  # One test for all three, because a partial answer is as unusable as none.
  case "$h$m$s" in ''|*[!0-9]*) return "$ZRO_E_UNAVAILABLE" ;; esac
  # '10#' for the same reason as in the validator: '08' is a valid hour and an
  # invalid octal number.
  printf '%s' "$(( ts - (10#$h * 3600 + 10#$m * 60 + 10#$s) ))"
}

# A timestamp as an operator reads it. Used in the report header, so that the
# window an answer was found in is on the screen next to the answer.
zro_win_human() {
  local ts=${1-}
  case $ts in ''|*[!0-9]*) return "$ZRO_E_INPUT" ;; esac
  [ -n "$ZRO_DATE_BIN" ] || return "$ZRO_E_UNAVAILABLE"
  "$ZRO_DATE_BIN" -d "@$ts" '+%Y-%m-%d %H:%M:%S' 2>/dev/null
}

# One end of an explicit range, as an absolute timestamp.
#
# Validated again here rather than only by the caller: this is the function that
# hands operator text to a program, and a value that reached it unvalidated would
# be a defect nobody could see from the call site.
zro_win_epoch() {
  local t=${1-} out
  zro_validate_datetime "$t" || return "$ZRO_E_INPUT"
  [ -n "$ZRO_DATE_BIN" ] || return "$ZRO_E_UNAVAILABLE"
  # A day the calendar does not have — 2026-02-30 — is refused here, which is
  # where the validator deliberately left it.
  out=$("$ZRO_DATE_BIN" -d "$t" '+%s' 2>/dev/null) || return "$ZRO_E_INPUT"
  case $out in ''|*[!0-9]*) return "$ZRO_E_INPUT" ;; esac
  printf '%s' "$out"
}

# The explicit range: two texts an operator typed, one window out.
#
# THE ONLY PATH THAT VALIDATES OPERATOR TEXT as a date. A preset computes its
# bounds from numbers this program already had, which is why the common question
# costs no typing and cannot be typed wrong.
zro_win_explicit() {
  local s=${1-} e=${2-} ss ee
  zro_validate_datetime "$s" || return "$ZRO_E_INPUT"
  zro_validate_datetime "$e" || return "$ZRO_E_INPUT"
  ss=$(zro_win_epoch "$s") || return "$ZRO_E_INPUT"
  ee=$(zro_win_epoch "$e") || return "$ZRO_E_INPUT"

  # A range that ends before it starts is refused, never quietly swapped. An
  # operator who typed the ends the wrong way round has to be told, or the
  # answer they read belongs to a window they did not ask for.
  [ "$ss" -le "$ee" ] || return "$ZRO_E_INPUT"
  printf '%s%s%s' "$ss" "$ZRO_WIN_TAB" "$ee"
}
