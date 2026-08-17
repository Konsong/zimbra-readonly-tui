# shellcheck shell=bash
# The only path from this program to the screen. Two backends behind one
# interface: whiptail for real use, stub for the test suite.
[ -n "${ZRO_LIB_UI_LOADED:-}" ] && return 0
ZRO_LIB_UI_LOADED=1

ZRO_UI_BACKEND="${ZRO_UI_BACKEND:-whiptail}"
ZRO_UI_QUEUE="${ZRO_UI_QUEUE:-}"
ZRO_UI_OUT="${ZRO_UI_OUT:-}"

# How much of the top border a decorated title may occupy.
ZRO_UI_TITLE_MAX="${ZRO_UI_TITLE_MAX:-56}"

# The selected address on the frame of every screen. whiptail keeps a title on
# the box border while the text inside scrolls, so it is the one part of a screen
# a long report cannot push out of view — which makes it the right place for the
# fact that would otherwise let an operator read one account's answer believing
# it is another's.
#
# Applied HERE, in the one path from this program to the screen, rather than by
# each screen: "every screen carries it" is a claim that has to be structurally
# true, and a screen written next month cannot forget to do something it never
# does. ZRO_SELECTED belongs to lib/selection.sh and is the one thing this module
# reads from outside itself; the default keeps ui.sh loadable on its own.
zro_ui_title() {
  local base=${1-} addr=${ZRO_SELECTED:-} room
  [ -n "$addr" ] || { printf '%s' "$base"; return 0; }
  # whiptail clips a title that does not fit, and what it clips is the END —
  # which on this title is the address. So what does not fit is shortened here
  # instead, and marked as shortened.
  #
  # The address is given whatever the screen's name leaves it, and never less
  # than twelve characters: fewer than that names no account at all. A screen
  # name long enough to take that room is shortened itself rather than left to
  # push the address off the border — which is the one outcome this function
  # exists to prevent. Nothing decides anything from the result: every screen
  # that acts on the address reads the variable.
  room=$((ZRO_UI_TITLE_MAX - ${#base} - 3))
  if [ "$room" -lt 12 ]; then
    room=12
    base=$(zro_ui_shorten "$base" "$((ZRO_UI_TITLE_MAX - room - 3))")
  fi
  printf '%s - %s' "$base" "$(zro_ui_shorten "$addr" "$room")"
}

# As much of a string as fits, with what was cut said rather than implied.
zro_ui_shorten() {
  local s=${1-} max=${2-0}
  # Room for nothing but the mark that says something was cut, so nothing is
  # what it returns. Bash reads a negative length as an offset from the end,
  # which would answer a nonsensical bound with most of the string.
  [ "$max" -gt 2 ] || return 0
  [ "${#s}" -le "$max" ] && { printf '%s' "$s"; return 0; }
  printf '%s..' "${s:0:max-2}"
}

zro_ui_reset() {
  [ -n "$ZRO_UI_QUEUE" ] || return 0
  printf '0' >"$ZRO_UI_QUEUE.pos"
  printf '0' >"$ZRO_UI_QUEUE.stops"
}

# Pops the next scripted answer. An exhausted queue reads as cancel, so a
# mis-scripted test fails fast instead of blocking.
#
# The position lives in a file, not a shell variable, because callers read
# prompts inside command substitution — `acct=$(zro_prompt_account)` runs in a
# subshell, and a variable incremented there would be lost, leaving the menu
# loop re-reading the same answer forever.
zro_ui_stub_next() {
  [ -n "$ZRO_UI_QUEUE" ] || return "$ZRO_E_CANCEL"
  local posfile="$ZRO_UI_QUEUE.pos" pos=0
  if [ -f "$posfile" ]; then
    pos=$(cat -- "$posfile")
    [ -n "$pos" ] || pos=0
  fi
  pos=$((pos + 1))
  printf '%s' "$pos" >"$posfile"

  local line
  line=$(sed -n "${pos}p" "$ZRO_UI_QUEUE")
  [ -n "$line" ] || return "$ZRO_E_CANCEL"
  [ "$line" = "__CANCEL__" ] && return "$ZRO_E_CANCEL"
  printf '%s' "$line"
}

zro_ui_stub_show() {
  [ -n "$ZRO_UI_OUT" ] || return 0
  printf '%s\n' "$*" >>"$ZRO_UI_OUT"
}

zro_ui_menu() {
  local title text=$2
  title=$(zro_ui_title "$1")
  shift 2
  if [ "$ZRO_UI_BACKEND" = stub ]; then
    # The ENTRIES are recorded as well as the prompt, because on two screens the
    # entries are what this program is telling the operator: an entry marked
    # unavailable, and a list this program built — the log files an operator picks
    # from. A transcript that kept only the prompt could not be asserted on at
    # all, and a menu would be the one screen whose text the suite cannot read.
    # Still ONE LINE per menu drawn, which is what the cases that count menus read.
    zro_ui_stub_show "MENU $title: $text | $*"
    zro_ui_stub_next
    return $?
  fi
  zro_ui_whiptail_menu "$title" "$text" "$@"
}

zro_ui_input() {
  local title text=$2 default=${3-}
  title=$(zro_ui_title "$1")
  if [ "$ZRO_UI_BACKEND" = stub ]; then
    # The DEFAULT is recorded as well as the prompt. On the address screen it is
    # what the operator is being offered — the address already selected, there to
    # be edited rather than retyped — so a transcript without it could not be
    # asserted on at all.
    zro_ui_stub_show "INPUT $title: $text${default:+ | $default}"
    zro_ui_stub_next
    return $?
  fi
  zro_ui_whiptail_input "$title" "$text" "$default"
}

zro_ui_msgbox() {
  local title text=$2
  title=$(zro_ui_title "$1")
  if [ "$ZRO_UI_BACKEND" = stub ]; then
    zro_ui_stub_show "MSG $title: $text"
    return 0
  fi
  zro_ui_whiptail_msgbox "$title" "$text"
}

# Draws and returns immediately, asking the operator for nothing. Used before a
# command that takes seconds, so the screen is never blank while the tool works.
zro_ui_notice() {
  local title text=$2
  title=$(zro_ui_title "$1")
  if [ "$ZRO_UI_BACKEND" = stub ]; then
    zro_ui_stub_show "NOTICE $title: $text"
    return 0
  fi
  zro_ui_whiptail_notice "$title" "$text"
}

zro_ui_textbox() {
  local title file=$2
  title=$(zro_ui_title "$1")
  if [ "$ZRO_UI_BACKEND" = stub ]; then
    zro_ui_stub_show "TEXT $title:"
    if [ -n "$ZRO_UI_OUT" ] && [ -f "$file" ]; then
      cat -- "$file" >>"$ZRO_UI_OUT"
    fi
    return 0
  fi
  zro_ui_whiptail_textbox "$title" "$file"
}

zro_ui_yesno() {
  local title text=$2
  title=$(zro_ui_title "$1")
  if [ "$ZRO_UI_BACKEND" = stub ]; then
    zro_ui_stub_show "YESNO $title: $text"
    local answer
    # A cancelled confirmation is a no. Nothing in this program should proceed
    # on an answer the operator did not give.
    answer=$(zro_ui_stub_next) || return 1
    [ "$answer" = "yes" ]
    return $?
  fi
  zro_ui_whiptail_yesno "$title" "$text"
}

# ------------------------------------------------------------ stopping a run --

# WHETHER THE OPERATOR HAS ASKED FOR A LONG RUN TO STOP.
#
# The one place in this program that reads the keyboard while nothing is being
# drawn. It is here rather than in the module that runs the loop for the reason
# every other drawing is: this file is the only path between this program and the
# terminal, so a screen written next month cannot reach the keyboard by a route
# that has no stub behind it.
#
# ASKED, NEVER WAITED FOR. A bulk query spends seconds per account and has to
# notice a keypress made at any point during one, so the poll reads whatever the
# terminal has ALREADY buffered rather than waiting for something to be typed.
# `read -n 1` is what makes that possible: bash puts the terminal into
# character-at-a-time mode for the duration of the read, so a key pressed while
# the line discipline was still collecting a line becomes readable at the next
# poll instead of waiting for an Enter nobody is going to press.
#
# The wait is a fraction of a second and is overridable, because it is spent once
# per account and a bulk query may run to two hundred of them.
ZRO_UI_STOP_WAIT="${ZRO_UI_STOP_WAIT:-0.1}"
# ESC, as the terminal delivers it. An arrow key sends this byte first and two
# more behind it, so an operator who pressed one during a run stops it — which
# costs them the run's remaining accounts and never its answer, since a stopped
# run keeps what it found.
ZRO_UI_STOP_KEY=$'\033'
# How many polls the stub answers before it reports a stop. Empty means never,
# which is what every case that is not about stopping wants.
ZRO_UI_STOP_AFTER="${ZRO_UI_STOP_AFTER:-}"

zro_ui_stop_requested() {
  if [ "$ZRO_UI_BACKEND" = stub ]; then
    zro_ui_stub_stop
    return $?
  fi
  zro_ui_tty_stop
}

# The scripted answer. The count lives in a file for the reason the queue
# position does: a run is driven inside command substitution, and a counter
# incremented in that subshell would be lost, so every poll would be the first.
zro_ui_stub_stop() {
  # Read defensively rather than as a plain variable: a case that has finished
  # with stopping unsets it, and an unset variable under `set -u` would take the
  # whole run down instead of answering 'nobody asked to stop'.
  local after=${ZRO_UI_STOP_AFTER:-}
  case $after in
    ''|*[!0-9]*|0) return 1 ;;
  esac
  [ -n "$ZRO_UI_QUEUE" ] || return 1
  local f="$ZRO_UI_QUEUE.stops" n=0
  if [ -f "$f" ]; then
    n=$(cat -- "$f")
    [ -n "$n" ] || n=0
  fi
  n=$((n + 1))
  printf '%s' "$n" >"$f"
  [ "$n" -ge "$after" ]
}

# What the terminal has waiting, if anything. A terminal that cannot be read is
# not a stop: this answers whether the operator asked to stop, and "nobody could
# ask" is not "somebody did".
zro_ui_tty_stop() {
  [ -r "$ZRO_UI_TTY" ] || return 1
  local key=''
  IFS= read -r -s -n 1 -t "$ZRO_UI_STOP_WAIT" key <"$ZRO_UI_TTY" || return 1
  [ "$key" = "$ZRO_UI_STOP_KEY" ]
}

# ---------------------------------------------------------------- whiptail --

ZRO_WHIPTAIL_BIN="${ZRO_WHIPTAIL_BIN:-$(zro_first_existing /usr/bin/whiptail /bin/whiptail)}"
# Where dialogs are drawn. Pinned to the controlling terminal rather than
# inherited, and overridable so the suite can prove the drawing arrived.
ZRO_UI_TTY="${ZRO_UI_TTY:-/dev/tty}"
ZRO_UI_HEIGHT="${ZRO_UI_HEIGHT:-20}"
# The SMALLEST a notice may be, not the size it is drawn at. See below.
ZRO_UI_NOTICE_HEIGHT="${ZRO_UI_NOTICE_HEIGHT:-8}"
ZRO_UI_WIDTH="${ZRO_UI_WIDTH:-78}"

# WHAT AN INFOBOX SPENDS ON ITSELF, in rows, MEASURED rather than reasoned about:
# whiptail keeps `height - 7` rows of text in one. Two of those are the border and
# the rest are its own padding; the number is what a real whiptail did, checked by
# drawing a seven-line notice at every height from 8 to 15 and asking which of its
# lines survived.
#
# THIS IS WHY THE HEIGHT IS COMPUTED AND NOT DECLARED. A notice used to be drawn
# at a fixed height of 8, which by the rule above is ONE row of text — so every
# notice in this program showed its first line and silently dropped the rest: the
# account a card was about, the cost a screen was spending, the key that stops a
# run. Nothing caught it, because the stub backend the suite drives has no
# geometry at all and the transcript it writes carries every line.
#
# Sized HERE, in the one place a box is built, rather than by each caller: a rule
# that every future caller has to remember is a rule the next screen breaks.
ZRO_UI_NOTICE_CHROME=7

# How tall a box has to be to show this text, bounded at both ends. The floor
# keeps a one-line notice from being a box with no shape; the ceiling is the
# height every other box in this program uses, because a box taller than the
# terminal does not draw at all. A notice longer than that is clipped, as it was
# before — but nothing in this program has one, and what does not fit is now the
# end of a long explanation rather than everything after the first line.
#
# WRAPPING IS NOT COUNTED. A line wider than the box takes two rows, and this
# counts the lines it was given. The ceiling leaves the slack; a caller whose text
# really is that long should shorten it rather than have the box grow past the
# screen.
zro_ui_notice_height() {
  local text=${1-} lines
  # The count is stripped of whitespace before it is judged: not every wc writes a
  # bare number, and a count that arrived padded would fail the test below and
  # silently size every box as though it held one line — which is the exact bug
  # this function exists to fix, reintroduced by its own guard.
  lines=$(printf '%s\n' "$text" | wc -l | tr -d '[:space:]')
  case $lines in
    ''|*[!0-9]*) lines=1 ;;
  esac
  local h=$((lines + ZRO_UI_NOTICE_CHROME))
  [ "$h" -ge "$ZRO_UI_NOTICE_HEIGHT" ] || h=$ZRO_UI_NOTICE_HEIGHT
  [ "$h" -le "$ZRO_UI_HEIGHT" ] || h=$ZRO_UI_HEIGHT
  printf '%s' "$h"
}
ZRO_UI_LISTHEIGHT="${ZRO_UI_LISTHEIGHT:-10}"
ZRO_UI_BACKTITLE="Zimbra salt-okunur yonetim araci"

# The menu labels are Turkish. Without a UTF-8 locale whiptail miscounts
# character widths and the boxes break, so this is checked at startup.
zro_ui_locale_ok() {
  case ${1-} in
    *.UTF-8|*.utf8|*.UTF8|*.utf-8) return 0 ;;
    *) return 1 ;;
  esac
}

