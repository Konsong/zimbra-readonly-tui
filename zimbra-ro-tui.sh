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
# shellcheck source=lib/selection.sh
. "$ZRO_ROOT/lib/selection.sh"
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
# shellcheck source=lib/identity.sh
. "$ZRO_ROOT/lib/identity.sh"
# shellcheck source=lib/delivery.sh
. "$ZRO_ROOT/lib/delivery.sh"
# shellcheck source=lib/logview.sh
. "$ZRO_ROOT/lib/logview.sh"

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
  # Read into the session cache HERE, in this shell, where the assignment
  # survives: every screen that displays the version reads it inside command
  # substitution, and a cache filled in a subshell is a cache nobody has.
  zro_cap_reset
  if ! zro_cap_version_load; then
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
#   $4  what to offer already typed in, if anything
zro_prompt_address() {
  local title=$1 text=$2 invalid=$3 default=${4-} value rc=0
  value=$(zro_ui_input "$title" "$text" "$default") || rc=$?
  [ "$rc" -eq 0 ] || return "$ZRO_E_CANCEL"
  if ! zro_validate_email "$value"; then
    zro_ui_msgbox "Gecersiz girdi" "$invalid"
    return "$ZRO_E_INPUT"
  fi
  printf '%s' "$value"
}

# THE ONE THING THIS SCREEN HAS TO SAY. The tracer matches a message-id
# case-sensitively and the other two filters case-insensitively, so an operator
# who retypes an identifier in the wrong case is answered "no delivery record" —
# and on this screen an empty answer reads as proof the message never arrived.
# The warning belongs where it can still be acted on, which is before the typing
# rather than after the answer.
ZRO_TXT_MSGID='Ileti kimligi (ornek: CAabc123@example.com)

BUYUK/kucuk harf duyarlidir: kimligi geldigi yerden oldugu gibi kopyalayin.
Basliktaki <> parantezleri yazilabilir, arama sirasinda cikarilir.'

