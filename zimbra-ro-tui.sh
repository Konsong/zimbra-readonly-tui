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
# shellcheck source=lib/table.sh
. "$ZRO_ROOT/lib/table.sh"
# shellcheck source=lib/validate.sh
. "$ZRO_ROOT/lib/validate.sh"
# shellcheck source=lib/selection.sh
. "$ZRO_ROOT/lib/selection.sh"
# shellcheck source=lib/exec.sh
. "$ZRO_ROOT/lib/exec.sh"
# shellcheck source=lib/settle.sh
. "$ZRO_ROOT/lib/settle.sh"
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
# shellcheck source=lib/mailset.sh
. "$ZRO_ROOT/lib/mailset.sh"
# shellcheck source=lib/bulk.sh
. "$ZRO_ROOT/lib/bulk.sh"
# shellcheck source=lib/mailbox.sh
. "$ZRO_ROOT/lib/mailbox.sh"
# shellcheck source=lib/store.sh
. "$ZRO_ROOT/lib/store.sh"
# shellcheck source=lib/search.sh
. "$ZRO_ROOT/lib/search.sh"
# shellcheck source=lib/message.sh
. "$ZRO_ROOT/lib/message.sh"
# shellcheck source=lib/identity.sh
. "$ZRO_ROOT/lib/identity.sh"
# shellcheck source=lib/directory.sh
. "$ZRO_ROOT/lib/directory.sh"
# shellcheck source=lib/delivery.sh
. "$ZRO_ROOT/lib/delivery.sh"
# shellcheck source=lib/logview.sh
. "$ZRO_ROOT/lib/logview.sh"
# shellcheck source=lib/logsearch.sh
. "$ZRO_ROOT/lib/logsearch.sh"
# shellcheck source=lib/queue.sh
. "$ZRO_ROOT/lib/queue.sh"
# shellcheck source=lib/service.sh
. "$ZRO_ROOT/lib/service.sh"

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
  # AND THE PROOFS THE EXISTENCE GATE KEEPS, for a reason the capability cache
  # does not have. That one lives in variables, so a new process starts with it
  # empty; this one lives in a file whose name carries a process id, and process
  # ids are reused. A session that inherited a file left behind by an earlier run
  # would start believing a mailbox exists on the strength of a proof nobody in
  # this session obtained — which is the one direction this gate may never fail
  # in. Emptied here rather than trusted to be absent.
  zro_mbox_forget
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
# SC2034: read by NAME through lib/table.sh, never expanded here.
# shellcheck disable=SC2034
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
#
# The explanatory text is an argument because two screens ask this question about
# two different things. On a delivery trace the window is compared against when a
# message ARRIVED, by a tracer that reads timestamps. On a log search it selects
# FILES and nothing else, and the files are then read whole — so the same prompt
# would tell one of the two screens' operators something untrue about their own
# answer. The trace's wording stays the default, because it was here first and
# every existing caller means it.
zro_prompt_window() {
  local text=${1:-$ZRO_TXT_ARRIVAL} choice rc=0 now day_start id
  local -a items=()
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    items+=("$id" "$(zro_table_rest ZRO_WINDOW_CHOICES "$id" 1)")
  done <<EOF
$(zro_table_keys ZRO_WINDOW_CHOICES)
EOF

  choice=$(zro_ui_menu "Varis araligi" "$text" "${items[@]}") || rc=$?
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

# WHAT THE UNDERLYING COMMAND SAID, as the block a screen hangs under its own
# explanation — or nothing at all when it said nothing.
#
#   $1  the heading the block is introduced by
#
# ONE PLACE, because seven screens append it and each of them appended it by
# copying the last one. The heading is the caller's, because what said it differs:
# 'Zimbra ciktisi' is a Zimbra command's own words, and a log this program could
# not open is the system's.
zro_error_detail() {
  local heading=${1-} detail
  detail=$(zro_last_error)
  [ -n "$detail" ] || return 0
  printf '

%s:
%s' "$heading" "$detail"
}

zro_report_error() {
  # Whatever Zimbra actually said, when it said anything. Without this the
  # operator sees a bare code and has to reproduce the command by hand to learn
  # that, say, mailboxd is stopped.
  local detail
  detail=$(zro_error_detail 'Zimbra ciktisi')

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
    # AN ANSWER, and one that ends the search rather than continuing it: mail for
    # an address in a domain this server does not host was never going to arrive
    # here. Its own screen rather than "kayit bulunamadi", which on a domain reads
    # as a query that found nothing to say.
    "$ZRO_E_NO_DOMAIN")
      zro_ui_msgbox "Alan adi bulunamadi" \
"Bu alan adi bu sunucuda tanimli degil.

Sorgu calisti ve yanit verdi: bu sunucu bu alan adinin postasini tasimiyor.
Secili adres bu alan adindaysa, adres yanlis yazilmis olabilir ya da posta
baska bir sunucuya gidiyordur.$detail" ;;
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

# WHAT A SCREEN WILL SPEND, SAID BEFORE IT SPENDS IT.
#
# Most of these screens cost what their answer turns out to name — the class of
# service an account points at, the lists it belongs to — so the honest thing to
# tell an operator beforehand is that there is more than one query and each takes
# seconds. The provenance screen is the one that can be exact: two reads of the
# same entry, always, whatever the account turns out to hold.
#
# It is said in ITS OWN SENTENCE rather than folded into the general one because
# it is the reason that screen exists apart from the card at all. An operator who
# reads "this runs the account read twice" and decides the question is not worth
# the wait has been told the thing the ticket for this screen was about.
zro_account_cost_note() {
  case ${1-} in
    account-provenance)
      printf 'Bu ekran hesap kaydini IKI KEZ okur: once yalnizca hesapta tanimli\n'
      printf 'olanlari, sonra yururlukteki degerleri. Her sorgu birkac saniye surer.' ;;
    # THE THIRD READ IS NAMED because it is not a field the first one could have
    # carried: a signature and a send-as identity are child entries in the
    # directory rather than attributes of the account. An operator told 'several
    # queries' would not know why one screen about one account costs three.
    account-mailsettings)
      printf 'Bu ekran hesabi UC KEZ okur: hesap kaydini, imzalarini ve gonderim\n'
      printf 'kimliklerini. Son ikisi dizinde ayri kayitlardir. Mailboxa bakilmaz.' ;;
    account-filters)
      printf 'Bu ekran hesap kaydini BIR KEZ okur ve mailboxa bakmaz.' ;;
    *)
      printf 'Bu ekran birden fazla sorgu calistirir; her biri birkac saniye surebilir.' ;;
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
$(zro_account_cost_note "$id")"

  case $id in
    account-card)         out=$(zro_account_card "$acct") || rc=$? ;;
    account-provenance)   out=$(zro_account_provenance "$acct") || rc=$? ;;
    account-membership)   out=$(zro_account_membership "$acct") || rc=$? ;;
    account-mailsettings) out=$(zro_mailset_card "$acct") || rc=$? ;;
    account-filters)      out=$(zro_mailset_filters_card "$acct") || rc=$? ;;
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

# THE EXISTENCE GATE AS A SCREEN: whether the selected account has a mailbox.
#
# The first operation in this tool that asks about anything other than the
# directory, and the precondition every later mailbox screen is built on. It is
# offered on its own for two reasons. The answer is one an operator wants for its
# own sake — "this user says their mail has vanished" ends in a different place for
# an account that has never had a mailbox than for one whose mailbox is empty — and
# a gate whose answer can be read is a gate an operator can reasonably trust.
#
# THE ACCOUNT, NOT THE ADDRESS, exactly as the directory screens do it: an alias
# answers, and the answer is the account's.
zro_screen_mailbox() {
  local id=${1-} acct out rc=0 title
  if ! title=$(zro_menu_label "$id"); then
    zro_log error "menu defect, no label for mailbox operation: $id"
    zro_report_defect
    return 0
  fi
  acct=$(zro_identity_selected_account)
  if [ -z "$acct" ]; then
    zro_log error "menu defect, mailbox operation with no selected address: $id"
    zro_report_defect
    return 0
  fi

  zro_ui_notice "Calisiyor" "Zimbra sorgulaniyor, lutfen bekleyin.

Hesap: $acct
$(zro_mailbox_cost_note "$id")"

  case $id in
    mailbox-status)  out=$(zro_mbox_card "$acct") || rc=$? ;;
    mailbox-quota)   out=$(zro_store_quota_card "$acct") || rc=$? ;;
    mailbox-size)    out=$(zro_store_size_card "$acct") || rc=$? ;;
    mailbox-folders) out=$(zro_store_folders_card "$acct") || rc=$? ;;
    # Declared in the one list and not answered here: a defect in this file, and
    # said out loud rather than swallowed. The dispatch above routes every id
    # beginning `mailbox-` here, so a screen declared and not wired up would
    # otherwise be drawn as the one above it, under its own label — and $out would
    # still hold the previous answer. An answer shown under a heading the operator
    # did not choose is the confusion the frame exists to prevent.
    *) zro_log error "menu defect, no mailbox operation for: $id"
       zro_report_defect
       return 0 ;;
  esac

  zro_mailbox_report "$rc" "$acct" "$title" && return 0
  zro_show_text "$title" "$(zro_screen_alias_note "$out")"
}

# WHAT A SCREEN BEHIND THE GATE DOES WITH A REFUSAL, decided once for all of them.
#
#   $1  the code the operation returned      $2  the account it was about
#   $3  the title of the screen the operator chose
#
# Succeeds when it has drawn something, so a caller returns on success and carries
# on with its own report otherwise.
#
# TWO OF THESE ARE NOT FAILURES AT ALL. An account with no mailbox and an address
# that is no account are ANSWERS — the gate ran, it was told something definite,
# and the operation it stopped was never going to add to it. Reported through the
# shared failure box they would read 'Mailbox bulunamadi', which is the sentence
# this whole design exists to replace: a mailbox is created on first login or first
# delivery, so an account without one is one nobody has used. The gate's own screen
# says exactly that, and it is drawn here from the verdict already in hand rather
# than by asking a second time.
#
# THE SILENT GATE IS THE THIRD, and is told apart from an ordinary outage. The
# shared reporter would say the query could not be run, which is true and is not
# what an operator needs: what they need is that no mailbox question can be
# answered until the service returns, and that this costs them nothing they could
# otherwise have had.
zro_mailbox_report() {
  local rc=${1-0} acct=${2-} title=${3-}
  case $rc in
    0) return 1 ;;
    "$ZRO_E_NO_MAILBOX")
      zro_show_text "$title" \
        "$(zro_screen_alias_note "$(zro_mbox_verdict_card "$acct" nomailbox)")" ;;
    "$ZRO_E_NO_ACCOUNT")
      zro_show_text "$title" \
        "$(zro_screen_alias_note "$(zro_mbox_verdict_card "$acct" noaccount)")" ;;
    "$ZRO_E_UNAVAILABLE") zro_mailbox_silent_gate ;;
    *) zro_report_error "$rc" ;;
  esac
  return 0
}

# What a mailbox screen will spend, said before it spends it.
#
# THE GATE'S OWN SENTENCE IS NOT THE OTHERS', and the difference is the point of
# saying anything. The existence screen reads one index statistic and nothing
# else, and costs NOTHING at all for an account this session has already proven —
# the only exact zero in the tool.
#
# EVERY SCREEN BEHIND IT PAYS THAT GATE FIRST, and says so, because a screen that
# promised two queries and made three would be understating the one cost this
# program can be exact about. It is paid once per account per session, so the
# second screen an operator opens about the same account does not pay it again.
ZRO_TXT_GATE_COST='Bu hesabin mailboxu bu oturumda ilk kez soruluyorsa kapi bir sorgu daha ekler;
daha once soruldiysa eklemez.'

