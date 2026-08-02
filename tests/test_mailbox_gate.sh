#!/usr/bin/env bash
# The existence gate: the oracle, the three verdicts, the proof that is cached
# and the absence that is not, and the one function that may reach the binary
# behind it.
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/validate.sh
. "$ZRO_SRC/lib/validate.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
export ZRO_MOCK_ID_USER=zimbra
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* 2>/dev/null || true

ZRO_MBOX_PROOF_FILE=$(mktemp); export ZRO_MBOX_PROOF_FILE

# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"
# shellcheck source=../lib/account.sh
. "$ZRO_SRC/lib/account.sh"
# shellcheck source=../lib/mailbox.sh
. "$ZRO_SRC/lib/mailbox.sh"

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG
FIX="$ZRO_TEST_ROOT/fixtures"

# THE FOUR OUTCOMES, CAPTURED ON THE LAB SERVER RATHER THAN WRITTEN FROM MEMORY.
# `zmprov gis` was run against an account with a mailbox, an account provisioned
# but never used, an address nobody has heard of, and once through LDAP mode —
# and the exit status and both streams were recorded for each. Every case below
# rests on those four files; nothing here invents what Zimbra says.
POPULATED="ahmet.yilmaz@example.com"
BARE="sade@example.com"
GONE="yok@example.com"

OK_OUT="$FIX/zmprov_gis_ok.txt"
NO_MBOX="$FIX/zmprov_gis_no_mailbox.err"
NO_ACCT="$FIX/zmprov_gis_no_such_account.err"
SOAP_ONLY="$FIX/zmprov_l_gis_soap_only.err"
OUTAGE="$FIX/zmprov_io_error_refused.err"

ran() { cat "$ZRO_MOCK_LOG"; }
runs() { ran | grep -c '^zmprov'; }
fresh() { : >"$ZRO_MOCK_LOG"; zro_mbox_forget; zro_clear_error; }

# The server, as one of the four captured outcomes. Every case says which server
# it is talking to rather than inheriting one from the file.
answers_exists() {
  ZRO_MOCK_ZMPROV_GIS_OUT="$OK_OUT" ZRO_MOCK_ZMPROV_GIS_RC=0 "$@"
}
answers_no_mailbox() {
  ZRO_MOCK_ZMPROV_GIS_ERR="$NO_MBOX" ZRO_MOCK_ZMPROV_GIS_RC=2 "$@"
}
answers_no_account() {
  ZRO_MOCK_ZMPROV_GIS_ERR="$NO_ACCT" ZRO_MOCK_ZMPROV_GIS_RC=2 "$@"
}
answers_outage() {
  ZRO_MOCK_ZMPROV_GIS_ERR="$OUTAGE" ZRO_MOCK_ZMPROV_GIS_RC=1 "$@"
}

# ------------------------------------------ the fixtures answer the question --

it "the captured outcomes really are four different answers"
# ASSERTED BEFORE ANYTHING READS THEM. Four files that turned out to carry the
# same sentence would let every case below pass while proving nothing: a gate that
# said one word for everything would agree with them.
assert_contains "$(cat "$NO_MBOX")" "mailbox not found"
assert_not_contains "$(cat "$NO_MBOX")" "no such account"
assert_contains "$(cat "$NO_ACCT")" "no such account"
assert_not_contains "$(cat "$NO_ACCT")" "mailbox not found"
assert_contains "$(cat "$SOAP_ONLY")" "can only be used with SOAP"
assert_contains "$(cat "$OK_OUT")" "stats:"

it "and the three failures are told apart by their words, not by their status"
# All three exit 2 on the real server. That is the entire reason classification
# reads the message: an exit code cannot tell an account that is not there from a
# mailbox that is not there, and those two send an operator to different places.
assert_out_eq "nomailbox" zro_mbox_classify "$(cat "$NO_MBOX")"
assert_out_eq "noaccount" zro_mbox_classify "$(cat "$NO_ACCT")"
assert_fail zro_mbox_classify "$(cat "$SOAP_ONLY")"
assert_fail zro_mbox_classify "$(cat "$OUTAGE")"
assert_fail zro_mbox_classify ""

# ------------------------------------------------------------ the verdicts --

it "a mailbox that is there is proven"
fresh
assert_eq "$(answers_exists zro_mbox_verdict "$POPULATED")" "exists"

it "an account with no mailbox is a RESULT, not a failure"
# The discipline the address resolver already follows: absence returns success and
# a question this program could not ask returns the code for why. A gate that
# failed here would put its own worst sentence behind a stopped service.
fresh
rc=0
verdict=$(answers_no_mailbox zro_mbox_verdict "$BARE") || rc=$?
assert_eq "$rc" "0"
assert_eq "$verdict" "nomailbox"