# Asks for a message-id, unwrapped and validated. Cancel and a rejected value are
# told apart exactly as they are for an address.
zro_prompt_msgid() {
  local value rc=0 id
  value=$(zro_ui_input "Ileti kimligi" "$ZRO_TXT_MSGID") || rc=$?
  [ "$rc" -eq 0 ] || return "$ZRO_E_CANCEL"
  # Unwrapped before it is judged, so that what is validated, what is shown on
  # the report and what is searched for are all the same value.
  id=$(zro_trace_msgid_bare "$value")
  if ! zro_validate_msgid "$id"; then
    zro_ui_msgbox "Gecersiz girdi" \
"Gecersiz ileti kimligi.

Kimlik tek parca olmalidir: bosluk, satir sonu ve kontrol karakteri
icermemelidir. Baslik satirini oldugu gibi degil, yalnizca kimligi yapistirin
(ornek: Message-ID: <CAabc123@example.com> icinden CAabc123@example.com)."
    return "$ZRO_E_INPUT"
  fi
  printf '%s' "$id"
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

# The identity fact and the repair it points at, written once. Both screens that
# report a log the account cannot read carry it: the trace's unavailability
# screen and the viewer's per-file one. They carried it in two wordings before
# this constant existed — one said "bu dosya", the other "Log dosyalari", one
# named ownership before permissions and the other after — which is how two
# screens end up recommending subtly different repairs for one cause.
#
# DOUBLE-QUOTED, like every other message here that names a Zimbra command. The
# static scanner strips double-quoted spans and reads what is left as code, so a
# single-quoted string naming zmfixperms would read as a call to it. There is
# nothing here for the shell to expand.
ZRO_TXT_LOG_UNREADABLE="Bu araci root ile baslatmis olsaniz bile her komut zimbra kullanicisi olarak
calisir; log dosyalari bu kullanici tarafindan okunabilir olmalidir.

Onarim: sahiplik veya izinler bozulmussa: zmfixperms"

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

# A defect in this program, said as one.
#
# NOT $ZRO_E_DENIED, which the reporter below renders as "this operation is not
# on the allowlist" — true of a command the exec gate refused, and a lie about a
# screen this file failed to wire up. An operator sent to check the allowlist for
# a dispatch table's mistake reads the wrong file and finds nothing wrong with
# it. Every caller logs the specifics first; this is what the operator sees.
zro_report_defect() {
  zro_ui_msgbox "Ic hata" \
"Bu islem calistirilamadi: aracin kendisinde bir hata var.

Zimbra'da veya bu sunucuda bir sorun oldugunu GOSTERMEZ ve hicbir sey
degistirilmedi. Ayrinti icin arac gunlugune bakin."
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
    # An address a module refused. It reaches here rather than through the
    # prompt's own rejection screen when a value got past selection — which makes
    # it a defect in this program as often as it is a mistyped address, so the
    # message says what to do about both. The Zimbra detail is deliberately left
    # off: nothing was run, so anything in that file belongs to an earlier screen
    # and would read as this one's explanation.
    "$ZRO_E_INPUT")
      zro_ui_msgbox "Gecersiz adres" \
"Bu islem icin secili adres gecerli bir e-posta adresi degil, bu nedenle
hicbir sorgu calistirilmadi.

Ana menuden adresi yeniden secin. Adres dogru gorunuyorsa arac gunlugune
bakin: adresi bu ekrana tasiyan yolda bir hata olabilir." ;;
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

# One directory question about the selected address. Nothing here asks for an
# address: the operator chose one before this screen was reached, it is on the
# frame of every box drawn below, and it is what the query is about.
#
# The result's title is the menu entry's own label, read back from the one list
# rather than written out a second time — an answer shown under a heading the
# operator did not choose is exactly the confusion the frame exists to prevent.
zro_screen_account() {
  local id=${1-} acct out rc=0 title
  if ! title=$(zro_menu_label "$id"); then
    zro_log error "menu defect, no label for account operation: $id"
    zro_report_defect
    return 0
  fi
  # An address-scoped screen reached with nothing selected is a defect in the
  # menu above. Refused here rather than passed on, because the modules judge an
  # empty address as invalid input and the operator would be shown a screen
  # about what they typed — on a screen where they typed nothing.
  # THE ACCOUNT, WHICH IS NOT ALWAYS THE ADDRESS. An alias answers every one of
  # these reads, but the answer is the account's — so it is the account this
  # screen asks about, and the note below says which address the operator chose.
  acct=$(zro_identity_selected_account)
  if [ -z "$acct" ]; then
    zro_log error "menu defect, account operation with no selected address: $id"
    zro_report_defect
    return 0
  fi

  # Each zmprov call starts a JVM and takes seconds, and these screens make more
  # than one: the card asks for the account, the class of service it names and
  # the lists it belongs to. Without this the terminal sits blank and looks
  # frozen for the whole of it.
  zro_ui_notice "Calisiyor" "Zimbra sorgulaniyor, lutfen bekleyin.

Hesap: $acct
Bu ekran birden fazla sorgu calistirir; her biri birkac saniye surebilir."

  case $id in
    account-card)       out=$(zro_account_card "$acct") || rc=$? ;;
    account-quota)      out=$(zro_account_quota "$acct") || rc=$? ;;
    account-membership) out=$(zro_account_membership "$acct") || rc=$? ;;
    # Declared in the one list and not answered here: a defect in this file, and
    # said out loud rather than swallowed. Without it $out would still hold the
    # PREVIOUS answer and the operator would read one question's result under
    # another's heading.
    *) zro_log error "menu defect, no account operation for: $id"
       zro_report_defect
       return 0 ;;
  esac

  if [ "$rc" -ne 0 ]; then
    zro_report_error "$rc"
    return 0
  fi
  zro_show_text "$title" "$(zro_screen_alias_note "$out")"
}

# An account screen's report, with the line an alias earns above it: the address
# the operator chose, and the account the answer below is about.
#
# ON ITS OWN FIRST LINE, above everything the report says. A card headed 'Hesap:
# ahmet.yilmaz@example.com' after an operator typed 'a.yilmaz@example.com' is
# correct and still reads as an answer about the wrong address — and the frame
# carries the alias, so without this the two would disagree with nobody saying why.
#
# THE REPORT IS PASSED IN rather than the note being returned to be glued on by
# the caller. A note printed on its own would end in the blank line that separates
# it, and command substitution eats trailing newlines — so the separation this
# note depends on would have been silently removed at every call site that built
# the string that way.
#
# Asked of how the address reached the entry rather than of what the entry is: a
# resource carrying an alias needs the same line, and nothing else does.
zro_screen_alias_note() {
  local body=${1-}
  if ! zro_identity_selected_aliased; then
    printf '%s' "$body"
    return 0
  fi
  printf '%s adresi bir alias; asagidaki bilgiler %s hesabina aittir.\n\n%s' \
    "$(zro_sel_address)" "$(zro_identity_selected_account)" "$body"
}

# Why a delivery trace cannot answer on this host, in terms that name the repair.
#
# ONE MESSAGE PER CAUSE, because the repairs have nothing in common: a binary this
# build does not ship is not something a permissions tool can fix, a log that is not
# there is not a mode, and a path this tool refuses to read is a setting. One message
# naming every cause would send most of its readers to the wrong place — and an
# operator who repairs the wrong thing concludes the tool is broken.
#
# WHICH cause it is comes from the capability module, in one word, and is not
# re-decided here. That is what keeps the mark on the menu entry and the explanation
# behind it from disagreeing.
#
# Unavailability is reported as a SCREEN rather than as an exit code. Every menu
# function here returns 0 to the loop above it, and the code for this condition —
# $ZRO_E_NOCAP — is what the exec gate returns when a command is reached anyway,
# which is the path that has a caller to report to. What the shared reporter would
# say for it is the bare 'this operation does not exist on this server' that this
# whole ticket exists to replace.
zro_delivery_unavailable() {
  # The file the operator has to go and look at. Named on every message below that
  # is about a file, because none of those causes can be repaired without knowing
  # which one it is.
  local path
  path=$(zro_inv_base_path syslog) || path="(bilinmiyor)"

  case $(zro_cap_trace_reason) in
    nobin)
      zro_delivery_unavailable_box \
