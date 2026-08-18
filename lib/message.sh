# shellcheck shell=bash
# ONE MESSAGE, WITHOUT OPENING IT. The record the database holds about it, and the
# head of the file the message itself is stored in. The body is out of scope here
# and is not read, not parsed and not shown.
[ -n "${ZRO_LIB_MESSAGE_LOADED:-}" ] && return 0
ZRO_LIB_MESSAGE_LOADED=1

# WHY THIS FILE EXISTS AT ALL, in one sentence: the natural command for message
# detail marks the message read, so the question is asked of the two places that
# have no opinion about the unread flag — the mailbox database and the blob on
# disk.
#
# `zmmailbox gm` is NOT on the allowlist and cannot be: `doGetMessage` hard-codes
# `setMarkRead(true)`, unconditionally and with no flag to prevent it, so the read
# that reports the unread flag is the read that clears it. What is here instead is
# the METADATA DUMP — every statement a select, the connection opened without
# auto-commit and never committed — plus a BOUNDED READ of the head of the blob for
# everything the database does not hold.
#
# TWO SOURCES, AND EACH ANSWERS WHAT THE OTHER CANNOT. The dump gives the stored
# record: the folder the message is filed in, the flags, the size, the date, the
# subject as the server indexed it, and the path of the blob. The blob's head gives
# the raw headers, the From, To and Cc addresses, and the MIME structure the
# attachment list is read off. Neither of them is a mailbox session, so this screen
# needs no existence gate: an account whose mailbox was never created has no row in
# this host's database and the dump says so in its own words.
#
# THE THIRD SECTION OF THE DUMP IS NOT SHOWN, and that is the body rule doing its
# work rather than an omission. `[Metadata]` carries Zimbra's decoded item metadata,
# and its `f` key is the message FRAGMENT — the preview text Zimbra cuts out of the
# body. A screen that printed that section would be displaying the body under
# another name, so only the database columns and the blob path are read out of the
# dump at all.
#
# WHAT IS MEASURED AND WHAT IS NOT. Every shape this file parses was captured from
# the lab server on 2026-08-17 and lives under tests/fixtures — the dump of a
# message, the dump of an item that has no blob, the three failure messages, and the
# head of two real blobs. What is deliberately NOT decoded is the `flags` column: it
# is a bitmask whose bit meanings nobody here has measured, so the number is shown as
# the server holds it and the screen says it is undecoded. `unread` is its own column
# and needs no decoding, which is why it is the one state this screen names.
#
# A MESSAGE WITH REVISIONS is not a case this file has seen: the dump prints the
# current item first and each earlier revision after it, so the readers below — which
# take the FIRST value of each column — answer about the current revision, and the
# earlier ones are read by nobody.

# WHERE THE BLOBS ARE. A declared root, production default, overridable so the suite
# can point at a fixture tree — the same rule the binary roots and the log roots live
# by, and required here for a reason of its own: the blob path arrives in the OUTPUT
# of a command rather than from an operator, and the only thing that makes such a
# path safe to open is that it has to sit under a root a reader of this file can see.
#
# REFUSED RATHER THAN SEARCHED FOR when it is absent. There is no second place to
# look and no fallback to the path the dump printed: a host whose store lives
# somewhere else says so in this variable, and a host where it is empty gets a screen
# that says the store root is not declared.
ZRO_STORE_ROOT="${ZRO_STORE_ROOT:-/opt/zimbra/store}"

# HOW MUCH OF A BLOB IS READ. Bounded in BYTES rather than in lines, which is the
# difference between this and the log viewer's bound: a log file is lines, while a
# message is a MIME stream whose base64 part is routinely one line of megabytes. A
# byte bound holds whatever the message turns out to look like.
#
# 64 KiB is generous for a header block — the transfer agent bounds one header line
# at 998 characters and a heavily routed message carries a few dozen of them — and it
# is what decides how deep into the MIME structure the attachment list can see. The
# bound is disclosed on the screen for exactly that reason: past it, an attachment
# nobody listed is an absence nobody claimed.
#
# Overridable like every other bound here, and judged before it is used: this value
# reaches a command line. See zro_msg_bound_ok.
ZRO_MSG_HEAD_BYTES="${ZRO_MSG_HEAD_BYTES:-65536}"

# The dump's three section headers, which are `public` constants in Zimbra's own
# source and asserted by its own integration test — so a parser may rely on them.
# Two are read and the third is named here only so that the reader can tell where
# the columns END.
ZRO_MSG_HDR_COLUMNS='[Database Columns]'
ZRO_MSG_HDR_BLOB='[Blob Path]'

# What the dump prints for a database column that is null. It is the record saying
# the column has no value, which is [unset] and not [unreadable]: the two reach the
# operator as different words because one is a fact about the message and the other
# is a fact about this program.
ZRO_MSG_NULL='<null>'

# The two bytes a gzip stream begins with. The store's VOLUME decides whether blobs
# are compressed — measured on the lab server, whose primary volume reports
# `compressed: false` — so the file is asked what it is rather than assumed to be
# either. Held as a constant because it is a fact about a file format, and compared
# with `=` rather than with a `case` pattern so the comparison stays byte-wise
# whatever the locale.
ZRO_MSG_GZIP_MAGIC=$'\x1f\x8b'

# A DOUBLE QUOTE, WRITTEN AS ITS BYTE, and the reason is a rule about this repository
# rather than about mail. A header parameter's value is quoted — `name="fatura.pdf"` —
# so the reader below has to match one; but tests/test_readonly_scan.sh tracks quote
# state across the WHOLE tree as one stream, and a lone quote written inside single
# quotes here would put that scan out of step for every file after this one, reading
# strings as code and code as strings. So no literal one appears in this file.
ZRO_MSG_DQUOTE=$'\x22'

# ------------------------------------------------------------ reading the dump --
#
# EVERY LINE IS STRIPPED OF A TRAILING CARRIAGE RETURN before it is matched, in this
# file's readers and nowhere else in the program. The dump itself is written with
# plain newlines, but a stored blob is CRLF — measured: the header block of a real
# blob ends with a line holding nothing but a carriage return — and the two are read
# by some of the same functions. One strip costs nothing and is what keeps 'the
# headers end at an empty line' true of the file this program actually opens.