zro_mailbox_cost_note() {
  case ${1-} in
    mailbox-status)
      printf 'Bu ekran mailbox dizin istatistigini BIR KEZ okur ve mailboxun icine\n'
      printf 'bakmaz. Bu oturumda daha once yanitlanmis bir hesap icin hic sorgu\n'
      printf 'calismaz.' ;;
    mailbox-folder|mailbox-folder-grants)
      printf 'Bu ekran once klasor listesini, sonra sectiginiz klasoru okur: iki\n'
      printf 'sorgu. %s' "$ZRO_TXT_GATE_COST" ;;
    mailbox-quota)
      # THE COS READ IS NAMED because it is a third invocation this screen cannot
      # predict: an account whose limit is inherited costs one more than an
      # account carrying its own, and which of the two it is is what the screen
      # went to find out.
      printf 'Bu ekran mailbox boyutunu ve hesap kaydini okur: iki sorgu.\n'
      printf 'Kullanim mailboxtan, limit dizinden gelir; limit COS kaydindan\n'
      printf 'devralinmissa bir sorgu daha. %s' "$ZRO_TXT_GATE_COST" ;;
    mailbox-size|mailbox-folders)
      printf 'Bu ekran mailboxun icini BIR KEZ okur. %s' "$ZRO_TXT_GATE_COST" ;;
    # THE SEARCH IS ONE INVOCATION HOWEVER MANY CRITERIA IT CARRIES: the criteria
    # are one query, and the query is one command. What grows with the number of
    # criteria is the narrowness of the answer, not the cost of asking.
    mailbox-search)
      printf 'Bu ekran, olcutler kac tane olursa olsun, mailboxta BIR arama\n'
      printf 'calistirir: bir sorgu. Her yeni arama bir sorgu daha. %s' "$ZRO_TXT_GATE_COST" ;;
    mailbox-conversation)
      printf 'Bu ekran once bir arama calistirir, sonra actiginiz her konusma icin\n'
      printf 'bir sorgu daha yapar. %s' "$ZRO_TXT_GATE_COST" ;;
    # THE ONE MAILBOX SCREEN THAT DOES NOT PAY THE GATE, and it says so where every
    # other one says the opposite. It opens no mailbox session at all: the record
    # comes from the database directly and the headers from the file on disk, so the
    # existence oracle has nothing to add — an account whose mailbox was never
    # created has no row to dump, and the dump says so itself.
    mailbox-message)
      printf 'Bu ekran veritabani kaydini BIR KEZ okur, sonra blob dosyasinin\n'
      printf 'turunu ve baslangicini okur: UC calistirma. Sikistirilmis bir blob bir\n'
      printf 'calistirma daha ekler. MAILBOX OTURUMU ACILMAZ, bu yuzden varlik kapisi\n'
      printf 'bu ekrana sorgu eklemez.' ;;
    # Reached only by an operation declared in the one list and not named here,
    # which is a defect in this file rather than a screen with no cost. Said as
    # the general sentence rather than silently: an operator is told a query is
    # running, and the log carries the name nobody wrote a note for.
    *)
      zro_log error "menu defect, no cost note for mailbox operation: ${1-}"
      printf 'Bu ekran mailboxun icini okur; sorgu birkac saniye surebilir.' ;;
  esac
}

ZRO_TXT_FOLDER_PICK='Klasor secin:

Liste bu mailboxtan okundu. Parantez icindeki sayilar klasordeki oge sayisi ve
okunmamis oge sayisidir.'

# A FOLDER, THEN THE QUESTION ABOUT IT. Two screens are reached this way — one
# folder's detail and one folder's grants — and both need a folder the operator
# has not got in hand.
#
# THE LISTING IS READ ONCE, before the loop rather than inside it. An operator
# opening three folders in a row pays for the listing once and for each folder
# once, instead of re-reading the mailbox every time they come back — and the
# folders of a mailbox do not change while somebody is reading one. Coming back to
# the menu and choosing the entry again is what re-reads it.
#
# A POSITION IN THE LIST, NEVER A PATH, exactly as the log viewer does it. What
# whiptail hands back is looked up in the array this program built out of the
# server's own answer, so no value from the screen becomes an argument — and a
# value that is not one of those positions names nothing and is refused.
zro_menu_folder() {
  local id=${1-} acct title rows rc=0 choice line i=0 path out
  local -a paths=() items=()

  if ! title=$(zro_menu_label "$id"); then
    zro_log error "menu defect, no label for folder operation: $id"
    zro_report_defect
    return 0
  fi
  acct=$(zro_identity_selected_account)
  if [ -z "$acct" ]; then
    zro_log error "menu defect, folder operation with no selected address: $id"
    zro_report_defect
    return 0
  fi

  zro_ui_notice "Calisiyor" "Zimbra sorgulaniyor, lutfen bekleyin.

Hesap: $acct
$(zro_mailbox_cost_note "$id")"

  rows=$(zro_store_folders_fetch "$acct") || rc=$?
  zro_mailbox_report "$rc" "$acct" "$title" && return 0

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # A row is taken apart by the module that decides what a row is. Written out
    # here it would be the third reader of that format, and the one a column added
    # to the listing would silently leave behind.
    i=$((i + 1))
    paths+=("$(zro_store_row_path "$line")")
    items+=("$i" "$(zro_store_row_label "$line")")
  done <<EOF
$rows
EOF

  if [ "${#paths[@]}" -eq 0 ]; then
    # Unreachable while the reader refuses an empty listing, and here so that the
    # two may only disagree loudly: a menu drawn with no entries is a screen an
    # operator cannot leave except by cancelling.
    zro_log error "folder defect, a listing that answered names no folder"
    zro_report_defect
    return 0
  fi

  while :; do
    rc=0
    choice=$(zro_ui_menu "$title" "$ZRO_TXT_FOLDER_PICK" "${items[@]}") || rc=$?
    [ "$rc" -eq 0 ] || return 0

    case $choice in
      ''|*[!0-9]*)
        zro_log error "denied, not a position in the folder list: $choice"
        continue ;;
    esac
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#paths[@]}" ]; then
      zro_log error "denied, position outside the folder list: $choice"
      continue
    fi
    path=${paths[choice - 1]}

    zro_ui_notice "Calisiyor" "Klasor okunuyor, lutfen bekleyin.

Hesap: $acct
Klasor: $path"

    rc=0
    case $id in
      mailbox-folder)        out=$(zro_store_folder_card "$acct" "$path") || rc=$? ;;
      mailbox-folder-grants) out=$(zro_store_grants_card "$acct" "$path") || rc=$? ;;
      # Routed here by the dispatch below and answered by neither arm: a defect in
      # this file, said as one rather than drawn as whichever answer $out still
      # held.
      *) zro_log error "menu defect, no folder operation for: $id"
         zro_report_defect
         return 0 ;;
    esac

    if [ "$rc" -eq "$ZRO_E_NO_FOLDER" ]; then
      zro_screen_folder_gone "$path"
      continue
    fi
    zro_mailbox_report "$rc" "$acct" "$title" && continue
    zro_show_text "$title" "$(zro_screen_alias_note "$out")"
  done
}

# A PATH THE LISTING OFFERED AND THE SERVER DOES NOT KNOW. It has one likely
# cause and it is not a mistake the operator made: the listing prints a
# parenthesised decoration INSIDE the path column for a search folder, a
# mountpoint and a feed — the query, the owner and the remote id, the URL — and
# none of that is part of the path. The tool cannot tell such a row from a folder
# whose name really ends in brackets, so it offers both and says this when the
# server refuses one.
#
# The other cause is ordinary and is named too: a folder deleted or renamed
# between the listing and the question.
zro_screen_folder_gone() {
  local path=${1-} detail
  detail=$(zro_error_detail 'Zimbra ciktisi')

  zro_ui_msgbox "Klasor bulunamadi" \
"Bu klasor sunucuda bulunamadi:
$path

Iki sebebi olabilir:
  - Listede bu satir bir arama klasoru, bir baglanti (mountpoint) veya bir
    besleme olabilir. Bunlarin yolunun sonuna parantez icinde sorgu, sahip veya
    adres bilgisi eklenir ve o kisim yolun parcasi degildir.
  - Klasor listelendikten sonra silinmis veya adi degistirilmis olabilir.

Listeye donup baska bir klasor secebilirsiniz.$detail"
}

# ------------------------------------------------------- the message search --
#
# THE QUERY IS BUILT, NEVER TYPED. An operator chooses a criterion from the list
# this program declares and supplies at most one value for it; the operator text
# that reaches Zimbra is a VALUE inside a term this program wrote, never an
# operator's own query. That is the same rule the canned log searches live by, and
# it matters more here: the query language has boolean operators, a field separator
# and a wildcard, so a query an operator typed could quietly mean something else
# than it reads.
#
# WHAT IS CARRIED BETWEEN THE SCREENS is a list of criterion ids and values, in a
# global, because bash 4.2 has no namerefs and the menu loop has to keep it across
# a prompt read inside command substitution — the same reason ZRO_UI_ARGV and
# ZRO_MENU_REASON are globals.
ZRO_SEARCH_SEL=()

zro_menu_search_reset() {
  ZRO_SEARCH_SEL=()
}

# The value chosen for a criterion, or a refusal when it has none.
zro_menu_search_get() {
  local id=${1-} i=0
  while [ "$i" -lt "${#ZRO_SEARCH_SEL[@]}" ]; do
    if [ "${ZRO_SEARCH_SEL[i]}" = "$id" ]; then
      printf '%s' "${ZRO_SEARCH_SEL[i + 1]}"
      return 0
    fi
    i=$((i + 2))
  done
  return 1
}

# One criterion set to one value, REPLACING whatever it held. A criterion chosen
# twice is an operator correcting themselves, and a query carrying `from:` twice
# would ask for messages from two senders at once — which is a question nobody
# asked and which answers with nothing.
zro_menu_search_put() {
  local id=${1-} value=${2-} i=0
  while [ "$i" -lt "${#ZRO_SEARCH_SEL[@]}" ]; do
    if [ "${ZRO_SEARCH_SEL[i]}" = "$id" ]; then
      ZRO_SEARCH_SEL[i + 1]=$value
      return 0
    fi
    i=$((i + 2))
  done
  ZRO_SEARCH_SEL+=("$id" "$value")
}

ZRO_TXT_SEARCH_BUILD='Olcut ekleyin, sonra aramayi calistirin. Secilen olcutler VE ile birlestirilir:
hepsine birden uyan iletiler bulunur.

Aramanin varsayilan kapsami cop kutusunu ve spam klasorunu DISARIDA BIRAKIR;
"Butun mailbox" olcutu bunu kaldirir.'

ZRO_TXT_SEARCH_ENVELOPE='Zarf alanlari, iletinin basliginda degil SMTP konusmasinda gecen adreslerdir.
Bu alanlarin dizine islenip islenmedigi sunucuya baglidir: laboratuvar
sunucusunda bu iki olcut, zarfi tam olarak bu adres olan iletiler icin bile bos
yanit verdi. Bos sonuc burada "yok" degil, "bu sunucuda aranamiyor" olabilir.'

# THE OTHER DISCLOSURE, AND IT IS NOT THE SAME ONE. The envelope pair was measured
# failing; these were never tried against a message that has an attachment, because
# the laboratory mailbox held none. `attachment:none` WAS measured and answered for
# every message there, so the criterion is real rather than a word the parser
# tolerates and ignores — what is unmeasured is only whether a type name matches the
# right MIME type when an attachment exists. The screen says exactly that much, and
# docs/research/2026-08-03-message-search-and-conversations.md §9 says it is said.
ZRO_TXT_SEARCH_ATTACHMENT='Ek olcutleri, eki olan bir ileti uzerinde denenemedi: laboratuvar mailboxunda
ekli ileti yoktu. "Eki olmayan iletiler" degeri olculdu ve dogru calisiyor; tur
adlarinin dogru MIME turlerine karsilik gelip gelmedigi OLCULMEDI.

Bos sonuc burada "eki olan ileti yok" demek olabilecegi gibi "tur adi eslesmedi"
de olabilir.'

# THE VALUE FOR ONE CRITERION, asked in the form its kind decides.
#
# The two criteria whose values this program owns are MENUS, not prompts: what
# comes back is one of the words in a table this file did not write, so nothing an
# operator typed can reach `is:` or `attachment:` at all. Everything else is a
# prompt and a validator, and a rejected value is told apart from a cancel — the
# first says what was wrong with what was typed, the second returns.
zro_menu_search_value() {
  local id=${1-} kind value rc=0 label
  local -a items=()
  kind=$(zro_search_kind "$id") || return "$ZRO_E_INPUT"
  label=$(zro_search_label "$id") || label=$id

  case $kind in
    scope)
      printf 'anywhere'
      return 0 ;;
    state|atype)
      # The table travels as a NAME, so the menu is drawn from the same
      # declaration it is judged against and a reader can see that it is.
      local table=ZRO_SEARCH_STATES
      [ "$kind" = atype ] && table=ZRO_SEARCH_ATTACHMENTS
      local choice_id
      while IFS= read -r choice_id; do
        [ -n "$choice_id" ] || continue
        items+=("$choice_id" "$(zro_search_choice_label "$table" "$choice_id")")
      done <<EOF
