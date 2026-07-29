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
