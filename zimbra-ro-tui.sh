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
# shellcheck source=lib/inventory.sh
. "$ZRO_ROOT/lib/inventory.sh"
# shellcheck source=lib/window.sh
. "$ZRO_ROOT/lib/window.sh"
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
  # Without a clock there is no arrival window and no year for a rotated log, so
  # the delivery trace cannot be answered at all. Refused here with the others
  # rather than from inside a screen, where it would arrive as a failure the
  # operator would have to work back from.
  [ -n "$ZRO_DATE_BIN" ] || missing="$missing date"
  [ -n "$ZRO_STAT_BIN" ] || missing="$missing stat"
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

# What every screen that offers an arrival window has to say. A window compared
# against arrival time is not the same thing as a window compared against
# delivery time, and an operator who reads it as the latter will conclude that a
# message which arrived at 23:59 and was delivered at 00:02 never arrived at all.
ZRO_TXT_ARRIVAL='Aralik, iletinin sunucuya varis zamanina gore uygulanir.
Aralik oncesinde varip aralik icinde teslim edilen bir ileti listelenmez.

Aralik secin:'

ZRO_TXT_DATETIME='Tarih ve saat (ornek: 2026-07-28 08:00)

Saat zorunludur; yerel saat olarak okunur.'

# What the window screen offers, as "<preset id>:<label>". The id is the tag
# whiptail hands back — the menu is drawn with --notags, so an operator never sees
# it — which means there is no second table mapping a number onto a preset and no
# way for the two to disagree.
#
# Every id here except 'explicit' must be one lib/window.sh implements, and every
# preset it implements must appear here. Neither half can check the other at run
# time without one of them reaching into the other's business, so the suite holds
# the two sets equal instead, the way it holds the allowlist and the binary-root
# table equal.
ZRO_WINDOW_CHOICES='hour:Son 1 saat
day:Son 24 saat
yesterday:Dun (tam gun)
week:Son 7 gun
explicit:Belirli aralik gir'

# Asks which arrival window to search and answers with two absolute local
# timestamps, TAB-separated.
#
# The presets compute their own bounds from the clock, so the four questions an
# operator actually asks cost no typing and cannot be mistyped. The explicit
# range is the only path that takes a date as text, and therefore the only one
# that can be refused as invalid input.
zro_prompt_window() {
  local choice rc=0 now day_start entry
  local -a items=()
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    items+=("${entry%%:*}" "${entry#*:}")
  done <<EOF
$ZRO_WINDOW_CHOICES
EOF

  choice=$(zro_ui_menu "Varis araligi" "$ZRO_TXT_ARRIVAL" "${items[@]}") || rc=$?
  [ "$rc" -eq 0 ] || return "$ZRO_E_CANCEL"

  if [ "$choice" = explicit ]; then
    zro_prompt_window_explicit
    return $?
  fi

  # Both readings are taken once, here, and handed to a pure function. Asking the
  # clock twice inside the arithmetic would let a window straddle midnight while
  # it was being computed.
  now=$(zro_win_now) || return "$ZRO_E_UNAVAILABLE"
  day_start=$(zro_win_day_start "$now") || return "$ZRO_E_UNAVAILABLE"
  # An id the window module does not implement is refused by it, not by a second
  # list here that would have to be kept in step with the first.
  zro_win_preset "$choice" "$now" "$day_start" || return "$ZRO_E_INPUT"
}