it "and an account that is not there is a third answer, not the second one"
fresh
rc=0
verdict=$(answers_no_account zro_mbox_verdict "$GONE") || rc=$?
assert_eq "$rc" "0"
assert_eq "$verdict" "noaccount"

it "it validates the address before running anything"
fresh
assert_status "$ZRO_E_INPUT" zro_mbox_verdict 'a@b.com; id'
assert_status "$ZRO_E_INPUT" zro_mbox_verdict ''
assert_eq "$(runs)" "0"

it "the oracle's own output is never shown, only that it answered"
# What it prints is the search index's document count, and the populated account
# on the lab server answers maxDocs:0 with 258 messages in it. A screen that
# repeated those numbers would look like an answer about the mailbox.
fresh
assert_eq "$(answers_exists zro_mbox_verdict "$POPULATED")" "exists"
assert_not_contains "$(answers_exists zro_mbox_verdict "$POPULATED")" "maxDocs"

# ------------------------------------------------- what the session remembers --

it "a proof is kept for the session, so a second question costs nothing"
fresh
answers_exists zro_mbox_verdict "$POPULATED" >/dev/null
answers_exists zro_mbox_verdict "$POPULATED" >/dev/null
answers_exists zro_mbox_verdict "$POPULATED" >/dev/null
assert_eq "$(runs)" "1"

it "and it survives the command substitution every screen reads it through"
# THE REASON IT IS A FILE. Menu code runs operations inside $( ), and a proof
# recorded in that subshell dies with it — the gate would then run once per screen
# at a JVM start each time, which is the bug the capability cache records having
# already been fixed once.
fresh
out=$(answers_exists zro_mbox_verdict "$POPULATED")
assert_eq "$out" "exists"
assert_ok zro_mbox_proven "$POPULATED"

it "an absence is NEVER kept, and is asked again every time"
# The next delivered message falsifies a no. An operator who has just sent a test
# message must not be told a stale one.
fresh
answers_no_mailbox zro_mbox_verdict "$BARE" >/dev/null
answers_no_mailbox zro_mbox_verdict "$BARE" >/dev/null
assert_eq "$(runs)" "2"
assert_fail zro_mbox_proven "$BARE"

it "and neither is a missing account"
fresh
answers_no_account zro_mbox_verdict "$GONE" >/dev/null
answers_no_account zro_mbox_verdict "$GONE" >/dev/null
assert_eq "$(runs)" "2"
assert_fail zro_mbox_proven "$GONE"

it "a proof is about one account and is not read as being about another"
fresh
answers_exists zro_mbox_verdict "$POPULATED" >/dev/null
assert_ok zro_mbox_proven "$POPULATED"
assert_fail zro_mbox_proven "$BARE"
assert_fail zro_mbox_proven "${POPULATED}x"

it "and an address typed in another case is the same account"
# A mail address is case-insensitive and zmprov answers in the case the directory
# holds. Comparing literally would make every operator who capitalised an address
# pay for the gate twice about one mailbox.
fresh
answers_exists zro_mbox_verdict "$POPULATED" >/dev/null
assert_ok zro_mbox_proven "Ahmet.Yilmaz@example.COM"
assert_eq "$(answers_exists zro_mbox_verdict "AHMET.YILMAZ@example.com")" "exists"
assert_eq "$(runs)" "1"

# ------------------------------------------------------------ the silent gate --

it "a mailbox service that does not answer leaves the gate unable to answer"
# NOT AN ABSENCE. The oracle speaks SOAP and nothing else, so an outage is a
# question the gate could not ask — and reporting it as "this account has no
# mailbox" would be the single most damaging thing this program could say.
fresh
assert_status "$ZRO_E_UNAVAILABLE" answers_outage zro_mbox_verdict "$POPULATED"

it "and nothing is proven or disproven by it"
assert_fail zro_mbox_proven "$POPULATED"

it "the LDAP retry that would follow is never attempted"
# zro_prov_read reaches for LDAP mode on its own when mailboxd is unreachable.
# For this read there is nothing to reach for: index statistics are not in the
# directory, so the retry is refused before it is made rather than after.
fresh
answers_outage zro_mbox_verdict "$POPULATED" >/dev/null 2>&1
assert_not_contains "$(ran)" "$(printf 'zmprov\t-l')"
assert_eq "$(runs)" "1"