"Takip programi (zmmsgtrace) bu kurulumda bulunamadi. Bu bir surum veya paketleme
farkidir; izinlerle ilgisi yoktur ve izin onarimi bunu duzeltmez.

Kontrol edin: zmmsgtrace programi libexec dizininde kurulu mu." ;;

    denied)
      zro_delivery_unavailable_box \
"Ana mail logunun yolu bu aracin okumayi kabul ettigi bicimde degil. Yol mutlak
olmali ve yalnizca [A-Za-z0-9._/-] karakterlerini icermelidir. Bu, sunucudaki bir
bozukluk degil, bir ayar hatasidir.

Yol: $path

Kontrol edin: ZRO_SYSLOG_FILE ayari." ;;

    missing)
      zro_delivery_unavailable_box \
"Ana mail logu bulunamadi. Bu bir izin sorunu DEGILDIR.

Beklenen dosya: $path

Iki olasilik var ve buradan ayirt edilemez: dosya hic yok, ya da bulundugu dizin
zimbra kullanicisi tarafindan acilamiyor.

Kontrol edin: syslog servisi calisiyor mu, Zimbra kayitlarini bu dosyaya yaziyor
mu, ve dosyanin dizini zimbra kullanicisi tarafindan gorulebiliyor mu." ;;

    *)
      zro_delivery_unavailable_box \
"Ana mail logu zimbra kullanicisi tarafindan okunamiyor, bu nedenle log
taranamaz. Yetki YUKSELTILMEZ, sorun bildirilir: ayni bozukluk Zimbra'nin
kendi araclarini da etkiler, dolayisiyla dogru sonuc onarmaktir.

Dosya: $path
Bu karar dosyanin sahipligi ve izin bitleri okunarak verilir; erisim listeleri
(ACL) hesaba katilmaz.

$ZRO_TXT_LOG_UNREADABLE" ;;
  esac
}

# The sentence every one of those messages opens with, written once. Each branch
# above says only what is true of its own cause; what they have in common is that
# the operator cannot trace on this host, and four copies of that line is four
# chances for one of them to say something slightly different.
zro_delivery_unavailable_box() {
  zro_ui_msgbox "Kullanilamaz" \
"Teslim takibi bu sunucuda kullanilamiyor.

${1-}"
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
zro_screen_trace() {
  local id=${1-} filter label subject window ws we out rc=0 note
  # REFUSED BEFORE THE FIRST PROMPT, not from inside a search. An operator who gets
  # this far has typed nothing yet, and the entry that brought them here is already
  # marked — this is where they learn why, and what repairs it.
  #
  # Asked here as well as by the menu that marked the entry, and both from the same
  # probe: the mark is what an operator sees first, and this is what makes it more
  # than a label. Neither is the last word either — the exec gate still refuses a
  # binary it cannot resolve and the trace still discloses a log it could not open.
  if ! zro_cap_trace_available; then
    zro_delivery_unavailable
    return 0
  fi

  # Which question was chosen, as the filter that asks it. Everything below this
  # point is the same for all three: the window, the wait, the report and every
  # failure. Two of them are about the SELECTED ADDRESS and ask for nothing; the
  # third is about an identifier, which is not an address and so is the one
  # question on this screen that still has something to type.
  case $id in
    trace-recipient) filter='--recipient'; subject=$(zro_sel_address) ;;
    trace-sender)    filter='--sender';    subject=$(zro_sel_address) ;;
    trace-msgid)     filter='--id';        subject=$(zro_prompt_msgid) || rc=$? ;;
    *) zro_log error "menu defect, no trace filter for: $id"
       zro_report_defect
       return 0 ;;
  esac
  # Cancel is navigation and a rejected identifier has had its own screen; both
  # return the operator to the menu they came from.
  [ "$rc" -eq 0 ] || return 0
  # An address-scoped screen reached with nothing selected is a defect in the
  # menu above, not something to search the whole log for.
  if [ -z "$subject" ]; then
    zro_log error "menu defect, trace with no selected address: $id"
    zro_report_defect
    return 0
  fi
  # A filter with no label is a defect in this file, not an operator error, so
  # it is logged and reported rather than swallowed — which would reach the
  # operator as the menu simply reappearing.
  if ! label=$(zro_trace_label "$filter"); then
    zro_log error "no label for delivery trace filter: $filter"
    zro_report_defect
    return 0
  fi

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
    return 0
  fi
  ws=${window%%"$ZRO_TAB"*}
  we=${window#*"$ZRO_TAB"}

  # Reading a whole log takes seconds, and longer on a busy server — and a wide
  # window reads several files, one invocation each.
  zro_ui_notice "Calisiyor" "Mail loglari taraniyor, lutfen bekleyin.

$label: $subject
Varis araligi: $(zro_win_human "$ws") - $(zro_win_human "$we")
Genis bir aralik birden fazla log dosyasi okur ve bu islemi uzatabilir."

  rc=0
  case $filter in
    --recipient) out=$(zro_trace_recipient "$subject" "$ws" "$we") || rc=$? ;;
    --sender)    out=$(zro_trace_sender "$subject" "$ws" "$we") || rc=$? ;;
    --id)        out=$(zro_trace_msgid "$subject" "$ws" "$we") || rc=$? ;;
    # Unreachable while the two lists above agree, and here so that they may
    # only disagree loudly: without it a filter added to the first list and
    # missed in this one would leave $out holding the PREVIOUS search's report
    # and $rc at zero, and the operator would be shown the last question's
    # answer under this question's label.
    *) zro_log error "no trace function for delivery filter: $filter"
       zro_report_defect
       return 0 ;;
  esac

  # Answered here rather than by the shared reporter: "kayit bulunamadi" alone
  # would let an operator conclude the message never arrived, when what it
  # really means is that nothing arrived IN THIS WINDOW — and a message that
  # arrived before it and was delivered inside it is not in the answer.
  if [ "$rc" -eq "$ZRO_E_NO_RESULT" ]; then
    # An empty answer to a message-id search has one more way of being wrong
    # than the other two do, and this is the screen where it can still be
    # acted on: the tracer matches this filter case-sensitively, so an
    # identifier retyped in the wrong case produces exactly this screen.
    note=''
    [ "$filter" = '--id' ] && note='
