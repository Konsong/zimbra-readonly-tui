#!/usr/bin/env bash
# A CODE THE EXEC GATE RETURNED TRAVELS OUT OF THE MODULE AS ITSELF.
#
# zro_exec returns one of five codes it produced itself, or the exit status of the
# command it ran, verbatim. A caller holding a number cannot tell those apart, so
# every module reading a gated command has to decide which it got.
set -uo pipefail

# Six of them decided separately, in three different memberships, and one stopped
# deciding at all: 73b510e replaced zro_msg_fail_code's `printf '%s' "$rc"` with a
# constant, so an allowlist denial on zmmetadump — exit 90, which this program
# defines as a defect in itself — reached the operator as "mailboxd is stopped,
# check zmcertmgr", naming a service that command never talks to.
#
# THE CASES HERE ASSERT THE OUTCOME, NOT THE SHAPE. A static reader could see that
# a module has a pass-through arm; it could not have seen 73b510e, which ADDED one
# arm while deleting another thirty lines away. Only a real refusal, driven through
# the module's own interface, tells the two apart. The refusal is forced by
# overriding the allowlist as an environment prefix on the assertion — the idiom
# tests/test_exec.sh:419 established for ZRO_BIN_ROOTS.
#
# TEN SEAMS, AND TWO LEFT OUT ON PURPOSE. Twelve functions in this tree call
# zro_exec. Eight map failures and could swallow a gate code; two — zro_trace_exec
# and zro_logsearch_grep — hold no mapping code at all and are asserted anyway, so
# that an arm which grew an rc check would fail here. The two left out are
# zro_cap_version_load and zro_msg_blob_compressed, and they are left out because
# THEY ANSWER WITH A BOOLEAN: one asks whether the host reports a version, the
# other whether a stored file begins with the gzip magic. A boolean cannot carry a
# code, so a case demanding 90 from either would be asserting something neither
# claims. Nothing is lost by it: the capability probe is not a safety check —
# CONTEXT.md says so in as many words — and the compression question's refusal
# surfaces one call down, at zro_msg_head_fetch, which is asserted below.
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/table.sh
. "$ZRO_SRC/lib/table.sh"
# shellcheck source=../lib/validate.sh
. "$ZRO_SRC/lib/validate.sh"

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
export ZRO_MOCK_ID_USER=zimbra