it "and it is refused as an outage rather than logged as a defect"
# An allowlist denial means a defect in this program. A read whose LDAP form
# nobody approved is not one, and the difference reaches the operator during
# exactly the incident when a tool can least afford to look broken.
fresh
said=$(answers_outage zro_mbox_verdict "$POPULATED" 2>&1 >/dev/null)
assert_not_contains "$said" "denied by allowlist"

it "the gate refuses that form even if something calls it"
# The case above decides not to ASK. This is the list still refusing to answer,
# which is the half the guarantee rests on.
assert_fail zro_allowed zmprov -l gis
assert_fail zro_allowed zmprov -l gis "$POPULATED"
assert_fail zro_ldap_form_allowed gis "$POPULATED"

# ------------------------------------------------ the gate a screen asks of --

it "the gate answers a mailbox screen with a documented code"
fresh
assert_ok answers_exists zro_mbox_require "$POPULATED"
fresh
assert_status "$ZRO_E_NO_MAILBOX" answers_no_mailbox zro_mbox_require "$BARE"
fresh
assert_status "$ZRO_E_NO_ACCOUNT" answers_no_account zro_mbox_require "$GONE"
fresh
assert_status "$ZRO_E_UNAVAILABLE" answers_outage zro_mbox_require "$POPULATED"

# ------------------------------------- the one function that reaches the binary --

it "an account with no mailbox never reaches the binary that would create one"
# THE WHOLE POINT. The gate runs first and refuses, and the vector is never built.
fresh
assert_status "$ZRO_E_NO_MAILBOX" answers_no_mailbox zro_mbox_run "$BARE" gaf
assert_not_contains "$(ran)" "zmmailbox"

it "nor does an account that is not there"
fresh
assert_status "$ZRO_E_NO_ACCOUNT" answers_no_account zro_mbox_run "$GONE" gaf
assert_not_contains "$(ran)" "zmmailbox"

it "nor does anything at all while the mailbox service is unreachable"
fresh
assert_status "$ZRO_E_UNAVAILABLE" answers_outage zro_mbox_run "$POPULATED" gaf
assert_not_contains "$(ran)" "zmmailbox"

it "a proven mailbox gets past the gate, and only the four approved reads do"
# AN OPERATION ARRIVES WITH THE TICKET THAT EXPOSES IT, never because the binary
# it belongs to became reachable. Four reads are approved behind this gate; the
# oracle proves the call would be safe and the list still decides whether it is
# one of them.
fresh
assert_ok answers_exists zro_mbox_run "$POPULATED" gaf
assert_contains "$(ran)" "zmmailbox"

fresh
assert_status "$ZRO_E_DENIED" answers_exists zro_mbox_run "$POPULATED" search
assert_not_contains "$(ran)" "zmmailbox"

it "and the refusal of an unapproved one is the list's, not the gate's"
# The two denials have to arrive as different sentences: a maintainer sent to the
# allowlist about a call that skipped the oracle would read the wrong file and
# find nothing wrong with it.
fresh
said=$(answers_exists zro_mbox_run "$POPULATED" search 2>&1 >/dev/null)
assert_contains "$said" "denied by allowlist"
assert_not_contains "$said" "only through the existence gate"

it "the commands that write a mailbox are refused although the binary is reachable"
# Each of these lives one letter away from a read that is approved, which is
# exactly why they are written down here rather than left to the absence of an
# entry. `gm` is in the list too and is not a write: it CLEARS THE UNREAD FLAG on
# the message it reports, which is a change to the mailbox made by a command
# named getMessage.
for sub in df ef cf mfg mff mfc rf sf iuif mfr mm ma gm gru emptyDumpster \
           deleteFolder emptyFolder createFolder modifyFolderGrant getMessage; do
  fresh
  assert_status "$ZRO_E_DENIED" answers_exists zro_mbox_run "$POPULATED" "$sub"
  assert_not_contains "$(ran)" "zmmailbox"
done

it "it refuses a subcommand shaped like a flag before the gate is even run"
# The subcommand reaches the exec gate in the token position, where a flag is not
# data but an operation of its own. Nothing an operator typed may arrive there.
fresh
assert_status "$ZRO_E_INPUT" zro_mbox_run "$POPULATED" -z
assert_status "$ZRO_E_INPUT" zro_mbox_run "$POPULATED" ''
assert_status "$ZRO_E_INPUT" zro_mbox_run "$POPULATED"
assert_eq "$(runs)" "0"

it "and it validates the account before running the oracle"
fresh
assert_status "$ZRO_E_INPUT" zro_mbox_run 'a@b.com; id' gaf
assert_eq "$(runs)" "0"