# The value of one database column, exactly as the dump printed it.
#
#   $1  the column name      $2  the dump
#
# Fails when the column is not there, which is a different answer from a column
# holding <null>: the dump's query is `SELECT *`, so which columns exist at all is
# decided by the schema version of the server being asked. A field nobody could read
# reaches the operator as 'bilinmiyor' and a column that is null as 'tanimsiz'.
#
# ONLY THE COLUMN SECTION IS READ. The reader stops at the next section header, so a
# key of the same name inside the metadata section — which is where the message
# FRAGMENT lives — can never answer as a column.
zro_msg_column() {
  local want=${1-} dump=${2-} line inside=1 name
  [ -n "$want" ] || return "$ZRO_E_INPUT"
  while IFS= read -r line; do
    line=${line%$'\r'}
    case $line in
      "$ZRO_MSG_HDR_COLUMNS") inside=0; continue ;;
      '['*']') inside=1; continue ;;
    esac
    [ "$inside" -eq 0 ] || continue
    # The dump writes a column as two spaces, the lowercased name, a colon and a
    # space. A line that is not that shape is not a column — the blank line before
    # the next section among them.
    case $line in '  '*': '*) ;; *) continue ;; esac
    name=${line#'  '}
    name=${name%%: *}
    [ "$name" = "$want" ] || continue
    # The SHORTEST prefix ending in ': ', so a subject that itself carries a colon
    # and a space arrives whole.
    printf '%s' "${line#*': '}"
    return 0
  done <<EOF
$dump
EOF
  return "$ZRO_E_NO_RESULT"
}

# THE THREE ANSWERS A COLUMN CAN GIVE, decided in ONE place — because four fields
# need them and the first version of this file got the fourth one wrong.
#
#   $1  the column name      $2  the dump
#   0   a value follows on stdout, and it is the record's own
#   1   what follows is the WORD an operator reads for the absence it is
#
# A column the schema does not carry is [unreadable], a fact about this program; a
# column holding <null> is [unset], a fact about the record. The two are deliberately
# different words. A field that has to FORMAT what it got — a size, a timestamp —
# cannot go through zro_msg_field, which answers with a word in both cases, so the
# split is made here rather than copied into each of them: the copy that drifted
# reported a null size as a value this program could not read.
zro_msg_raw_or_word() {
  local value
  if ! value=$(zro_msg_column "${1-}" "${2-}"); then
    printf '%s' "$ZRO_TXT_UNKNOWN"
    return 1
  fi
  if [ "$value" = "$ZRO_MSG_NULL" ]; then
    printf '%s' "$ZRO_TXT_UNSET"
    return 1
  fi
  printf '%s' "$value"
  return 0
}

# One column as a field on the screen: the value, or the word for the absence it is.
# Both are already printed by the reader above; this only normalises the status, for
# a caller that draws the answer either way.
zro_msg_field() {
  zro_msg_raw_or_word "${1-}" "${2-}" || return 0
  return 0
}

# THE EPOCH SECONDS OUT OF A TIMESTAMP COLUMN, and nothing that merely looks like
# one.
#
# The dump prints `date` and `change_date` as `<epoch> (<formatted>)`, where the
# formatted half is built in the JVM's DEFAULT TIMEZONE — the server's, whatever that
# is — and in Java's own field order. This program takes the number and formats it
# itself, for the reason the mailbox size is asked for as a raw byte count: a value
# rendered by somebody else's locale is a value this program cannot check.
zro_msg_epoch() {
  local raw=${1-} first
  first=${raw%% *}
  case $first in
    ''|*[!0-9]*) return "$ZRO_E_NO_RESULT" ;;
  esac
  printf '%s' "$first"
}

# A timestamp column as an operator reads it: local wall clock, then the count it
# was derived from, so the two can be checked against each other and against a log
# line.
zro_msg_when() {
  local raw when secs
  raw=$(zro_msg_raw_or_word "${1-}" "${2-}") || { printf '%s' "$raw"; return 0; }
  secs=$(zro_msg_epoch "$raw") || { printf '%s' "$ZRO_TXT_UNKNOWN"; return 0; }
  when=$(zro_clock_fmt '%Y-%m-%d %H:%M:%S' "$secs") || { printf '%s' "$ZRO_TXT_UNKNOWN"; return 0; }
  printf '%s (%s)' "$when" "$secs"
}

# THE BLOB PATH THE DUMP COMPUTED, or a refusal when the dump printed none.
#
# The section is absent whenever the item has no blob digest — every folder, tag and
# contact, and a message whose blob the store lost — so its absence is an answer
# about the record rather than a failure, and the screen says which.
#
# The path is taken as the first non-empty line after the header and is NOT trusted
# for being there: it is admitted below, against a character set and against the
# declared store root, before anything opens it.
zro_msg_blob_path() {
  local dump=${1-} line found=1
  while IFS= read -r line; do
    line=${line%$'\r'}
    if [ "$found" -eq 0 ]; then
      [ -n "$line" ] || continue
      printf '%s' "$line"
      return 0
    fi
    [ "$line" = "$ZRO_MSG_HDR_BLOB" ] && found=0
  done <<EOF
$dump
EOF
  return "$ZRO_E_NO_RESULT"
}

# ------------------------------------------------------- admitting a blob path --