$(zro_table_keys "$table")
EOF
      value=$(zro_ui_menu "$label" "Deger secin:" "${items[@]}") || return "$ZRO_E_CANCEL"
      # Judged against the table this program drew, exactly as a menu id is: a
      # value that is not one of those words names nothing.
      if ! zro_search_choice_label "$table" "$value" >/dev/null; then
        zro_log error "denied, not a declared search value: $value"
        return "$ZRO_E_INPUT"
      fi
      printf '%s' "$value"
      return 0 ;;
  esac

  # What to ask for comes from the module that declares the kinds, so a criterion
  # cannot arrive with no way to ask for its value. A kind with no prompt and no
  # menu is a defect in that declaration rather than a screen with nothing to say.
  local prompt
  if ! prompt=$(zro_search_prompt "$kind"); then
    zro_log error "search defect, no prompt for criterion kind: $kind"
    return "$ZRO_E_INPUT"
  fi

  value=$(zro_ui_input "$label" "$prompt" "$(zro_menu_search_get "$id" || printf '')") || rc=$?
  [ "$rc" -eq 0 ] || return "$ZRO_E_CANCEL"

  # A message-id arrives wearing the angle brackets a header puts on it, and they
  # come off here for the same reason the delivery trace takes them off: measured
  # on the lab server, the bracketed form matches nothing.
  if [ "$kind" = msgid ]; then
    value=${value#<}
    value=${value%>}
  fi

  # Validated by the one function that will have to build a term out of it. A
  # second copy of the rules here is a second set to get wrong, and the term
  # builder is where the value really has to survive.
  if ! zro_search_term "$id" "$value" >/dev/null; then
    zro_ui_msgbox "Gecersiz girdi" \
"Bu deger '$label' olcutu icin kullanilamaz.

  - Adres tam bir e-posta adresi olmali, alan adi ise yalnizca alan adi.
  - Gun 2026-07-28 biciminde ve takvimde var olan bir gun olmali.
  - Klasor yolu '/' ile baslamali.
  - Metin bos olamaz, satir sonu veya kontrol karakteri iceremez, basinda ya da
    sonunda bosluk olamaz ve TERS BOLU ILE BITEMEZ.

Ters bolu ile biten bir deger, sorgu dilinde kendi tirnagini kapatir: sunucu ya
baska bir degeri arar ya da sorgunun tamamini reddeder. Ikisi de sessizce yanlis
sonuc verir, bu yuzden arac boyle bir degeri gondermez."
    return "$ZRO_E_INPUT"
  fi
  printf '%s' "$value"
}

# THE CRITERIA SCREEN AND THE ANSWER BEHIND IT. Two operations arrive here — the
# message search and the conversation search — because they are one query builder
# asked for two kinds of hit, and a second copy of this loop would be a second set
# of criteria to keep in step.
zro_menu_search() {
  local id=${1-} acct title choice rc=0 query raw value
  if ! title=$(zro_menu_label "$id"); then
    zro_log error "menu defect, no label for search operation: $id"
    zro_report_defect
    return 0
  fi
  acct=$(zro_identity_selected_account)
  if [ -z "$acct" ]; then
    zro_log error "menu defect, search operation with no selected address: $id"
    zro_report_defect
    return 0
  fi

  # The criteria are the operator's, and they are kept while this screen is open
  # and dropped when it is left: an operator who comes back to the menu and starts
  # again is starting again. Reset HERE rather than on the way out, so a screen
  # left by cancelling cannot leave a criterion behind for the next one.
  zro_menu_search_reset

  local -a items=()
  local crit_id crit_label
  while :; do
    items=()
    while IFS= read -r crit_id; do
      [ -n "$crit_id" ] || continue
      crit_label=$(zro_search_label "$crit_id") || continue
      if value=$(zro_menu_search_get "$crit_id"); then
        crit_label="$crit_label = $(zro_search_value_label "$crit_id" "$value")"
      fi
      items+=("$crit_id" "$crit_label")
    done <<EOF
$(zro_search_ids)
EOF
    items+=(__run__ "ARAMAYI CALISTIR" __clear__ "Olcutleri temizle")

    rc=0
    choice=$(zro_ui_menu "$title" "$ZRO_TXT_SEARCH_BUILD" "${items[@]}") || rc=$?
    [ "$rc" -eq 0 ] || return 0

    case $choice in
      __clear__) zro_menu_search_reset; continue ;;
      __run__) ;;
      *)
        # Judged against the list this program itself drew, exactly as the main
        # menu judges an operation id.
        if ! zro_search_label "$choice" >/dev/null; then
          zro_log error "denied, not a declared search criterion: $choice"
          continue
        fi
        # Two pairs carry a screen of their own before they are used, because what
        # an empty answer from them means is not what an operator expects. They say
        # DIFFERENT things and the difference is the point: the envelope pair was
        # measured answering nothing where it should have answered, while the
        # attachment pair was never run against a message carrying an attachment at
        # all. One is a measured gap, the other an unmeasured one, and a screen that
        # blurred them would be claiming a finding nobody made.
        case $choice in
          env-sender|env-recipient) zro_ui_msgbox "Zarf alanlari" "$ZRO_TXT_SEARCH_ENVELOPE" ;;
          attachment-name|attachment-type)
            zro_ui_msgbox "Ek olcutleri" "$ZRO_TXT_SEARCH_ATTACHMENT" ;;
        esac
        rc=0
        value=$(zro_menu_search_value "$choice") || rc=$?
        [ "$rc" -eq 0 ] || continue
        zro_menu_search_put "$choice" "$value"
        continue ;;
    esac

    # ------------------------------------------------------------- the run --
    rc=0
    query=$(zro_search_query ${ZRO_SEARCH_SEL[@]+"${ZRO_SEARCH_SEL[@]}"}) || rc=$?
    if [ "$rc" -ne 0 ]; then
      zro_ui_msgbox "Olcut yok" \
"Arama en az bir olcutle calisir.

Olcutsuz bir sorguyu sunucu reddeder, ve butun mailboxu listelemek bu aracin
yaptigi bir sey degildir. Listeden bir olcut secip deger verin."
      continue
    fi

    zro_ui_notice "Calisiyor" "Mailbox araniyor, lutfen bekleyin.

Hesap: $acct
$(zro_mailbox_cost_note "$id")"

    rc=0
    case $id in
      mailbox-search)       raw=$(zro_search_fetch "$acct" "$query") || rc=$? ;;
      mailbox-conversation) raw=$(zro_search_conv_fetch "$acct" "$query") || rc=$? ;;
      *) zro_log error "menu defect, no search operation for: $id"
         zro_report_defect
         return 0 ;;
    esac

    # Two endings of this read are not the shared failure. A folder criterion can
    # name a folder that is not there, which is a fact about what was asked rather
    # than about the server, and a query the server will not parse is a defect in
    # this program that has to reach the log with the query in it.
    case $rc in
      "$ZRO_E_NO_FOLDER") zro_screen_search_no_folder; continue ;;
      "$ZRO_E_INPUT")     zro_screen_search_refused "$query"; continue ;;
    esac
    zro_mailbox_report "$rc" "$acct" "$title" && continue

    zro_show_text "$title" \
      "$(zro_screen_alias_note "$(zro_search_body "$acct" "$query" "$raw" \
         ${ZRO_SEARCH_SEL[@]+"${ZRO_SEARCH_SEL[@]}"})")"

    # A message search ends with its answer: every row carries the id the message
    # detail screen is reached WITH, and that screen is its own entry on the main
    # menu rather than a step behind this one — it opens no mailbox session, so it
    # is not a screen this one has to lead to. A conversation search does lead
    # somewhere: a conversation is a thing to open.
    [ "$id" = mailbox-conversation ] || continue
    zro_menu_conversation "$acct" "$title" "$raw"
  done
}

ZRO_TXT_CONV_PICK='Konusma secin; icindeki iletiler listelenir.

Parantezli sayi konusmadaki ileti sayisidir. Eksi ile baslayan id, tek iletilik
bir konusmayi gosterir.'

# ONE CONVERSATION, PICKED FROM THE SEARCH THAT FOUND IT.
#
# A POSITION IN THE LIST, NEVER AN ID FROM THE SCREEN, exactly as the folder menu
# and the log viewer do it: what whiptail hands back is looked up in the array this
# program built out of the server's own answer, so no value from the screen becomes
# an argument.
zro_menu_conversation() {
  local acct=${1-} title=${2-} raw=${3-} choice rc=0 conv line i=0 out rows
  local -a ids=() items=()

  # The rows are taken apart by the module that decides what a row is, and read
  # out of a variable rather than off a nested heredoc: one answer, one reader.
  rows=$(zro_search_parse_rows <<EOF
$raw
EOF
)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    i=$((i + 1))
    ids+=("$(zro_search_field_id "$line")")
    items+=("$i" "$(zro_search_row_label "$line")")
  done <<EOF
$rows
EOF

  [ "${#ids[@]}" -gt 0 ] || return 0

  while :; do
    rc=0
    choice=$(zro_ui_menu "$title" "$ZRO_TXT_CONV_PICK" "${items[@]}") || rc=$?
    [ "$rc" -eq 0 ] || return 0

    case $choice in
      ''|*[!0-9]*)
        zro_log error "denied, not a position in the conversation list: $choice"
        continue ;;
    esac
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#ids[@]}" ]; then
      zro_log error "denied, position outside the conversation list: $choice"
      continue
    fi
    conv=${ids[choice - 1]}

    # ANSWERED WITHOUT ASKING ANYTHING when the conversation holds one message:
    # its id is the negation of that message's, and a value beginning with a dash
    # may not reach a command line. The operator loses nothing — the listing would
    # have shown them the row they just picked.
    if zro_search_conv_virtual "$conv"; then
      zro_show_text "$title" "$(zro_search_virtual_body "$conv")"
      continue
    fi

    zro_ui_notice "Calisiyor" "Konusma okunuyor, lutfen bekleyin.

Hesap: $acct
Konusma id: $conv"

    rc=0
    out=$(zro_search_conv_messages "$acct" "$conv") || rc=$?
    # A conversation the server no longer has is an ANSWER, and the card says so
    # from the same empty answer it would draw an empty listing from.
    if [ "$rc" -eq "$ZRO_E_NO_RESULT" ]; then
      zro_show_text "$title" "$(zro_search_conv_body "$acct" "$conv" '')"
      continue
    fi
    zro_mailbox_report "$rc" "$acct" "$title" && continue
    zro_show_text "$title" \
      "$(zro_screen_alias_note "$(zro_search_conv_body "$acct" "$conv" "$out")")"
  done
}

# ------------------------------------------------------- the message detail --
#
# ONE MESSAGE, ASKED FOR BY ITS IDENTIFIER. The screen behind the search's id
# column, and the one mailbox screen that opens no mailbox: the record comes out of
# the database through the metadata dump and the headers out of the file the message
# is stored in, so neither the existence gate nor a session is involved.
#
# THE OPERATOR TYPES AN ID AND NOTHING ELSE. It is validated as digits before
# anything runs, which is also what keeps the negation of an id — the value Zimbra
# names a single-message conversation with — off a command line.

ZRO_TXT_MSG_PICK='Ileti id (ornek: 274)

Id degerlerini Ileti arama ekranindan okuyabilirsiniz. Yalnizca rakam olabilir:
eksi ile baslayan bir deger tek iletilik bir KONUSMA kimligidir, ileti kimligi
degildir.'

zro_menu_message() {
  local id=${1-} acct title item rc=0 out last=''
  if ! title=$(zro_menu_label "$id"); then
    zro_log error "menu defect, no label for message operation: $id"
    zro_report_defect
    return 0
  fi
  acct=$(zro_identity_selected_account)
  if [ -z "$acct" ]; then
    zro_log error "menu defect, message operation with no selected address: $id"
    zro_report_defect
    return 0
  fi

  while :; do
    rc=0
    # What was typed last is offered back, so reading two neighbouring messages is
    # an edit of one digit rather than a retyping.
    item=$(zro_ui_input "$title" "$ZRO_TXT_MSG_PICK" "$last") || rc=$?
    [ "$rc" -eq 0 ] || return 0
    if ! zro_validate_item_id "$item"; then
      zro_ui_msgbox "Gecersiz girdi" \
"Bu bir ileti id degeri degil.

Id yalnizca rakamlardan olusur, sifir ile baslamaz ve en fazla on basamaklidir.
Eksi ile baslayan bir deger tek iletilik bir konusmanin kimligidir: aradiginiz
ileti id, o degerin isaretsiz halidir."
      continue
    fi
    last=$item

    zro_ui_notice "Calisiyor" "Ileti okunuyor, lutfen bekleyin.

Hesap: $acct
Ileti id: $item
$(zro_mailbox_cost_note "$id")"

    rc=0
    out=$(zro_msg_card "$acct" "$item") || rc=$?
    case $rc in
      0) zro_show_text "$title" "$(zro_screen_alias_note "$out")" ;;
      "$ZRO_E_NO_RESULT")  zro_screen_message_no_item "$acct" "$item" ;;
      "$ZRO_E_NO_MAILBOX") zro_screen_message_not_here "$acct" ;;
      "$ZRO_E_TIMEOUT")    zro_screen_message_timeout ;;
      # THE SHARED REPORTER WOULD NAME THE WRONG SERVICE HERE. Its message for this
      # code is about mailboxd and an admin certificate, and this screen's read talks
      # to neither: it connects to the mailbox database directly.
      "$ZRO_E_UNAVAILABLE") zro_screen_message_database ;;
      *) zro_report_error "$rc" ;;
    esac
  done
}