it "no other caller may reach that binary, whatever it asks for"
# The runtime half of the structural rule the static scanner enforces. A screen
# that opened a session without the oracle having run would create the mailbox it
# was asked to describe, so the exec gate refuses the binary by who is asking —
# and does it BEFORE the allowlist, so a bypass never reads as an operation nobody
# approved yet.
fresh
bypass() { zro_exec "$ZRO_GATED_BIN" gaf "$POPULATED"; }
said=$(bypass 2>&1 >/dev/null)
assert_status "$ZRO_E_DENIED" bypass
assert_contains "$said" "only through the existence gate"
assert_not_contains "$said" "denied by allowlist"
assert_not_contains "$(ran)" "zmmailbox"

# --------------------------------------- the vector the binary really takes --
#
# What is proven here is the SHAPE — a caller who wrote an account and a
# subcommand gets `-z -m <account> <subcommand>` — because every screen behind the
# gate is built on it. These cases used to extend the allowlist and the root table
# for their own length, because nothing was approved behind the gate; the folder
# and size screens made both extensions real, and the cases run against the list
# the program ships with.
it "the subcommand reaches the allowlist in a position it can see"
# The reason the two orders differ at all. `zmmailbox:-z:-m` would approve
# everything behind it, which is what `zmprov:-l` is kept out of the list for.
assert_ok zro_allowed zmmailbox gaf
assert_ok zro_allowed zmmailbox gaf "$POPULATED"
assert_fail zro_allowed zmmailbox -z
assert_fail zro_allowed zmmailbox -m
assert_fail zro_allowed zmmailbox -z -m

it "and the binary is run with its own prefix put back in front of it"
fresh
answers_exists zro_mbox_run "$POPULATED" gaf >/dev/null 2>&1
assert_contains "$(ran)" "$(printf 'zmmailbox\t-z\t-m\t%s\tgaf' "$POPULATED")"

it "with the caller's arguments left behind the subcommand, in order"
fresh
answers_exists zro_mbox_run "$POPULATED" gaf '/Sent' 'a b' >/dev/null 2>&1
assert_contains "$(ran)" \
  "$(printf 'zmmailbox\t-z\t-m\t%s\tgaf\t/Sent\ta b' "$POPULATED")"

it "and a flag standing in that data is refused, as it is behind every subcommand"
# The account arrives where the allowlist reads data, so the whole vector goes
# through the same rule: a flag written there is not data, it changes what the
# command does, and it is looked up by name like any other operation.
fresh
assert_status "$ZRO_E_DENIED" answers_exists zro_mbox_run "$POPULATED" gaf --json
assert_not_contains "$(ran)" "zmmailbox"

it "and the oracle ran before any of it"
# Order asserted rather than assumed: a vector built first and gated afterwards
# would pass every case above and create a mailbox on the account it refused.
fresh
answers_exists zro_mbox_run "$POPULATED" gaf >/dev/null 2>&1
first=$(ran | grep -nE '^(zmprov|zmmailbox)' | head -n 1)
assert_contains "$first" "zmprov	gis"

it "the gate still refuses the same call for an account with no mailbox"
# The allowlist is open for these cases; the gate is what is being asked. A
# subcommand becoming approved may not become a way past the oracle.
fresh
assert_status "$ZRO_E_NO_MAILBOX" answers_no_mailbox zro_mbox_run "$BARE" gaf
assert_not_contains "$(ran)" "zmmailbox"

it "and refuses it from a caller that is not the one that owns the gate"
fresh
approved_bypass() { zro_exec "$ZRO_GATED_BIN" gaf "$POPULATED"; }
assert_status "$ZRO_E_DENIED" approved_bypass
assert_not_contains "$(ran)" "zmmailbox"

it "and refuses a vector with no account in it, rather than running one"
fresh
no_account_vector() { zro_exec "$ZRO_GATED_BIN" gaf; }
ZRO_GATE_OWNER_REAL=$ZRO_GATE_OWNER
ZRO_GATE_OWNER=no_account_vector
assert_status "$ZRO_E_DENIED" no_account_vector
ZRO_GATE_OWNER=$ZRO_GATE_OWNER_REAL
assert_not_contains "$(ran)" "zmmailbox"

it "the binary resolves under the root the table declares for it, and only there"
# The allowlist says what may be asked; the table says where the binary is. Both
# had to change for these screens to exist, and neither answers the other's
# question — so a maintainer reading the allowlist still learns everything this
# tool can execute.
assert_out_eq "$ZRO_ZIMBRA_BIN/zmmailbox" zro_bin_path zmmailbox
assert_contains "$(zro_bin_root_entries)" "zmmailbox:ZRO_ZIMBRA_BIN"

rm -f -- "$ZRO_MOCK_LOG" "$ZRO_MBOX_PROOF_FILE"
zro_t_report