Ileti kimligi BUYUK/kucuk harf duyarli olarak aranir: kimligi geldigi yerden
oldugu gibi kopyaladiginizdan emin olun.'
    zro_ui_msgbox "Sonuc yok" \
"$subject icin bu varis araliginda teslim kaydi bulunamadi.

Aralik: $(zro_win_human "$ws") - $(zro_win_human "$we")

Aralik iletinin sunucuya varis zamanina gore uygulanir: aralik oncesinde varip
aralik icinde teslim edilen bir ileti bu sonuca girmez. Kayit bulunamamasi,
iletinin sunucuya hic ulasmadigini kanitlamaz — araligi genisletmeyi deneyin.$note"
    return 0
  fi
  # A PARTIAL SCAN IS AN ANSWER, not a failure, so it is shown rather than
  # reported. What makes it honest is that the disclosure travels with it in two
  # places: the banner the report carries at the top, and this title — whiptail
  # keeps a title on the box frame while the text scrolls, so it is the one part
  # of the screen a long trace cannot push out of view.
  if [ "$rc" -eq "$ZRO_E_PARTIAL" ]; then
    zro_show_text "Teslim izi - EKSIK TARAMA" "$out"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    zro_report_error "$rc"
    return 0
  fi
  zro_show_text "Teslim izi" "$out"
}

# What both viewer screens have to say, and the reason the whole screen is safe
# to offer: it reads, and the bound is not a detail of the implementation but
# what the operator is being shown.
ZRO_TXT_LOGVIEW='Log dosyalarinin SON satirlari gosterilir. Dosyalar okunur;
degistirilmez, silinmez, sikistirilmis bir dosya yerinde acilmaz.

Hangi logu goruntulemek istiyorsunuz?'

ZRO_TXT_LOGVIEW_FILE='En yeni dosya en ustte. Tarih, dosyanin SON YAZILMA
zamanidir: rotasyon sabaha karsi calistigi icin bir dosya cogunlukla kendi
tarihinden onceki gunun satirlarini tutar.

Dosya secin:'