# AN ID THIS MAILBOX DOES NOT HOLD. Its own screen rather than the shared 'kayit
# bulunamadi', because the query ran and answered: there is no such item in this
# account's own database rows, which is a result an operator acts on.
#
# The likeliest cause is not a typing mistake and is named first: an id is unique
# per MAILBOX, so an id read off one account's search results names nothing, or
# names something else, in another account's.
zro_screen_message_no_item() {
  local acct=${1-} item=${2-} detail
  detail=$(zro_error_detail 'Zimbra ciktisi')

  zro_ui_msgbox "Ileti bulunamadi" \
"Bu hesapta $item id degerli bir oge yok.

Sorgu calisti ve yanit verdi; bu bir hata degil, bir sonuc.

Id degerleri HER MAILBOXA OZELDIR: baska bir hesabin arama sonucundan alinan bir
id bu hesapta ya hicbir seyi ya da baska bir seyi gosterir. Su anda secili hesap:
$acct

Ileti listelendikten sonra silinmis de olabilir; silinen bir oge cop kutusundan
temizlendiginde veritabani satiri da gider.$detail"
}

# THE DUMP'S ONE SENTENCE THAT COVERS TWO ANSWERS. It says `not found on this host`
# both for an address the directory has never heard of and for an account whose
# mailbox has never been created — it reads the mailbox table and nothing else, so it
# cannot tell them apart. The screen says so instead of picking one.
zro_screen_message_not_here() {
  local acct=${1-} detail
  detail=$(zro_error_detail 'Zimbra ciktisi')

  zro_ui_msgbox "Mailbox bu sunucuda yok" \
"$acct icin bu sunucunun veritabaninda mailbox satiri yok.

Bu tek cumle IKI ANLAMA GELIR ve dokum ikisini ayirt etmez:
  - boyle bir hesap yok, ya da
  - hesap var ve mailboxu hic yaratilmamis (ilk giriste veya ilk teslimde
    yaratilir).

Hangisi oldugunu Mailbox var mi ekrani soyler: o ekran dizine bakar ve iki durumu
ayri ayri yanitlar.$detail"
}

# THE HANG THIS SCREEN WOULD OTHERWISE HAVE. The dump has no timeout of its own: with
# the database unreachable it retries forever, in a loop with no bound — measured, one
# retry every five seconds until it is killed. What ends it is the wall-clock timeout
# every command in this tool runs under, and the difference between a tool that hangs
# and a tool that says this is that clock.
#
# THE DETAIL IS THE SERVER'S OWN SENTENCE, and getting it here took a measurement: this
# binary writes its retries to STDOUT and leaves stderr empty, so the module borrows
# the head of stdout when a failure said nothing on the usual stream.
zro_screen_message_timeout() {
  local detail
  detail=$(zro_error_detail 'Komutun kendi cikti satirlari')

  zro_ui_msgbox "Zaman asimi" \
"Ileti kaydi ayrilan surede okunamadi ve islem kesildi.

Bu ekranin okudugu dokum, mailbox veritabanina DOGRUDAN baglanir ve veritabani
yanit vermezse kendiliginden vazgecmez: bes saniyede bir, sonsuza kadar yeniden
dener. Bu yuzden sureyi bu arac koyar ve suresi dolunca komutu keser.

Kontrol edin: mysql (mailbox veritabani) servisi calisiyor mu — zmcontrol status.
Gerekirse ZRO_TIMEOUT degerini yukseltip yeniden deneyin.$detail"
}

# A FAILURE OF THE DUMP THIS PROGRAM DOES NOT RECOGNISE, and the service it really
# needs. The shared reporter's message for this code names mailboxd and the admin
# certificate, which are the SOAP path's two usual causes — and this read takes no
# SOAP path at all: it opens a JDBC connection to the mailbox database. An operator
# sent to check mailboxd would be looking at a service that is very likely running.
zro_screen_message_database() {
  local detail
  detail=$(zro_error_detail 'Komutun kendi cikti satirlari')

  zro_ui_msgbox "Mailbox veritabani okunamadi" \
"Ileti kaydi okunamadi: dokum calisti ve bu aracin tanimadigi bir hata verdi.

Bu ekran mailbox VERITABANINA dogrudan baglanir (jdbc, yerel mysql). mailboxd
servisi ve admin sertifikasi bu okumaya dahil DEGILDIR, dolayisiyla sorun orada
degil olabilir.

Kontrol edin:
  - mysql (mailbox veritabani) servisi calisiyor mu — zmcontrol status
  - diskte yer var mi, ve mysql gunlugunde hata var mi$detail"
}

# A FOLDER CRITERION NAMING A FOLDER THAT IS NOT THERE. Its own screen rather than
# the shared failure, because nothing failed: the search was asked about a folder
# this mailbox does not have, and the repair is a path the operator can look up.
zro_screen_search_no_folder() {
  local detail
  detail=$(zro_error_detail 'Zimbra ciktisi')

  zro_ui_msgbox "Klasor bulunamadi" \
"Aramada verilen klasor bu mailboxta yok.

Klasor yollarini 'Klasorler' ekranindan gorebilirsiniz; yol '/' ile baslar ve
buyuk-kucuk harf farkli olabilir. Sunucu, verilen yolun basina kendi '/'
isaretini ekleyerek yanit verir, bu yuzden mesajda iki bolu isareti gorunur.$detail"
}

# A QUERY THE SERVER WOULD NOT PARSE. This program builds every query it sends, so
# this is a defect in the builder rather than something the operator did — and the
# screen shows the query, because that is the one thing that makes it reportable.
zro_screen_search_refused() {
  local query=${1-} detail
  detail=$(zro_error_detail 'Zimbra ciktisi')

  zro_log error "search defect, the server refused a query this tool built: $query"
  zro_ui_msgbox "Sorgu reddedildi" \
"Sunucu bu sorguyu kabul etmedi:

$query

Sorguyu bu arac olusturur, yani bu bir kullanim hatasi degil, aracta bir eksik.
Yukaridaki satiri ve olcutleri not edip bildirin.$detail"
}

# THE SILENT GATE. The oracle talks SOAP to the mailbox service and has no other
# form, so a service that does not answer leaves the gate unable to answer for any
# account at all.
#
# ITS OWN SCREEN RATHER THAN THE SHARED FAILURE, because it is not the same
# sentence. The shared one says a query could not be run and names the two usual
# causes, which is right and incomplete: what an operator needs to know here is
# that every mailbox question is refused until the service returns, that this costs
# them nothing — the commands behind the gate reach the same service — and that
# the directory screens are unaffected. A bare refusal reads as a broken tool
# during the incident the tool exists to diagnose.
zro_mailbox_silent_gate() {
  local detail
  detail=$(zro_error_detail 'Zimbra ciktisi')

  zro_ui_msgbox "Mailbox sorusu yanitlanamiyor" \
"Bu hesabin mailboxu olup olmadigi su anda ogrenilemiyor. Bu soruyu yanitlayan
tek komut mailboxd servisine SOAP ile baglanir, ve servis yanit vermiyor.

Bu bir eksiklik degil, bir sonuc: mailbox ekranlarinin calistirdigi komutlar da
ayni servise baglanir, yani servis donene kadar hicbiri zaten yanit veremezdi.
Kaybedilen bir bilgi yok.

Dizin ekranlari etkilenmez: hesap karti, uyelikler ve alan adi karti LDAP
uzerinden calismaya devam eder.

Kontrol edin:
  - mailbox servisi durmus     (kontrol: zmcontrol status)
  - admin sertifikasi gecersiz (kontrol: zmcertmgr viewdeployedcrt)$detail"
}

# The distribution list card: who receives mail sent to this address, who owns
# the list, and who may send to it.
#
# THE SELECTED ADDRESS IS THE LIST. Nothing here asks for one, and nothing here
# resolves it a second time either: the menu offers this entry only for an address
# the session already established is a list, and the card reads the list's own
# canonical name out of the answer it gets.
zro_screen_dl() {
  local id=${1-} addr out rc=0 title
  if ! title=$(zro_menu_label "$id"); then
    zro_log error "menu defect, no label for list operation: $id"
    zro_report_defect
    return 0
  fi
  addr=$(zro_sel_address)
  if [ -z "$addr" ]; then
    zro_log error "menu defect, list operation with no selected address: $id"
    zro_report_defect
    return 0
  fi

  # The list read, plus one per grantee named in its grants. Each is a JVM start,
  # so the terminal is told what it is waiting for rather than sitting blank.
  zro_ui_notice "Calisiyor" "Zimbra sorgulaniyor, lutfen bekleyin.

Liste: $addr
Liste kaydi ve yetkili adresleri okunuyor; her sorgu birkac saniye surebilir."

  out=$(zro_dl_card "$addr") || rc=$?
  if [ "$rc" -eq "$ZRO_E_NO_RESULT" ]; then
    # Not the shared reporter's bare "kayit bulunamadi": what happened is that
    # this address is not a distribution list, which is a different sentence and
    # points at a different next step.
    zro_ui_msgbox "Liste bulunamadi" \
"$addr bir dagitim listesi olarak kayitli degil.

Sorgu calisti ve yanit verdi. Adres bir hesap, bir alias veya bir kaynak
olabilir: ana menuden adresi yeniden secerek ne oldugunu gorebilirsiniz."
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    zro_report_error "$rc"
    return 0
  fi
  zro_show_text "$title" "$out"
}

# The domain card: the status, the type, the catch-all and the default class of
# service of the domain the selected address belongs to.
#
# THE DOMAIN IS DERIVED, NEVER ASKED FOR. Every address carries one, so a screen
# that prompted for it would be asking the operator to retype half of what they
# already chose — and an address that is nowhere in the directory still has a
# domain, which is exactly when this screen answers the question the account read
# could not: whether this server carries that domain's mail at all.
zro_screen_domain() {
  local id=${1-} addr domain out rc=0 title
  if ! title=$(zro_menu_label "$id"); then
    zro_log error "menu defect, no label for domain operation: $id"
    zro_report_defect
    return 0
  fi
  addr=$(zro_sel_address)
  if [ -z "$addr" ]; then
    zro_log error "menu defect, domain operation with no selected address: $id"
    zro_report_defect
    return 0
  fi
  # The selection was validated when it was made, so an address with no domain in
  # it got past that check — a defect in this program rather than something the
  # operator typed, and never a directory read for a name nobody has.
  if ! domain=$(zro_domain_of "$addr"); then
    zro_log error "menu defect, selected address carries no domain: $addr"
    zro_report_defect
    return 0
  fi

  zro_ui_notice "Calisiyor" "Zimbra sorgulaniyor, lutfen bekleyin.

Alan adi: $domain
Bu ekran alan adi kaydini okur; sunucudaki hesaplar sayilmaz."

  out=$(zro_domain_card "$domain") || rc=$?
  if [ "$rc" -ne 0 ]; then
    zro_report_error "$rc"
    return 0
  fi
  zro_show_text "$title" "$out"
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
      detail=$(zro_error_detail 'Sistemin bildirdigi')
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
    if [ "$rc" -eq "$ZRO_E_UNAVAILABLE" ] && ! zro_cap_search_available; then
      # A COMPRESSED FILE IS THE ONE THING THIS SCREEN READS AT REDUCED PRIORITY.
      # Decompressing a rotated log is the same disk and the same processor
      # whether a search or this screen asked for it, so the gate wraps it — and a
      # host without the two commands that do the wrapping is refused rather than
      # given an ordinary-priority read. Named here rather than left to the shared
      # reporter, because the plain files on this same list still work and an
      # operator has to be told that.
      zro_ui_msgbox "Sikistirilmis dosya acilamadi" \
"Bu dosya sikistirilmis, ve bir sikistirilmis logu acmak bu araca gore bir
TARAMA kadar is demektir: dusuk islemci onceligi ve bos disk onceligi ile
calistirilir. Bunu yapan iki komut bu sunucuda bulunamadi.

Beklenen: nice ve ionice (Ubuntu/Debian: coreutils ve util-linux paketleri).

Sikistirilmamis dosyalar bu ekrandan okunmaya devam eder: listede .gz uzantisi
olmayan bir dosya secebilirsiniz."
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

# ------------------------------------------------------------ the log search --
#
# The viewer's other half. It reads the WHOLE of every file an arrival window
# covers, so that "nothing found" is a fact about the server rather than about how
# far the tool bothered to look — which is the one thing the bounded viewer above
# can never say, and says so on its own screen.

ZRO_TXT_LOGSEARCH='Secilen aralikta kalan log dosyalarinin TAMAMI taranir; dosyalar yalnizca
okunur. Hazir sorularin arama kaliplari araca aittir: siz yazmazsiniz.

Neyi ariyorsunuz?'

ZRO_TXT_LOGSEARCH_LOG='Duz metin, sectiginiz logda harfi harfine aranir: yazdiginiz nokta, arti ve
parantez kendisiyle eslesir, kalip olarak yorumlanmaz.

Hangi logda aranacak?'

ZRO_TXT_LOGSEARCH_TEXT='Aranacak metin (ornek: B0CC6104BA2, ali+fatura@example.com,
connection refused)

Yazdiginiz metin oldugu gibi aranir; bosluklu bir ifade de yazabilirsiniz.
BUYUK/kucuk harf duyarlidir ve metin - ile baslayamaz.'