# Builds ZRO_UI_ARGV. Bash 4.2 has no namerefs, so the vector is handed back
# through a global rather than returned. Both the run path and the test-facing
# printer go through here, so what the suite asserts on is what actually runs.
zro_ui_whiptail_build() {
  local kind=$1 title=$2 text=$3
  shift 3
  ZRO_UI_ARGV=("$ZRO_WHIPTAIL_BIN" --backtitle "$ZRO_UI_BACKTITLE" --title "$title")
  case $kind in
    menu)    ZRO_UI_ARGV+=(--notags --menu "$text" "$ZRO_UI_HEIGHT" "$ZRO_UI_WIDTH" "$ZRO_UI_LISTHEIGHT" "$@") ;;
    input)   ZRO_UI_ARGV+=(--inputbox "$text" "$ZRO_UI_HEIGHT" "$ZRO_UI_WIDTH" "$@") ;;
    msgbox)  ZRO_UI_ARGV+=(--msgbox "$text" "$ZRO_UI_HEIGHT" "$ZRO_UI_WIDTH") ;;
    infobox) ZRO_UI_ARGV+=(--infobox "$text" "$(zro_ui_notice_height "$text")" "$ZRO_UI_WIDTH") ;;
    textbox) ZRO_UI_ARGV+=(--scrolltext --textbox "$text" "$ZRO_UI_HEIGHT" "$ZRO_UI_WIDTH") ;;
    yesno)   ZRO_UI_ARGV+=(--yesno "$text" "$ZRO_UI_HEIGHT" "$ZRO_UI_WIDTH") ;;
  esac
}

