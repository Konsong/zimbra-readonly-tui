# shellcheck shell=bash
# The only path from this program to the screen. Two backends behind one
# interface: whiptail for real use, stub for the test suite.
[ -n "${ZRO_LIB_UI_LOADED:-}" ] && return 0
ZRO_LIB_UI_LOADED=1

ZRO_UI_BACKEND="${ZRO_UI_BACKEND:-whiptail}"
ZRO_UI_QUEUE="${ZRO_UI_QUEUE:-}"
ZRO_UI_OUT="${ZRO_UI_OUT:-}"

zro_ui_reset() {
  [ -n "$ZRO_UI_QUEUE" ] || return 0
  printf '0' >"$ZRO_UI_QUEUE.pos"
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
  local title=$1 text=$2
  shift 2
  if [ "$ZRO_UI_BACKEND" = stub ]; then
    zro_ui_stub_show "MENU $title: $text"
    zro_ui_stub_next
    return $?
  fi
  zro_ui_whiptail_menu "$title" "$text" "$@"
}

zro_ui_input() {
  local title=$1 text=$2 default=${3-}
  if [ "$ZRO_UI_BACKEND" = stub ]; then
    zro_ui_stub_show "INPUT $title: $text"
    zro_ui_stub_next
    return $?
  fi
  zro_ui_whiptail_input "$title" "$text" "$default"
}

zro_ui_msgbox() {
  local title=$1 text=$2
  if [ "$ZRO_UI_BACKEND" = stub ]; then
    zro_ui_stub_show "MSG $title: $text"
    return 0
  fi
  zro_ui_whiptail_msgbox "$title" "$text"
}

zro_ui_textbox() {
  local title=$1 file=$2
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
  local title=$1 text=$2
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

# ---------------------------------------------------------------- whiptail --

ZRO_WHIPTAIL_BIN="${ZRO_WHIPTAIL_BIN:-$(zro_first_existing /usr/bin/whiptail /bin/whiptail)}"
ZRO_UI_HEIGHT="${ZRO_UI_HEIGHT:-20}"
ZRO_UI_WIDTH="${ZRO_UI_WIDTH:-78}"
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
  # whiptail writes its result to stderr and its chrome to the terminal.
  "${ZRO_UI_ARGV[@]}" 3>&1 1>&2 2>&3
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

zro_ui_whiptail_msgbox() {
  zro_ui_whiptail_run msgbox "$1" "$2" >/dev/null 2>&1
  return 0
}

zro_ui_whiptail_textbox() {
  zro_ui_whiptail_run textbox "$1" "$2" >/dev/null 2>&1
  return 0
}

zro_ui_whiptail_yesno() {
  zro_ui_whiptail_run yesno "$1" "$2" >/dev/null 2>&1
}