# THE WINDOW SAYS SOMETHING DIFFERENT HERE than it does on a delivery trace, and
# the difference is worth a screen of its own. The trace hands its window to a
# tracer that compares it against each line. This one uses it to choose FILES, and
# then reads those files from end to end — so an answer can carry lines from either
# side of the range, and an operator who read this as a line filter would think the
# tool had ignored them.
ZRO_TXT_LOGSEARCH_WINDOW='Aralik, hangi log DOSYALARININ taranacagini secer. Secilen dosyalar bastan
sona okunur, bu yuzden sonuclarda araligin biraz disindaki satirlar da
gorunebilir.

Aralik secin:'

# WHY THE SEARCH CANNOT RUN, as its own screen. One cause today, and it is not
# about a log: this tool runs every scan at reduced processor and idle disk
# priority, and a host without the two commands that do it cannot be offered a
# scan that keeps that promise.
zro_logsearch_unavailable() {
  case $(zro_cap_search_reason) in
    noprio)
      zro_ui_msgbox "Kullanilamaz" \
"Log aramasi bu sunucuda calistirilamiyor.

Bu arac her log taramasini DUSUK islemci onceligi ve BOS disk onceligi ile
calistirir; boylece yuk altindaki bir mail sunucusunda sorun ararken sorunu
buyutmez. Bunu yapan iki komut bu sunucuda bulunamadi.

Beklenen: nice ve ionice (Ubuntu/Debian: coreutils ve util-linux paketleri).
Baska bir yerdelerse ZRO_NICE_BIN ve ZRO_IONICE_BIN degiskenleriyle
gosterebilirsiniz.

Tarama, onceligi dusurmeden CALISTIRILMAZ: log dosyalarinin son satirlari icin
'Log dosyalari' ekranini kullanabilirsiniz." ;;
    *) zro_log error "menu defect, no unavailability screen for the log search: $(zro_cap_search_reason)"
       zro_report_defect ;;
  esac
}

# The questions this screen offers, and the one door that is not a question.
#
# THE OPERATOR NEVER TYPES A PATTERN. Every entry but the last carries a pattern
# the tool owns, and the last one is matched literally — so there is no path from
# this screen to a regular expression an operator wrote, on a production mail
# server.
zro_menu_logsearch() {
  local choice rc id label
  local -a items=()
  while :; do
    items=()
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      # A declared question with no label would reach the operator as a menu entry
      # with no name. Left out and said out loud; the suite holds the two sets
      # equal, which is where this is really prevented.
      if ! label=$(zro_logsearch_question_label "$id"); then
        zro_log error "no label for declared log search question: $id"
        continue
      fi
      items+=("$id" "$label")
    done <<EOF
$(zro_logsearch_questions)
EOF
    # THE QUESTIONS THAT ARE ABOUT EVERYBODY, after the ones that list what
    # happened. Each takes a value and asks whether it is there at all — one scan
    # of the window's files, and no query about any account.
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      if ! label=$(zro_logsearch_lookup_label "$id"); then
        zro_log error "no label for declared log search lookup: $id"
        continue
      fi
      items+=("$id" "$label")
    done <<EOF
$(zro_logsearch_lookups)
EOF
    items+=(text "Duz metin ara (harfi harfine)")

    rc=0
    choice=$(zro_ui_menu "Log arama" "$ZRO_TXT_LOGSEARCH" "${items[@]}") || rc=$?
    [ "$rc" -eq 0 ] || return 0

    if [ "$choice" = text ]; then
      zro_screen_logsearch_text
      continue
    fi
    if zro_logsearch_lookup_log "$choice" >/dev/null 2>&1; then
      zro_screen_logsearch_lookup "$choice"
      continue
    fi
    # Judged against the list this program itself drew. Nothing else may name a
    # question, so a value that is not one of those ids is a defect rather than a
    # question nobody declared.
    if ! zro_logsearch_question_log "$choice" >/dev/null 2>&1; then
      zro_log error "not a declared log search question: $choice"
      continue
    fi
    zro_screen_logsearch_named "$choice"
  done
}

# A named question, and the one thing an operator may supply to it.
#
# THE FILTER IS OFFERED ONLY WHEN THE SESSION HAS AN ADDRESS, because it can only
# be the selected one: this screen does not ask for an address, it uses the one
# every other screen is already about. Offered as a menu rather than as a
# confirmation so that cancelling goes back rather than quietly meaning "no".
zro_screen_logsearch_named() {
  local id=${1-} log label filter='' choice rc=0
  if ! log=$(zro_logsearch_question_log "$id"); then
    zro_log error "menu defect, no log for log search question: $id"
    zro_report_defect
    return 0
  fi
  label=$(zro_logsearch_question_label "$id")

  if zro_sel_have; then
    rc=0
    choice=$(zro_ui_menu "Adres suzgeci" \
"Bu soru secili adrese gore daraltilabilir. Suzgec SATIR BAZLIDIR: yalnizca
adresi de iceren satirlar listelenir, ve adresi tasimayan satirlar (ornegin bir
istisna izinin govdesi) bu durumda gorunmez.

Nasil aransin?" \
      all "Butun kayitlar" \
      one "Yalnizca $(zro_sel_address)") || rc=$?
    [ "$rc" -eq 0 ] || return 0
    [ "$choice" != one ] || filter=$(zro_sel_address)
  fi

  zro_screen_logsearch_do "$log" named "$id" "$filter" "$label"
}

ZRO_TXT_LOGSEARCH_DOMAIN='Gonderen alan adi (ornek: example.com)

Bu alan adindan bu sunucuya mail GELDI mi diye bakilir: log satirlarinda
zarf gondericisi (from=<...@alan>) aranir. Bu alan adina GIDEN mailler bu
listede yer almaz.'

# A question about everybody, asked with a value.
#
# BOTH OF THEM ARE ONE SCAN. Asked of the accounts they concern, each would be a
# query per mailbox and a gate check per account; asked of the log they are the
# same cost as any other search on this screen — the window's files, once — and
# they open no mailbox at all. That is the whole reason they are here rather than
# behind the existence gate.
#
# The value is asked for BEFORE the window and the cost, so that an operator who
# mistypes an identifier finds out before they agree to spend a scan on it.
zro_screen_logsearch_lookup() {
  local id=${1-} log label value rc=0
  if ! log=$(zro_logsearch_lookup_log "$id"); then
    zro_log error "menu defect, no log for log search lookup: $id"
    zro_report_defect
    return 0
  fi
  label=$(zro_logsearch_lookup_label "$id")

  case $id in
    msgid)
      # The same prompt the delivery trace asks with, including the warning that
      # the identifier is matched case-sensitively — which is worth more here than
      # there, because this reader has no opinion about case at all.
      value=$(zro_prompt_msgid) || rc=$? ;;
    sender-domain)
      value=$(zro_prompt_domain) || rc=$? ;;
    # Declared in the table and prompted for nowhere: a defect in this file.
    *) zro_log error "menu defect, no prompt for log search lookup: $id"
       zro_report_defect
       return 0 ;;
  esac
  # Cancel is navigation and a rejected value has had its own screen; both return
  # the operator to the menu they came from.
  [ "$rc" -eq 0 ] || return 0
  [ -n "$value" ] || return 0

  zro_screen_logsearch_do "$log" "$id" "$value" '' "$label: $value"
}

# Asks for a domain and validates it. Cancel and a rejected value are told apart
# exactly as they are for an address.
#
# ITS OWN PROMPT rather than the address one, because a domain is not an address:
# the address validator would refuse `example.com` for having no local part, and an
# operator asked for a domain would be told their domain is not an address.
zro_prompt_domain() {
  local value rc=0
  value=$(zro_ui_input "Alan adi" "$ZRO_TXT_LOGSEARCH_DOMAIN") || rc=$?
  [ "$rc" -eq 0 ] || return "$ZRO_E_CANCEL"
  if ! zro_validate_domain "$value"; then
    zro_ui_msgbox "Gecersiz girdi" \
"Gecersiz alan adi.

Yalnizca alan adini yazin: ornek.com gibi. Adres (ad@ornek.com), protokol
(https://) veya yol eklemeyin."
    return "$ZRO_E_INPUT"
  fi
  printf '%s' "$value"
}

# Free text, in whichever declared log the operator names.
#
# The log is offered by name and comes back as one of the names this program drew,
# exactly as the viewer's file list comes back as a position. Nothing an operator
# types is ever a path or a log name.
zro_screen_logsearch_text() {
  local key text rc=0 label
  local -a items=()
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    if ! label=$(zro_logview_label "$key"); then
      zro_log error "no label for declared log: $key"
      continue
    fi
    items+=("$key" "$label")
  done <<EOF
$(zro_inv_keys)
EOF
  if [ "${#items[@]}" -eq 0 ]; then
    zro_log error "no log is both declared and named; the search has nothing to offer"
    zro_ui_msgbox "Kullanilamaz" "Aranabilecek log tanimli degil."
    return 0
  fi

  rc=0
  key=$(zro_ui_menu "Duz metin arama" "$ZRO_TXT_LOGSEARCH_LOG" "${items[@]}") || rc=$?
  [ "$rc" -eq 0 ] || return 0
  if ! zro_logview_label "$key" >/dev/null 2>&1; then
    zro_log error "not a declared log: $key"
    return 0
  fi

  rc=0
  text=$(zro_ui_input "Duz metin arama" "$ZRO_TXT_LOGSEARCH_TEXT") || rc=$?
  [ "$rc" -eq 0 ] || return 0
  # Cancel and a rejected value are told apart here as they are for an address:
  # the first returns the operator to the previous screen, the second says what
  # was wrong with what they typed.
  if ! zro_logsearch_validate_text "$text"; then
    zro_ui_msgbox "Gecersiz girdi" \
"Bu metin aranamaz.

Metin bos olamaz, satir sonu veya kontrol karakteri iceremez, basinda ya da
sonunda bosluk olamaz, '-' ile baslayamaz ve $ZRO_LOGSEARCH_TEXT_MAX karakteri
gecemez.

Ortada bosluk serbesttir: 'connection refused' gibi bir ifade aranabilir."
    return 0
  fi

  zro_screen_logsearch_do "$key" text "$text" '' "$(printf 'duz metin: %s' "$text")"
}

# The window, the cost, the confirmation, the scan and the answer.
#
#   $1  a declared log   $2  'named' or 'text'   $3  the question id or the text
#   $4  an address filter or empty               $5  what to call it on screen
#
# THE COST IS DECLARED AND CONFIRMED BEFORE ANYTHING IS READ, which is what cost
# class 3 means on a screen rather than in a table: how many files and how many
# bytes, from the same rule the scan will select by.
#
# IT IS THE SAME RULE, NOT THE SAME LIST, and the difference is worth stating. The
# selection is made again when the scan runs, because a path is never carried into
# the engine from a screen — the files come from the log inventory, which is what
# keeps this from being a general-purpose file reader. So a rotation that happens
# between the confirmation and the scan can move a file across the boundary. The
# residual runs in the visible direction: the answer names the files it really
# read, file by file, so what was scanned is on the screen next to what was
# promised rather than assumed to match it.
#
# Shared by both doors deliberately. What differs between a named question and free
# text is the pattern and the label; the window, the cost, the wait and every
# ending are the same, and a second copy of them is a second set to get wrong.
zro_screen_logsearch_do() {
  local key=${1-} kind=${2-} subject=${3-} filter=${4-} label=${5-}
  local window ws we plan files bytes out rc=0

  rc=0
  window=$(zro_prompt_window "$ZRO_TXT_LOGSEARCH_WINDOW") || rc=$?
  if [ "$rc" -ne 0 ]; then
    # Cancel is navigation, and a rejected date has already been shown on its own
    # screen. The clock is named rather than passed to the shared reporter,
    # because the only thing in that prompt which can be unavailable is the clock.
    case $rc in
      "$ZRO_E_CANCEL"|"$ZRO_E_INPUT") ;;
      "$ZRO_E_UNAVAILABLE")
        zro_ui_msgbox "Saat okunamadi" \
"Sistem saati okunamadi, bu nedenle aralik hesaplanamadi.