# The bounded log viewer: the last lines of one file from the log inventory.
#
# THE OPERATOR NEVER TYPES A PATH. This screen offers the declared logs by name,
# the next one offers that log's files by position, and a position is what comes
# back. That is what keeps a glob, a symbolic link or an oddly named neighbour
# from turning a log viewer into a general-purpose file reader — and the module
# refuses a path the inventory does not list even so, so neither check rests on
# the other.
#
# Offered whether or not a delivery trace can run on this host. The two read the
# same files, but the trace needs the tracing binary and the primary mail log,
# while this screen can still show mailbox.log on a host that has neither. Marking
# it with the trace's probe would hide a screen that works.
zro_menu_logview() {
  local choice rc key label
  local -a items=()
  while :; do
    items=()
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      # A declared log with no label would reach the operator as a menu entry
      # with no name, so it is left out and said out loud. The suite holds the
      # two sets equal, which is where this is really prevented.
      if ! label=$(zro_logview_label "$key"); then
        zro_log error "no label for declared log: $key"
        continue
      fi
      items+=("$key" "$label")
    done <<EOF
$(zro_inv_keys)
EOF
    if [ "${#items[@]}" -eq 0 ]; then
      zro_log error "no log is both declared and named; the viewer has nothing to offer"
      zro_ui_msgbox "Kullanilamaz" "Goruntulenebilecek log tanimli degil."
      return 0
    fi

    rc=0
    choice=$(zro_ui_menu "Log dosyalari" "$ZRO_TXT_LOGVIEW" "${items[@]}") || rc=$?
    [ "$rc" -eq 0 ] || return 0
    # Judged against the list this program itself drew. Nothing else may name a
    # log, so a value that is not one of those entries is a defect rather than a
    # log nobody declared.
    if ! zro_logview_label "$choice" >/dev/null 2>&1; then
      zro_log error "not a declared log: $choice"
      continue
    fi
    zro_menu_logview_file "$choice"
  done
}

# One log's files, and the last lines of whichever one is chosen.
#
# The list is rebuilt on every pass, so a rotation that happened while the
# operator was reading is visible when they come back rather than leaving them
# pointed at a file that has just been renamed.
zro_menu_logview_file() {
  local key=${1-} files rc choice out detail line mtime path i
  local -a paths items
  while :; do
    rc=0
    files=$(zro_logview_files "$key") || rc=$?
    if [ "$rc" -ne 0 ]; then
      # A name the inventory does not declare or a root that fails admission:
      # both are defects in this program or in an override, already logged where
      # they were found.
      zro_report_error "$rc"
      return 0
    fi
    if [ -z "$files" ]; then
      # ORDINARY, not a failure: a host that does not write this log has none of
      # its files. Said as its own screen because an empty list must never be
      # read as an empty file — one says nothing was written, the other says
      # nothing is there to read.
      zro_ui_msgbox "Bulunamadi" \
"Bu log bu sunucuda bulunamadi: $(zro_inv_base_path "$key")

Dosya hic yok olabilir, ya da bulundugu dizin zimbra kullanicisi tarafindan
acilamiyor olabilir. Bu ikisi buradan ayirt edilemez.

Bu, log bos demek DEGILDIR."
      return 0
    fi

    paths=(); items=(); i=0
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      mtime=${line%%"$ZRO_TAB"*}
      path=${line#*"$ZRO_TAB"}
      i=$((i + 1))
      paths+=("$path")
      items+=("$i" "$(zro_logview_file_label "$mtime" "$path")")
    done <<EOF
$files
EOF

    rc=0
    choice=$(zro_ui_menu "$(zro_logview_label "$key")" "$ZRO_TXT_LOGVIEW_FILE" \
      "${items[@]}") || rc=$?
    [ "$rc" -eq 0 ] || return 0

    # A POSITION IN THE LIST, NEVER A PATH. This is the line that keeps the
    # viewer bounded to the inventory: whatever comes back is looked up in the
    # list this program drew, so a value that is not one of those positions names
    # nothing at all and is refused rather than read.
    case $choice in
      ''|*[!0-9]*)
        zro_log error "denied, not a position in the log file list: $choice"
        continue ;;
    esac
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#paths[@]}" ]; then
      zro_log error "denied, position outside the log file list: $choice"
      continue
    fi
    path=${paths[choice - 1]}

    # A compressed file is decompressed whole before its last lines can be, and
    # a rotated mail log is large. Without this the terminal sits blank.
    zro_ui_notice "Calisiyor" "Log okunuyor, lutfen bekleyin.

Dosya: $path
Sikistirilmis bir dosya bastan sona acilir; bu islem birkac saniye surebilir."

    rc=0
    out=$(zro_logview_read "$key" "$path") || rc=$?

    if [ "$rc" -eq "$ZRO_E_NO_RESULT" ]; then
      # Not the shared reporter's "kayit bulunamadi": nothing was searched for
      # here. The file has no lines, which is a fact about the file and not an
      # answer about anything an operator was looking for.
      zro_ui_msgbox "Dosya bos" \
"Bu dosyada hic satir yok:
$path

Bu, aradiginiz kaydin olusmadigini gostermez; yalnizca bu dosyanin bos
oldugunu gosterir. Ayni logun daha eski dosyalarini deneyin."
      continue
    fi
    if [ "$rc" -eq "$ZRO_E_NO_LOG" ]; then
      # Named file by file rather than through the shared reporter, whose message
      # for this code is about the arrival window a trace selected — a window
      # nobody chose on this screen.
      detail=$(zro_last_error)
      [ -n "$detail" ] && detail="

Sistemin bildirdigi:
$detail"
      zro_ui_msgbox "Log okunamadi" \
"Bu dosya okunamadi:
$path

$ZRO_TXT_LOG_UNREADABLE$detail"
      continue
    fi
    if [ "$rc" -eq "$ZRO_E_TIMEOUT" ]; then
      # Named here rather than left to the shared reporter, which says only that
      # a command timed out. On this screen there is one cause worth naming: the
      # end of a compressed file cannot be reached without decompressing all of
      # it, so a very large rotated log can run out the clock. The bound protects
      # memory; this is what protects the terminal.
      zro_ui_msgbox "Zaman asimi" \
"Bu dosya ayrilan surede okunamadi:
$path

Sikistirilmis bir dosyanin son satirlarina ulasmak icin dosya bastan sona
acilir; cok buyuk bir dosyada bu sure yetmeyebilir.

Islem kesildi ve dosyaya DOKUNULMADI. Gerekirse ZRO_TIMEOUT degerini
yukseltip yeniden deneyin."
      continue
    fi
    if [ "$rc" -ne 0 ]; then
      zro_report_error "$rc"
      continue
    fi
    # The file's own name on the frame: whiptail keeps a title while the text
    # scrolls, so an operator who has scrolled past the header can still see
    # which file they are reading.
    zro_show_text "Log: ${path##*/}" "$out"
  done
}

