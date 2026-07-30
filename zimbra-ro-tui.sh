#!/usr/bin/env bash
# Zimbra salt-okunur yonetim araci.
#
# No errexit: whiptail returns non-zero on Cancel, which would kill the TUI,
# and errexit is silently disabled inside conditional contexts. Failures are
# handled where they happen.
set -uo pipefail

ZRO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib/core.sh
. "$ZRO_ROOT/lib/core.sh"
# shellcheck source=lib/validate.sh
. "$ZRO_ROOT/lib/validate.sh"
# shellcheck source=lib/exec.sh
. "$ZRO_ROOT/lib/exec.sh"
# shellcheck source=lib/capability.sh
. "$ZRO_ROOT/lib/capability.sh"
# shellcheck source=lib/ui.sh
. "$ZRO_ROOT/lib/ui.sh"
# shellcheck source=lib/account.sh
. "$ZRO_ROOT/lib/account.sh"
# shellcheck source=lib/delivery.sh
. "$ZRO_ROOT/lib/delivery.sh"

trap zro_cleanup EXIT INT TERM

zro_startup_check() {
  if [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
     { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
    zro_log error "Bash 4.2 veya uzeri gerekiyor (bulunan: ${BASH_VERSION})"
    return "$ZRO_E_UNAVAILABLE"
  fi

  local user
  user=$(zro_current_user) || return "$ZRO_E_UNAVAILABLE"
  if ! zro_identity_mode "$user" >/dev/null; then
    zro_log error "Bu arac yalnizca zimbra veya root ile calisir (bulunan: $user)"
    return "$ZRO_E_BADUSER"
  fi

  # Every screen is drawn on the controlling terminal. Without one there is
  # nowhere to draw, and whiptail would wait on input nobody can give.
  if [ "$ZRO_UI_BACKEND" != stub ] && ! { : >>"$ZRO_UI_TTY"; } 2>/dev/null; then
    zro_log error "Terminale yazilamiyor ($ZRO_UI_TTY); bu arac etkilesimli bir terminal gerektirir"
    return "$ZRO_E_UNAVAILABLE"
  fi

  local missing=""
  [ -n "$ZRO_TIMEOUT_BIN" ] || missing="$missing timeout"
  [ -n "$ZRO_ID_BIN" ] || missing="$missing id"
  if [ "$(zro_identity_mode "$user")" = runuser ] && [ -z "$ZRO_RUNUSER" ]; then
    missing="$missing runuser"
  fi
  if [ -n "$missing" ]; then
    zro_log error "Gerekli sistem komutlari bulunamadi:$missing"
    return "$ZRO_E_UNAVAILABLE"
  fi

  if ! zro_bin_available zmcontrol; then
    zro_log error "Zimbra kurulumu bulunamadi: $ZRO_ZIMBRA_BIN"
    return "$ZRO_E_UNAVAILABLE"
  fi

  # Smoke check: prove the whole wrapper works before showing any menu, so a
  # broken environment fails here with one clear message rather than later from
  # inside a screen.
  zro_cap_reset
  local version
  version=$(zro_cap_version)
  if [ -z "$version" ]; then
    zro_log error "Zimbra servisine erisilemedi ($ZRO_ZIMBRA_BIN/zmcontrol -v)"
    return "$ZRO_E_UNAVAILABLE"
  fi

  if ! zro_ui_locale_ok "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"; then
    zro_log warn "UTF-8 olmayan locale: Turkce menu metinleri bozuk gorunebilir"
  fi

  return 0
}

zro_show_text() {
  local title=$1 body=$2 f
  f=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"
  printf '%s\n' "$body" >"$f"
  zro_ui_textbox "$title" "$f"
  rm -f -- "$f"
}

# Asks for one e-mail address and validates it. Cancel and ESC are told apart
# from a rejected value: the first returns the operator to the previous screen,
# the second re-offers the same one.
#
#   $1  screen title      $2  prompt text      $3  what to say when it is invalid
zro_prompt_address() {
  local title=$1 text=$2 invalid=$3 value rc=0
  value=$(zro_ui_input "$title" "$text") || rc=$?
  [ "$rc" -eq 0 ] || return "$ZRO_E_CANCEL"
  if ! zro_validate_email "$value"; then
    zro_ui_msgbox "Gecersiz girdi" "$invalid"
    return "$ZRO_E_INPUT"
  fi
  printf '%s' "$value"
}

zro_prompt_account() {
  zro_prompt_address "Hesap" "Hesap adresi:" "Gecersiz hesap adresi."
}

zro_prompt_recipient() {
  zro_prompt_address "Alici" "Alici adresi:" "Gecersiz alici adresi."
}

zro_report_error() {
  # Whatever Zimbra actually said, when it said anything. Without this the
  # operator sees a bare code and has to reproduce the command by hand to learn
  # that, say, mailboxd is stopped.
  local detail
  detail=$(zro_last_error)
  [ -n "$detail" ] && detail="

Zimbra ciktisi:
$detail"

  case $1 in
    "$ZRO_E_NO_ACCOUNT") zro_ui_msgbox "Bulunamadi" "Hesap bulunamadi.$detail" ;;
    "$ZRO_E_NO_MAILBOX") zro_ui_msgbox "Bulunamadi" "Mailbox bulunamadi.$detail" ;;
    "$ZRO_E_NO_RESULT")  zro_ui_msgbox "Sonuc yok" "Kayit bulunamadi." ;;
    # The tool ran but could not read the log it was pointed at. Naming the
    # repair matters: the usual cause is ownership on the syslog file, which
    # breaks Zimbra's own tooling too, so fixing it is the right outcome.
    "$ZRO_E_NO_LOG")
      zro_ui_msgbox "Log okunamiyor" \