'date' komutu bu sunucuda calismiyor olabilir." ;;
      *) zro_report_error "$rc" ;;
    esac
    return 0
  fi
  ws=${window%%"$ZRO_TAB"*}
  we=${window#*"$ZRO_TAB"}

  rc=0
  plan=$(zro_logsearch_plan "$key" "$ws" "$we") || rc=$?
  if [ "$rc" -ne 0 ]; then
    zro_report_error "$rc"
    return 0
  fi
  files=${plan%%"$ZRO_TAB"*}
  bytes=${plan#*"$ZRO_TAB"}

  if [ "$files" -eq 0 ]; then
    # ORDINARY, not a failure: a host that does not write this log has none of its
    # files. Its own screen because an empty file list must never be read as an
    # empty answer — one says nothing was written, the other says there was
    # nothing to read.
    zro_ui_msgbox "Bulunamadi" \
"Bu log bu sunucuda bulunamadi: $(zro_inv_base_path "$key")

Dosya hic yok olabilir, ya da bulundugu dizin zimbra kullanicisi tarafindan
acilamiyor olabilir. Bu ikisi buradan ayirt edilemez.

Bu, aradiginiz kaydin olmadigini GOSTERMEZ."
    return 0
  fi

  # THE DECISION IS THE OPERATOR'S, and this is the screen where they can still
  # make it. A scan of a production mail log is real disk work on the server that
  # is already in trouble; the numbers are what turn "this might be slow" into
  # something anybody can decide.
  if ! zro_ui_yesno "Tarama maliyeti" \
"Aranacak: $files dosya, $(zro_human_bytes "$bytes") (diskteki boyut).

Dosyalar BASTAN SONA okunur. Sikistirilmis dosyalar acildiginda bu boyuttan
birkac kat buyuk olur, ve acilmalari zaman alir.

Tarama dusuk islemci onceligi ve bos disk onceligi ile calisir: mail sunucusu
diski isterse tarama bekler. Hicbir dosya degistirilmez.

Devam edilsin mi?"; then
    return 0
  fi

  zro_ui_notice "Calisiyor" "Log dosyalari taraniyor, lutfen bekleyin.

$label
Aralik: $(zro_win_human "$ws") - $(zro_win_human "$we")
$files dosya bastan sona okunacak; bu islem birkac dakika surebilir."

  rc=0
  case $kind in
    named) out=$(zro_logsearch_named "$subject" "$filter" "$ws" "$we") || rc=$? ;;
    text)  out=$(zro_logsearch_text "$key" "$subject" "$ws" "$we") || rc=$? ;;
    # The two questions about everybody. Each door is named literally, for the
    # reason the delivery trace names its three filters literally: a single call
    # site handing a variable to the engine would be a question nobody can read out
    # of this file.
    msgid) out=$(zro_logsearch_msgid "$subject" "$ws" "$we") || rc=$? ;;
    sender-domain) out=$(zro_logsearch_sender_domain "$subject" "$ws" "$we") || rc=$? ;;
    # Unreachable while the two callers above agree with this list, and here so
    # that they may only disagree loudly: without it a door added to one and
    # missed here would leave $out holding the PREVIOUS search's answer and $rc at
    # zero, and the operator would read the last question's answer under this
    # question's label.
    *) zro_log error "menu defect, no log search door for: $kind"
       zro_report_defect
       return 0 ;;
  esac

  # AN EMPTY ANSWER IS THE ANSWER, and this is the only screen in the tool that
  # may say so. Every file the window selected was opened and read from its first
  # line, so nothing found means nothing was there — as long as nothing was
  # missed, which is exactly what this code means and what the partial one below
  # does not.
  if [ "$rc" -eq "$ZRO_E_NO_RESULT" ]; then
    # THE FILES BY NAME, not just how many. This is the one screen in the tool
    # that says an absence means something, and an absence is only worth what the
    # list of what was read is worth: an operator has to be able to see that
    # yesterday's rotation was in it before they conclude anything from it. The
    # engine printed nothing — that is what this code means — so the list is
    # rebuilt from the same selection, which costs a glob and opens no file.
    zro_ui_msgbox "Kayit yok" \
"$label

Aralik: $(zro_win_human "$ws") - $(zro_win_human "$we")
Taranan dosyalar (en yeniden eskiye, her biri BASTAN SONA okundu):
$(zro_logsearch_files "$key" "$ws" "$we" | cut -f2 | sed 's/^/  /')

Bu aralikta eslesen satir YOK. Dosyalarin tamami okundugu icin bu, aranan seyin
YUKARIDAKI dosyalarda gerceklesmedigi anlamina gelir — daha eskisi icin araligi
genisletin."
    return 0
  fi
  # A PARTIAL SCAN IS AN ANSWER, not a failure, so it is shown rather than
  # reported. What makes it honest is that the disclosure travels in two places:
  # the banner the answer carries at the top, and this title — whiptail keeps a
  # title on the box frame while the text scrolls, so it is the one part of the
  # screen a long answer cannot push out of view.
  if [ "$rc" -eq "$ZRO_E_PARTIAL" ]; then
    zro_show_text "Log arama - EKSIK TARAMA" "$out"
    return 0
  fi
  if [ "$rc" -eq "$ZRO_E_NO_LOG" ]; then
    zro_screen_logsearch_no_log "$key"
    return 0
  fi
  if [ "$rc" -eq "$ZRO_E_TIMEOUT" ]; then
    zro_ui_msgbox "Zaman asimi" \
"Tarama ayrilan surede bitmedi.

Islem kesildi ve hicbir dosyaya DOKUNULMADI. Bu, aradiginiz kaydin olmadigini
GOSTERMEZ: tarama yarim kaldi.

Araligi daraltip yeniden deneyin, ya da ZRO_TIMEOUT degerini yukseltin."
    return 0
  fi
  if [ "$rc" -eq "$ZRO_E_UNAVAILABLE" ] && ! zro_cap_search_available; then
    # The host lost the priority tools between the menu being drawn and the scan
    # being run, or the operator started the tool on a host that never had them.
    # Either way this is the screen that names the repair.
    zro_logsearch_unavailable
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    zro_report_error "$rc"
    return 0
  fi
  zro_show_text "Log arama" "$out"
}

# Not one file could be read. Named file by file rather than through the shared
# reporter, whose message for this code is about an arrival window a trace
# selected — a window nobody chose on this screen.
zro_screen_logsearch_no_log() {
  local detail
  detail=$(zro_error_detail 'Sistemin bildirdigi')
  zro_ui_msgbox "Log okunamadi" \
"Bu logun secilen araliktaki dosyalarindan HICBIRI okunamadi:
$(zro_inv_base_path "${1-}")

Bu, aradiginiz kaydin olmadigini GOSTERMEZ: hicbir dosya taranamadi.

$ZRO_TXT_LOG_UNREADABLE$detail"
}

# ------------------------------------------------------------ the mail queue --

ZRO_TXT_QUEUE_WAIT='Kuyruk yalnizca LISTELENIR; hicbir ileti gonderilmez, yeniden siraya
alinmaz ve silinmez. Cok dolu bir kuyrukta bu islem birkac saniye surebilir.'

ZRO_TXT_QUEUE_PICK='Once sayilar, sonra ayrinti. Kuyruk okundu ve bu ekranda tutuluyor:
ayrintiya bakmak sunucuya yeni bir sorgu GONDERMEZ.'

# WHY THE QUEUE CANNOT BE READ, as its own screen per cause.
#
# TWO CAUSES WITH NOTHING IN COMMON. A build without the mail transfer agent has
# no queue tool and no setting that would produce one — the repair is a package.
# A host whose access-control setting does not list the account every command runs
# as HAS the tool, and refuses; the repair is that setting, and naming a package
# there would send an operator to install what is already installed.
#
# The cause comes from the capability module rather than being worked out again
# here, so the mark on the menu entry and this screen cannot disagree.
zro_queue_unavailable() {
  local said
  said=$(zro_last_error)
  [ -n "$said" ] && said="

Programin bildirdigi:
$said"

  case $(zro_cap_queue_reason) in
    nobin)
      zro_queue_unavailable_box \
"Kuyruk programi (postqueue) bu kurulumda bulunamadi. Bu sunucuda mail transfer
agent (zimbra-mta) paketi kurulu degil gorunuyor, dolayisiyla burada bir mail
kuyrugu YOKTUR. Bu bir izin sorunu DEGILDIR; izin veya ayar onarimi bunu
duzeltmez.

Beklenen konum: $ZRO_POSTFIX_SBIN/postqueue

Kontrol edin: bu sunucuda zimbra-mta paketi kurulu mu (zmcontrol status
ciktisinda mta satiri var mi)." ;;

    denied)
      zro_queue_unavailable_box \
"Kuyruk programi var ve calisiyor, ancak SUNUCU bu hesaba kuyrugu gostermeyi
reddediyor. Reddeden bu arac degil, Postfixin kendi ayaridir: kuyruk
authorized_mailq_users ayarindaki hesaplara gosterilir ve zimbra kullanicisi bu
listede degil.

Yetki YUKSELTILMEZ, sorun bildirilir: bu arac her komutu zimbra kullanicisi
olarak calistirir ve bunu degistirmez.

Kontrol edin: postconf -h authorized_mailq_users
Kurulumun varsayilan degeri static:anyone, yani herkese aciktir.$said" ;;

    # Reached only when the capability module learned to answer something this
    # case list has not caught up with, which is a defect in this file rather
    # than a fact about the server.
    *) zro_log error "menu defect, no unavailability screen for the mail queue: $(zro_cap_queue_reason)"
       zro_report_defect ;;
  esac
}

# The sentence both messages open with, written once, exactly as the delivery
# trace's four share theirs.
zro_queue_unavailable_box() {
  zro_ui_msgbox "Kullanilamaz" \
"Mail kuyrugu bu sunucuda okunamiyor.

${1-}"
}

# THE MAIL QUEUE: what is waiting, as counts first and bounded detail behind
# them.
#
# READ ONCE, and both screens are rendered from that one reading. An operator who
# looks at the counts, opens the detail and comes back has spent one invocation,
# not three — and the two screens cannot disagree about a queue that moved
# between them, which on a busy server it does every few seconds.
zro_menu_queue() {
  local title listing out choice rc=0
  if ! title=$(zro_menu_label mail-queue); then
    zro_log error "menu defect, no label for the mail queue"
    zro_report_defect
    return 0
  fi
  # REFUSED BEFORE THE WAIT, not from inside it. The entry that brought the
  # operator here is already marked; this is where they learn why and what
  # repairs it.
  if ! zro_cap_queue_available; then
    zro_queue_unavailable
    return 0
  fi

  zro_ui_notice "Calisiyor" "Mail kuyrugu okunuyor, lutfen bekleyin.

$ZRO_TXT_QUEUE_WAIT"

  listing=$(zro_queue_fetch) || rc=$?
  if [ "$rc" -ne 0 ]; then
    case $rc in
      # BOTH OF THESE ARE CAPABILITY ANSWERS, and the screen for them is the one
      # the menu mark points at. The refusal was recorded when it happened, so
      # asking the capability module again here answers 'denied' rather than
      # sending the operator to a second explanation of the same thing.
      #
      # ASKED RATHER THAN ASSUMED, and that is the difference between a screen
      # and a defect log. A tool that was there when the menu was drawn and is
      # gone now — a package removed while the session ran — refuses with a code
      # the capability cache still answers 'ok' for, and there is no repair
      # screen to draw for a state nobody can be in twice. It is reported as the
      # failure it was.
      "$ZRO_E_PERM"|"$ZRO_E_NOCAP")
        if zro_cap_queue_available; then
          zro_report_error "$rc"
        else
          zro_queue_unavailable
        fi ;;
      "$ZRO_E_TIMEOUT")
        zro_ui_msgbox "Zaman asimi" \
"Mail kuyrugu ayrilan surede okunamadi.

Islem kesildi ve kuyruga DOKUNULMADI: hicbir ileti gonderilmedi, yeniden
siraya alinmadi veya silinmedi.

Cok buyuk bir kuyrukta listeleme uzun surebilir. Gerekirse ZRO_TIMEOUT
degerini yukseltip yeniden deneyin." ;;
      *) zro_report_error "$rc" ;;
    esac
    return 0
  fi

  while :; do
    zro_show_text "$title" "$(zro_queue_summary_card "$listing")"

    rc=0
    choice=$(zro_ui_menu "$title" "$ZRO_TXT_QUEUE_PICK" \
      detail "Ayrintili liste (en fazla $ZRO_QUEUE_DETAIL_MAX kayit)" \
      back "Geri") || rc=$?
    [ "$rc" -eq 0 ] || return 0
    [ "$choice" = detail ] || return 0

    rc=0
    out=$(zro_queue_detail_card "$listing") || rc=$?
    case $rc in
      0) zro_show_text "$title" "$out" ;;
      # An empty queue has no detail, and that is the summary's answer rather
      # than a failure of this screen.
      "$ZRO_E_NO_RESULT")
        zro_ui_msgbox "$title" "Kuyruk bos: gosterilecek kayit yok." ;;
      # A bound that is not a count is a defect in whatever set it.
      *) zro_report_defect ;;
    esac
  done
}

# --------------------------------------------------------- the service status --

ZRO_TXT_SVC_WAIT='Bu komut once dizin (LDAP) sunucusuna sorar, sonra her servisi tek tek
sorar; birkac saniye surer. Hicbir servis baslatilmaz veya durdurulmaz.

Yazdigi tek sey Zimbranin kendi agacindaki .zmcontrol.cache dosyasi ve
gecici dosyalardir; ekranda yeniden soylenir.'