# THE ONE LIST: every operation this tool offers, in the order it offers them, as
# "<id>:<scope>:<label>".
#
# One list rather than a tree of category menus, because the question an operator
# arrives with is about an address and not about a category — and a tree makes
# them answer "which kind of question is this" before they may ask it. The
# ADDRESS-SCOPED operations come first and the server-wide ones after, so the
# order says which is which without a heading whiptail has no way to draw.
#
# The ID is what comes back from the menu: it is a fixed identifier this program
# wrote, never operator text, and it is what the dispatch below reads. The SCOPE
# is what decides whether an address is asked for before the operation runs. The
# LABEL is what the operator reads, here and again as the title over the result,
# so those two cannot drift apart. A label may contain a colon; only the first
# two are separators.
# THREE SCOPES, not two. 'account' needs the selected address to BE an account —
# an account read on a distribution list fails with "no such account", which is
# true and useless. 'address' needs an address of any kind: mail to a list shows
# up in the transfer agent's log under the list's own address, so a trace answers
# there exactly as it does for a mailbox. 'server' needs none.
#
# The distinction is what makes the identity worth resolving. Without it the two
# kinds would share one mark, and marking a trace unavailable on a list address
# would take away the one screen that still answers.
ZRO_MENU_OPS='account-card:account:Hesap karti
account-quota:account:Kota kullanimi
account-membership:account:Dagitim listesi uyelikleri
trace-recipient:address:Teslim takibi: bu adrese gelenler
trace-sender:address:Teslim takibi: bu adresten gidenler
trace-msgid:server:Teslim takibi: ileti kimligine gore
logview:server:Log dosyalari (son satirlar)'

# The declared entry for an id, or a refusal. Every lookup below goes through
# this, so an id that is not in the list has exactly one answer everywhere.
zro_menu_entry() {
  local id=${1-} entry
  [ -n "$id" ] || return "$ZRO_E_INPUT"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ "${entry%%:*}" = "$id" ]; then
      printf '%s' "$entry"
      return 0
    fi
  done <<EOF
$ZRO_MENU_OPS
EOF
  return "$ZRO_E_INPUT"
}

# The declared ids, in the order they are offered.
zro_menu_ids() {
  local entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    printf '%s\n' "${entry%%:*}"
  done <<EOF
$ZRO_MENU_OPS
EOF
}