# The character set a blob path must match before it may be opened, and the root it
# must sit under. Pure: a path in, a verdict out, nothing logged and nothing read.
#
# THE PATH COMES FROM A PROGRAM'S OUTPUT, NEVER FROM AN OPERATOR, and that is
# precisely why it is judged. Nothing an operator types reaches this argument — the
# item id does, and it is digits — but the value that arrives here was printed by
# another program, computed from a volume path and a database column, and this
# function is the only thing between it and a file this tool opens. The log inventory
# admits its paths against the same character set for the same underlying reason; the
# rule is written out here rather than borrowed because half of it is about a root
# the log inventory has no notion of.
#
# UNDER THE DECLARED STORE ROOT AND NOWHERE ELSE. A dump that answered with a path
# outside it — a volume this program does not know about, or an answer nobody
# expected — is refused rather than followed: the operator is told which path was
# refused, which is visible, where opening it would not be.
zro_msg_blob_ok() {
  local p=${1-} root=$ZRO_STORE_ROOT
  [ -n "$p" ] || return 1
  [ -n "$root" ] || return 1
  # A TRAILING SLASH IN THE OVERRIDE IS NOT A DIFFERENT ROOT. `/opt/zimbra/store/` is
  # what a human writes half the time, and comparing it literally would refuse every
  # blob on the host — a refusal in the safe direction and an incomprehensible one.
  # Stripped here rather than at the declaration, because the declaration is a default
  # an operator overrides after this file has been read.
  while [ "${#root}" -gt 1 ] && [ "${root%/}" != "$root" ]; do
    root=${root%/}
  done
  [ "${#p}" -le 4096 ] || return 1
  case $p in
    /*) ;;
    *) return 1 ;;
  esac
  case $p in
    *[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  # A parent-directory component would let the root reach outside itself, which is
  # the dump deciding which files this program opens instead of the declaration.
  case $p in
    ..|../*|*/..|*/../*) return 1 ;;
  esac
  # Quoted, so the root is compared as the literal text it is: a root carrying a
  # glob character cannot widen into one that admits its neighbours.
  case $p in
    "$root"/?*) ;;
    *) return 1 ;;
  esac
  return 0
}

# Admission, refusing out loud — the shape lib/inventory.sh gives its own paths, and
# for the same reason: a rule whose refusal nobody logs is a path that vanishes
# without a word. The predicate above stays pure so the suite can drive it over a
# table of paths without a log line per case.
zro_msg_admit_blob() {
  local p=${1-}
  zro_msg_blob_ok "$p" && return 0
  if [ -z "$ZRO_STORE_ROOT" ]; then
    zro_log error "denied, no store root is declared (ZRO_STORE_ROOT is empty): $p"
    return 1
  fi
  zro_log error "denied, blob path outside the permitted set or the store root: $p"
  return 1
}

# ------------------------------------------------------------------ the reads --

# What the dump fails with, captured verbatim from the lab server on 2026-08-17:
#
#   invalid request: No such item: mbox=9, item=999999
#   invalid request: Account ahmet.yilmaz@example.com not found on this host
#   Usage: zmmetadump -m <mailbox id/email> -i <item id> [--dumpster]
#
# CLASSIFIED ON THE MESSAGE, NEVER ON THE STATUS, for the reason the existence gate
# gives about its own two sentences: every failure of this command exits 1 — the
# usage banner included — so the status cannot tell a message that is not there from
# a database that is not answering. Each of the three arrives on STDERR with stdout
# empty, and a successful dump arrives on stdout with stderr empty; both were
# measured with the streams kept apart.
ZRO_MSG_TXT_NO_ITEM='No such item'
ZRO_MSG_TXT_NOT_HERE='not found on this host'
ZRO_MSG_TXT_USAGE='Usage: zmmetadump'

# ONE SENTENCE COVERS TWO ANSWERS, AND IT IS REPORTED AS THE WEAKER OF THEM. The
# dump says `not found on this host` both for an address the directory never heard
# of and for an account whose mailbox has never been created — measured, on the lab
# server's account that deliberately has none. It reads the `mailbox` table and
# nothing else, so it cannot tell those apart, and this program may not invent the
# difference: the code is the no-mailbox one and the screen says in as many words
# that either cause produces it.
zro_msg_fail_code() {
  local errfile=${1-}
  # A GATE CODE NEVER ARRIVES HERE. zro_settle asks zro_exec_own_code before it calls
  # this, and returns what the gate returned, so everything below is a failure of a
  # command that actually ran. The timeout used to be re-stated at the top of this
  # function for exactly that reason and is not any more: one place decides which
  # codes are the gate's, and it is not this one.
  if grep -qF -- "$ZRO_MSG_TXT_NO_ITEM" "$errfile" 2>/dev/null; then
    printf '%s' "$ZRO_E_NO_RESULT"
    return 0
  fi
  if grep -qF -- "$ZRO_MSG_TXT_NOT_HERE" "$errfile" 2>/dev/null; then
    printf '%s' "$ZRO_E_NO_MAILBOX"
    return 0
  fi
  # The usage banner means this program built a vector the binary would not take,
  # which is a defect in this file rather than something the operator did. Logged
  # where it is recognised, because the screen above reports input errors in terms
  # of what an operator typed and nobody typed this.
  if grep -qF -- "$ZRO_MSG_TXT_USAGE" "$errfile" 2>/dev/null; then
    zro_log error "message defect, the metadata dump answered with its usage banner"
    printf '%s' "$ZRO_E_INPUT"
    return 0
  fi
  # THE SHARED ZIMBRA-ERROR READER IS DELIBERATELY NOT CONSULTED HERE, and that is a
  # decision rather than an omission. Every pattern it matches belongs to the SOAP
  # path — `zclient.IO_ERROR`, `SERVICE_UNAVAILABLE`, an expired admin certificate —
  # and this command takes no such path: measured, its failure text is a `DbPool`
  # exception carrying a JDBC URL. Reading it through that mapper would answer a
  # database problem with the screen that names mailboxd and `zmcertmgr`, sending the
  # operator to repair something that is not broken.
  #
  # So anything this function does not recognise is reported as the service this
  # command really needs being unreachable, and the screen for it names the database.
  # That is now only ever true of a command that RAN — which is what makes it safe to
  # say, and what it could not say while a denial reached this line.
  printf '%s' "$ZRO_E_UNAVAILABLE"
}

# THE STORED RECORD OF ONE MESSAGE. One invocation.
#
#   $1  the account          $2  an item id, as the search table prints it
#
# THE ACCOUNT IS PASSED AS ITS ADDRESS, NEVER AS A MAILBOX ID, and that is a
# correctness decision rather than a convenience. Given a numeric id the dump SKIPS
# the lookup that decides whether the mailbox is on this host, and a wrong id then
# falls through to a query against a table that does not exist — answering
# `No such item`, which this program would report as a message that is not there.
# With the address, a mailbox this host does not carry says so in its own words.
#
# The subcommand position carries the flag that IS the operation, and the item id
# rides behind it as data — validated as digits here, which is also what keeps the
# negation of an id, the one Zimbra names a single-message conversation with, off a
# command line.
zro_msg_dump_fetch() {
  local acct=${1-} id=${2-} err out rc=0
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"
  zro_validate_item_id "$id" || return "$ZRO_E_INPUT"
  err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"

  out=$(zro_exec zmmetadump -m "$acct" -i "$id" 2>"$err") || rc=$?

  # THE EXPLANATION IS ON THE STREAM THAT NORMALLY CARRIES THE ANSWER, and that was
  # measured rather than assumed. With the database stopped, this binary writes
  # `Could not establish a connection to the database.  Retrying in 5 seconds.` and a
  # `DbPool` stack trace to STDOUT — 7828 bytes of it in the 22 seconds it was given,
  # one retry every five — and leaves STDERR completely EMPTY. Every other failure it
  # has is the other way round.
  #
  # So a failure that said nothing on stderr borrows the head of stdout. Without this
  # the one screen that has something useful to show — the timeout, on the one command
  # in this tool that would otherwise hang forever — would have nothing to show.
  if [ "$rc" -ne 0 ] && [ ! -s "$err" ] && [ -n "$out" ]; then
    printf '%.*s\n' "$ZRO_ERROR_KEEP_BYTES" "$out" >"$err"
  fi

  rc=$(zro_settle "$err" "$rc" zro_msg_fail_code)
  [ "$rc" -eq 0 ] || return "$rc"

  # A dump that answered always prints its column section. Output without one is not
  # a dump at all, and it is refused rather than drawn as a record with every field
  # unreadable — which would report a fact about this program as a fact about the
  # message.
  case $out in
    *"$ZRO_MSG_HDR_COLUMNS"*) ;;
    *) zro_log error "message defect, the dump carried no column section: $(printf '%.120s' "$out")"
       return "$ZRO_E_NO_RESULT" ;;
  esac
  printf '%s\n' "$out"
}

# THE BOUND, JUDGED BEFORE IT IS USED, because it reaches a command line.
#
# The rule lib/logview.sh and lib/search.sh state for their own bounds: a leading
# dash arriving where a count belongs is an allowlist denial, and an allowlist denial
# in this program means a defect rather than an operator's mistake. A bound that is
# not a count is a defect in whatever set it, never a reason to fall back to a
# default nobody chose.
zro_msg_bound_ok() {
  local n=$ZRO_MSG_HEAD_BYTES
  case $n in
    ''|*[!0-9]*) zro_log error "denied, blob head bound is not a count: $n"
                 return "$ZRO_E_INPUT" ;;
  esac
  if [ "$n" -eq 0 ]; then
    zro_log error "denied, blob head bound is zero"
    return "$ZRO_E_INPUT"
  fi
  return 0
}

# WHETHER THIS BLOB IS COMPRESSED, ASKED OF THE FILE ITSELF.
#
# One gated read of two bytes. The alternative — running `gzip -dc` and reading the
# failure — was measured and refused: on an uncompressed blob it answers
# `not in gzip format`, which is a failure this program would have to tell apart
# from a blob it really cannot read, and the operator would pay a wasted invocation
# for the ambiguity. Two bytes cannot carry a NUL for either answer, so the value
# survives command substitution intact.
zro_msg_blob_compressed() {
  local path=${1-} magic
  magic=$(zro_exec head -c 2 "$path" 2>/dev/null) || return 1
  [ "$magic" = "$ZRO_MSG_GZIP_MAGIC" ]
}

# THE HEAD OF ONE BLOB, BOUNDED, WITHOUT WRITING ANYTHING.
#
#   $1      a path the dump printed and zro_msg_admit_blob admitted
#   stdout  the first $ZRO_MSG_HEAD_BYTES bytes of the message as stored
#
# A COMPRESSED BLOB IS READ THROUGH `gzip -dc` AND NOTHING ELSE. That is the one
# form which writes to stdout and leaves the file where it was; the bare command and
# the in-place decompression both replace the file and delete the original, and both
# are absent from the allowlist and therefore refused.
#
# WHAT DECIDES IS THE ANSWER, NOT THE STATUS, and that is a portability fix rather
# than a shortcut. A bounded reader that has had its fill closes the pipe on the
# decompression, and HOW THAT ARRIVES DEPENDS ON THE gzip BUILD: measured on three
# hosts, the lab server and WSL report the SIGPIPE as 141, while the CI runner's gzip
# catches it, prints `gzip: stdout: Broken pipe` and exits non-zero with a different
# code. Normalising 141 alone would leave every compressed blob larger than the bound
# reading as unreadable on the third kind of host — which is exactly what happened,
# and what a suite that only ran on the first two would never have shown.
#
# A DECOMPRESSION THAT REALLY FAILED YIELDS NOTHING AT ALL: a file that is not a gzip
# stream produces no bytes, and that case stays a failure. So a non-empty head is
# taken as the answer it is, and pipefail is still set — without it the empty-head
# failure would arrive as success, which is the one answer this function may not
# invent. A complaint alongside a non-empty head is logged rather than raised: what
# was read is bounded and disclosed either way.
zro_msg_head_fetch() {
  local path=${1-} err out rc=0 said n=$ZRO_MSG_HEAD_BYTES
  zro_msg_bound_ok || return "$ZRO_E_INPUT"
  zro_msg_admit_blob "$path" || return "$ZRO_E_DENIED"
  err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"

  if zro_msg_blob_compressed "$path"; then
    out=$( set -o pipefail
           zro_exec gzip -dc "$path" 2>"$err" | zro_exec head -c "$n" 2>>"$err" ) || rc=$?
    if [ "$rc" -ne 0 ] && [ -n "$out" ]; then
      zro_log warn "the decompression complained after the bound was filled: $path (rc $rc)"
      rc=0
    fi
  else
    out=$(zro_exec head -c "$n" "$path" 2>"$err") || rc=$?
  fi
  said=$(head -c "$ZRO_ERROR_KEEP_BYTES" -- "$err" 2>/dev/null)
  rm -f -- "$err"
  # A GATE REFUSAL IS PASSED THROUGH RATHER THAN FLATTENED, and everything else
  # becomes the one documented code for a stored file that could not be read. A
  # binary this host does not have, an unsupported user, an expired clock: none of
  # those is a blob that cannot be read, and an operator sent to check the store
  # over a missing `head` would repair nothing. What must not happen either is
  # `gzip`'s own exit status leaving this module: a file that is not a gzip stream
  # answers 1, which is not a code this program defines, and a caller switching on
  # it would be reading a number nobody documented.
  #
  # ASKED OF THE GATE rather than listed here. The list this replaces carried
  # ZRO_E_INPUT, which zro_exec never returns — it converts zro_bin_path's and
  # zro_identity_mode's before they leave — so it was passing through a code that
  # could not arrive, which is what a list nobody could check against its source
  # drifts into. The two early returns above are this function's own and are made
  # before anything runs.
  if [ "$rc" -ne 0 ]; then
    [ -z "$said" ] || zro_set_error "$said"
    zro_exec_own_code "$rc" && return "$rc"
    zro_log warn "blob unreadable: $path (${said:-no message on stderr})"
    return "$ZRO_E_NO_BLOB"
  fi
  zro_clear_error
  # An empty blob is not a message. It is reported as no result rather than drawn as
  # a message with no headers, which would say the message carries none.
  [ -n "$out" ] || return "$ZRO_E_NO_RESULT"
  printf '%s\n' "$out"
}

# ------------------------------------------------------- reading a blob's head --

# THE HEADER BLOCK, as the file holds it: every line up to the first empty one.
#
#   stdin   the blob head
#   stdout  the header lines, carriage returns stripped and nothing else touched
#
# Nothing is reordered, unfolded or rewritten: this is the answer to 'what does the
# message actually say about itself', and a header block a program tidied is a header
# block an operator cannot compare against the one in their hand. The single
# carriage return per line is taken off because the file is CRLF and a terminal is
# not.
zro_msg_header_block() {
  local line
  while IFS= read -r line; do
    line=${line%$'\r'}
    [ -n "$line" ] || return 0
    printf '%s\n' "$line"
  done
}

# Whether the head really reached the end of the header block. A bounded read that
# stopped inside the headers is a header block with more to it, and the screen says
# so rather than presenting what it got as the whole of them.
zro_msg_headers_complete() {
  local line
  while IFS= read -r line; do
    line=${line%$'\r'}
    [ -n "$line" ] || return 0
  done
  return 1
}

# ONE HEADER'S VALUE, UNFOLDED.
#
#   $1  the header name, matched case-insensitively   $2  a header block
#
# A header name is case-insensitive by the grammar's own rule, and the two message
# ids in this program's fixtures are written `Message-Id` and `Message-ID` by two
# different programs — so matching case-sensitively would answer 'this message has
# no id' about half the mail on a server.
#
# THE FIRST OCCURRENCE ANSWERS. A header block carries several `Received` lines and
# may carry more than one of anything; the first is the one the message was sent
# with, and a screen showing a field twice under one label answers a question nobody
# asked.
#
# A CONTINUATION LINE BELONGS TO THE HEADER ABOVE IT — the grammar says so: a line
# beginning with a space or a tab continues the value rather than starting a new
# field. They are joined with a single space, which is what the value means; the raw
# block above still shows them as they were written.
zro_msg_header() {
  local want=${1-} block=${2-} line value='' found=1 name
  [ -n "$want" ] || return "$ZRO_E_INPUT"
  while IFS= read -r line; do
    line=${line%$'\r'}
    case $line in
      ' '*|"$ZRO_TAB"*)
        if [ "$found" -eq 0 ]; then
          # Leading whitespace of a continuation is the folding, not the value.
          line=${line#"${line%%[![:space:]]*}"}
          value="$value $line"
        fi
        continue ;;
    esac
    [ "$found" -eq 0 ] && break
    case $line in *': '*|*':') ;; *) continue ;; esac
    name=${line%%:*}
    [ "${name,,}" = "${want,,}" ] || continue
    found=0
    value=${line#*:}
    value=${value# }
  done <<EOF
$block
EOF
  [ "$found" -eq 0 ] || return "$ZRO_E_NO_RESULT"
  printf '%s' "$value"
}

# One header as a field on the screen, or the word for the absence it is. A header
# the message does not carry is a fact about the message: mail with no Cc is
# ordinary, and 'yok' says that where 'bilinmiyor' would blame this program.
zro_msg_header_field() {
  local value
  value=$(zro_msg_header "${1-}" "${2-}") || { printf '%s' "$ZRO_TXT_NONE"; return 0; }
  [ -n "$value" ] || { printf '%s' "$ZRO_TXT_NONE"; return 0; }
  printf '%s' "$value"
}

# THE MIME PARTS VISIBLE IN THE HEAD, as rows this program can act on:
#
#   stdin   the blob head
#   stdout  "<content type>\t<disposition>\t<file name>", one part per line
#
# A part begins after a boundary line and its own header block follows, which is the
# whole of the rule applied here — and the reason a row is only emitted when that
# block really carries a MIME header. A plain-text signature is introduced by a line
# reading `--`, so a reader that trusted every line beginning with two dashes would
# report a signature as an attachment; what follows one of those is prose, it carries
# no Content-Type and no file name, and it is dropped for saying nothing.
#
# NESTED PARTS ARE LISTED TOO, and their boundaries are not told apart from the outer
# one. That is deliberate: what an operator wants to know is what the message
# carries, not which multipart it is nested in, and a reader that followed only the
# top-level boundary would miss the attachment of a message whose text and
# attachment sit inside an alternative part.
#
# NOTHING FROM A PART'S BODY IS READ. The rows carry what the part says about
# itself, and the bytes between the header block and the next boundary are skipped
# without being looked at — which is the body rule, applied where it would be easiest
# to break.
#
# THE ONE WAY THIS OVER-LISTS is stated rather than left to be discovered: a body that
# quotes a message — a forwarded mail pasted inline, after a line of dashes — carries
# lines that really are MIME headers, and a row appears for them. It errs towards
# listing something that is there rather than towards claiming an attachment is
# absent, which is the direction this screen has to fail in.
zro_msg_part_rows() {
  local line state=top block=''
  while IFS= read -r line; do
    line=${line%$'\r'}
    case $state in
      top)
        # The message's own header block. It ends at the first empty line, and
        # everything after it is the entity's body.
        [ -n "$line" ] || state=body
        continue ;;
      body)
        case $line in
          --*) state=part; block='' ;;
        esac
        continue ;;
      part)
        case $line in
          '')
            zro_msg_part_row "$block"
            state=body
            continue ;;
          --*)
            # A boundary where a part's header block was still open: an empty part,
            # or the closing boundary. What was collected is still a part.
            zro_msg_part_row "$block"
            block=''
            continue ;;
        esac
        block="$block$line
"
        continue ;;
    esac
  done
  # A head bounded in the middle of a part's headers still says what that part is.
  [ "$state" = part ] && zro_msg_part_row "$block"
  return 0
}

# One part's header block as a row, or nothing when the block says nothing about
# itself.
zro_msg_part_row() {
  local block=${1-} type disposition name
  [ -n "$block" ] || return 0
  type=$(zro_msg_header 'Content-Type' "$block") || type=''
  disposition=$(zro_msg_header 'Content-Disposition' "$block") || disposition=''
  name=$(zro_msg_param name "$type")
  [ -n "$name" ] || name=$(zro_msg_param filename "$disposition")
  # The type without its parameters is what the row shows; the file name has already
  # been taken out of them.
  type=${type%%;*}
  type=${type%"${type##*[![:space:]]}"}
  disposition=${disposition%%;*}
  disposition=${disposition%"${disposition##*[![:space:]]}"}
  [ -n "$type" ] || [ -n "$name" ] || return 0
  printf '%s\t%s\t%s\n' "$type" "$disposition" "$name"
}

# A parameter of a header value: `name="fatura.pdf"` out of a Content-Type, or
# `filename=...` out of a Content-Disposition. Prints nothing when the value carries
# no such parameter.
#
# THE QUOTED FORM AND THE BARE ONE, because both are written by real mail agents. A
# value continuing to the next parameter is cut at the semicolon, and a quoted one at
# its closing quote. The encoded form RFC 2231 defines — `name*=utf-8''...` — is NOT
# decoded and is left as it stands: a file name shown as the header wrote it is a
# fact, and a decoder nobody measured would be a guess in the one field an operator
# reads to recognise an attachment.
zro_msg_param() {
  local want=${1-} value=${2-} rest
  [ -n "$want" ] || return 0
  case $value in
    *"$want="*) ;;
    *) return 0 ;;
  esac
  rest=${value#*"$want="}
  case $rest in
    "$ZRO_MSG_DQUOTE"*)
      rest=${rest#"$ZRO_MSG_DQUOTE"}
      rest=${rest%%"$ZRO_MSG_DQUOTE"*} ;;
    *)
      rest=${rest%%;*}
      rest=${rest%"${rest##*[![:space:]]}"} ;;
  esac
  printf '%s' "$rest"
}

# The fields of a part row, for a caller that wants one of them. The rows above are
# positional, and a screen stepping over the fields it does not want would be a
# second reader of this format.
zro_msg_row_type() {
  local row=${1-}
  printf '%s' "${row%%"$ZRO_TAB"*}"
}

zro_msg_row_disposition() {
  local row=${1-} rest
  rest=${row#*"$ZRO_TAB"}
  printf '%s' "${rest%%"$ZRO_TAB"*}"
}

zro_msg_row_name() {
  local row=${1-}
  printf '%s' "${row##*"$ZRO_TAB"}"
}

# Whether a part is one an operator would call an attachment: it has a file name, or
# the message itself says it is one. Asked of the row rather than decided while
# parsing, so the table can show every part and still count the attachments.
zro_msg_row_attachment() {
  local row=${1-}
  [ -n "$(zro_msg_row_name "$row")" ] && return 0
  case $(zro_msg_row_disposition "$row") in
    attachment|Attachment|ATTACHMENT) return 0 ;;
  esac
  return 1
}

# --------------------------------------------------- what an operator reads --

ZRO_TXT_MSG_NO_BLOB='Bu kaydin blob yolu yok: veritabanindaki blob_digest degeri bos. Dokum bu bolumu
yalnizca kaydin bir blob dosyasi varsa yazar.

Bu, kaydin ILETI OLMAMASI anlamina da gelebilir: klasorler, etiketler ve kisiler de
birer kayittir ve blob dosyalari yoktur. Yukaridaki Tur (ham) alani Zimbranin kendi
oge turudur; bu arac onu cozmez.'
ZRO_TXT_MSG_NO_PARTS='Bu ileti tek parcali: MIME parcasi yok, dolayisiyla ek listesi de yok.'

# SAID INSTEAD OF THE LINE ABOVE when the bound cut the header block short. The two
# may never be confused: one is an answer about the message, the other is the absence
# of an answer — and the first one, said about a head that stopped inside the
# headers, would be this screen claiming a message has no attachment on the strength
# of bytes it never read.
ZRO_TXT_MSG_PARTS_UNKNOWN='PARCA LISTESI CIKARILAMADI: okunan bolum baslik icinde bitti, yani MIME yapisina
hic ulasilamadi. Bu, iletinin eki YOKTUR demek DEGILDIR — ek olup olmadigi bu
sinirin icinden anlasilamaz. ZRO_MSG_HEAD_BYTES degerini yukseltip yeniden
deneyebilirsiniz.'

# Said wherever this screen mentions what it did not do. One constant, because three
# paragraphs would be three chances to promise something slightly different.
ZRO_TXT_MSG_NO_BODY='ILETI GOVDESI GOSTERILMEZ. Bu ekran veritabani kaydini ve blob dosyasinin
BASLIK bolumunu okur; govde okunmaz, ayristirilmaz ve yazdirilmaz. Dokumun
[Metadata] bolumu de gosterilmez: o bolum Zimbranin govdeden cikardigi onizleme
metnini (fragment) tasir.'

# DOUBLE-QUOTED ON PURPOSE, like every other message in this program that names a
# Zimbra command: the static scanner strips double-quoted spans and reads what is
# left as code, so a single-quoted string naming the mailbox binary would read as a
# second path to a binary that provisions. There is nothing here for the shell to
# expand.
ZRO_TXT_MSG_READONLY="Bu ekran hicbir iletiyi okundu isaretlemez. Ileti detayini tek komutta veren
Zimbra komutu (zmmailbox gm) okundu bayragini KOSULSUZ temizler ve bu araca
alinmadi; bunun yerine kayit dogrudan veritabanindan, baslangic bolumu ise blob
dosyasindan okunur."

# THE STORED RECORD. Every field is read out of the dump's column section, and a
# column the schema does not carry reads as unreadable rather than as empty.
zro_msg_record_body() {
  local acct=${1-} id=${2-} dump=${3-}

  zro_card_line 'Hesap' "$acct"
  zro_card_line 'Ileti id' "$id"
  zro_card_line 'Mailbox id' "$(zro_msg_field mailbox_id "$dump")"
  zro_card_line 'Tur (ham)' "$(zro_msg_field type "$dump")"
  # AN ID RATHER THAN A PATH, because that is what the database holds: resolving the
  # name would mean a folder listing, which is a mailbox read behind the existence
  # gate — and this screen opens no session. The listing prints the same id in its own
  # first column, so the operator is pointed at where the two sit side by side.
  zro_card_line 'Klasor id' "$(zro_msg_field folder_id "$dump") (yol: Klasorler ekrani)"
  # WHAT THIS COLUMN IS DEPENDS ON WHAT THE ITEM IS: a message's parent is its
  # conversation and a folder's is the folder above it. The label says both rather
  # than decoding the type column to choose one, because the type numbers are not
  # something this tool has measured either.
  zro_card_line 'Ust kayit / konusma' "$(zro_msg_field parent_id "$dump")"
  zro_card_line 'Konu' "$(zro_msg_field subject "$dump")"
  zro_card_line 'Gonderen (kayit)' "$(zro_msg_field sender "$dump")"
  zro_card_line 'Alicilar (kayit)' "$(zro_msg_field recipients "$dump")"
  zro_card_line 'Tarih' "$(zro_msg_when date "$dump")"
  zro_card_line 'Kayit degisimi' "$(zro_msg_when change_date "$dump")"
  zro_card_line 'Boyut' "$(zro_msg_size_field "$dump")"
  zro_card_line 'Okunmamis' "$(zro_msg_unread_field "$dump")"
  zro_card_line 'Bayraklar (ham)' "$(zro_msg_field flags "$dump")"
  zro_card_line 'Etiketler (ham)' "$(zro_msg_field tags "$dump")"
  zro_card_line 'Etiket adlari' "$(zro_msg_field tag_names "$dump")"
  zro_card_line 'Blob ozeti' "$(zro_msg_field blob_digest "$dump")"
}

# The size column in both forms, through the reader that owns the rule: a size is
# shown as bytes and as something readable, always. A column this program could not
# read says so rather than becoming a zero.
zro_msg_size_field() {
  local raw
  raw=$(zro_msg_raw_or_word size "${1-}") || { printf '%s' "$raw"; return 0; }
  # A size that is not a count is refused rather than read, for the reason the
  # mailbox size lives by one module over: the digits out of a locale-formatted
  # string would be a number wrong by a factor nobody can see.
  case $raw in
    ''|*[!0-9]*) printf '%s' "$ZRO_TXT_UNKNOWN"; return 0 ;;
  esac
  zro_store_size_field "$raw"
}

# THE ONE STATE THIS SCREEN NAMES. `unread` is a column of its own and needs no
# decoding, unlike `flags`, whose bit meanings nobody here has measured.
#
# ON AN ITEM THAT IS NOT A MESSAGE IT IS A COUNT, and that is measured rather than
# guessed: the dump of the Inbox folder on the lab server answers `unread: 14`, which
# is the number of unread items in it. So a value that is neither 0 nor 1 is shown as
# the number it is. Reporting it as unreadable would be this program claiming it
# could not read a value it read perfectly well.
zro_msg_unread_field() {
  local raw
  raw=$(zro_msg_raw_or_word unread "${1-}") || { printf '%s' "$raw"; return 0; }
  case $raw in
    0) printf 'hayir (okunmus)' ;;
    1) printf 'evet' ;;
    ''|*[!0-9]*) printf '%s' "$ZRO_TXT_UNKNOWN" ;;
    *) printf '%s (ileti degil: bu kayitta okunmamis oge sayisi)' "$raw" ;;
  esac
}

# WHAT THE BLOB SAID ABOUT ITSELF: the addresses, the parts, and the raw headers.
#
#   $1  the head as it was read
#   $2  0 when the head reached the end of the header block, anything else when the
#       bound cut it short
#
# THE ONE POSITIVE CLAIM ON THIS SCREEN IS MADE ONLY WHEN IT CAN BE. 'This message
# has no parts, so it has no attachments' is an answer; said about a head the bound
# cut off inside the headers it is a guess, and the screen would then contradict
# itself ten lines later where the bound is disclosed. Nothing was read past the
# bound, so nothing is claimed about it.
zro_msg_blob_body() {
  local head=${1-} complete=${2-0} block rows count=0 attachments=0 line body=''

  block=$(zro_msg_header_block <<EOF
$head
EOF
)
  printf '\n'
  zro_card_line 'From' "$(zro_msg_header_field From "$block")"
  zro_card_line 'To' "$(zro_msg_header_field To "$block")"
  zro_card_line 'Cc' "$(zro_msg_header_field Cc "$block")"
  zro_card_line 'Subject (baslik)' "$(zro_msg_header_field Subject "$block")"
  zro_card_line 'Date (baslik)' "$(zro_msg_header_field Date "$block")"
  zro_card_line 'Message-ID' "$(zro_msg_header_field Message-ID "$block")"

  rows=$(zro_msg_part_rows <<EOF
$head
EOF
)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    count=$((count + 1))
    zro_msg_row_attachment "$line" && attachments=$((attachments + 1))
    body="$body$(printf '%-28s  %-11s %s' \
      "$(zro_msg_row_type "$line")" \
      "$(zro_msg_row_disposition "$line")" \
      "$(zro_msg_row_name "$line")")
"
  done <<EOF
$rows
EOF

  zro_card_line 'MIME parcasi' "$count"
  zro_card_line 'Ek sayisi' "$attachments"

  printf '\n'
  if [ "$count" -eq 0 ] && [ "$complete" -ne 0 ]; then
    printf '%s\n' "$ZRO_TXT_MSG_PARTS_UNKNOWN"
  elif [ "$count" -eq 0 ]; then
    printf '%s\n' "$ZRO_TXT_MSG_NO_PARTS"
  else
    printf '%-28s  %-11s %s\n' 'Tur' 'Yerlesim' 'Dosya adi'
    printf '%s' "$body"
  fi

  printf '\n'
  printf 'HAM BASLIKLAR\n'
  printf -- '--------------------------------------------------------------------\n'
  # Unmodified, on purpose: what follows is what the file says.
  printf '%s\n' "$block"
}

# ONE MESSAGE, AS TWO READS AND ONE SCREEN.
#
#   $1  the account      $2  an item id
#
# The record comes first and the blob after it, and the order is what makes the
# screen drawable at all: the blob path is in the record, and a record that answered
# is worth showing whether or not the file it points at could be opened.
#
# A BLOB THIS PROGRAM WOULD NOT OPEN IS SAID ON THE SCREEN, not swallowed. A path
# outside the declared store root or outside the admitted character set is refused,
# and the refusal names the path — an operator reading 'the headers are not here'
# with no reason given would take it for a message that has none.
zro_msg_card() {
  local acct=${1-} id=${2-} dump path head rc=0 complete=1
  zro_reset_mode
  dump=$(zro_msg_dump_fetch "$acct" "$id") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  zro_msg_record_body "$acct" "$id" "$dump"

  if ! path=$(zro_msg_blob_path "$dump"); then
    zro_card_line 'Blob yolu' "$ZRO_TXT_NONE"
    printf '\n%s\n' "$ZRO_TXT_MSG_NO_BLOB"
    zro_msg_footer
    return 0
  fi
  zro_card_line 'Blob yolu' "$path"

  if ! zro_msg_admit_blob "$path"; then
    printf '\n'
    printf 'BLOB DOSYASI ACILMADI. Dokumun bildirdigi yol bu aracin okumayi kabul\n'
    printf 'ettigi bicimde degil: yol mutlak olmali, yalnizca [A-Za-z0-9._/-]\n'
    printf 'karakterlerini icermeli ve tanimli blob kokunun altinda kalmali.\n'
    printf '\n'
    zro_card_line 'Tanimli blob koku' "${ZRO_STORE_ROOT:-$ZRO_TXT_UNSET}"
    printf '\n'
    printf 'Kayit yukarida oldugu gibi gecerlidir; eksik olan yalnizca baslik\n'
    printf 'bolumudur. Kontrol edin: ZRO_STORE_ROOT ayari ve sunucudaki volume yolu.\n'
    zro_msg_footer
    return 0
  fi

  rc=0
  head=$(zro_msg_head_fetch "$path") || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '\n'
    printf '%s\n' "$(zro_msg_unreadable_text "$rc")"
    zro_msg_footer
    return 0
  fi

  zro_msg_headers_complete <<EOF
$head
EOF
  complete=$?

  zro_msg_blob_body "$head" "$complete"

  printf '\n'
  printf 'Blob dosyasinin ilk %s bayti okundu (dosyanin TAMAMI DEGILDIR).\n' "$ZRO_MSG_HEAD_BYTES"
  if [ "$complete" -ne 0 ]; then
    printf 'BASLIK BOLUMU BU SINIRIN ICINDE BITMEDI: yukarida gorunen basliklar\n'
    printf 'iletinin basliklarinin TAMAMI DEGILDIR.\n'
  else
    printf 'Baslik bolumu bu sinirin icinde bitti. Parca listesi yine yalnizca bu\n'
    printf 'siniri kapsar: daha derindeki bir ek listelenmemis olabilir.\n'
  fi
  # SAID WHETHER OR NOT THIS FILE WAS COMPRESSED, and that is a decision rather than
  # sloppiness: asking the file a second time would be an invocation spent on a
  # sentence, and what an operator needs to know is how this screen reads a blob at
  # all. Double-quoted on purpose, so the static scanner reads it as the data it is.
  printf "\nSikistirilmis bir blob gzip -dc ile STDOUTa acilir: dosya yerinde\n"
  printf "degistirilmez, silinmez ve yeni bir dosya yazilmaz. Sikistirilmamis bir\n"
  printf "blob dogrudan ve yalnizca bastan okunur.\n"
  zro_msg_footer
}

# THE TWO THINGS EVERY ENDING OF THIS SCREEN HAS TO SAY, written once. Four endings
# reach it — the record with no blob path, the path this tool would not open, the blob
# it could not read, and the whole answer — and each of them appended these two
# paragraphs by copying the last one, which is four chances for the promise about the
# body to go missing from the screen that most needs it.
zro_msg_footer() {
  printf '\n%s\n' "$ZRO_TXT_MSG_NO_BODY"
  printf '\n%s\n' "$ZRO_TXT_MSG_READONLY"
}

# Why the blob could not be read, in the terms its own cause names. Each of these
# has a different repair, which is why the shared failure box is not what a caller
# gets: the record is still on the screen, and this hangs under it.
zro_msg_unreadable_text() {
  local rc=${1-0} detail
  detail=$(zro_last_error)
  case $rc in
    "$ZRO_E_TIMEOUT")
      printf 'BLOB DOSYASI AYRILAN SUREDE OKUNAMADI. Sikistirilmis bir dosyanin\n'
      printf 'basina ulasmak icin dosya bastan acilir; cok buyuk bir ekte bu sure\n'
      printf 'yetmeyebilir. Islem kesildi ve dosyaya DOKUNULMADI.\n' ;;
    "$ZRO_E_UNAVAILABLE")
      printf 'BLOB DOSYASI ACILAMADI. Sikistirilmis bir dosyayi acmak bu araca gore\n'
      printf 'bir TARAMA kadar is demektir: dusuk islemci onceligi ve bos disk\n'
      printf 'onceligi ile calistirilir. Bunu yapan komutlar (nice, ionice) bu\n'
      printf 'sunucuda bulunamadi.\n' ;;
    "$ZRO_E_DENIED")
      # Either the path was not admitted or the read itself was refused by the exec
      # gate. The second means a defect in this program, so neither is described as
      # something the operator did.
      printf 'BLOB DOSYASI ACILMADI: yol kabul edilmedi ya da okuma calistirma\n'
      printf 'kapisi tarafindan reddedildi. Ikincisi olduysa bu aracta bir eksiktir;\n'
      printf 'arac gunlugune bakin.\n' ;;
    "$ZRO_E_NO_RESULT")
      printf 'BLOB DOSYASI BOS. Kayit bir blob yolu bildiriyor, ama dosyada hic bayt\n'
      printf 'yok: bu, iletinin basliksiz oldugunu degil, dosyanin bos oldugunu\n'
      printf 'gosterir.\n' ;;
    "$ZRO_E_NO_BLOB")
      printf 'BLOB DOSYASI OKUNAMADI. Kayit bir yol bildiriyor, ama o dosya bu\n'
      printf 'sunucuda acilamadi: dosya artik orada olmayabilir, ya da zimbra\n'
      printf 'kullanicisi tarafindan okunamiyor olabilir.\n'
      printf '\n'
      printf 'Sahiplik veya izinler bozulmussa onarim: zmfixperms\n' ;;
    # Reached only by a code this list has fallen behind, which is a defect in this
    # file rather than a fact about the file on disk. Said as the general sentence
    # rather than silently, and the record above is still the screen's answer.
    *)
      printf 'BLOB DOSYASI OKUNAMADI (kod %s). Kayit yukarida oldugu gibi\n' "$rc"
      printf 'gecerlidir; eksik olan yalnizca baslik bolumudur.\n' ;;
  esac
  [ -n "$detail" ] || return 0
  printf '\nSistemin bildirdigi:\n%s\n' "$detail"
}