# TAB-joined rendering of the vector, so tests can assert that an operator
# string stayed a single argument instead of splitting into flags.
zro_ui_whiptail_argv() {
  zro_ui_whiptail_build "$@"
  local a out=""
  for a in "${ZRO_UI_ARGV[@]}"; do
    out="$out	$a"
  done
  printf '%s' "${out#	}"
}

zro_ui_whiptail_run() {
  zro_ui_whiptail_build "$@"
  # whiptail DRAWS on stdout and returns the operator's answer on stderr.
  #
  # Both were previously left as the caller found them, which broke twice over:
  # callers read prompts inside command substitution, making stdout a pipe, and
  # the msgbox wrapper discarded stdout outright. The dialog went to /dev/null
  # while whiptail still waited on stdin — the terminal looked frozen.
  #
  # So drawing is pinned to the terminal and the answer travels out on whatever
  # stdout the caller has. Order matters: fd2 is aimed at the caller's stdout
  # first, then fd1 is moved to the terminal.
  #
  # SC2069 flags `2>&1` before a stdout redirect because it is usually a
  # mistake. Here it is the point: this swaps the two streams rather than
  # merging them.
  # shellcheck disable=SC2069
  "${ZRO_UI_ARGV[@]}" 2>&1 1>"$ZRO_UI_TTY"
}