zro_menu_scope() {
  local entry
  entry=$(zro_menu_entry "${1-}") || return "$ZRO_E_INPUT"
  entry=${entry#*:}
  printf '%s' "${entry%%:*}"
}

zro_menu_label() {
  local entry
  entry=$(zro_menu_entry "${1-}") || return "$ZRO_E_INPUT"
  entry=${entry#*:}
  printf '%s' "${entry#*:}"
}

# WHY an operation cannot answer, in one word, or nothing when it can. Decided in
# ONE place so that the mark on the entry, the refusal before dispatch and the
# screen that explains it cannot disagree. It is never a safety check — the exec
# gate refuses on its own terms — it is what keeps an operator from spending a
# search to discover something already known.
#
# TWO REASONS, and they are about different things. 'nocap' is a fact about this
# host: a binary this build does not ship, a log nothing can read. 'notaccount'
# is a fact about the selected address: it resolved to something an account read
# cannot answer for. A host fact outranks an address fact, because it holds
# whatever address is chosen next.
#
# An identity nobody could establish refuses NOTHING. A resolution that failed
# means this program does not know what the address is, and marking an entry from
# that would be reporting ignorance as a fact about the server.
#
# THE ANSWER COMES BACK IN A GLOBAL, not on stdout, and that is not a style
# choice. This asks the capability module, whose probes fill a session cache —
# and an assignment made inside $( ) dies with the subshell, which is the exact
# bug lib/capability.sh records having already been fixed once. A caller that
# read this through a command substitution would re-probe the host for every
# entry of every redraw. Bash 4.2 has no namerefs, so a global is how a value
# comes back from a function that must run in its caller's shell, the same way
# ZRO_UI_ARGV does.
ZRO_MENU_REASON=""

zro_menu_refusal() {
  local id=${1-}
  ZRO_MENU_REASON=""
  case $id in
    trace-*) zro_cap_trace_available || { ZRO_MENU_REASON=nocap; return 0; } ;;
  esac
  if [ "$(zro_menu_scope "$id" 2>/dev/null)" = account ]; then
    case $(zro_identity_selected_kind) in
      list|absent) ZRO_MENU_REASON=notaccount ;;
    esac
  fi
  return 0
}

# What the entry says about itself before it is chosen. whiptail has no notion of
# a disabled entry, so the label carries the reason — and a different one per
# reason, because 'unavailable' on an operation that works perfectly for the next
# address would read as a broken tool rather than as a wrong question.
zro_menu_mark() {
  case ${1-} in
    nocap)      printf ' - KULLANILAMAZ' ;;
    notaccount) printf ' - BU ADRES HESAP DEGIL' ;;
  esac
  return 0
}

# Why it cannot, in terms that name the repair. Each cause its own screen,
# because a cause an operator would repair the same way as another does not earn
# a message of its own — and one message naming every cause would send most of
# its readers to the wrong place.
#
# The reason comes from the one decision above rather than being worked out
# again, so the only way to arrive here without a screen is for this case list to
# have fallen behind it — which is a defect in this file, and is said as one
# rather than papered over with a message about this server.
zro_menu_unavailable() {
  case ${2-} in
    nocap)      zro_delivery_unavailable ;;
    notaccount) zro_screen_identity ;;
    *) zro_log error "menu defect, no unavailability screen for: ${1-} (${2-})"
       zro_report_defect ;;
  esac
}

ZRO_TXT_SELECT='Uzerinde calisilacak adres:

Secilen adres her ekranin basliginda gorunur, ve degistirilene kadar butun hesap
islemleri bu adres hakkindadir.'

# The first entry. It says which of the two things it is — there is nothing
# selected yet, or there is and this changes it — because an operator who has to
# select an address before anything works should not have to infer that from a
# title that is still empty.
zro_menu_select_label() {
  zro_sel_have || { printf 'Adres sec'; return 0; }
  printf 'Adresi degistir'
}

# Asks for the address the session is about. The only screen in this program that
# asks for one: everything else reads what this set. What is already selected is
# offered typed in, so changing one address for the next is an edit rather than a
# retyping — and comparing two accounts is a keystroke rather than a restart.
#
# The address is then RESOLVED, before any screen has a chance to assume it is an
# account. That is the one moment in a session where the question "what is this
# address" is worth up to two invocations: asked here it is asked once, and every
# screen after it either works or says why in terms of what the address really is.
zro_menu_select() {
  local addr rc=0
  addr=$(zro_prompt_address "Adres" "$ZRO_TXT_SELECT" \
    "Gecersiz adres. Ornek: ad.soyad@example.com" "$(zro_sel_address)") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  zro_sel_set "$addr" || return "$ZRO_E_INPUT"
  zro_screen_identity_resolve
}

# Resolves the selected address and shows what it turned out to be.
#
# ALWAYS SHOWN, including for the ordinary account. A screen drawn only when the
# answer is surprising is a screen nobody learns to read, and the account case is
# not nothing either: it is where a mistyped address is caught, one keystroke
# after it was typed, instead of two invocations into a card.
#
# A resolution that could not run leaves the address selected and the identity
# unanswered. The address validated; only the question about it failed, and every
# screen behind the menu still refuses on its own terms. What must not happen is
# the failure being read as an answer — so the error screen is the shared one for
# whatever actually went wrong, and nothing is marked from it.
zro_screen_identity_resolve() {
  local rec rc=0
  zro_ui_notice "Calisiyor" "Adres dizinde araniyor, lutfen bekleyin.

Adres: $(zro_sel_address)
Bu adresin hesap mi, alias mi, liste mi oldugu sorgulaniyor."

  rec=$(zro_identity_resolve "$(zro_sel_address)") || rc=$?
  if [ "$rc" -ne 0 ]; then
    zro_report_error "$rc"
    return 0
  fi
  zro_sel_set_identity "$rec"
  zro_screen_identity
}