# WHICH SERVICES ARE RUNNING. One invocation, and the only operation in this tool
# whose command writes anything at all — which the screen says, above and below
# the answer.
zro_screen_service() {
  local title out card rc=0
  if ! title=$(zro_menu_label service-status); then
    zro_log error "menu defect, no label for the service status"
    zro_report_defect
    return 0
  fi

  zro_ui_notice "Calisiyor" "Servis durumu soruluyor, lutfen bekleyin.

$ZRO_TXT_SVC_WAIT"

  out=$(zro_svc_fetch) || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq "$ZRO_E_TIMEOUT" ]; then
      # NAMED HERE RATHER THAN LEFT TO THE SHARED REPORTER, which says only that
      # a command timed out. On this screen there is one cause worth naming: the
      # command asks the directory server before it asks anything else and has NO
      # ALARM OF ITS OWN around that step, so a directory that does not answer
      # leaves it waiting forever. The bound below is the only thing that ends
      # it, and an operator who is not told that reads a hang where there was a
      # refusal.
      zro_ui_msgbox "Zaman asimi" \
"Servis durumu ayrilan surede alinamadi ve komut $ZRO_TIMEOUT saniyede kesildi.

Bu komut once dizin (LDAP) sunucusuna sorar ve BU ADIMDA KENDI ZAMAN SINIRI
YOKTUR: dizin yanit vermezse suresiz bekler. Onu kesen, bu aracin her komuta
uyguladigi ust siniridir.

Islem kesildi ve hicbir servise DOKUNULMADI.

Kontrol edin: dizin (ldap) servisi calisiyor mu, ve sunucu asiri yuklu mu."
      return 0
    fi
    zro_report_error "$rc"
    return 0
  fi

  rc=0
  card=$(zro_svc_card "$out") || rc=$?
  if [ "$rc" -ne 0 ]; then
    # The command answered something with no service line in it. Said as itself:
    # a screen reporting every service as absent would be the most alarming one
    # in the tool, and it would be invented.
    zro_ui_msgbox "Okunamadi" \
"Komut calisti, ancak yanitinda hicbir servis satiri yok; bu ekran durumu
okuyamadi.

Bu, servislerin durdugu anlamina GELMEZ. Arac gunlugune ve dogrudan
zmcontrol status ciktisina bakin."
    return 0
  fi
  zro_show_text "$title" "$card"
}

# ---------------------------------------------------------- the bulk queries --

ZRO_TXT_BULK_SOURCE='Sorgu, YAZDIGINIZ listedeki hesaplar icin calisir. Sunucudaki butun
hesaplar taranmaz: boyle bir tarama bu araca hic konulmadi.

Liste nereden gelsin?'

ZRO_TXT_BULK_FILE='Liste dosyasinin TAM YOLU (ornek: /root/hesaplar.txt)

Dosyada her satirda bir adres olabilir; virgul, noktali virgul ve bosluk da
adresleri ayirir. Dosya yalnizca OKUNUR.

Yol / ile baslamalidir ve yalnizca harf, rakam, nokta, alt tire, tire ve
bolu isareti icerebilir.'

ZRO_TXT_BULK_TEXT='Adresleri virgul ile ayirarak yazin ya da yapistirin
(ornek: ali@example.com, veli@example.com)

Noktali virgul, bosluk ve satir sonu da ayirac sayilir.'

# What an operator is holding when a path is refused, and what to do about it.
# Each cause its own screen, because a cause an operator would repair the same way
# as another does not earn a message of its own — and one message naming every
# cause would send most of its readers to the wrong place.
#
# THE FILE IS READ BY THIS PROGRAM ITSELF, not by a Zimbra command, so the
# unreadable case names the account the TOOL runs as rather than the zimbra
# account every query runs as. Those are not always the same user, and sending an
# operator to zmfixperms over their own list file would be sending them to repair
# something that is not broken.
zro_screen_bulk_file_refused() {
  local verdict=${1-} path=${2-}
  case $verdict in
    shape)
      zro_ui_msgbox "Gecersiz dosya yolu" \
"Bu yol acilmadi: aranan bicimde degil.

Yol / ile baslamali, .. icermemeli ve yalnizca harf, rakam, nokta, alt tire,
tire ve bolu isareti icermelidir. Bosluk, tirnak ve kabuk karakterleri
kabul edilmez.

Girilen: $path" ;;
    missing)
      zro_ui_msgbox "Dosya bulunamadi" \
"Bu sunucuda boyle bir dosya yok:
$path

Yol dogru yazilmis mi, dosya bu sunucuda mi kontrol edin." ;;
    notfile)
      zro_ui_msgbox "Dosya degil" \
"Bu yol bir dosyayi degil, baska bir seyi gosteriyor (dizin ya da aygit):
$path

Adres listesi duz metin bir DOSYA olmalidir." ;;
    unreadable)
      zro_ui_msgbox "Dosya okunamiyor" \
"Bu dosya acilamadi:
$path

Dosya, bu araci calistiran kullanici tarafindan okunabilir olmalidir." ;;
    empty)
      zro_ui_msgbox "Dosya bos" \
"Bu dosyada hicbir sey yok:
$path

Dosya okundu ve icinde tek bir adres bile bulunmadi. Bu bir hata degil:
dosyanin kendisi bos." ;;
    toobig)
      zro_ui_msgbox "Dosya cok buyuk" \
"Bu dosya bir adres listesi icin fazla buyuk, bu nedenle acilmadi:
$path

En fazla $(zro_human_bytes "$ZRO_BULK_FILE_BYTES") okunur. Bu boyut binlerce
adrese yeter; daha buyuk bir dosya buyuk ihtimalle adres listesi degildir." ;;
    *)
      zro_log error "menu defect, no screen for list file verdict: $verdict"
      zro_report_defect ;;
  esac
}

# THE PATH THE OPERATOR NAMED, once it has been judged. Empty until then.
#
# A global rather than something printed, and not for tidiness: the caller needs
# BOTH the path and the file's contents — one to head the report with and one to
# read the list out of — and a function that printed the contents could not also
# hand back the path. An assignment made inside the command substitution that
# collected the contents would die with the subshell, which is the bug lib/core.sh
# records having already been fixed twice. Named the way ZRO_MENU_REASON and
# ZRO_UI_ARGV are: bash 4.2 has no namerefs, so this is how a value comes back
# from a function that must run in its caller's shell.
ZRO_BULK_PATH=""

# Asks for a list file and admits it, or explains why not.
#
# The path is judged BEFORE anything opens it, which is the one thing this prompt
# is for: every other file this tool reads is one the tool itself chose out of a
# declared inventory, and this is the only place an operator names one.
zro_prompt_bulk_file() {
  local path rc=0 verdict
  ZRO_BULK_PATH=""
  path=$(zro_ui_input "Liste dosyasi" "$ZRO_TXT_BULK_FILE") || rc=$?
  [ "$rc" -eq 0 ] || return "$ZRO_E_CANCEL"

  verdict=$(zro_bulk_file_verdict "$path")
  if [ "$verdict" != ok ]; then
    zro_screen_bulk_file_refused "$verdict" "$path"
    return "$ZRO_E_INPUT"
  fi
  ZRO_BULK_PATH=$path
  return 0
}

# WHAT THE RUN WILL COST, SAID BEFORE IT SPENDS IT — and, unlike a log scan, said
# in accounts and minutes rather than in files and bytes, because that is the unit
# this screen's work grows with.
#
# THE CAP IS STATED WHETHER OR NOT IT APPLIED. An operator who handed over three
# hundred addresses has to learn that a hundred of them will not be read HERE,
# where they can still decide, rather than from a line at the bottom of a report
# they have already read as an answer about three hundred accounts.
zro_bulk_confirm_text() {
  local plan=${1-} label=${2-} n bad dup cut
  n=$(zro_bulk_plan_addresses "$plan" | grep -c .)
  bad=$(zro_bulk_plan_count "$plan" bad)
  dup=$(zro_bulk_plan_count "$plan" dup)
  cut=$(zro_bulk_plan_count "$plan" cut)

  printf 'Sorgu: %s\n\n' "$label"
  printf 'Sorgulanacak: %s adres, her biri icin bir dizin sorgusu.\n' "$n"
  printf 'Tahmini sure: %s\n\n' "$(zro_bulk_duration "$((n * ZRO_BULK_SECONDS))")"
  [ "$bad" -gt 0 ] && printf 'Listede %s gecersiz girdi var; atlanacaklar.\n' "$bad"
  [ "$dup" -gt 0 ] && printf 'Listede %s tekrar eden adres var; bir kez sorgulanacaklar.\n' "$dup"
  [ "$cut" -gt 0 ] && printf 'Liste siniri asiyor; %s adres SORGULANMAYACAK.\n' "$cut"
  printf 'Sinir: en fazla %s adres.\n\n' "$ZRO_BULK_MAX"
  printf 'Sorgu sirasinda ESC ile durdurabilirsiniz; o ana kadar bulunanlar\n'
  printf 'korunur ve sonuc EKSIK olarak isaretlenir.\n\n'
  printf 'Devam edilsin mi?'
  return 0
}

# ONE QUESTION, ASKED ABOUT A LIST THE OPERATOR SUPPLIED.
#
# The screen that exists instead of the server-wide sweep. Nothing here reads the
# selected address: a bulk query is about the list, and the address on the frame is
# what the session is about — which is why these two entries are server-scoped and
# still cost class 1.
zro_menu_bulk() {
  local id=${1-} question title source raw plan rc=0 choice out
  if ! title=$(zro_menu_label "$id"); then
    zro_log error "menu defect, no label for bulk operation: $id"
    zro_report_defect
    return 0
  fi
  # The question is named literally, for the reason every other dispatch in this
  # file names its own: an id built by cutting a prefix off a menu entry is an
  # operation nobody can read out of this file.
  case $id in
    bulk-status) question=status ;;
    bulk-mail)   question=mail ;;
    *) zro_log error "menu defect, no bulk question for: $id"
       zro_report_defect
       return 0 ;;
  esac

  rc=0
  choice=$(zro_ui_menu "Liste kaynagi" "$ZRO_TXT_BULK_SOURCE" \
    file "Adres listesini bir dosyadan oku" \
    text "Adresleri buraya yaz veya yapistir") || rc=$?
  [ "$rc" -eq 0 ] || return 0

  case $choice in
    file)
      # Cancel is navigation and a refused path has had its own screen already.
      # The prompt runs HERE rather than inside a command substitution, so that
      # the path it admitted survives to be read and to head the report.
      zro_prompt_bulk_file || return 0
      rc=0
      raw=$(zro_bulk_read_file "$ZRO_BULK_PATH") || rc=$?
      if [ "$rc" -ne 0 ]; then
        # The file passed admission one line ago and would not open. Something
        # changed underneath, which is a fact about the file rather than about
        # what the operator typed.
        zro_screen_bulk_file_refused unreadable "$ZRO_BULK_PATH"
        return 0
      fi
      source="dosya: $ZRO_BULK_PATH" ;;
    text)
      rc=0
      raw=$(zro_ui_input "Adres listesi" "$ZRO_TXT_BULK_TEXT") || rc=$?
      [ "$rc" -eq 0 ] || return 0
      source="yazilan liste" ;;
    *) zro_log error "menu defect, no such list source: $choice"
       zro_report_defect
       return 0 ;;
  esac

  rc=0
  plan=$(zro_bulk_plan "$raw") || rc=$?
  if [ "$rc" -ne 0 ]; then
    # The cap is a declaration this program owns, so a cap that is not a count is
    # a defect in it rather than something the operator typed.
    zro_report_defect
    return 0
  fi

  if [ -z "$(zro_bulk_plan_addresses "$plan")" ]; then
    # A RESULT ABOUT THE LIST, not a failure: whatever was there has been read and
    # none of it was an address. Two screens rather than one, because the two
    # cases are two different mistakes — a list that had nothing in it at all, and
    # a list full of entries none of which is an address. Nothing else can reach
    # here: a repeat and a capped entry both require an accepted one in front of
    # them, so with no address accepted the only other tag possible is 'bad'.
    if [ "$(zro_bulk_plan_count "$plan" bad)" -eq 0 ]; then
      zro_ui_msgbox "Liste bos" \
"Bu listede hicbir sey yok, bu nedenle hicbir sorgu calistirilmadi.

Kaynak: $source

Adresleri virgul, noktali virgul, bosluk ya da satir sonu ile ayirin."
      return 0
    fi
    # A SCROLLING BOX RATHER THAN A MESSAGE, because what this one has to show is
    # a line per refused entry and a list pasted from the wrong column is twenty
    # of them. A message box does not scroll, so the explanation would be the part
    # that fell off the bottom.
    zro_show_text "Sorgulanacak adres yok" \
"Bu listedeki girdilerin hicbiri gecerli bir e-posta adresi degil, bu nedenle
hicbir sorgu calistirilmadi.

$(zro_card_line 'Liste kaynagi' "$source")
$(zro_card_line 'Gecersiz girdi' "$(zro_bulk_plan_count "$plan" bad)")

