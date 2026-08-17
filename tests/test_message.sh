#!/usr/bin/env bash
# ONE MESSAGE WITHOUT OPENING IT: the record the metadata dump prints, and the head
# of the blob the message is stored in.
#
# EVERY FIXTURE HERE WAS CAPTURED ON THE LAB SERVER on 2026-08-17, with the addresses
# and subjects changed and nothing else. The shapes are exactly where a bug from an
# invented fixture would come from: a column section whose values may be `<null>` or
# absent altogether, and a blob that is CRLF, folds its headers with a space AND with
# a tab, and carries a signature separator that looks like a MIME boundary. See
# docs/research/2026-08-17-message-detail.md.
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/validate.sh
. "$ZRO_SRC/lib/validate.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_SYSTEM_BIN="$ZRO_TEST_ROOT/mocks/system"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
export ZRO_NICE_BIN="$ZRO_TEST_ROOT/mocks/bin/nice"
export ZRO_IONICE_BIN="$ZRO_TEST_ROOT/mocks/bin/ionice"
export ZRO_MOCK_ID_USER=zimbra
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* "$ZRO_TEST_ROOT"/mocks/system/* 2>/dev/null || true

# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"
# shellcheck source=../lib/account.sh
. "$ZRO_SRC/lib/account.sh"
# shellcheck source=../lib/store.sh
. "$ZRO_SRC/lib/store.sh"
# shellcheck source=../lib/message.sh
. "$ZRO_SRC/lib/message.sh"

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG
FIX="$ZRO_TEST_ROOT/fixtures"

ACCT="ahmet.yilmaz@example.com"
ITEM=274

# THE STORE, AS A TREE THIS TEST OWNS. The dump's own fixture names the production
# path, so the blob path is rewritten to point inside this tree and the declared root
# is pointed at it — which is the same override every other root in this suite gets.
# Rewritten rather than invented: what the dump prints keeps its shape, and the case
# below still proves the path is read out of the dump's own output.
STORE=$(mktemp -d)
export ZRO_STORE_ROOT="$STORE"
BLOB_DIR="$STORE/0/9/msg/0"
mkdir -p "$BLOB_DIR"
BLOB="$BLOB_DIR/274-778.msg"
cp -- "$FIX/store_blob_multipart.msg" "$BLOB"
SIMPLE="$BLOB_DIR/262-638.msg"
cp -- "$FIX/store_blob_simple.msg" "$SIMPLE"

DUMP_SRC="$FIX/zmmetadump_message.txt"
DUMP="$STORE/dump-274.txt"
sed "s|^/opt/zimbra/store/.*|$BLOB|" "$DUMP_SRC" >"$DUMP"
FOLDER_DUMP="$FIX/zmmetadump_folder.txt"

dump=$(cat "$DUMP")
folder_dump=$(cat "$FOLDER_DUMP")
multipart=$(cat "$BLOB")
simple=$(cat "$SIMPLE")

ran() { cat "$ZRO_MOCK_LOG"; }
fresh() { : >"$ZRO_MOCK_LOG"; zro_clear_error; }
answers() {
  export ZRO_MOCK_ZMMETADUMP_274_OUT="$DUMP"
  unset ZRO_MOCK_ZMMETADUMP_274_ERR ZRO_MOCK_ZMMETADUMP_274_RC
}
fails() {
  unset ZRO_MOCK_ZMMETADUMP_274_OUT
  export ZRO_MOCK_ZMMETADUMP_274_ERR="$1"
  export ZRO_MOCK_ZMMETADUMP_274_RC="${2:-1}"
}

# ------------------------------------------------------ the record, parsed --

it "reads a column out of the dump's own section"
assert_out_eq "9" zro_msg_column mailbox_id "$dump"
assert_out_eq "274" zro_msg_column id "$dump"
assert_out_eq "2" zro_msg_column folder_id "$dump"
assert_out_eq "1117" zro_msg_column size "$dump"
assert_out_eq "1" zro_msg_column unread "$dump"

it "and a value carrying a colon arrives whole"
# The subject is where this bites: `Ekli ileti: temmuz faturasi` cut at the first
# colon would report a different subject than the message has.
assert_out_eq "Ekli ileti: temmuz faturasi" zro_msg_column subject "$dump"

it "and the digest is passed through exactly as the server wrote it"
# Zimbra's base64 variant uses ',' where the standard alphabet uses '/'. A reader
# that tidied it would print a digest nobody can compare against the server's.
assert_out_eq "5iDsvR0c7xLln34hBVGfHiF0eT6s6,qrqk6FJf,Kt+E=" zro_msg_column blob_digest "$dump"

it "tells a column that is null from a column that is not there"
# Two different facts, and the words for them are not interchangeable: one is about
# the message, the other about this program.
assert_out_eq "<null>" zro_msg_column parent_id "$dump"
assert_out_eq "$ZRO_TXT_UNSET" zro_msg_field parent_id "$dump"
assert_fail zro_msg_column no_such_column "$dump"
assert_out_eq "$ZRO_TXT_UNKNOWN" zro_msg_field no_such_column "$dump"

it "and reads nothing at all out of the metadata section"
# THE BODY RULE, AT THE PLACE IT WOULD BREAK FIRST. `[Metadata]` carries the message
# FRAGMENT under the key `f` — the preview text Zimbra cuts out of the body — so a
# reader that did not stop at the section boundary would answer with body text.
assert_fail zro_msg_column f "$dump"
assert_fail zro_msg_column s "$dump"
assert_fail zro_msg_column t "$dump"

it "renders a timestamp column from the count, not from the server's own formatting"
# The parenthesised half of the column is built in the JVM's default timezone and
# Java's field order. What this program shows is its own rendering of the number,
# with the number beside it so the two can be checked against each other.
when=$(zro_msg_when date "$dump")
assert_contains "$when" "(1786971466)"
assert_contains "$when" "2026-08-1"
assert_out_eq "$ZRO_TXT_UNKNOWN" zro_msg_when no_such_column "$dump"

it "and refuses a timestamp that is not a count"
assert_out_eq "1786971466" zro_msg_epoch "1786971466 (Mon 2026/08/17 15:57:46 TRT)"
assert_fail zro_msg_epoch "Mon 2026/08/17"
assert_fail zro_msg_epoch ""

it "shows the size in both forms, and refuses a size that is not a number"
assert_out_eq "1.0 KB (1117 bayt)" zro_msg_size_field "$dump"
# A LOCALE-FORMATTED SIZE IS REFUSED RATHER THAN READ, which is the rule the mailbox
# size lives by one module over: the digits out of '1,4 KB' would report a message
# fourteen times too large on every server whose decimal separator is a comma.
assert_out_eq "$ZRO_TXT_UNKNOWN" zro_msg_size_field "$(printf '%s\n  size: 1,4 KB\n' "$ZRO_MSG_HDR_COLUMNS")"

it "and a size the record does not carry is UNSET, not unreadable"
# THE TWO WORDS ARE NOT INTERCHANGEABLE and every typed field has to get it right, not
# only the plain ones: <null> is the record saying it holds no size, which is a fact
# about the message, while 'bilinmiyor' is this program saying it could not read one.
assert_out_eq "$ZRO_TXT_UNSET" zro_msg_size_field "$(printf '%s\n  size: <null>\n' "$ZRO_MSG_HDR_COLUMNS")"
assert_out_eq "$ZRO_TXT_UNKNOWN" zro_msg_size_field "$ZRO_MSG_HDR_COLUMNS"
assert_out_eq "$ZRO_TXT_UNSET" zro_msg_when "date" "$(printf '%s\n  date: <null>\n' "$ZRO_MSG_HDR_COLUMNS")"
assert_out_eq "$ZRO_TXT_UNSET" zro_msg_unread_field "$(printf '%s\n  unread: <null>\n' "$ZRO_MSG_HDR_COLUMNS")"

it "names the one state the record can be read for, and decodes no bitmask"
# `unread` is a column of its own. `flags` and `type` are numbers whose meanings
# nobody here has measured, so they are shown as the server holds them.
assert_out_eq "evet" zro_msg_unread_field "$dump"
assert_out_eq "2" zro_msg_field flags "$dump"
assert_out_eq "5" zro_msg_field type "$dump"
assert_out_eq "hayir (okunmus)" zro_msg_unread_field "$(printf '%s\n  unread: 0\n' "$ZRO_MSG_HDR_COLUMNS")"
assert_out_eq "$ZRO_TXT_UNKNOWN" zro_msg_unread_field "$(printf '%s\n  unread: x\n' "$ZRO_MSG_HDR_COLUMNS")"

it "and on a record that is not a message that column is a count, so it reads as one"
# MEASURED: the dump of the Inbox FOLDER answers `unread: 14`, which is the number of
# unread items in it rather than a flag. Reporting that as unreadable would be this
# program claiming it could not read a value it read perfectly well.
assert_contains "$(zro_msg_unread_field "$folder_dump")" "14"
assert_contains "$(zro_msg_unread_field "$folder_dump")" "ileti degil"

# -------------------------------------------------------------- the blob path --

it "takes the blob path out of the dump's own output"
assert_out_eq "$BLOB" zro_msg_blob_path "$dump"

it "and an item with no blob has no path, which is an answer about the record"
# The section is absent whenever the blob digest is null — every folder, and a
# message whose blob the store lost.
assert_fail zro_msg_blob_path "$folder_dump"

it "admits a blob path under the declared root and refuses everything else"
assert_ok zro_msg_blob_ok "$BLOB"
assert_ok zro_msg_blob_ok "$ZRO_STORE_ROOT/0/9/msg/0/274-778.msg"
assert_fail zro_msg_blob_ok ""
assert_fail zro_msg_blob_ok "0/9/msg/0/274-778.msg"
assert_fail zro_msg_blob_ok "$ZRO_STORE_ROOT"
assert_fail zro_msg_blob_ok "/etc/shadow"
assert_fail zro_msg_blob_ok "${ZRO_STORE_ROOT}x/0/9/msg/0/1-1.msg"

it "and refuses the characters no path this tool opens needs"
# The rule the log inventory applies to its own paths, and here for the same reason
# on a value that arrives in another program's OUTPUT: a quote, a space or a shell
# metacharacter in a path this tool opens is a path nobody has judged.
assert_fail zro_msg_blob_ok "$ZRO_STORE_ROOT/0/9/msg/0/it's.msg"
assert_fail zro_msg_blob_ok "$ZRO_STORE_ROOT/0/9/msg/0/two words.msg"
assert_fail zro_msg_blob_ok "$ZRO_STORE_ROOT/0/9/msg/0/\$(id).msg"
assert_fail zro_msg_blob_ok "$ZRO_STORE_ROOT/0/9/../../etc/shadow"

it "and a trailing slash on the declared root is the same root"
# What a human writes half the time. Compared literally it would refuse every blob on
# the host — a refusal in the safe direction and an incomprehensible one.
ZRO_STORE_ROOT="$STORE/" assert_ok zro_msg_blob_ok "$BLOB"
ZRO_STORE_ROOT="$STORE//" assert_ok zro_msg_blob_ok "$BLOB"
ZRO_STORE_ROOT="$STORE/" assert_fail zro_msg_blob_ok "/etc/shadow"

it "and refuses every path when no store root is declared"
# Refused rather than searched for: there is no second place to look, and following
# whatever the dump printed is exactly what the declaration exists to prevent.
ZRO_STORE_ROOT="" assert_fail zro_msg_blob_ok "$BLOB"
ZRO_STORE_ROOT="" assert_fail zro_msg_admit_blob "$BLOB"

it "and says out loud which of the two refusals it was"
said=$(ZRO_STORE_ROOT="" zro_msg_admit_blob "$BLOB" 2>&1)
assert_contains "$said" "no store root is declared"
said=$(zro_msg_admit_blob "/etc/shadow" 2>&1)
assert_contains "$said" "outside the permitted set"

# ------------------------------------------------------------- the blob head --

it "reads the header block as the file holds it, minus the carriage returns"
block=$(zro_msg_header_block <<EOF
$multipart
EOF
)
assert_contains "$block" "From: Ali Veli <ali.veli@example.org>"
assert_contains "$block" 'Content-Type: multipart/mixed; boundary="SINIR-A1B2C3"'
# The block ends at the first empty line, so nothing past the headers is in it.
assert_not_contains "$block" "SINIR-A1B2C3
Content-Type: text/plain"
assert_not_contains "$block" $'\r'

it "and stops at the headers rather than reading the body"
assert_not_contains "$block" "Govde metni"

it "knows whether the head reached the end of the header block"
assert_ok zro_msg_headers_complete <<EOF
$multipart
EOF
assert_fail zro_msg_headers_complete <<EOF
From: Ali Veli <ali.veli@example.org>
To: ahmet.yilmaz@example.com
EOF

it "reads one header, unfolding the continuation lines the grammar defines"
# Both folding forms are in this fixture because both are in the file the server
# wrote: the first Received folds with a SPACE and the second with a TAB.
assert_out_eq "ahmet.yilmaz@example.com" zro_msg_header To "$block"
assert_out_eq "bilgi-islem@example.com, Ayse Demir <ayse.demir@example.com>" \
  zro_msg_header Cc "$block"
received=$(zro_msg_header Received "$block")
assert_contains "$received" "with LMTP; Mon, 17 Aug 2026 15:57:46 +0300 (TRT)"
assert_not_contains "$received" "userid 997"

it "and matches a header name case-insensitively, because the grammar does"
# Two programs wrote the two fixtures here: one spells it `Message-ID` and the other
# `Message-Id`. A case-sensitive reader would report half the mail on a server as
# carrying no identifier.
assert_out_eq "<ekli-ileti-1@example.org>" zro_msg_header message-id "$block"
simple_block=$(zro_msg_header_block <<EOF
$simple
EOF
)
assert_out_eq "<temmuz-faturasi-1@example.org>" zro_msg_header Message-ID "$simple_block"

it "and a header the message does not carry is a fact about the message"
assert_fail zro_msg_header Cc "$simple_block"
assert_out_eq "$ZRO_TXT_NONE" zro_msg_header_field Cc "$simple_block"

it "lists the MIME parts visible in the head, with what each says about itself"
rows=$(zro_msg_part_rows <<EOF
$multipart
EOF
)
assert_eq "$(printf '%s\n' "$rows" | wc -l)" "2"
assert_contains "$rows" "$(printf 'text/plain\t\t')"
assert_contains "$rows" "$(printf 'application/pdf\tattachment\tfatura.pdf')"

it "and reads nothing out of a part's body"
assert_not_contains "$rows" "Govde metni"
assert_not_contains "$rows" "JVBERi0xLjQK"

it "and a plain-text signature separator is not a part"
# A signature is introduced by a line reading `--`, so a reader that trusted every
# line beginning with two dashes would report one as an attachment. What follows is
# prose: no type, no file name, no row.
assert_eq "$(zro_msg_part_rows <<EOF
$simple
EOF
)" ""

it "and a part is an attachment when it has a name or the message says so"
assert_ok zro_msg_row_attachment "$(printf 'application/pdf\tattachment\tfatura.pdf')"
assert_ok zro_msg_row_attachment "$(printf 'image/png\tinline\tlogo.png')"
assert_fail zro_msg_row_attachment "$(printf 'text/plain\t\t')"

it "reads a header parameter in both the quoted and the bare form"
assert_out_eq "fatura.pdf" zro_msg_param name 'application/pdf; name="fatura.pdf"'
assert_out_eq "fatura.pdf" zro_msg_param filename 'attachment; filename=fatura.pdf'
assert_out_eq "fatura.pdf" zro_msg_param filename 'attachment; filename=fatura.pdf; size=12'
assert_out_eq "" zro_msg_param name 'text/plain; charset=UTF-8'

# ---------------------------------------------------------------- the reads --

it "asks the dump for one item of one mailbox, by address and by id"
# THE ADDRESS RATHER THAN A MAILBOX ID, because a numeric id skips the lookup that
# decides whether the mailbox is on this host — and a wrong one then answers
# `No such item`, which this program would report as a message that is not there.
fresh; answers
out=$(zro_msg_dump_fetch "$ACCT" "$ITEM")
assert_contains "$out" "[Database Columns]"
assert_contains "$(ran)" "$(printf 'zmmetadump\t-m\t%s\t-i\t274' "$ACCT")"

it "and asks for nothing else of that binary"
assert_not_contains "$(ran)" "--dumpster"
assert_eq "$(ran | grep -c '^zmmetadump')" "1"

it "and it runs under the wall-clock timeout, which is not optional here"
# The dump has no timeout of its own: with the database unreachable it retries
# forever. The clock the gate imposes is the whole reason this screen can exist.
assert_contains "$(ran)" "$(printf 'timeout\t-k\t5')"

it "refuses an address or an id it would not put on a command line, and runs nothing"
fresh; answers
assert_status "$ZRO_E_INPUT" zro_msg_dump_fetch "not-an-address" "$ITEM"
assert_status "$ZRO_E_INPUT" zro_msg_dump_fetch "$ACCT" "abc"
assert_status "$ZRO_E_INPUT" zro_msg_dump_fetch "$ACCT" "0"
assert_status "$ZRO_E_INPUT" zro_msg_dump_fetch "$ACCT" "-263"
assert_status "$ZRO_E_INPUT" zro_msg_dump_fetch "$ACCT" ""
assert_eq "$(ran)" ""

it "reports an item the mailbox does not hold as a result rather than a failure"
fresh; fails "$FIX/zmmetadump_no_such_item.err"
assert_status "$ZRO_E_NO_RESULT" zro_msg_dump_fetch "$ACCT" "$ITEM"
assert_contains "$(zro_last_error)" "No such item"

it "reports a mailbox this host does not carry as the no-mailbox answer it is"
# ONE SENTENCE, TWO CAUSES: measured on the lab server, the dump says
# `not found on this host` both for an address the directory never heard of and for
# an account whose mailbox was never created. It reads the mailbox table and nothing
# else, so this program may not invent the difference.
fresh; fails "$FIX/zmmetadump_not_on_host.err"
assert_status "$ZRO_E_NO_MAILBOX" zro_msg_dump_fetch "$ACCT" "$ITEM"
assert_contains "$(zro_last_error)" "not found on this host"

it "reports the usage banner as a defect in this program, and says so in the log"
# The banner arrives on stderr with exit 1 when an option is missing or malformed.
# Nobody types this: the vector is built here.
fresh; fails "$FIX/zmmetadump_usage.err"
said=$(zro_msg_dump_fetch "$ACCT" "$ITEM" 2>&1 >/dev/null) || true
assert_contains "$said" "message defect"

it "reports the clock running out as a timeout, not as a message that is not there"
fresh; answers
ZRO_MOCK_TIMEOUT_FIRE=1 assert_status "$ZRO_E_TIMEOUT" zro_msg_dump_fetch "$ACCT" "$ITEM"

it "and an expired clock stays a timeout whatever the streams carry"
# THE ONE FAILURE THIS SCREEN MAY NEVER RE-DESCRIBE FROM TEXT. The clock is this
# program's own fact, and the shared Zimbra-error reader would have turned a stopped
# database into the screen that names mailboxd and an admin certificate — a service
# this read does not talk to. The stderr here is another binary's captured refusal,
# used deliberately: it is exactly the text that would have been mapped.
fresh
ZRO_MOCK_ZMMETADUMP_274_OUT="" ZRO_MOCK_ZMMETADUMP_274_ERR="$FIX/zmprov_io_error_refused.err" \
  ZRO_MOCK_ZMMETADUMP_274_RC=124 \
  assert_status "$ZRO_E_TIMEOUT" zro_msg_dump_fetch "$ACCT" "$ITEM"

it "and the explanation comes off STDOUT, which is where this binary writes it"
# MEASURED on the lab server with mysqld stopped: the dump writes
# `Could not establish a connection to the database.  Retrying in 5 seconds.` and a
# DbPool stack trace to STDOUT — one retry every five seconds — and leaves STDERR
# empty. Without borrowing that, the timeout screen would have nothing to show.
fresh
ZRO_MOCK_ZMMETADUMP_274_OUT="$FIX/zmmetadump_db_down.txt" \
  ZRO_MOCK_ZMMETADUMP_274_ERR="" ZRO_MOCK_ZMMETADUMP_274_RC=124 \
  assert_status "$ZRO_E_TIMEOUT" zro_msg_dump_fetch "$ACCT" "$ITEM"
assert_contains "$(zro_last_error)" "Could not establish a connection to the database"

it "and a failure this program does not recognise names the service the dump needs"
# Not the raw exit status, which is a code lib/core.sh does not define, and not the
# shared reader's SOAP verdict either: the dump ran and failed, so what is reported is
# that the service it really needs — the mailbox database — could not be read.
fresh
ZRO_MOCK_ZMMETADUMP_274_OUT="$FIX/zmmetadump_db_down.txt" \
  ZRO_MOCK_ZMMETADUMP_274_ERR="" ZRO_MOCK_ZMMETADUMP_274_RC=1 \
  assert_status "$ZRO_E_UNAVAILABLE" zro_msg_dump_fetch "$ACCT" "$ITEM"
assert_contains "$(zro_last_error)" "getting database connection"

it "refuses output that is not a dump at all rather than drawing an empty record"
fresh
ZRO_MOCK_ZMMETADUMP_274_OUT="$FIX/zmcontrol_v.txt" \
  assert_status "$ZRO_E_NO_RESULT" zro_msg_dump_fetch "$ACCT" "$ITEM"

it "reads the head of an uncompressed blob, bounded, and asks the file what it is"
fresh
head_out=$(zro_msg_head_fetch "$BLOB")
assert_contains "$head_out" "Subject: Ekli ileti: temmuz faturasi"
assert_contains "$(ran)" "$(printf 'head\t-c\t2\t%s' "$BLOB")"
assert_contains "$(ran)" "$(printf 'head\t-c\t%s\t%s' "$ZRO_MSG_HEAD_BYTES" "$BLOB")"
assert_not_contains "$(ran)" "gzip"

it "and the bound is the command's own, applied to the bytes it reads"
fresh
short=$(ZRO_MSG_HEAD_BYTES=120 zro_msg_head_fetch "$BLOB")
assert_eq "${#short}" "120"
assert_contains "$(ran)" "$(printf 'head\t-c\t120\t%s' "$BLOB")"

it "and a bound that is not a count is a defect, so nothing runs"
fresh
ZRO_MSG_HEAD_BYTES=-c assert_status "$ZRO_E_INPUT" zro_msg_head_fetch "$BLOB"
ZRO_MSG_HEAD_BYTES=0 assert_status "$ZRO_E_INPUT" zro_msg_head_fetch "$BLOB"
assert_eq "$(ran)" ""

it "reads a compressed blob through the decompress-to-stdout form and writes nothing"
# The store's volume decides whether blobs are compressed, so both cases are real.
# What may never happen is the file being replaced: bare gzip and `gzip -d` both
# decompress IN PLACE and delete the original, and both are absent from the
# allowlist.
fresh
GZ="$BLOB_DIR/275-779.msg"
gzip -c "$FIX/store_blob_multipart.msg" >"$GZ"
before=$(cksum <"$GZ")
gz_out=$(zro_msg_head_fetch "$GZ")
assert_contains "$gz_out" "Subject: Ekli ileti: temmuz faturasi"
assert_contains "$(ran)" "$(printf 'gzip\t-dc\t%s' "$GZ")"
assert_eq "$(cksum <"$GZ")" "$before"
assert_ok test -f "$GZ"

it "and the decompression yields to the server, as every whole-file read does"
# gzip is declared to run at reduced priority in lib/exec.sh, so a compressed blob
# is read the way a log scan is: the gate wraps it, and no module can ask otherwise.
assert_contains "$(ran)" "$(printf 'nice\t-n\t19')"
assert_contains "$(ran)" "$(printf 'ionice\t-c\t3')"

it "and a stream longer than the bound is an ordinary answer, not a failure"
# HOW THE DECOMPRESSION REPORTS THE CLOSED PIPE IS THE HOST'S BUSINESS, NOT THIS
# SCREEN'S. Measured on three: the lab server and WSL report the SIGPIPE as 141, while
# the CI runner's gzip catches it, prints `gzip: stdout: Broken pipe` and exits
# non-zero with another code. This case is what caught that — it failed on CI and
# passed here — so what is asserted is the ANSWER: the bound's worth of bytes came
# back, whichever way the host said the pipe was closed.
fresh
BIG="$BLOB_DIR/276-780.msg"
{ cat "$FIX/store_blob_multipart.msg"; head -c 200000 /dev/zero | tr '\0' 'x'; } | gzip -c >"$BIG"
big_out=$(ZRO_MSG_HEAD_BYTES=4096 zro_msg_head_fetch "$BIG")
assert_eq "${#big_out}" "4096"

it "and the same answer on a host whose gzip complains instead of dying of SIGPIPE"
# THE HOST THIS SUITE CANNOT BE RUN ON, scripted through the mock: it writes what it
# had, prints `gzip: stdout: Broken pipe` and exits non-zero by itself. The bytes came
# back either way, which is why this reader judges the answer rather than the status.
fresh
big_out=$(ZRO_MOCK_GZIP_PIPE_RC=1 ZRO_MSG_HEAD_BYTES=4096 zro_msg_head_fetch "$BIG")
assert_eq "${#big_out}" "4096"
big_out=$(ZRO_MOCK_GZIP_PIPE_RC=2 ZRO_MSG_HEAD_BYTES=4096 zro_msg_head_fetch "$BIG")
assert_eq "${#big_out}" "4096"

it "and a decompression that yielded nothing at all is still a failure there too"
# The rule's other half: what makes a non-empty head trustworthy is that a stream this
# host cannot decompress produces no bytes. Scripted the same way, with no output.
fresh
ZRO_MOCK_GZIP_ERR="gzip: not in gzip format" ZRO_MOCK_GZIP_RC=1 \
  assert_status "$ZRO_E_NO_BLOB" zro_msg_head_fetch "$BIG"

it "and a file that is not a gzip stream is a failure rather than an empty head"
# The one case pipefail is set for: without it the decompression's failure arrives
# as an empty answer, which this function may not invent.
fresh
BAD="$BLOB_DIR/277-781.msg"
printf '\037\213not really gzip at all\n' >"$BAD"
assert_status "$ZRO_E_NO_BLOB" zro_msg_head_fetch "$BAD"

it "and no status this program does not define ever leaves the read"
# `head` answers 1 for a file that is not there and `gzip` answers 1 for a stream it
# cannot decompress; neither is a code lib/core.sh declares, and a caller switching on
# one would be reading a number nobody documented. Both become the one code for a
# stored file that could not be read.
fresh
assert_status "$ZRO_E_NO_BLOB" zro_msg_head_fetch "$BLOB_DIR/999-999.msg"

it "but a refusal by the gate travels out as itself"
# A binary this host does not have, an unsupported user, an expired clock: none of
# those is a blob that cannot be read, and an operator sent to check the store over a
# missing `head` would repair nothing.
fresh
ZRO_MOCK_TIMEOUT_FIRE=1 assert_status "$ZRO_E_TIMEOUT" zro_msg_head_fetch "$BLOB"

it "refuses a path outside the declared store root without opening anything"
fresh
assert_status "$ZRO_E_DENIED" zro_msg_head_fetch "/etc/shadow"
assert_eq "$(ran)" ""

it "and reports an empty blob as empty rather than as a message with no headers"
fresh
EMPTY="$BLOB_DIR/278-782.msg"
: >"$EMPTY"
assert_status "$ZRO_E_NO_RESULT" zro_msg_head_fetch "$EMPTY"

# ---------------------------------------------------------------- the screen --

it "draws the record and the blob's headers on one screen"
fresh; answers
card=$(zro_msg_card "$ACCT" "$ITEM")
assert_contains "$card" "Hesap                : $ACCT"
assert_contains "$card" "Ileti id             : 274"
assert_contains "$card" "Klasor id            : 2"
assert_contains "$card" "Konu                 : Ekli ileti: temmuz faturasi"
assert_contains "$card" "Boyut                : 1.0 KB (1117 bayt)"
assert_contains "$card" "Okunmamis            : evet"
assert_contains "$card" "Blob yolu            : $BLOB"
assert_contains "$card" "From                 : Ali Veli <ali.veli@example.org>"
assert_contains "$card" "To                   : ahmet.yilmaz@example.com"
assert_contains "$card" "Cc                   : bilgi-islem@example.com, Ayse Demir <ayse.demir@example.com>"
assert_contains "$card" "HAM BASLIKLAR"

it "and lists the attachment the MIME structure names"
assert_contains "$card" "fatura.pdf"
assert_contains "$card" "application/pdf"
assert_contains "$card" "Ek sayisi            : 1"
assert_contains "$card" "MIME parcasi         : 2"

it "and does not display the message body, in either of the two places it could"
# The blob's own text part, and the dump's [Metadata] section — whose `f` key is the
# fragment Zimbra cuts out of the body. Neither reaches the screen.
assert_not_contains "$card" "Govde metni"
assert_not_contains "$card" "JVBERi0xLjQK"
# The metadata section's own lines, which is where the fragment lives. The screen
# NAMES that section in the paragraph that says it is not shown, so what is asserted
# is the absence of its content rather than of the word.
assert_not_contains "$card" "f = "
assert_not_contains "$card" "t = ahmet"
assert_contains "$card" "ILETI GOVDESI GOSTERILMEZ"

it "and says how much of the file it read"
assert_contains "$card" "ilk $ZRO_MSG_HEAD_BYTES bayti okundu"
assert_contains "$card" "TAMAMI DEGILDIR"

it "and says the bound cut the header block when it did"
fresh; answers
cut=$(ZRO_MSG_HEAD_BYTES=200 zro_msg_card "$ACCT" "$ITEM")
assert_contains "$cut" "BASLIK BOLUMU BU SINIRIN ICINDE BITMEDI"

it "and then claims NOTHING about the parts, rather than contradicting itself"
# A HEAD THAT STOPPED INSIDE THE HEADERS NEVER REACHED THE MIME STRUCTURE. Saying
# 'this message is single-part, so it has no attachment' about those bytes is a guess,
# and the screen would deny an attachment ten lines above admitting it read too little
# to know. So the positive claim is suppressed and the absence of an answer is said.
assert_contains "$cut" "PARCA LISTESI CIKARILAMADI"
assert_contains "$cut" "eki YOKTUR demek DEGILDIR"
assert_not_contains "$cut" "$ZRO_TXT_MSG_NO_PARTS"

it "and a head that really ended the headers still makes that claim, because it is one"
# The single-part message, read whole: here 'no parts, so no attachments' is an answer
# about the message rather than a guess about bytes nobody read.
fresh
sed "s|^/opt/zimbra/store/.*|$SIMPLE|" "$DUMP_SRC" >"$STORE/dump-262.txt"
export ZRO_MOCK_ZMMETADUMP_262_OUT="$STORE/dump-262.txt"
whole=$(zro_msg_card "$ACCT" 262)
assert_contains "$whole" "$ZRO_TXT_MSG_NO_PARTS"
assert_not_contains "$whole" "PARCA LISTESI CIKARILAMADI"
# And the signature separator in that blob is still not a part.
assert_contains "$whole" "MIME parcasi         : 0"

it "and says it marks nothing read, naming the command it does not use"
assert_contains "$card" "okundu isaretlemez"
assert_contains "$card" "zmmailbox gm"

it "draws the record of an item that has no blob, and says the path is absent"
fresh
ZRO_MOCK_ZMMETADUMP_274_OUT="$FOLDER_DUMP"
card_folder=$(zro_msg_card "$ACCT" "$ITEM")
assert_contains "$card_folder" "Konu                 : Inbox"
assert_contains "$card_folder" "Blob yolu            : $ZRO_TXT_NONE"
assert_contains "$card_folder" "blob_digest degeri bos"
# And says what an operator who typed a folder's id needs to hear: the record may
# not be a message at all.
assert_contains "$card_folder" "ILETI OLMAMASI"
assert_contains "$card_folder" "Tur (ham)            : 1"
assert_contains "$card_folder" "ILETI GOVDESI GOSTERILMEZ"
answers

it "draws the record when the blob cannot be read, and says which half is missing"
fresh; answers
MISSING_DUMP="$STORE/dump-missing.txt"
sed "s|^/opt/zimbra/store/.*|$BLOB_DIR/999-999.msg|" "$DUMP_SRC" >"$MISSING_DUMP"
ZRO_MOCK_ZMMETADUMP_274_OUT="$MISSING_DUMP"
card_missing=$(zro_msg_card "$ACCT" "$ITEM")
assert_contains "$card_missing" "Ileti id             : 274"
assert_contains "$card_missing" "BLOB DOSYASI OKUNAMADI"
assert_not_contains "$card_missing" "HAM BASLIKLAR"
answers

it "and refuses a blob path the dump reported outside the store root, saying so"
# The path comes from another program's output, so this is the case the admission
# rule exists for. The record is still the screen's answer; what is refused is
# opening a file nobody declared.
fresh; answers
OUTSIDE_DUMP="$STORE/dump-outside.txt"
sed "s|^/opt/zimbra/store/.*|/etc/shadow|" "$DUMP_SRC" >"$OUTSIDE_DUMP"
ZRO_MOCK_ZMMETADUMP_274_OUT="$OUTSIDE_DUMP"
card_outside=$(zro_msg_card "$ACCT" "$ITEM" 2>/dev/null)
assert_contains "$card_outside" "Blob yolu            : /etc/shadow"
assert_contains "$card_outside" "BLOB DOSYASI ACILMADI"
assert_contains "$card_outside" "Tanimli blob koku    : $ZRO_STORE_ROOT"
assert_not_contains "$card_outside" "HAM BASLIKLAR"
answers

it "and a failure of the dump travels out as itself rather than as an empty screen"
fresh; fails "$FIX/zmmetadump_no_such_item.err"
assert_status "$ZRO_E_NO_RESULT" zro_msg_card "$ACCT" "$ITEM"
fresh; fails "$FIX/zmmetadump_not_on_host.err"
assert_status "$ZRO_E_NO_MAILBOX" zro_msg_card "$ACCT" "$ITEM"

rm -rf -- "$STORE"
zro_t_report