zro_prompt_window_explicit() {
  local start end out rc=0
  start=$(zro_ui_input "Baslangic" "Baslangic
$ZRO_TXT_DATETIME") || rc=$?
  [ "$rc" -eq 0 ] || return "$ZRO_E_CANCEL"
  end=$(zro_ui_input "Bitis" "Bitis
$ZRO_TXT_DATETIME") || rc=$?
  [ "$rc" -eq 0 ] || return "$ZRO_E_CANCEL"

  # Cancel and a rejected value are told apart here as they are for an address:
  # the first returns the operator to the previous screen, the second re-offers
  # it. A malformed date is never repaired into a window nobody asked for.
  out=$(zro_win_explicit "$start" "$end") || rc=$?
  if [ "$rc" -ne 0 ]; then
    zro_ui_msgbox "Gecersiz girdi" \
"Tarih araligi okunamadi.

Bicim: YYYY-MM-DD SS:DD  (ornek: 2026-07-28 08:00)
Bitis, baslangictan once olamaz."
    return "$ZRO_E_INPUT"
  fi
  printf '%s' "$out"
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
    # The tool ran but could not read a log it was pointed at, or found none to
    # read at all. Either way NOTHING WAS SCANNED, which is not the same answer as
    # "no records" and must never be read as one. Naming the repair matters: the
    # usual cause is ownership on the syslog file, which breaks Zimbra's own
    # tooling too, so fixing it is the right outcome.
    "$ZRO_E_NO_LOG")
      zro_ui_msgbox "Log okunamiyor" \
"Mail logu okunamadi, bu nedenle hicbir sey taranamadi. Bu, kayit bulunamadi
demek DEGILDIR: secilen aralik hakkinda hicbir sey ogrenilemedi.

Secilen araligi kapsayan okunabilir bir log dosyasi yok. Log dosyalari zimbra
kullanicisi tarafindan okunabilir olmalidir. Izinler bozulmussa onarmak icin:
zmfixperms$detail" ;;
    # Not the delivery trace's path: that screen shows its partial scan rather than
    # reporting it, banner and all. This is here because code 30 means the same
    # thing wherever it comes from — an answer assembled from some of its sources —
    # and the bulk screens M6 brings will return it too. Whichever screen returns
    # it, it may not arrive as a bare number the operator has to look up.
    "$ZRO_E_PARTIAL")
      zro_ui_msgbox "Eksik sonuc" \
"Islem tamamlandi, ancak kaynaklarin bir kismi okunamadi; sonuc eksik.

Bir sey bulunamamasi, aranan seyin var olmadigini KANITLAMAZ.$detail" ;;
    # Carries the detail like every other failure here. A trace cut off after it had
    # already skipped a log file records that file as the detail, and a timeout
    # screen that dropped it would be the one path where a skipped file went
    # unmentioned.
    "$ZRO_E_TIMEOUT")    zro_ui_msgbox "Zaman asimi" "Komut zaman asimina ugradi.$detail" ;;
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
# The operator chooses an arrival window and the tool works out which log files it
# covers, so nobody has to know which rotated file holds yesterday or that the
# most recent one is already compressed. Both answering paths say what was
# searched and over what window: an operator who reads an empty answer as "it
# never arrived" goes on to make the wrong decision, and that ambiguity is the
# reason this screen exists at all.
zro_menu_delivery() {
  local choice addr window ws we out rc
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

    rc=0
    window=$(zro_prompt_window) || rc=$?
    if [ "$rc" -ne 0 ]; then
      # Cancel is navigation, and a rejected date has already been shown on its
      # own screen. Anything else would otherwise reach the operator as the menu
      # simply reappearing, which reads like the tool ignoring them.
      #
      # The clock is named rather than passed to the shared reporter, because the
      # only thing in that prompt which can be unavailable is the clock, and the
      # shared message for that code talks about the mailbox service.
      case $rc in
        "$ZRO_E_CANCEL"|"$ZRO_E_INPUT") ;;
        "$ZRO_E_UNAVAILABLE")
          zro_ui_msgbox "Saat okunamadi" \
"Sistem saati okunamadi, bu nedenle varis araligi hesaplanamadi.

'date' komutu bu sunucuda calismiyor olabilir." ;;
        *) zro_report_error "$rc" ;;
      esac
      continue
    fi
    ws=${window%%"$ZRO_TAB"*}
    we=${window#*"$ZRO_TAB"}

    # Reading a whole log takes seconds, and longer on a busy server — and a wide
    # window reads several files, one invocation each.
    zro_ui_notice "Calisiyor" "Mail loglari taraniyor, lutfen bekleyin.

Alici: $addr
Varis araligi: $(zro_win_human "$ws") - $(zro_win_human "$we")
Genis bir aralik birden fazla log dosyasi okur ve bu islemi uzatabilir."

    rc=0
    out=$(zro_trace_recipient "$addr" "$ws" "$we") || rc=$?

    # Answered here rather than by the shared reporter: "kayit bulunamadi" alone
    # would let an operator conclude the message never arrived, when what it
    # really means is that nothing arrived IN THIS WINDOW — and a message that
    # arrived before it and was delivered inside it is not in the answer.
    if [ "$rc" -eq "$ZRO_E_NO_RESULT" ]; then
      zro_ui_msgbox "Sonuc yok" \
"$addr icin bu varis araliginda teslim kaydi bulunamadi.

Aralik: $(zro_win_human "$ws") - $(zro_win_human "$we")

Aralik iletinin sunucuya varis zamanina gore uygulanir: aralik oncesinde varip
aralik icinde teslim edilen bir ileti bu sonuca girmez. Kayit bulunamamasi,
iletinin sunucuya hic ulasmadigini kanitlamaz — araligi genisletmeyi deneyin."
      continue
    fi
    # A PARTIAL SCAN IS AN ANSWER, not a failure, so it is shown rather than
    # reported. What makes it honest is that the disclosure travels with it in two
    # places: the banner the report carries at the top, and this title — whiptail
    # keeps a title on the box frame while the text scrolls, so it is the one part
    # of the screen a long trace cannot push out of view.
    if [ "$rc" -eq "$ZRO_E_PARTIAL" ]; then
      zro_show_text "Teslim izi - EKSIK TARAMA" "$out"
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