zro_ui_whiptail_menu() {
  local title=$1 text=$2
  shift 2
  local out rc=0
  out=$(zro_ui_whiptail_run menu "$title" "$text" "$@") || rc=$?
  [ "$rc" -eq 0 ] || return "$ZRO_E_CANCEL"
  printf '%s' "$out"
}

zro_ui_whiptail_input() {
  local title=$1 text=$2 default=${3-}
  local out rc=0
  out=$(zro_ui_whiptail_run input "$title" "$text" "$default") || rc=$?
  [ "$rc" -eq 0 ] || return "$ZRO_E_CANCEL"
  printf '%s' "$out"
}

# These three discard the ANSWER stream only. Redirecting stderr here as well
# would send the drawing back into the void, which is the bug this shape fixes.
zro_ui_whiptail_msgbox() {
  zro_ui_whiptail_run msgbox "$1" "$2" >/dev/null
  return 0
}

zro_ui_whiptail_textbox() {
  zro_ui_whiptail_run textbox "$1" "$2" >/dev/null
  return 0
}

zro_ui_whiptail_yesno() {
  zro_ui_whiptail_run yesno "$1" "$2" >/dev/null
}

zro_ui_whiptail_notice() {
  zro_ui_whiptail_run infobox "$1" "$2" >/dev/null
  return 0
}
