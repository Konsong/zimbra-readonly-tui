#!/usr/bin/env bash
# The two screens that answer 'is the server itself the problem', driven through
# the stub UI backend: which services are running, and what is in the mail queue.
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
export ZRO_MOCK_ID_USER=zimbra
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* "$ZRO_TEST_ROOT"/mocks/libexec/* \
         "$ZRO_TEST_ROOT"/mocks/system/* "$ZRO_TEST_ROOT"/mocks/sbin/* 2>/dev/null || true

# This file is about these two screens, not about what the machine running the
# suite happens to ship. The trace probes are pinned so that another entry's mark
# is never something the host decided.
export ZRO_CAP_FORCE_TRACE_BIN=yes
export ZRO_CAP_FORCE_TRACE_LOG=ok

ZRO_CAP_QUEUE_DENIED_FILE=$(mktemp); export ZRO_CAP_QUEUE_DENIED_FILE

# shellcheck source=../zimbra-ro-tui.sh
. "$ZRO_SRC/zimbra-ro-tui.sh"
# Sourced after the program, because it reads the program's own declarations.
# shellcheck source=lib/cost.sh
. "$ZRO_TEST_ROOT/lib/cost.sh"

ZRO_MOCK_LOG=$(mktemp);  export ZRO_MOCK_LOG
ZRO_UI_QUEUE=$(mktemp);  export ZRO_UI_QUEUE
ZRO_UI_OUT=$(mktemp);    export ZRO_UI_OUT
FIX="$ZRO_TEST_ROOT/fixtures"
export ZRO_MOCK_ZMCONTROL__V_OUT="$FIX/zmcontrol_v.txt"

queue() { printf '%s\n' "$@" >"$ZRO_UI_QUEUE"; zro_ui_reset; }
transcript() { cat "$ZRO_UI_OUT"; }
entries() { grep -F 'MENU Ana menu' "$ZRO_UI_OUT" | tail -n 1 | sed 's/^.*| //'; }
ran() { cat "$ZRO_MOCK_LOG"; }
statuses() { ran | grep -c '^zmcontrol	status'; }
listings() { ran | grep -c '^postqueue'; }
run() { : >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"; zro_cap_reset; zro_menu_main; }

# The server as the lab server answered for it.
healthy_server() {
  export ZRO_MOCK_ZMCONTROL_STATUS_OUT="$FIX/zmcontrol_status_ok.txt"
  unset ZRO_MOCK_ZMCONTROL_STATUS_RC ZRO_MOCK_ZMCONTROL_STATUS_ERR
}
degraded_server() {
  export ZRO_MOCK_ZMCONTROL_STATUS_OUT="$FIX/zmcontrol_status_stopped.txt"
  unset ZRO_MOCK_ZMCONTROL_STATUS_RC ZRO_MOCK_ZMCONTROL_STATUS_ERR
}
blocked_server() {
  unset ZRO_MOCK_ZMCONTROL_STATUS_OUT ZRO_MOCK_ZMCONTROL_STATUS_ERR
  export ZRO_MOCK_ZMCONTROL_STATUS_RC=124
}
queue_with_mail() {
  export ZRO_CAP_FORCE_QUEUE_BIN=yes
  export ZRO_MOCK_POSTQUEUE__P_OUT="$FIX/postqueue_p_deferred_hold.txt"
  unset ZRO_MOCK_POSTQUEUE__P_ERR ZRO_MOCK_POSTQUEUE__P_RC
}
queue_empty() {
  export ZRO_CAP_FORCE_QUEUE_BIN=yes
  export ZRO_MOCK_POSTQUEUE__P_OUT="$FIX/postqueue_p_empty.txt"
  unset ZRO_MOCK_POSTQUEUE__P_ERR ZRO_MOCK_POSTQUEUE__P_RC
}
queue_refused() {
  export ZRO_CAP_FORCE_QUEUE_BIN=yes
  unset ZRO_MOCK_POSTQUEUE__P_OUT
  export ZRO_MOCK_POSTQUEUE__P_ERR="$FIX/postqueue_p_denied.err"
  export ZRO_MOCK_POSTQUEUE__P_RC=69
}
no_queue_tool() { export ZRO_CAP_FORCE_QUEUE_BIN=no; }

# --------------------------------------------------------------- the entries --

it "both screens are offered, and neither asks for an address"
healthy_server; queue_with_mail
zro_sel_clear
queue "__CANCEL__"
run
list=$(entries)
for id in mail-queue service-status; do
  assert_contains "$list" "$id"
  assert_out_eq "server" zro_menu_scope "$id"
done

it "and both declare the class of a question about this host itself"
# Class 5, whose unit is the HOST. Neither reads a directory entry, opens a
# mailbox or scans a file this program chose: one invocation asks this server
# about itself, and there is one server to ask however large the directory on it
# grows.
assert_out_eq "5" zro_menu_cost mail-queue
assert_out_eq "5" zro_menu_cost service-status
assert_out_eq "host" zro_cost_unit 5

it "and neither is marked while this host can answer them"
assert_not_contains "$list" "Servis durumu - "
assert_not_contains "$list" "iletiler) - "

# -------------------------------------------------------- the service status --

it "the status screen renders every service, running and stopped alike"
degraded_server
queue "service-status" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "Servis sayisi        : 10"
assert_contains "$out" "Calisan              : 9"
assert_contains "$out" "Durmus               : 1"
assert_contains "$out" "stats"
assert_contains "$out" "DURMUS"
assert_contains "$out" "zimbraAdmin webapp"
assert_contains "$out" "Calisiyor"

it "and it costs one question asked of one host"
assert_cost service-status "$(statuses)" 1

it "and the screen says what the command writes, in the box with the answer"
# THE SECOND OF THE THREE CONDITIONS that admit this command: no domain state
# changes, THE SCREEN SAYS WHAT IT WRITES, and an ADR records the judgement. It
# is asserted at the screen because that is where the operator is standing when
# the claim matters to them.
assert_contains "$out" ".zmcontrol.cache"
assert_contains "$out" "gecici dosya"
assert_contains "$out" "hicbir hesap, mailbox, klasor veya ayar degismez"

it "and it says so before the wait as well as after it"
# An operator who is told only afterwards has already spent the command. The
# notice that goes up before the query carries the same fact in one sentence.
notice_line=$(grep -n "bekleyin" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
result_line=$(grep -n "Servis sayisi" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
said_line=$(grep -n ".zmcontrol.cache" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
assert_eq "$([ "$notice_line" -lt "$result_line" ] && printf yes || printf no)" "yes"
assert_eq "$([ "$said_line" -lt "$result_line" ] && printf yes || printf no)" "yes"

it "and it never runs a command that would change what a service is doing"
assert_eq "$(ran | grep -c '^zmcontrol	\(start\|stop\|restart\|shutdown\)')" "0"
assert_eq "$(ran | grep '^zmcontrol	status')" "zmcontrol	status"

it "a status command that blocked is reported, not left hanging"
# `zmcontrol status` asks the directory server before anything else and has no
# alarm of its own around that step. The gate's wall-clock timeout is the only
# thing that ends it, and the screen has to say so — an operator told 'the
# command failed' would go looking at the services, which is the one place the
# answer is not.
blocked_server
queue "service-status" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "Zaman asimi"
assert_contains "$out" "$ZRO_TIMEOUT"
assert_contains "$out" "LDAP"
assert_contains "$out" "DOKUNULMADI"

it "and the menu comes back afterwards rather than the tool stopping"
assert_contains "$out" "MENU Ana menu"

# --------------------------------------------------------------- the queue --

it "the queue screen answers with counts before it answers with anything else"
healthy_server; queue_with_mail
queue "mail-queue" "__CANCEL__" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "Kuyruktaki kayit     : 3"
assert_contains "$out" "Bekleyen (ertelenmis): 2"
assert_contains "$out" "Tutulan (hold)       : 1"

it "and the detail is behind the counts rather than beside them"
counts_line=$(grep -n "Kuyruktaki kayit" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
detail_line=$(grep -n "21E9B104C1C" "$ZRO_UI_OUT" | head -n 1 | cut -d: -f1)
assert_eq "$detail_line" ""
assert_eq "$([ -n "$counts_line" ] && printf yes || printf no)" "yes"

it "and choosing it renders the entries, bounded and said to be bounded"
ZRO_QUEUE_DETAIL_MAX_REAL=$ZRO_QUEUE_DETAIL_MAX
ZRO_QUEUE_DETAIL_MAX=2
queue "mail-queue" "detail" "__CANCEL__" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "21E9B104C1C"
assert_contains "$out" "kullanici@nosuchdomain.invalid"
assert_contains "$out" "ilk 2"
# The bound is real, not decorative: the third entry of three is not on the
# screen, and the screen said as much rather than ending as though it were the
# whole queue.
assert_not_contains "$out" "26D3F102FBF"
assert_contains "$out" "YOKTUR"
ZRO_QUEUE_DETAIL_MAX=$ZRO_QUEUE_DETAIL_MAX_REAL

it "and both screens came out of ONE reading of the queue"
# A queue moves every few seconds on a busy server. Reading it twice would cost
# a second invocation AND let the counts disagree with the list under them.
assert_cost mail-queue "$(listings)" 1

it "and the only form of the tool that ran is the one that lists"
assert_eq "$(ran | grep '^postqueue')" "postqueue	-p"

it "an empty queue is an answer, and says what it does not prove"
queue_empty
queue "mail-queue" "__CANCEL__" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "Kuyruktaki kayit     : 0"
assert_contains "$out" "Kuyruk bos"
assert_contains "$out" "GELMEZ"

it "and it has no detail to show"
queue_empty
queue "mail-queue" "detail" "__CANCEL__" "__CANCEL__"
run
assert_contains "$(transcript)" "gosterilecek kayit yok"

# ------------------------------- the two ways this host can have no queue --

it "a build with no queue tool marks the entry before it is selected"
healthy_server; no_queue_tool
queue "__CANCEL__"
run
assert_contains "$(entries)" "KULLANILAMAZ"

it "and selecting it names the package, and says it is not a permission problem"
no_queue_tool
queue "mail-queue" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "zimbra-mta"
assert_contains "$out" "izin sorunu DEGILDIR"
assert_contains "$out" "$ZRO_POSTFIX_SBIN/postqueue"

it "and nothing was run to find that out"
assert_eq "$(listings)" "0"

it "a host that refuses the read names the setting that refused it"
# A DIFFERENT ANSWER WITH A DIFFERENT REPAIR. The tool is present and Postfix's
# own access-control setting does not list the account every command runs as.
# Telling this operator to install a package would send them to repair something
# that is already there.
queue_refused
queue "mail-queue" "__CANCEL__"
run
out=$(transcript)
assert_contains "$out" "authorized_mailq_users"
assert_contains "$out" "static:anyone"
assert_not_contains "$out" "zimbra-mta"

it "and it quotes what the tool itself said"
assert_contains "$out" "not allowed to view the mail queue"

it "and it is not reported as an allowlist denial, which would be our defect"
assert_not_contains "$out" "izin listesinde degil"
assert_not_contains "$out" "Ic hata"

it "and the entry carries the mark from then on, without asking again"
# The refusal cannot be probed for — that setting is read inside the tool — so it
# is learned once and remembered. What it buys is that the operator is not
# charged for the same refusal twice.
queue "mail-queue" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
zro_menu_main
assert_contains "$(entries)" "KULLANILAMAZ"
assert_eq "$(listings)" "0"
assert_contains "$(transcript)" "authorized_mailq_users"

zro_t_report