# What the selected address is, drawn from what the session already learned.
#
# NOTHING IS RE-QUERIED HERE. It is reached twice — once after a resolution, and
# again when an account operation is chosen for an address that is not an account
# — and the second of those is a refusal, where spending two more invocations to
# repeat an answer already in hand would be the tool charging for its own mistake.
zro_screen_identity() {
  local rec out
  rec=$(zro_sel_identity)
  if ! zro_sel_have_identity; then
    # Only reachable if the menu offered this without an answer to show, which
    # is a wiring defect rather than anything about the address.
    zro_log error "menu defect, identity screen with no resolved identity"
    zro_report_defect
    return 0
  fi
  if ! out=$(zro_identity_card "$rec"); then
    zro_log error "identity defect, no card for record: $rec"
    zro_report_defect
    return 0
  fi
  zro_show_text "Adres kimligi" "$out"
}

# An account-scoped operation chosen with nothing selected asks for the address
# and then CONTINUES TO THAT OPERATION. Returning to the menu to have it chosen a
# second time would be the tool making the operator repeat themselves, which is
# the whole thing the selected address exists to stop.
zro_menu_need_address() {
  zro_sel_have && return 0
  zro_menu_select
}

zro_menu_main() {
  local choice rc id label scope
  local -a items
  # Asked once, here, for the same reason the probes below are: this loop is
  # returned to after every operation, and a version re-read inside the command
  # substitution that displays it would be a JVM start per screen.
  zro_cap_version_load || true
  while :; do
    # Rebuilt on every pass: the first entry's label changes with the selection,
    # and a mark reads the session's capability cache.
    items=(select "$(zro_menu_select_label)")
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      # Read back through the same accessor every other reader uses, rather than
      # taken apart a second time here: one parser for the declaration means the
      # entry an operator picks and the title over their answer are one string.
      label=$(zro_menu_label "$id")
      # The entry says so BEFORE it is selected, which is the whole point: an
      # operator who learns that tracing is unavailable after choosing an address
      # and a window has already spent the search this mark exists to save.
      # whiptail has no notion of a disabled entry, so the label carries it and
      # the screen behind it explains why.
      #
      # Asked here rather than inside the command substitution below, so the
      # probes run in this shell and the session cache they fill is the one the
      # screen behind the entry reads. Inside $( ) every redraw would ask the
      # host again.
      zro_menu_refusal "$id"
      label="$label$(zro_menu_mark "$ZRO_MENU_REASON")"
      items+=("$id" "$label")
    done <<EOF
$(zro_menu_ids)
EOF
    items+=(quit "Cikis")

    rc=0
    choice=$(zro_ui_menu "Ana menu" "Zimbra: $(zro_cap_version)" "${items[@]}") || rc=$?
    # The one screen where leaving is leaving: there is no previous screen to
    # return to. Every other screen in this program returns here instead.
    [ "$rc" -eq 0 ] || return 0

    case $choice in
      select) zro_menu_select; continue ;;
      quit) return 0 ;;
    esac

    # Judged against the list this program itself drew. Nothing else may name an
    # operation, so a value that is not one of those ids is a defect rather than
    # an operation nobody declared.
    if ! scope=$(zro_menu_scope "$choice"); then
      zro_log error "not a declared operation: $choice"
      continue
    fi
    # A HOST FACT FIRST, before the operator is asked for anything. Whether this
    # build ships the tracer holds for every address, so learning it after an
    # address has been chosen and a window answered would be the mark on the entry
    # arriving too late to save the work it exists to save.
    zro_menu_refusal "$choice"
    if [ "$ZRO_MENU_REASON" = nocap ]; then
      zro_menu_unavailable "$choice" "$ZRO_MENU_REASON"
      continue
    fi
    # Before the operation, not inside it: an operation that asked for the
    # address itself would be an operation that could forget to.
    if [ "$scope" != server ]; then
      zro_menu_need_address || continue
    fi
    # ASKED AGAIN, because the answer can only exist now. Whether this address is
    # an account is not knowable until there is an address, and the prompt above
    # is where a session with none acquires one — together with its identity. An
    # account read dispatched here on a distribution list would fail with "no such
    # account", which is the one sentence this whole path exists to stop.
    zro_menu_refusal "$choice"
    if [ -n "$ZRO_MENU_REASON" ]; then
      zro_menu_unavailable "$choice" "$ZRO_MENU_REASON"
      continue
    fi

    case $choice in
      account-*) zro_screen_account "$choice" ;;
      trace-*)   zro_screen_trace "$choice" ;;
      logview)   zro_menu_logview ;;
      # Declared in the list above and dispatched nowhere: a defect in this file.
      # Silently redrawing the menu would reach the operator as the tool ignoring
      # them, which is how a missing branch survives a release.
      *) zro_log error "menu defect, no operation for entry: $choice"
         zro_report_defect ;;
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