Sorgulanmayan girdiler:
$(zro_bulk_plan_rejects "$plan")"
    return 0
  fi

  if ! zro_ui_yesno "Toplu sorgu maliyeti" "$(zro_bulk_confirm_text "$plan" "$title")"; then
    return 0
  fi

  rc=0
  out=$(zro_bulk_run "$question" "$source" "$plan") || rc=$?
  # A PARTIAL ANSWER IS AN ANSWER, so it is shown rather than reported — and the
  # disclosure travels in two places, the banner at the top of the text and this
  # title, because whiptail keeps a title on the frame while a long report scrolls.
  if [ "$rc" -eq "$ZRO_E_PARTIAL" ]; then
    zro_show_text "$title - EKSIK SONUC" "$out"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    zro_report_error "$rc"
    return 0
  fi
  zro_show_text "$title" "$out"
}

# THE COST CLASSES AN OPERATION MAY CLAIM, as "<class>:<the unit its work is
# counted in>".
#
# A class is not a speed and not a warning: it is what the work grows with, said as
# the unit one invocation buys. Class 1 is counted in ENTRIES — a directory read
# about one account, domain or list, plus a read per entry that entry itself names.
# Class 2 is counted in MAILBOXES — a read about the message store of one account,
# which is one invocation per account and is cached for the session once it has
# answered. Class 3 is counted in FILES — one read per log file opened, and which
# files those are is the operator's arrival window on a trace and the operator's own
# choice in the viewer. What every declared class has in common is the sentence the
# whole tool rests on: none of these units is the number of accounts on the server.
#
# THE UNIT IS WHAT MAKES THE CLASS CHECKABLE. A screen's cost can then be asserted
# as a count of the things its own answer named — the entries a record points at,
# the files a window covers — rather than as a number somebody wrote down and would
# have updated. A screen that quietly started reading per account fails against the
# unit it declared, which is the whole reason the class is written here.
#
# THE UNIT IS NOT ALWAYS ONE INVOCATION, and exactly one screen shows why. The
# provenance screen reads ONE entry TWICE — once with the class of service expanded
# into it and once without — because the difference between those two answers is
# the question it exists to ask. It is class 1 all the same: what its work grows
# with is entries, and one account still costs a fixed two reads however large the
# directory around it gets. A screen that pays more than once per entry says so at
# its own declaration, and the suite asserts the multiple rather than the total.
#
# CLASS 2 ARRIVED WITH THE OPERATION THAT MAKES ONE. It was left out while nothing
# claimed it, because the suite holds this table and the list below equal in BOTH
# directions and a class nothing claims is a declaration nothing checks. What claims
# it is the existence gate: one read about one account's message store, cached once
# it has answered, and the precondition every later mailbox screen is built on. Its
# unit is the mailbox rather than the entry, and the difference is not cosmetic — a
# directory read answers for an account that has never been used, and this one is
# the question of whether there is anything there to read.
#
# CLASS 4 IS NOT HERE AND CANNOT BE ADDED. A server-wide sweep is what this tool
# refuses to be, and the refusal is worth nothing if the vocabulary can still name
# one: a class that can be declared is a class that will one day be claimed. The
# suite refuses the digit itself, in this table and in the list below, so the
# attempt fails the build rather than passing as an ordinary new entry.
#
# CLASS 5 ARRIVED WITH THE OPERATIONS THAT MAKE ONE, exactly as class 2 did, and
# it is numbered 5 because the digit 4 is refused rather than free. Its unit is
# the HOST: one invocation asks this server a question about ITSELF — which
# services are running, what is waiting in the mail queue — and there is one
# server to ask however large the directory on it grows. That is what makes it a
# class of its own rather than an awkward reading of one of the three above: it
# names no account, opens no mailbox, and reads no file this program chose.
#
# WHAT ITS WORK REALLY GROWS WITH IS THE SERVER'S OWN BUSINESS — the services
# installed, the messages queued — and neither of those is a number an operator
# can spend. The queue tool on a queue of thousands is one invocation and so is
# the queue tool on an empty one; what a busy queue costs is the SCREEN, which is
# why the screen behind this class answers with counts before it answers with a
# list.
# SC2034: read by NAME through lib/table.sh, never expanded here.
# shellcheck disable=SC2034
ZRO_COST_CLASSES='1:entry
2:mailbox
3:file
5:host'

# The unit a declared class's work is counted in, or a refusal for a class this
# tool does not declare. Every lookup goes through this, so a class nobody
# declared — 4 above all — has exactly one answer everywhere: no.
zro_cost_unit() {
  zro_table_rest ZRO_COST_CLASSES "${1-}" 1
}

# THE ONE LIST: every operation this tool offers, in the order it offers them, as
# "<id>:<scope>:<class>:<label>".
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
# CLASS is what the operation costs at production scale, named from the table
# above. The LABEL is what the operator reads, here and again as the title over
# the result, so those two cannot drift apart. A label may contain a colon; only
# the first three are separators.
#
# FOUR SCOPES, not two. 'account' needs the selected address to BE an account —
# an account read on a distribution list fails with "no such account", which is
# true and useless. 'list' is the mirror of it: a list read on an account fails
# just as flatly, and the screen behind it is the one that answers for the kind
# 'account' cannot. 'address' needs an address of any kind: mail to a list shows
# up in the transfer agent's log under the list's own address, so a trace answers
# there exactly as it does for a mailbox — and every address has a domain, so the
# domain card answers even for one the directory has never heard of. 'server'
# needs none.
#
# The distinction is what makes the identity worth resolving. Without it every
# kind would share one mark, and marking a trace unavailable on a list address
# would take away the one screen that still answers.
#
# THE CLASS IS HERE RATHER THAN IN A COMMENT AT THE TOP OF A MODULE, because a
# comment is not something the program can be held to. Declared here it sits in
# the one list every operation must already appear in to exist at all, so an
# operation cannot arrive without a class the way it cannot arrive without a
# label — and the suite holds this list and the table above equal in both
# directions, the way it already holds the allowlist and the table of binary
# roots. An operation with no class fails the build; a class no operation claims
# fails it too.
# SC2034: read by NAME through lib/table.sh, never expanded here.
# shellcheck disable=SC2034
ZRO_MENU_OPS='account-card:account:1:Hesap karti
account-provenance:account:1:Deger nereden geliyor (hesap mi, devralma mi)
account-membership:account:1:Dagitim listesi uyelikleri
account-mailsettings:account:1:Posta ayarlari (filtre, teslim, imza)
account-filters:account:1:Filtre kurallarinin tam metni
mailbox-status:account:2:Mailbox var mi
mailbox-quota:account:2:Kota kullanimi
mailbox-size:account:2:Mailbox boyutu
mailbox-folders:account:2:Klasorler
mailbox-folder:account:2:Klasor detayi
mailbox-folder-grants:account:2:Klasor paylasimlari
mailbox-search:account:2:Ileti arama
mailbox-conversation:account:2:Konusma arama ve konusmadaki iletiler
mailbox-message:account:2:Ileti detayi (kayit ve basliklar)
dl-card:list:1:Dagitim listesi karti
domain-card:address:1:Alan adi karti
trace-recipient:address:3:Teslim takibi: bu adrese gelenler
trace-sender:address:3:Teslim takibi: bu adresten gidenler
trace-msgid:server:3:Teslim takibi: ileti kimligine gore
logview:server:3:Log dosyalari (son satirlar)
log-search:server:3:Log arama (dosyalarin tamaminda)
mail-queue:server:5:Mail kuyrugu (bekleyen iletiler)
service-status:server:5:Servis durumu
bulk-status:server:1:Toplu sorgu: listedeki hesaplarin durumu
bulk-mail:server:1:Toplu sorgu: listedeki filtre ve yonlendirmeler'

# The declared entry for an id, or a refusal. Every lookup below goes through
# this, so an id that is not in the list has exactly one answer everywhere.
zro_menu_entry() {
  zro_table_entry ZRO_MENU_OPS "${1-}"
}

# The declared ids, in the order they are offered.
zro_menu_ids() {
  zro_table_keys ZRO_MENU_OPS
}

zro_menu_scope() {
  zro_table_field ZRO_MENU_OPS "${1-}" 1
}

# The cost class an operation claims. A class this tool does not declare is not
# reported as the operation's own — it is refused here, so an entry naming class
# 4 answers the same way an entry naming nothing does.
zro_menu_cost() {
  local class
  class=$(zro_table_field ZRO_MENU_OPS "${1-}" 2) || return "$ZRO_E_INPUT"
  zro_cost_unit "$class" >/dev/null || return "$ZRO_E_INPUT"
  printf '%s' "$class"
}

# The remainder rather than a fixed field: a label is what the operator reads and
# may carry a colon, as the bulk query's two already do.
zro_menu_label() {
  zro_table_rest ZRO_MENU_OPS "${1-}" 3
}

# WHY an operation cannot answer, in one word, or nothing when it can. Decided in
# ONE place so that the mark on the entry, the refusal before dispatch and the
# screen that explains it cannot disagree. It is never a safety check — the exec
# gate refuses on its own terms — it is what keeps an operator from spending a
# search to discover something already known.
#
# THREE REASONS, and they are about different things. 'nocap' is a fact about this
# host: a binary this build does not ship, a log nothing can read. 'notaccount'
# and 'notlist' are facts about the selected address: it resolved to something the
# screen behind the entry cannot answer for. A host fact outranks an address fact,
# because it holds whatever address is chosen next.
#
# The two address reasons are separate marks rather than one 'wrong kind', because
# an operator reads the mark to learn what the address IS. 'this address is not an
# account' on a list and 'this address is not a list' on an account are the same
# refusal and opposite pieces of information.
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
    # The queue's two host facts, ranked in the capability module and read here
    # as the one word the menu can draw. The refusal by the host's own
    # access-control setting is learned by being refused once, so this entry is
    # marked from the moment the operator has met it — and never before, because
    # the only way to ask is to ask.
    mail-queue) zro_cap_queue_available || { ZRO_MENU_REASON=nocap; return 0; } ;;
    # The search's one host fact, and it is about how a scan RUNS rather than
    # about what it reads: a host that cannot reduce priority cannot be offered a
    # scan that keeps this tool's promise to yield. Which files are readable is
    # answered by the scan itself and disclosed as a partial scan, exactly as the
    # viewer answers it — so this entry is marked for that and nothing else.
    log-search) zro_cap_search_available || { ZRO_MENU_REASON=nocap; return 0; } ;;
  esac
  case $(zro_menu_scope "$id" 2>/dev/null) in
    account)
      case $(zro_identity_selected_kind) in
        list|absent) ZRO_MENU_REASON=notaccount ;;
      esac ;;
    list)
      # An alias and a resource are accounts, so they are refused here exactly as
      # a plain account is. Absence is refused by both scopes, and says so twice
      # in two different words, which is the only pair of marks that can be read
      # together and still be right.
      case $(zro_identity_selected_kind) in
        account|alias|resource|absent) ZRO_MENU_REASON=notlist ;;
      esac ;;
  esac
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
    notlist)    printf ' - BU ADRES LISTE DEGIL' ;;
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
    # A HOST FACT IS ABOUT ONE OPERATION'S TOOL, so which screen explains it
    # depends on which tool is missing. The delivery trace and the mail queue
    # share the word 'nocap' and share nothing else: one names a tracing binary
    # and a log file's ownership, the other names a package and a Postfix
    # setting. Reading the same screen for both would send half its readers to
    # repair something that is not broken.
    nocap)
      case ${1-} in
        trace-*)    zro_delivery_unavailable ;;
        mail-queue) zro_queue_unavailable ;;
        log-search) zro_logsearch_unavailable ;;
        *) zro_log error "menu defect, no unavailability screen for: ${1-} (${2-})"
           zro_report_defect ;;
      esac ;;
    # Both address reasons answer with the same screen, and that is the point of
    # it: what the operator needs is not "this is not a list" but what the address
    # turned out to be instead, which the session already knows and never re-reads.
    notaccount|notlist) zro_screen_identity ;;
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
      account-*)   zro_screen_account "$choice" ;;
      # The two screens that need a folder before they can ask anything come
      # first: both are mailbox operations, and a case list that matched the
      # family before the members would send them to a screen that has no folder
      # to work with.
      mailbox-folder|mailbox-folder-grants) zro_menu_folder "$choice" ;;
      # The two that build a query before they ask anything, and for the same
      # reason: what the operator chooses first is the question, not the screen.
      mailbox-search|mailbox-conversation) zro_menu_search "$choice" ;;
      # And the one that asks for an identifier first. Before the family, like the
      # four above: a case list that matched `mailbox-*` first would send it to a
      # screen with no message to read.
      mailbox-message) zro_menu_message "$choice" ;;
      mailbox-*)   zro_screen_mailbox "$choice" ;;
      dl-card)     zro_screen_dl "$choice" ;;
      domain-card) zro_screen_domain "$choice" ;;
      trace-*)     zro_screen_trace "$choice" ;;
      logview)     zro_menu_logview ;;
      log-search)  zro_menu_logsearch ;;
      mail-queue)  zro_menu_queue ;;
      service-status) zro_screen_service ;;
      # The two that are about a list rather than about the selected address. They
      # come last for the reason the order of the whole list says: what needs no
      # address comes after what does, and these need not even a server-wide
      # question — they need what the operator hands them.
      bulk-*)      zro_menu_bulk "$choice" ;;
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
