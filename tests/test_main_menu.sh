#!/usr/bin/env bash
# The one list, and the address it is all about — driven through the stub UI
# backend.
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ZIMBRA_LIBEXEC="$ZRO_TEST_ROOT/mocks/libexec"
export ZRO_SYSTEM_BIN="$ZRO_TEST_ROOT/mocks/system"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
export ZRO_UI_BACKEND=stub
export ZRO_SOURCED_ONLY=1
export ZRO_MOCK_ID_USER=zimbra
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* "$ZRO_TEST_ROOT"/mocks/libexec/* \
         "$ZRO_TEST_ROOT"/mocks/system/* 2>/dev/null || true

# This file is about the menu, not about what this host happens to ship. Both
# trace probes are pinned so that an entry's mark is something a case asks for
# rather than something the machine running the suite decides.
export ZRO_CAP_FORCE_TRACE_BIN=yes
export ZRO_CAP_FORCE_TRACE_LOG=ok

# shellcheck source=../zimbra-ro-tui.sh
. "$ZRO_SRC/zimbra-ro-tui.sh"

ZRO_MOCK_LOG=$(mktemp);  export ZRO_MOCK_LOG
ZRO_UI_QUEUE=$(mktemp);  export ZRO_UI_QUEUE
ZRO_UI_OUT=$(mktemp);    export ZRO_UI_OUT
FIX="$ZRO_TEST_ROOT/fixtures"
export ZRO_MOCK_ZMCONTROL__V_OUT="$FIX/zmcontrol_v.txt"
export ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt"
export ZRO_MOCK_ZMPROV_GAM_OUT="$FIX/zmprov_gam_ok.txt"

ADDR="ahmet.yilmaz@example.com"
OTHER="ayse.demir@example.com"

queue() { printf '%s\n' "$@" >"$ZRO_UI_QUEUE"; zro_ui_reset; }
transcript() { cat "$ZRO_UI_OUT"; }
# The entries of the last main menu drawn, as the stub recorded them.
entries() { grep -F 'MENU Ana menu' "$ZRO_UI_OUT" | tail -n 1 | sed 's/^.*| //'; }
run() { : >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"; zro_menu_main; }

# ------------------------------------------------------------- the list --

it "the first entry on the main menu is the address"
zro_sel_clear
queue "__CANCEL__"
run
assert_contains "$(entries)" "select Adres sec account-card"

it "and it offers every declared operation, in the order they are declared"
# Two declarations held equal: the list the operator is shown, and the list this
# program dispatches from. They are the same list here, which is the point — a
# menu built by hand beside a table is a menu that can offer what nothing runs.
expected="select Adres sec"
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  label=${entry#*:}
  expected="$expected ${entry%%:*} ${label#*:}"
done <<EOF
$ZRO_MENU_OPS
EOF
expected="$expected quit Cikis"
assert_eq "$(entries)" "$expected"

it "the operations that need an address come before the ones that do not"
# Three scopes, and only two positions: what needs an address of any kind comes
# before what needs none. 'account' and 'address' are both the first group —
# they differ in what the address has to BE, not in whether one is asked for.
seen_server=""
misplaced=""
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  scope=${entry#*:}
  case ${scope%%:*} in
    server)          seen_server=yes ;;
    account|address) [ -z "$seen_server" ] || misplaced="$misplaced [${entry%%:*}]" ;;
    *) misplaced="$misplaced [scope? ${entry%%:*}]" ;;
  esac
done <<EOF
$ZRO_MENU_OPS
EOF
assert_eq "$misplaced" ""

it "and an operation that needs the address to be an account says so"
# The scope is what routes an address to the screens that can answer for it, so
# the two kinds are held apart in the declaration rather than inferred from an
# id's prefix at the point of use.
assert_out_eq "account" zro_menu_scope account-card
assert_out_eq "address" zro_menu_scope trace-recipient
assert_out_eq "server"  zro_menu_scope logview

it "every declared operation is dispatched somewhere"
# The other half of the same equality, and the half a label cannot show: an entry
# offered and wired to nothing redraws the menu, which reads as the tool ignoring
# the operator. Each id is selected in turn and the run is refused everything it
# asks for afterwards; what may not appear is a defect.
zro_sel_set "$ADDR"
undispatched=""
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  queue "${entry%%:*}" "__CANCEL__" "__CANCEL__" "__CANCEL__" "__CANCEL__"
  said=$(zro_menu_main 2>&1 >/dev/null)
  case $said in
    *"menu defect"*) undispatched="$undispatched [${entry%%:*}]" ;;
  esac
done <<EOF
$ZRO_MENU_OPS
EOF
assert_eq "$undispatched" ""

it "and an id this program never drew runs nothing at all"
zro_sel_set "$ADDR"
queue "account-card; id" "__CANCEL__"
: >"$ZRO_MOCK_LOG"
said=$(zro_menu_main 2>&1 >/dev/null)
assert_contains "$said" "not a declared operation"
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "zmprov"

it "the exit entry leaves the menu"
queue "quit"
assert_ok zro_menu_main

it "so does cancelling it, which is the one screen where leaving is leaving"
queue "__CANCEL__"
assert_ok zro_menu_main

# ------------------------------------------------ choosing an address --

it "an account operation chosen with nothing selected asks for the address"
zro_sel_clear
queue "account-card" "$ADDR" "__CANCEL__"
run
assert_contains "$(transcript)" "INPUT Adres"

it "and then continues to the operation that was chosen, not back to the menu"
# The whole point of asking: an operator who chose a screen and typed an address
# has said everything the tool needs, and being returned to the menu to choose
# the same entry again is the tool making them repeat themselves.
assert_contains "$(transcript)" "Ahmet Yilmaz"
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$ADDR"

it "the next operation does not ask again"
zro_sel_clear
queue "account-card" "$ADDR" "account-membership" "__CANCEL__"
run
out=$(transcript)
assert_eq "$(grep -c 'INPUT Adres' "$ZRO_UI_OUT")" "1"
assert_contains "$out" "Ahmet Yilmaz"
assert_contains "$out" "bilgi-islem@example.com"

it "the selection can be changed without leaving the tool"
zro_sel_clear
queue "select" "$ADDR" "select" "$OTHER" "account-card" "__CANCEL__"
run
assert_eq "$(zro_sel_address)" "$OTHER"
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$OTHER"

it "and the address it is being changed from is offered ready to edit"
# Comparing two users is one keystroke and an edit, not a restart and a retyping.
# The prompt's text runs to several lines and the stub records it as it is
# drawn, so what is asserted is the offered value at the end of the record —
# once, for the second prompt: the first had nothing to offer.
assert_eq "$(grep -c -- "| $ADDR\$" "$ZRO_UI_OUT")" "1"

it "the entry says whether it chooses an address or replaces one"
zro_sel_clear
queue "__CANCEL__"
run
assert_contains "$(entries)" "select Adres sec"
zro_sel_set "$ADDR"
queue "__CANCEL__"
run
assert_contains "$(entries)" "select Adresi degistir"

it "cancelling the address prompt returns to the menu and runs nothing"
zro_sel_clear
queue "account-card" "__CANCEL__" "__CANCEL__"
run
# Drawn once before the prompt and once after it: the operator is back where they
# were, not one screen further out and not inside a screen with no address.
assert_eq "$(grep -c 'MENU Ana menu' "$ZRO_UI_OUT")" "2"
# The menu itself reads the version, so what matters is that no question was
# asked about an account nobody chose.
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "zmprov"
assert_fail zro_sel_have

it "an address that is not one is refused, and nothing is run"
zro_sel_clear
queue "account-card" 'ahmet@example.com; id' "__CANCEL__" "__CANCEL__"
run
assert_contains "$(transcript)" "Gecersiz"
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "zmprov"
assert_fail zro_sel_have

it "and the refusal is a screen, not a selection nobody checked"
zro_sel_clear
queue "select" "yok" "__CANCEL__"
run
assert_contains "$(transcript)" "Gecersiz"
assert_fail zro_sel_have

# ------------------------------------------------------------ the frame --

it "every screen drawn after an address is chosen carries it on the frame"
# whiptail keeps the title on the border while the text inside scrolls, so it is
# the one part of a long answer that cannot be pushed out of view — and reading
# one account's answer believing it is another's is the failure this prevents.
zro_sel_clear
queue "select" "$ADDR" "account-card" "__CANCEL__"
run
missing=""
while IFS= read -r line; do
  case $line in
    # Everything up to and including the address prompt is still about a session
    # that has no address; from the answer to that prompt onwards, nothing is.
    "MENU Ana menu:"*|"INPUT Adres:"*) ;;
    MENU*|INPUT*|MSG*|NOTICE*|TEXT*)
      case $line in
        *"$ADDR"*) ;;
        *) missing="$missing [$line]" ;;
      esac ;;
  esac
done <"$ZRO_UI_OUT"
assert_eq "$missing" ""

it "the result is titled with the entry the operator chose"
# One label, read back from the list rather than written out a second time: an
# answer under a heading nobody chose is the confusion the frame exists to stop.
assert_contains "$(transcript)" "TEXT Hesap karti - $ADDR"

it "and so does the menu the operator is returned to"
assert_contains "$(transcript)" "MENU Ana menu - $ADDR"

# ------------------------------------- the answers, about that address --

it "the summary is rendered for the selected address"
zro_sel_set "$ADDR"
queue "account-card" "__CANCEL__"
run
assert_contains "$(transcript)" "Ahmet Yilmaz"

it "and the operator is told a query is running before the wait begins"
assert_contains "$(transcript)" "bekleyin"
# The notice has to come before the result, or it is not a notice.
notice_line=$(grep -n "bekleyin" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
result_line=$(grep -n "Ahmet Yilmaz" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
assert_eq "$([ "$notice_line" -lt "$result_line" ] && printf yes || printf no)" "yes"

it "the quota screen is reachable and rendered"
zro_sel_set "$ADDR"
queue "account-quota" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "5.0 GB"
assert_contains "$out" "gosterilmiyor"
# Reaching this screen must not run the command that creates mailboxes.
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf '\tgmi')"

it "the membership screen is reachable and rendered"
zro_sel_set "$ADDR"
queue "account-membership" "__CANCEL__"
run
assert_contains "$(transcript)" "bilgi-islem@example.com"

it "a missing account is reported without leaving the menu"
zro_sel_set "yok@example.com"
queue "account-card" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMPROV_GA_OUT="" \
ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_ga_no_such_account.err" \
ZRO_MOCK_ZMPROV_GA_RC=1 zro_menu_main
assert_contains "$(transcript)" "bulunamadi"
assert_eq "$(grep -c 'MENU Ana menu' "$ZRO_UI_OUT")" "2"

it "an empty membership list is reported as no result, not an error"
empty=$(mktemp); : >"$empty"
zro_sel_set "yalniz@example.com"
queue "account-membership" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMPROV_GAM_OUT="$empty" zro_menu_main
assert_contains "$(transcript)" "Kayit bulunamadi"
rm -f -- "$empty"

# ---------------------------------------------------- what this host has --

it "an operation this host cannot perform is marked before it is selected"
zro_sel_set "$ADDR"
queue "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_CAP_FORCE_TRACE_BIN=no zro_menu_main
marked=$(entries)
assert_contains "$marked" "Teslim takibi: bu adrese gelenler - KULLANILAMAZ"
assert_contains "$marked" "Teslim takibi: ileti kimligine gore - KULLANILAMAZ"
# And only the ones it is about: the log viewer reads the same files by a path
# neither probe is about, and marking it with them would hide a screen that works.
assert_not_contains "$marked" "Log dosyalari (son satirlar) - KULLANILAMAZ"
assert_not_contains "$marked" "Hesap karti - KULLANILAMAZ"

it "and selecting it explains why instead of asking for anything"
queue "trace-recipient" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
ZRO_CAP_FORCE_TRACE_BIN=no zro_menu_main
out=$(transcript)
assert_contains "$out" "Kullanilamaz"
assert_not_contains "$out" "MENU Varis araligi"
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "zmmsgtrace"

it "an unavailable operation never asks for an address it cannot use"
# The mark is learned before the search; being asked for an address first and
# refused afterwards would spend the operator's time to say the same thing.
zro_sel_clear
queue "trace-recipient" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_CAP_FORCE_TRACE_BIN=no zro_menu_main
assert_not_contains "$(transcript)" "INPUT Adres"
assert_fail zro_sel_have

it "an account screen reached with nothing selected asks Zimbra nothing"
# Unreachable from the menu, which chooses an address before it dispatches an
# address-scoped operation. Asserted all the same, and as a defect rather than as
# invalid input: on this path the operator typed nothing, so a screen about what
# they typed would send them looking for a mistake they did not make.
zro_sel_clear
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
said=$(zro_screen_account account-card 2>&1 >/dev/null)
assert_contains "$said" "menu defect"
assert_contains "$(transcript)" "Ic hata"
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "an address a module refused is its own screen, not a bare code"
# The third of the three failures the account card has to tell apart — a missing
# account, an unreachable mailbox service, and an address that is not one. The
# first two already had screens; this one used to fall through to "Islem
# basarisiz (kod 10)", which names no repair and reads like a Zimbra fault.
#
# Reached through the shared reporter rather than through the menu, because the
# menu validates an address before it dispatches: this is the screen for a value
# that got past selection, which makes it as much a defect in this program as a
# mistyped address, and the message has to serve both readings.
: >"$ZRO_UI_OUT"
# A message left on file by an EARLIER screen, which is the whole point of the
# assertion below: nothing ran on this path, so whatever is there belongs to
# something else and would be read as this screen's explanation.
zro_set_error "ERROR: zclient.IO_ERROR (Connection refused)"
zro_report_error "$ZRO_E_INPUT"
said=$(transcript)
assert_contains "$said" "Gecersiz adres"
assert_not_contains "$said" "kod 10"
assert_not_contains "$said" "Connection refused"
zro_clear_error

it "and an operation this file does not answer is reported as the defect it is"
# Never the allowlist's message: an operator sent to check the allowlist for a
# dispatch table's mistake reads the wrong file and finds nothing wrong with it.
zro_sel_set "$ADDR"
: >"$ZRO_UI_OUT"
said=$(zro_screen_account account-nonesuch 2>&1 >/dev/null)
assert_contains "$said" "menu defect"
out=$(transcript)
assert_contains "$out" "Ic hata"
assert_not_contains "$out" "izin listesinde"

it "the server is asked for its version once, however often the menu is drawn"
# This loop is returned to after every operation. The version is displayed, so
# it is read inside command substitution — where an assignment to the session
# cache dies with the subshell, and the menu pays a JVM start every time it is
# drawn. It is filled in the menu's own shell instead.
zro_cap_reset
zro_sel_set "$ADDR"
queue "account-card" "account-card" "__CANCEL__"
run
assert_eq "$(grep -c '^zmcontrol' "$ZRO_MOCK_LOG")" "1"
# Three draws of the menu, one reading of the version.
assert_eq "$(grep -c 'MENU Ana menu' "$ZRO_UI_OUT")" "3"

it "no menu screen opens a mailbox"
zro_sel_clear
queue "select" "$ADDR" "account-card" "account-membership" "__CANCEL__"
run
log=$(cat "$ZRO_MOCK_LOG")
assert_contains "$log" "zmprov"
assert_not_contains "$log" "zmmailbox"
assert_not_contains "$log" "$(printf '\tgmi')"

# ------------------------------------------- what the address turned out to be --
#
# Resolution runs when an address is chosen, and everything after it is routed by
# the answer. The cases below script the server per case rather than relying on
# the file's default answer, so each one says which directory it is talking to.

# Puts the server back the way the rest of this file expects it: an ordinary
# account that answers `ga` and `gam`.
restore_server() {
  export ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt"
  unset ZRO_MOCK_ZMPROV_GA_ERR ZRO_MOCK_ZMPROV_GA_RC
  unset ZRO_MOCK_ZMPROV_GDL_OUT ZRO_MOCK_ZMPROV_GDL_ERR ZRO_MOCK_ZMPROV_GDL_RC
}

it "choosing an address resolves it and says what it is"
zro_sel_clear
queue "select" "$ADDR" "__CANCEL__"
run
assert_contains "$(transcript)" "TEXT Adres kimligi"
assert_contains "$(transcript)" "Bu adres bir hesap"

it "an alias is resolved to the account behind it, and both are named"
# zmprov_ga_active.txt is the account ahmet.yilmaz@example.com, which is what
# TEST-C really answers when an alias is asked for: the header names the account,
# not the address that was typed.
zro_sel_clear
queue "select" "a.yilmaz@example.com" "account-card" "__CANCEL__"
run
said=$(transcript)
assert_contains "$said" "a.yilmaz@example.com"
assert_contains "$said" "$ADDR"
assert_contains "$said" "bir alias"

it "and the card it draws is queried for the account, not for the alias"
# Both spellings answer, so this is not about the query working. It is about the
# card saying whose account it is describing.
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'zmprov\tga\t%s' "$ADDR")"

it "and the note it opens with is separated from the report, not glued to it"
# Command substitution eats trailing newlines, so a note built as its own string
# and concatenated by the caller loses the blank line that separates it — and the
# first label of the report ends up on the end of the sentence above it.
note=$(zro_screen_alias_note "Hesap                : $ADDR")
assert_contains "$note" "$(printf 'aittir.\n\nHesap')"

it "and a report about an address that is not an alias is left exactly as it was"
zro_sel_clear
zro_sel_set "$ADDR"
assert_out_eq "govde" zro_screen_alias_note "govde"

it "a distribution list is not reported as a missing account"
zro_sel_clear
export ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_ga_no_such_account.err"
export ZRO_MOCK_ZMPROV_GA_RC=2
export ZRO_MOCK_ZMPROV_GDL_OUT="$FIX/zmprov_gdl_ok.txt"
queue "select" "tum-personel@example.com" "__CANCEL__"
run
said=$(transcript)
assert_contains "$said" "dagitim listesi"
assert_not_contains "$said" "Hesap bulunamadi"

it "and the account operations are marked before they are chosen"
assert_contains "$(entries)" "Hesap karti - BU ADRES HESAP DEGIL"

it "but delivery tracing is not, because a list address appears in the mail log"
# The reason the scope is finer than address-or-not: marking the trace here would
# take away the one screen that still answers for this address.
assert_not_contains "$(entries)" "gelenler - BU ADRES HESAP DEGIL"

it "choosing an account operation anyway shows what the address is, and runs nothing"
zro_sel_clear
queue "select" "tum-personel@example.com" "account-card" "__CANCEL__"
run
assert_contains "$(transcript)" "dagitim listesi"
# Two reads for the resolution and not one more: no card was attempted.
assert_eq "$(grep -c '^zmprov' "$ZRO_MOCK_LOG")" "2"

it "an address that is nowhere is marked as well, and said to be absent"
zro_sel_clear
export ZRO_MOCK_ZMPROV_GDL_ERR="$FIX/zmprov_gdl_no_such_list.err"
export ZRO_MOCK_ZMPROV_GDL_RC=2
unset ZRO_MOCK_ZMPROV_GDL_OUT
queue "select" "yok@example.com" "__CANCEL__"
run
assert_contains "$(transcript)" "dizinde bulunamadi"
assert_contains "$(entries)" "Hesap karti - BU ADRES HESAP DEGIL"

it "a resolution that could not run marks nothing at all"
# THE ONE THING A FAILURE MAY NOT DO. Marking an entry from a question this
# program could not ask would report its own ignorance as a fact about the
# server — and the address is still selected, because it is still valid.
zro_sel_clear
export ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_io_error_refused.err"
export ZRO_MOCK_ZMPROV_GA_RC=1
export ZRO_MOCK_ZMPROV__L_GA_ERR="$FIX/zmprov_io_error_refused.err"
export ZRO_MOCK_ZMPROV__L_GA_RC=1
queue "select" "$ADDR" "__CANCEL__"
run
said=$(transcript)
assert_contains "$said" "Zimbra servisine erisilemiyor"
assert_not_contains "$said" "dizinde bulunamadi"
assert_not_contains "$(entries)" "BU ADRES HESAP DEGIL"
assert_eq "$(zro_sel_address)" "$ADDR"
unset ZRO_MOCK_ZMPROV__L_GA_ERR ZRO_MOCK_ZMPROV__L_GA_RC
restore_server

it "and the account operation behind it is still offered, and still tries"
# An operation refused from an unresolved identity would be the failure above
# deciding something. The screen reports its own outcome instead.
zro_sel_clear
queue "select" "$ADDR" "account-card" "__CANCEL__"
run
assert_contains "$(transcript)" "Ahmet Yilmaz"

it "an entry's mark is decided in the loop's own shell, so a probe caches"
# THE REASON THE REFUSAL COMES BACK IN A GLOBAL. The capability probes fill a
# session cache, and an assignment made inside $( ) dies with the subshell —
# lib/capability.sh records that bug being fixed once already. A mark computed
# through a command substitution would re-probe the host for every entry of every
# redraw, and nothing on screen would look any different.
zro_cap_reset
unset ZRO_CAP_FORCE_TRACE_BIN
zro_sel_clear
queue "__CANCEL__"
run
assert_eq "$ZRO_CAP_TRACE_BIN_CACHE" "yes"
export ZRO_CAP_FORCE_TRACE_BIN=yes

it "resolving an address costs one invocation when it is an account"
# Cost class 1, asserted as the number it is: the account read that identifies
# the address is the only read the selection pays for.
zro_sel_clear
queue "select" "$ADDR" "__CANCEL__"
run
assert_eq "$(grep -c '^zmprov' "$ZRO_MOCK_LOG")" "1"

it "changing the address forgets what the previous one was"
# A menu marked for one account while the session is about another is the exact
# failure the selected address exists to prevent, one level further in.
zro_sel_clear
export ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_ga_no_such_account.err"
export ZRO_MOCK_ZMPROV_GA_RC=2
export ZRO_MOCK_ZMPROV_GDL_OUT="$FIX/zmprov_gdl_ok.txt"
# Two answers for the one prompt this program has, given to it directly: the
# menu around it is not what is being tested here.
queue "tum-personel@example.com" "$ADDR"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
zro_menu_select >/dev/null
zro_menu_refusal account-card
assert_eq "$ZRO_MENU_REASON" "notaccount"
restore_server
zro_menu_select >/dev/null
zro_menu_refusal account-card
assert_eq "$ZRO_MENU_REASON" ""

rm -f -- "$ZRO_MOCK_LOG" "$ZRO_UI_QUEUE" "$ZRO_UI_QUEUE.pos" "$ZRO_UI_OUT"
zro_t_report