# THE THREE ROOTS THE SEAMS BELOW READ THROUGH, pointed at trees this file owns.
# Exported before the modules are sourced, because lib/inventory.sh builds its
# declared root table at load time and lib/mailbox.sh registers its proof file there.
TREE=$(mktemp -d)
mkdir -p "$TREE/var/log" "$TREE/zimbra/log" "$TREE/store"
export ZRO_SYSLOG_FILE="$TREE/var/log/zimbra.log"
export ZRO_LOG_DIR="$TREE/zimbra/log"
export ZRO_STORE_ROOT="$TREE/store"
ZRO_MBOX_PROOF_FILE=$(mktemp); export ZRO_MBOX_PROOF_FILE
# One line, so the log seams have a file to open. Its date is never read — no case
# here asks a question about time — which is why it may be a literal rather than
# stamped relative to now, the way a screen test answering the window menu must be.
printf '%s\n' 'Aug  2 12:00:00 posta postfix/smtpd[1]: line' >"$ZRO_SYSLOG_FILE"
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* "$ZRO_TEST_ROOT"/mocks/libexec/* \
         "$ZRO_TEST_ROOT"/mocks/system/* "$ZRO_TEST_ROOT"/mocks/sbin/* 2>/dev/null || true

# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"
# shellcheck source=../lib/account.sh
. "$ZRO_SRC/lib/account.sh"
# shellcheck source=../lib/message.sh
. "$ZRO_SRC/lib/message.sh"
# shellcheck source=../lib/mailbox.sh
. "$ZRO_SRC/lib/mailbox.sh"
# shellcheck source=../lib/delivery.sh
. "$ZRO_SRC/lib/delivery.sh"
# shellcheck source=../lib/inventory.sh
. "$ZRO_SRC/lib/inventory.sh"
# shellcheck source=../lib/logsearch.sh
. "$ZRO_SRC/lib/logsearch.sh"
# shellcheck source=../lib/logview.sh
. "$ZRO_SRC/lib/logview.sh"
# shellcheck source=../lib/queue.sh
. "$ZRO_SRC/lib/queue.sh"
# shellcheck source=../lib/service.sh
. "$ZRO_SRC/lib/service.sh"

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG

ACCT="ahmet.yilmaz@example.com"
ITEM=274

# AN ALLOWLIST CARRYING THE EXISTENCE ORACLE AND NOTHING ELSE. Written out rather
# than emptied: an empty list would also deny, and would additionally test that the
# reader survives a table with no rows — a different question, answered in
# tests/test_table.sh, and one this case must not depend on. `zmprov:gis` stays
# because the existence gate runs it as a PRECONDITION of the mailbox seam below:
# denying the oracle would refuse that seam before it reached the subcommand whose
# denial is the thing under test.
DENY_ALL='zmprov:gis'


# THE TWO REFUSALS THAT ARE FORCED IDENTICALLY AT EVERY SEAM. The prefix dies with
# the call — bash restores an assignment made before a function invocation — so no
# case can leak its override into the next. The third, ZRO_E_NOCAP, is written out
# at each seam instead, because the root to empty differs per binary and naming it
# is what proves the seam reaches the binary it claims to.
gate_denies()  { ZRO_ALLOW="$DENY_ALL"   assert_status "$ZRO_E_DENIED"  "$@"; }
gate_baduser() { ZRO_MOCK_ID_USER=nobody assert_status "$ZRO_E_BADUSER" "$@"; }

# ---------------------------------------------- the metadata dump --

it "the metadata dump reports an allowlist denial as a denial, not as a stopped service"
: >"$ZRO_MOCK_LOG"
ZRO_ALLOW="$DENY_ALL" assert_status "$ZRO_E_DENIED" zro_msg_dump_fetch "$ACCT" "$ITEM"

it "and it ran nothing"
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "and the metadata dump passes the gate's other two codes as well"
gate_baduser zro_msg_dump_fetch "$ACCT" "$ITEM"
ZRO_ZIMBRA_BIN=/nonexistent assert_status "$ZRO_E_NOCAP" zro_msg_dump_fetch "$ACCT" "$ITEM"

# ------------------------------------------------- the server itself --

it "the mail queue passes the gate's codes through"
gate_denies  zro_queue_fetch
gate_baduser zro_queue_fetch
ZRO_POSTFIX_SBIN=/nonexistent assert_status "$ZRO_E_NOCAP" zro_queue_fetch

it "the service status passes the gate's codes through"
gate_denies  zro_svc_fetch
gate_baduser zro_svc_fetch
ZRO_ZIMBRA_BIN=/nonexistent assert_status "$ZRO_E_NOCAP" zro_svc_fetch

# --------------------------------------------- the two dispatchers --

# These two hold no mapping code at all: every arm is a tail call, so the gate's
# status is theirs by construction. Asserted anyway, because that is a property of
# how they are written today and nothing else states it — an arm that grew an rc
# check would take the disclosure with it and no other case would notice.

it "the delivery tracer's dispatcher passes the gate's codes through"
gate_denies  zro_trace_exec --recipient 'ahmet.yilmaz@example.com'
gate_baduser zro_trace_exec --recipient 'ahmet.yilmaz@example.com'
ZRO_ZIMBRA_LIBEXEC=/nonexistent assert_status "$ZRO_E_NOCAP" \
  zro_trace_exec --recipient 'ahmet.yilmaz@example.com'

it "the log searcher's dispatcher passes the gate's codes through"
gate_denies  zro_logsearch_grep -F 'reject' /dev/null
gate_baduser zro_logsearch_grep -F 'reject' /dev/null
ZRO_SYSTEM_BIN=/nonexistent assert_status "$ZRO_E_NOCAP" \
  zro_logsearch_grep -F 'reject' /dev/null

# ------------------------------------------------ inside one mailbox --

# The gate's own owner. Its subcommand arrives as an argument, so the refusal is
# forced by the vector rather than by the allowlist — and the existence oracle is
# left approved above, because zro_mbox_run runs it as a precondition and a refused
# oracle would answer before the subcommand was ever judged.
# Also covered from the other side in tests/test_mailbox_gate.sh, which asks what
# the gate refuses; this asks what the module does with the refusal.
it "the mailbox gate passes the gate's codes through"
zro_mbox_forget
ZRO_MOCK_ZMPROV_GIS_OUT="$ZRO_TEST_ROOT/fixtures/zmprov_gis_ok.txt" \
  ZRO_MOCK_ZMPROV_GIS_RC=0 ZRO_ALLOW="$DENY_ALL" \
  assert_status "$ZRO_E_DENIED" zro_mbox_run "$ACCT" gaf

# THE PROOF IS SEEDED FIRST, AND WITHOUT IT THESE TWO CASES ASSERT NOTHING ABOUT
# THE SUBCOMMAND. The gate runs its oracle before the subcommand and the oracle
# goes through zro_exec too, so a bad user or a missing binary refuses the ORACLE
# and the case passes with `gaf` deleted. A mailbox already proven costs no read at
# all — zro_mbox_require returns without calling zro_exec — which leaves the
# zmmailbox call as the only thing left to refuse.
#
# SAID PLAINLY: that is an argument from the code, not something these two cases
# can show. Both refusals happen before anything is executed, so the mock log is
# empty either way and no assertion here can tell the seeded path from the
# unseeded one. The allowlist case above is the discriminating one — it names a
# subcommand, and nothing but the subcommand can be refused for it.
zro_mbox_forget
zro_mbox_prove "$ACCT"
ZRO_MOCK_ID_USER=nobody assert_status "$ZRO_E_BADUSER" zro_mbox_run "$ACCT" gaf
ZRO_ZIMBRA_BIN=/nonexistent assert_status "$ZRO_E_NOCAP" zro_mbox_run "$ACCT" gaf
zro_mbox_forget

it "the blob head passes the gate's codes through"
BLOB="$ZRO_STORE_ROOT/0/9/msg/0/274-778.msg"
mkdir -p "$(dirname -- "$BLOB")"
: >"$BLOB"
# The allowlist case is deliberately not alone here: zro_msg_admit_blob answers with
# the same code for a path outside the store root, so a denial on its own cannot say
# which of the two refused. The other two can only come from the gate, and they are
# what pins this seam.
gate_denies  zro_msg_head_fetch "$BLOB"
gate_baduser zro_msg_head_fetch "$BLOB"
ZRO_SYSTEM_BIN=/nonexistent assert_status "$ZRO_E_NOCAP" zro_msg_head_fetch "$BLOB"

# ------------------------------------------------- the directory read --

# The one call site that hands the gate a variable. Its own pre-gate check refuses
# a subcommand outside ZRO_PROV_READS before anything runs; `ga` is inside it, so
# what this case reaches is the gate itself.
it "the directory read passes the gate's codes through"
gate_denies  zro_prov_read "$ZRO_E_NO_ACCOUNT" ga "$ACCT"
gate_baduser zro_prov_read "$ZRO_E_NO_ACCOUNT" ga "$ACCT"
ZRO_ZIMBRA_BIN=/nonexistent assert_status "$ZRO_E_NOCAP" \
  zro_prov_read "$ZRO_E_NO_ACCOUNT" ga "$ACCT"

# ------------------------------------------------------- the log reads --

it "the bounded log read passes the gate's codes through"
gate_denies  zro_logview_read syslog "$ZRO_SYSLOG_FILE"
gate_baduser zro_logview_read syslog "$ZRO_SYSLOG_FILE"
ZRO_SYSTEM_BIN=/nonexistent assert_status "$ZRO_E_NOCAP" \
  zro_logview_read syslog "$ZRO_SYSLOG_FILE"

# NOT A RETURN VALUE, AND THAT IS THE POINT OF ASSERTING IT HERE. This one always
# answers 0: it runs a pipeline and writes the stages' statuses to a file, which
# zro_logsearch_gate_code then reads. So the gate's code travels out of this seam in
# that file, and a case asserting the return value would pass while proving nothing.
it "the log scan records the gate's code in the statuses it writes"
SCAN_ERR=$(mktemp)
SCAN_DENIED=$(mktemp); SCAN_BADUSER=$(mktemp); SCAN_NOCAP=$(mktemp)
# A status file each, rather than one reused: the last case below reads a status
# back through the reader that interprets it, and a shared file would hand it
# whichever scan happened to run last.
ZRO_ALLOW="$DENY_ALL" assert_status 0 \
  zro_logsearch_scan_file "$ZRO_SYSLOG_FILE" -F 'reject' '' 10 "$SCAN_ERR" "$SCAN_DENIED"
assert_contains "$(cat "$SCAN_DENIED")" "$ZRO_E_DENIED"

it "and the same is true of the gate's other two codes"
ZRO_MOCK_ID_USER=nobody assert_status 0 \
  zro_logsearch_scan_file "$ZRO_SYSLOG_FILE" -F 'reject' '' 10 "$SCAN_ERR" "$SCAN_BADUSER"
assert_contains "$(cat "$SCAN_BADUSER")" "$ZRO_E_BADUSER"
ZRO_SYSTEM_BIN=/nonexistent assert_status 0 \
  zro_logsearch_scan_file "$ZRO_SYSLOG_FILE" -F 'reject' '' 10 "$SCAN_ERR" "$SCAN_NOCAP"
assert_contains "$(cat "$SCAN_NOCAP")" "$ZRO_E_NOCAP"

it "and the reader turns those statuses back into the gate's own code"
assert_out_eq "$ZRO_E_DENIED"  zro_logsearch_gate_code "$(cat "$SCAN_DENIED")"
assert_out_eq "$ZRO_E_BADUSER" zro_logsearch_gate_code "$(cat "$SCAN_BADUSER")"
assert_out_eq "$ZRO_E_NOCAP"   zro_logsearch_gate_code "$(cat "$SCAN_NOCAP")"

zro_t_report