"Mail logu okunamadi, bu nedenle hicbir sey taranamadi.

Log dosyalari zimbra kullanicisi tarafindan okunabilir olmalidir. Izinler
bozulmussa onarmak icin: zmfixperms$detail" ;;
    "$ZRO_E_TIMEOUT")    zro_ui_msgbox "Zaman asimi" "Komut zaman asimina ugradi." ;;
    "$ZRO_E_DENIED")     zro_ui_msgbox "Reddedildi" "Bu islem izin listesinde degil." ;;
    "$ZRO_E_NOCAP")      zro_ui_msgbox "Kullanilamaz" "Bu islem bu sunucuda mevcut degil." ;;
    "$ZRO_E_PERM")       zro_ui_msgbox "Yetki" "Yetki reddedildi.$detail" ;;
    "$ZRO_E_UNAVAILABLE")
      zro_ui_msgbox "Zimbra servisine erisilemiyor" \
"Sorgu calistirilamadi.

zmprov varsayilan olarak mailboxd servisine SOAP ile baglanir. En sik iki sebep:
  - mailbox servisi durmus     (kontrol: zmcontrol status)
  - admin sertifikasi gecersiz (kontrol: zmcertmgr viewdeployedcrt)$detail" ;;
    *)                   zro_ui_msgbox "Hata" "Islem basarisiz (kod $1).$detail" ;;
  esac
}

zro_menu_account() {
  local choice acct out rc
  while :; do
    rc=0
    choice=$(zro_ui_menu "Hesap ve kota" "Islem secin:" \
      1 "Hesap ozeti" \
      2 "Kota kullanimi" \
      3 "Dagitim listesi uyelikleri") || rc=$?
    [ "$rc" -eq 0 ] || return 0

    rc=0
    acct=$(zro_prompt_account) || rc=$?
    [ "$rc" -eq 0 ] || continue

    # Each zmprov call starts a JVM and takes seconds; these screens make two.
    # Without this the terminal sits blank and looks frozen.
    zro_ui_notice "Calisiyor" "Zimbra sorgulaniyor, lutfen bekleyin.

Hesap: $acct
Her sorgu birkac saniye surebilir."

    rc=0
    case $choice in
      1) out=$(zro_account_summary "$acct") || rc=$? ;;
      2) out=$(zro_account_quota "$acct") || rc=$? ;;
      3) out=$(zro_account_membership "$acct") || rc=$? ;;
      *) continue ;;
    esac

    if [ "$rc" -ne 0 ]; then
      zro_report_error "$rc"
      continue
    fi
    zro_show_text "Sonuc" "$out"
  done
}

# The delivery trace: whether a message reached the server, answered from the
# mail transfer agent's log. No mailbox is opened anywhere below this line.
#
# Only the log the tracing tool defaults to is searched in this version, and the
# screens say so on both paths. An operator who reads an empty answer as "it
# never arrived" goes on to make the wrong decision, and that ambiguity is the
# reason this screen exists at all.
zro_menu_delivery() {
  local choice addr out rc
  while :; do
    rc=0
    choice=$(zro_ui_menu "Teslim takibi" "Islem secin:" \
      1 "Alici adresine gore izle") || rc=$?
    [ "$rc" -eq 0 ] || return 0

    case $choice in
      1) ;;
      *) continue ;;
    esac

    rc=0
    addr=$(zro_prompt_recipient) || rc=$?
    [ "$rc" -eq 0 ] || continue

    # Reading a whole log takes seconds, and longer on a busy server.
    zro_ui_notice "Calisiyor" "Mail loglari taraniyor, lutfen bekleyin.

Alici: $addr
Buyuk bir log dosyasi bu islemi uzatabilir."

    rc=0
    out=$(zro_trace_recipient "$addr") || rc=$?

    # Answered here rather than by the shared reporter: "kayit bulunamadi" alone
    # would let an operator conclude the message never arrived, when what it
    # really means is that it is not in the one log that was read.
    if [ "$rc" -eq "$ZRO_E_NO_RESULT" ]; then
      zro_ui_msgbox "Sonuc yok" \
"$addr icin teslim kaydi bulunamadi.

Yalnizca guncel birincil mail logu tarandi; rotasyona girmis eski loglar bu
surumde taranmiyor. Kayit bulunamamasi, iletinin sunucuya hic ulasmadigini
kanitlamaz."
      continue
    fi
    if [ "$rc" -ne 0 ]; then
      zro_report_error "$rc"
      continue
    fi
    zro_show_text "Teslim izi" "$out"
  done
}

zro_menu_main() {
  local choice rc
  while :; do
    rc=0
    choice=$(zro_ui_menu "Ana menu" "Zimbra: $(zro_cap_version)" \
      1 "Hesap ve kota kontrolleri" \
      2 "Teslim takibi (mail loglari)" \
      9 "Cikis") || rc=$?
    [ "$rc" -eq 0 ] || return 0
    case $choice in
      1) zro_menu_account ;;
      2) zro_menu_delivery ;;
      9) return 0 ;;
    esac
  done
}

zro_main() {
  zro_startup_check || return $?
  zro_menu_main
}

# Sourced by the test suite; executed in production.
if [ -z "${ZRO_SOURCED_ONLY:-}" ]; then
  zro_main
  exit $?
fi
