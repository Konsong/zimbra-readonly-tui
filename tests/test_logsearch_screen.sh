#!/usr/bin/env bash
# The log search's screens, driven through the stub UI backend.
#
# What these cases hold the tool to is what an OPERATOR would see: the questions
# offered, the cost declared before anything is read, the confirmation that can
# refuse it, and — above everything else — that an empty answer and an incomplete
# one arrive as two different screens.
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ZIMBRA_LIBEXEC="$ZRO_TEST_ROOT/mocks/libexec"
export ZRO_POSTFIX_SBIN="$ZRO_TEST_ROOT/mocks/sbin"
export ZRO_SYSTEM_BIN="$ZRO_TEST_ROOT/mocks/system"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
export ZRO_NICE_BIN="$ZRO_TEST_ROOT/mocks/bin/nice"
export ZRO_IONICE_BIN="$ZRO_TEST_ROOT/mocks/bin/ionice"
export ZRO_UI_BACKEND=stub
export ZRO_SOURCED_ONLY=1
export ZRO_CAP_FORCE_QUEUE_BIN=yes
export ZRO_MOCK_ID_USER=zimbra
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* "$ZRO_TEST_ROOT"/mocks/libexec/* \
         "$ZRO_TEST_ROOT"/mocks/system/* "$ZRO_TEST_ROOT"/mocks/sbin/* 2>/dev/null || true

export TZ=UTC

TREE=$(mktemp -d)
mkdir -p "$TREE/var/log" "$TREE/zimbra/log"
export ZRO_SYSLOG_FILE="$TREE/var/log/zimbra.log"
export ZRO_LOG_DIR="$TREE/zimbra/log"

FIX="$ZRO_TEST_ROOT/fixtures"
SYS="$TREE/var/log/zimbra.log"
MBOX="$TREE/zimbra/log/mailbox.log"

# The mail log as it really is: the interesting lines in the middle of a file
# whose end holds nothing but noise.
pad() { seq 1 "$1" | sed 's/^/Aug  2 12:00:00 posta postfix\/smtpd[1]: padding line /'; }
{ pad 300; cat "$FIX/zimbra_log_outcomes.txt"; pad 300; } >"$SYS"
touch -d '2026-07-30 10:00' -- "$SYS"
cat "$FIX/mailbox_log_errors.txt" >"$MBOX"
touch -d '2026-07-30 09:00' -- "$MBOX"
chmod 644 -- "$SYS" "$MBOX"
# The audit log is declared and simply not on this host, which is ordinary and is
# one of the screens below.

# shellcheck source=../zimbra-ro-tui.sh
. "$ZRO_SRC/zimbra-ro-tui.sh"
# Sourced after the program, because it reads the program's own declarations.
# shellcheck source=lib/cost.sh
. "$ZRO_TEST_ROOT/lib/cost.sh"

ZRO_MOCK_LOG=$(mktemp);  export ZRO_MOCK_LOG
ZRO_UI_QUEUE=$(mktemp);  export ZRO_UI_QUEUE
ZRO_UI_OUT=$(mktemp);    export ZRO_UI_OUT
ZRO_ERROR_FILE=$(mktemp); export ZRO_ERROR_FILE
export ZRO_MOCK_ZMCONTROL__V_OUT="$ZRO_TEST_ROOT/fixtures/zmcontrol_v.txt"

queue() { printf '%s\n' "$@" >"$ZRO_UI_QUEUE"; zro_ui_reset; }
transcript() { cat "$ZRO_UI_OUT"; }
ran() { grep -E '^(grep|gzip)' "$ZRO_MOCK_LOG"; }

# The window preset every case below uses. 'week' reaches back over both files on
# this tree without an explicit range to type.
#
# A named question with nothing selected asks no filter question, so the common
# path is: the question, the window, the confirmation, then out.
NAMED=("rejected" "week" "yes" "__CANCEL__" "__CANCEL__")

# --- the way in ---------------------------------------------------------------

it "the log search is reachable from the main menu"
queue "log-search" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
zro_menu_main
assert_contains "$(transcript)" "Log arama"

it "and stands beside the viewer rather than replacing it"
# Two screens with two jobs: the viewer answers what a log says now, from the end
# of one file; this answers whether something happened, from the whole of every
# file. An operator has to be able to see both.
queue "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
zro_menu_main
out=$(transcript)
assert_contains "$out" "Log dosyalari (son satirlar)"
assert_contains "$out" "Log arama (dosyalarin tamaminda)"

it "the first screen offers every declared question by name"
queue "__CANCEL__"
: >"$ZRO_UI_OUT"
zro_menu_logsearch
out=$(transcript)
missing=""
while IFS= read -r id; do
  [ -n "$id" ] || continue
  case $out in
    *"$(zro_logsearch_question_label "$id")"*) ;;
    *) missing="$missing [$id]" ;;
  esac
done <<EOF
$(zro_logsearch_questions)
EOF
assert_eq "$missing" ""

it "and free text as the one entry that is not a question the tool owns"
assert_contains "$out" "Duz metin ara"

# --- the cost, before anything is read ----------------------------------------

it "declares how many files and how many bytes before it reads any of them"
queue "${NAMED[@]}"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
zro_menu_logsearch
out=$(transcript)
assert_contains "$out" "YESNO Tarama maliyeti"
assert_contains "$out" "1 dosya"
assert_contains "$out" "$(zro_human_bytes "$(stat -c %s "$SYS")")"

it "and the declaration comes before the first reader runs"
# ORDER IS THE WHOLE POINT of a declared cost. A number shown after the disk work
# has happened is a receipt, not a decision.
cost_at=$(grep -n 'YESNO Tarama maliyeti' "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
notice_at=$(grep -n 'NOTICE Calisiyor' "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
assert_ok test "$cost_at" -lt "$notice_at"

it "reads nothing at all when the operator declines the cost"
queue "rejected" "week" "no" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
zro_menu_logsearch
assert_eq "$(ran)" ""
assert_not_contains "$(transcript)" "TEXT Log arama"

it "and a cancelled confirmation is a no, not a yes"
queue "rejected" "week" "__CANCEL__" "__CANCEL__" "__CANCEL__"
: >"$ZRO_MOCK_LOG"
zro_menu_logsearch
assert_eq "$(ran)" ""

it "requires a window, and cancelling it reads nothing"
queue "rejected" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
zro_menu_logsearch
assert_eq "$(ran)" ""
# There is no entry on that menu that means "every file there is".
assert_not_contains "$(transcript)" "Tum zamanlar"

it "and says the window chooses files rather than filtering lines"
assert_contains "$(transcript)" "DOSYALARININ taranacagini secer"

# --- the answer ---------------------------------------------------------------

it "shows the matching lines, under a header naming what was searched"
queue "${NAMED[@]}"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
zro_menu_logsearch
out=$(transcript)
assert_contains "$out" "TEXT Log arama"
assert_contains "$out" "NOQUEUE: reject:"
assert_contains "$out" "Reddedilen mail"
assert_contains "$out" "$SYS"
assert_contains "$out" "TAMAMI okundu"

it "and it found what a bounded read of the same file cannot"
# The line is 300 lines from the end. This is the difference between the two log
# screens, asserted as an operator would meet it.
assert_contains "$out" "olmayan-kullanici@example.com"

it "one file opened, one read, held to the class the entry declares"
# Class 3 costs one read per log file opened, and which files those are is the
# operator's window. No answer they can give makes this screen read one file per
# account — that is the whole of its claim to the class.
assert_cost log-search "$(ran | grep -c .)" 1

it "says the scan is running before the wait begins"
assert_contains "$out" "NOTICE"
assert_contains "$out" "bekleyin"

it "an empty answer is a complete one, and says so in those words"
# THE SENTENCE THIS WHOLE FEATURE EXISTS TO BE ABLE TO WRITE. Every file was read
# from its first line, so nothing found means nothing happened — and this is the
# only screen in the tool allowed to say that.
queue "text" "syslog" "yok-boyle-bir-sey-19283746" "week" "yes" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
zro_menu_logsearch
out=$(transcript)
assert_contains "$out" "MSG Kayit yok"
assert_contains "$out" "BASTAN SONA okundu"
assert_contains "$out" "gerceklesmedigi anlamina gelir"

it "and names the files that absence covers, not just how many there were"
# An absence is worth exactly what the list of what was read is worth. This is the
# one screen in the tool that says nothing found means nothing happened, so an
# operator has to be able to see that yesterday's rotation was in the list before
# they conclude anything from it.
assert_contains "$out" "$SYS"

it "and an incomplete one never says it"
# The same empty result out of a scan that could not open a file is a different
# screen with the opposite meaning.
cp "$MBOX" "$TREE/zimbra/log/mailbox.log.1.gz"
touch -d '2026-07-29 03:20' -- "$TREE/zimbra/log/mailbox.log.1.gz"
queue "text" "mailbox" "yok-boyle-bir-sey-19283746" "week" "yes" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
zro_menu_logsearch
out=$(transcript)
assert_contains "$out" "EKSIK TARAMA"
assert_not_contains "$out" "MSG Kayit yok"

it "a partial scan carries the warning in the title as well as in the answer"
# whiptail keeps a title on the frame while the text scrolls, so the title is the
# one part of the screen a long answer cannot push out of view.
queue "text" "mailbox" "LmtpServer" "week" "yes" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
zro_menu_logsearch
out=$(transcript)
assert_contains "$out" "TEXT Log arama - EKSIK TARAMA"
assert_contains "$out" "KANITLAMAZ"
assert_contains "$out" "zmfixperms"
# And the answer that could be found is still there, under the banner.
assert_contains "$out" "TcpServer/7025"
rm -f -- "$TREE/zimbra/log/mailbox.log.1.gz"

it "a scan that hits the cap says so, and says the scan stopped there"
queue "text" "syslog" "padding" "week" "yes" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_LOGSEARCH_MATCHES=3 zro_menu_logsearch
out=$(transcript)
assert_contains "$out" "SINIRA ULASILDI"
assert_contains "$out" "TEXT Log arama - EKSIK TARAMA"

it "a log this host does not have is not an empty answer"
queue "text" "audit" "cmd=Auth" "week" "yes" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
zro_menu_logsearch
out=$(transcript)
assert_contains "$out" "MSG Bulunamadi"
assert_contains "$out" "GOSTERMEZ"
assert_eq "$(ran)" ""

it "a file that cannot be read at all names the cause and the repair"
queue "${NAMED[@]}"
: >"$ZRO_UI_OUT"
ZRO_MOCK_GREP_RC=2 ZRO_MOCK_GREP_ERR="grep: $SYS: Permission denied" \
  zro_menu_logsearch
out=$(transcript)
assert_contains "$out" "MSG Log okunamadi"
assert_contains "$out" "zmfixperms"
assert_contains "$out" "Permission denied"
assert_contains "$out" "GOSTERMEZ"

it "a scan cut off by the clock is not an answer about the server"
queue "${NAMED[@]}"
: >"$ZRO_UI_OUT"
ZRO_MOCK_TIMEOUT_FIRE=1 zro_menu_logsearch
out=$(transcript)
assert_contains "$out" "Zaman asimi"
assert_contains "$out" "DOKUNULMADI"
assert_contains "$out" "GOSTERMEZ"

# --- free text ----------------------------------------------------------------

it "free text is matched literally, and the answer says what was searched for"
queue "text" "syslog" "B0CC6104BA2" "week" "yes" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
zro_menu_logsearch
out=$(transcript)
assert_contains "$out" "duz metin: B0CC6104BA2"
assert_contains "$out" "queued as B0CC6104BA2"
assert_contains "$(ran)" "$(printf 'grep\t-a\t-F')"

it "a phrase with a space in it is searched, not refused"
# What an operator arrives holding is usually a sentence out of a log line. The
# screen says so, and this is the case that keeps it true.
queue "text" "syslog" "Connection refused" "week" "yes" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
zro_menu_logsearch
out=$(transcript)
assert_contains "$out" "duz metin: Connection refused"
assert_contains "$out" "kuyruk-test@dc01.example.com"
assert_not_contains "$out" "MSG Gecersiz girdi"

it "and text the tool will not search is refused with what was wrong with it"
# The empty answer is checked in tests/test_logsearch.sh instead: an empty line in
# the stub's queue is how a cancel is written, so this seam cannot tell the two
# apart — and on a real screen whiptail returns the same status for both.
for bad in "-v" " leading-space"; do
  queue "text" "syslog" "$bad" "__CANCEL__" "__CANCEL__"
  : >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
  zro_menu_logsearch
  assert_contains "$(transcript)" "MSG Gecersiz girdi"
  assert_eq "$(ran)" ""
done

it "no free text an operator types is ever run as a pattern"
# The half of this feature that keeps a search from being a way to run a regular
# expression on a production mail server. Whatever is typed into THIS door reaches
# the literal reader, whatever it looks like.
#
# The sending-domain question is the one place a typed value reaches a pattern, and
# it is not this door: that value is validated as a domain and escaped first, which
# tests/test_logsearch.sh drives over every metacharacter the tool declares.
: >"$ZRO_MOCK_LOG"
for typed in 'status=.*' '.*' 'a|b' '(x)+'; do
  queue "text" "syslog" "$typed" "week" "yes" "__CANCEL__" "__CANCEL__"
  zro_menu_logsearch >/dev/null 2>&1
done
assert_eq "$(grep -c '	-E	' "$ZRO_MOCK_LOG")" "0"

it "and every pattern that did reach the pattern reader is one the tool declares"
: >"$ZRO_MOCK_LOG"
while IFS= read -r id; do
  [ -n "$id" ] || continue
  queue "$id" "week" "yes" "__CANCEL__" "__CANCEL__"
  zro_menu_logsearch >/dev/null 2>&1
done <<EOF
$(zro_logsearch_questions)
EOF
undeclared=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  # The pattern follows '-E' and the cap in the recorded vector.
  pat=$(printf '%s' "$line" | awk -F'\t' '{ for (i = 1; i < NF; i++) if ($i == "-E") print $(i + 3) }')
  [ -n "$pat" ] || continue
  found=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$(zro_logsearch_pattern "$id")" = "$pat" ] && found=1
  done <<INNER
$(zro_logsearch_questions)
INNER
  [ -n "$found" ] || undeclared="$undeclared [$pat]"
done <<EOF
$(grep '^grep' "$ZRO_MOCK_LOG")
EOF
assert_eq "$undeclared" ""

# --- the questions that are about everybody -----------------------------------

it "the question menu offers both questions about the server itself"
queue "__CANCEL__"
: >"$ZRO_UI_OUT"
zro_menu_logsearch
out=$(transcript)
missing=""
while IFS= read -r id; do
  [ -n "$id" ] || continue
  case $out in
    *"$(zro_logsearch_lookup_label "$id")"*) ;;
    *) missing="$missing [$id]" ;;
  esac
done <<EOF
$(zro_logsearch_lookups)
EOF
assert_eq "$missing" ""

it "a message-id is asked for, then found across the window in one scan"
queue "msgid" "delivered-1785678543@capture.example.com" "week" "yes" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
zro_menu_logsearch
out=$(transcript)
assert_contains "$out" "ileti kimligi: delivered-1785678543@capture.example.com"
assert_contains "$out" "message-id=<delivered-1785678543@capture.example.com>"
assert_eq "$(ran | grep -c .)" "1"

it "and the prompt warns that the identifier is matched case-sensitively"
# It matters more here than on the delivery trace: this reader has no opinion about
# case at all, so an identifier retyped in the wrong case is an empty answer on the
# one screen whose empty answers are supposed to mean something.
assert_contains "$out" "BUYUK/kucuk harf duyarlidir"

it "one file, one read, held to the class the entry declares"
assert_cost log-search "$(ran | grep -c .)" 1

it "a sending domain is asked for, and answered from the envelope sender"
queue "sender-domain" "example.com" "week" "yes" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
zro_menu_logsearch
out=$(transcript)
assert_contains "$out" "gonderen alan adi: example.com"
assert_contains "$out" "from=<ahmet.yilmaz@example.com>"
assert_eq "$(ran | grep -c .)" "1"

it "and the prompt says which direction the question is about"
# Mail FROM this domain, not mail TO it. An operator who read it the other way
# would take an empty answer as proof of the opposite thing.
assert_contains "$out" "GELDI mi"
assert_contains "$out" "GIDEN mailler bu"

it "neither question asks the directory or a mailbox anything"
# THE WHOLE POINT OF ANSWERING THEM FROM THE LOG. Per account, each would be a
# query per mailbox and a gate check per account; here they are one scan, and the
# existence gate is not involved at all.
log=$(cat "$ZRO_MOCK_LOG")
assert_contains "$log" "grep"
assert_not_contains "$log" "zmprov"
assert_not_contains "$log" "zmmailbox"
assert_not_contains "$log" "zmmsgtrace"

it "and a cap reached through one of these doors is disclosed like any other"
# The engine's disclosures are shared, but a door that bypassed them would be
# invisible here — and these two are the doors whose answers read most like a
# verdict. The captured identifier appears twice in the mail log, so a cap of one
# stops the scan inside the file it was found in.
queue "msgid" "delivered-1785678543@capture.example.com" "week" "yes" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_LOGSEARCH_MATCHES=1 zro_menu_logsearch
out=$(transcript)
assert_contains "$out" "SINIRA ULASILDI"
assert_contains "$out" "TEXT Log arama - EKSIK TARAMA"

it "an answer that found nothing still names the window and the files"
queue "sender-domain" "yok-boyle-alan.example" "week" "yes" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
zro_menu_logsearch
out=$(transcript)
assert_contains "$out" "MSG Kayit yok"
assert_contains "$out" "BASTAN SONA okundu"
assert_contains "$out" "$SYS"

it "a value that is not a domain is refused before any file is opened"
queue "sender-domain" "ahmet@example.com" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
zro_menu_logsearch
assert_contains "$(transcript)" "MSG Gecersiz girdi"
assert_eq "$(ran)" ""

it "and cancelling the value returns to the question menu, having read nothing"
for entry in msgid sender-domain; do
  queue "$entry" "__CANCEL__" "__CANCEL__"
  : >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
  zro_menu_logsearch
  assert_eq "$(ran)" ""
  assert_eq "$(grep -c 'MENU Log arama' "$ZRO_UI_OUT")" "2"
done

it "and neither is narrowed by the selected address"
# They are questions about the server. Offering the address filter would turn one
# of them into a question about the session's subject, which is the screen next
# door.
zro_sel_set "ahmet.yilmaz@example.com"
queue "msgid" "delivered-1785678543@capture.example.com" "week" "yes" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
zro_menu_logsearch
out=$(transcript)
assert_not_contains "$out" "MENU Adres suzgeci"
assert_contains "$out" "message-id=<delivered-1785678543@capture.example.com>"
zro_sel_clear

# --- the address filter -------------------------------------------------------

it "offers the selected address as a filter, and only when there is one"
queue "${NAMED[@]}"
: >"$ZRO_UI_OUT"
zro_menu_logsearch
assert_not_contains "$(transcript)" "MENU Adres suzgeci"

zro_sel_set "ahmet.yilmaz@example.com"
queue "deferred" "one" "week" "yes" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
zro_menu_logsearch
out=$(transcript)
assert_contains "$out" "Adres suzgeci"
assert_contains "$out" "ahmet.yilmaz@example.com"

it "and says that the filter is per line, so a stack trace body will not show"
assert_contains "$out" "SATIR BAZLIDIR"

it "searching every record is the other answer, and it is offered first"
queue "deferred" "all" "week" "yes" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
zro_menu_logsearch
out=$(transcript)
assert_contains "$out" "Butun kayitlar"
assert_contains "$out" "status=deferred"
assert_not_contains "$out" "Adres suzgeci  :"
zro_sel_clear

# --- the host that cannot yield ------------------------------------------------

it "marks the entry when this host cannot reduce priority"
# Learned before the operator spends a window and a confirmation on it, which is
# what a mark is for.
queue "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_IONICE_BIN='' zro_menu_main
assert_contains "$(transcript)" "Log arama (dosyalarin tamaminda) - KULLANILAMAZ"

it "and the screen behind it names the two commands and the repair"
queue "log-search" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
ZRO_NICE_BIN='' zro_menu_main
out=$(transcript)
assert_contains "$out" "MSG Kullanilamaz"
assert_contains "$out" "ionice"
assert_contains "$out" "util-linux"
assert_eq "$(ran)" ""

it "and the viewer is still offered, because it does not scan"
assert_contains "$out" "Log dosyalari (son satirlar)"
assert_not_contains "$out" "Log dosyalari (son satirlar) - KULLANILAMAZ"

# --- navigation ----------------------------------------------------------------

it "cancelling the question menu returns to the caller"
queue "__CANCEL__"
: >"$ZRO_MOCK_LOG"
assert_ok zro_menu_logsearch
assert_eq "$(ran)" ""

it "and returning from an answer lands on the question menu again"
queue "${NAMED[@]}"
: >"$ZRO_UI_OUT"
zro_menu_logsearch
assert_eq "$(grep -c 'MENU Log arama' "$ZRO_UI_OUT")" "2"

it "the search opens no mailbox and runs no Zimbra binary"
queue "${NAMED[@]}"
: >"$ZRO_MOCK_LOG"
zro_menu_logsearch
log=$(cat "$ZRO_MOCK_LOG")
assert_contains "$log" "grep"
assert_not_contains "$log" "zmprov"
assert_not_contains "$log" "zmmailbox"
assert_not_contains "$log" "zmmsgtrace"

it "and every scan it ran was wrapped in reduced priority"
assert_contains "$log" "nice"
assert_contains "$log" "ionice"

rm -f -- "$ZRO_MOCK_LOG" "$ZRO_UI_QUEUE" "$ZRO_UI_QUEUE.pos" "$ZRO_UI_OUT" "$ZRO_ERROR_FILE"
rm -rf -- "$TREE"
zro_t_report
