# shellcheck shell=bash
# The log search: finding something in the whole of every log file an arrival
# window covers, rather than in the last lines of one of them.
#
# It is the other half of lib/logview.sh, and the difference between them is the
# whole point. The viewer answers "what does this log say now" from the end of one
# file. This answers "did this happen", and an answer to that question is worth
# nothing unless everything it was meant to read was read. Nothing here opens a
# mailbox and nothing here reaches a Zimbra binary.
[ -n "${ZRO_LIB_LOGSEARCH_LOADED:-}" ] && return 0
ZRO_LIB_LOGSEARCH_LOADED=1

# THE DECISION THIS MODULE IS BUILT ON, AND IT IS NOT THE OBVIOUS ONE.
#
# A search of a mail log on a server with a hundred thousand mailboxes has to be
# bounded somewhere, and there are two places to put the bound. Bounding the INPUT
# — reading only the newest lines of each file, as the viewer does — is cheaper and
# is the wrong one: it answers "no record found" from a fifth of the file, and an
# operator reads that as "it never happened". That is the exact failure this
# project has already been bitten by, and the reason the arrival window's banners
# exist one screen over. On the lab server the delivery outcomes sit in the first
# fifth of a 4940-line log against a bounded read of 500: the tail does not reach
# them.
#
# So the bound is on the OUTPUT. Every file the window selects is read from its
# first line, and what stops is the printing: after a fixed number of matches the
# scan gives up and SAYS SO, naming the files it had read and the files it never
# reached. An answer that hit the cap is incomplete and is reported as incomplete;
# an answer that did not is complete, and "nothing was found" then means what it
# says — which is the one sentence this feature exists to be able to write.
#
# The cap is grep's own, applied by the reader rather than by this side of the
# pipe. A search that let the matches through and trimmed them here would hold a
# whole log's worth of matching lines in memory, on the server it is diagnosing,
# which is the same mistake in a new place.
#
# WHAT THE WINDOW DOES AND DOES NOT DO. It selects FILES, through the same pure
# coverage-interval logic a delivery trace uses. It does not filter LINES: the
# reader here has no notion of time, so a selected file is searched whole and the
# answer can carry lines from either side of the window's edges. The screen says
# this. Filtering by time would mean parsing a timestamp out of three log formats
# that do not agree on one — the mail log writes `Aug  2 16:49:03` with no year at
# all — and a parser that guessed wrong would silently drop the lines it was asked
# for.

# How many matching lines one search may print. Overridable like every other bound
# here, and judged before it is used: this value reaches a command line.
#
# Two hundred rather than the viewer's five hundred: this is a screen an operator
# reads to find one thing, and a cap that fills more than a few pages is a cap that
# has stopped bounding anything an operator can use.
ZRO_LOGSEARCH_MATCHES="${ZRO_LOGSEARCH_MATCHES:-200}"

# The longest free text this program will search for. A pattern that does not fit
# on the screen is one an operator cannot check against what they meant to type.
ZRO_LOGSEARCH_TEXT_MAX=200

# THE NAMED QUESTIONS, as "<id>:<log the question is about>:<label>".
#
# The operator chooses a question and this program owns the pattern. That is the
# half of this feature that keeps a search from being a way to run a regular
# expression on a production server: no text an operator types becomes a pattern
# here, and the address that may narrow one of these questions is matched as the
# literal it is by a second reader rather than spliced into this one.
#
# ONE VALUE IN THIS MODULE REACHES A PATTERN, and it is not here: the sending
# domain, further down, because *arrived from* is a fact about one field of a line
# and no whole-line match can express it. It is validated as a domain and escaped
# before it goes anywhere near the reader, and the function that builds it says
# why. Everything else an operator can type — free text, an address filter, a
# message-id — reaches the literal reader and only the literal reader.
#
# Every id here must have a pattern below and every pattern must be named here.
# Neither half can check the other at run time without reaching into its business,
# so the suite holds the two sets equal — the same arrangement as the window's
# presets and the menu that offers them.
#
# The log is part of the declaration rather than something the operator picks,
# because which file answers a question is not an operator's decision to get wrong:
# rejected mail is in the mail log and nowhere else, and a session is in the audit
# log and nowhere else.
#
# SC2034: read by NAME through lib/table.sh, never expanded here.
# shellcheck disable=SC2034
ZRO_LOGSEARCH_QUESTIONS='rejected:syslog:Reddedilen mail (sunucu kabul etmedi)
deferred:syslog:Ertelenen mail (kuyrukta bekliyor, denemeler suruyor)
bounced:syslog:Geri donen mail (teslim edilemedi, gonderene bildirildi)
delivered:syslog:Yerel teslim (mailbox sunucusuna teslim edildi mi)
sessions:audit:Hesap oturumlari (basarili ve basarisiz girisler)
mboxerror:mailbox:Mailbox hatalari (istisna ve hata satirlari)'

# --- reading a declaration table ---------------------------------------------
#
# TWO TABLES SHARE ONE SHAPE, `<id>:<log>:<label>`, and therefore one reader. They
# are two tables because their CONTRACTS differ — a question below carries a
# pattern this program owns and may be narrowed by an address, while a lookup
# further down takes a value and asks whether it is there at all — and that is a
# difference between what the entries MEAN, not between how a line is taken apart.
# A second copy of the taking-apart is a copy that can drift while both tables
# still look right.
#
# That reader used to live here and took its table as a VALUE, so that nothing
# generic had to know which declarations exist. It is lib/table.sh now, it takes
# the table as a NAME, and that file says why the trade turned the other way once
# a refusal had to be able to name the declaration it came from.
#
# What stays here is the six names the rest of the program uses. Thin on purpose:
# what they carry is WHICH declaration is being read, which is the thing a call
# site should say out loud and the thing a generic reader cannot.

zro_logsearch_questions() {
  zro_table_keys ZRO_LOGSEARCH_QUESTIONS
}

zro_logsearch_question_log() {
  zro_table_field ZRO_LOGSEARCH_QUESTIONS "${1-}" 1
}

# The remainder, not a field: a label is operator-facing text and may carry a
# colon.
zro_logsearch_question_label() {
  zro_table_rest ZRO_LOGSEARCH_QUESTIONS "${1-}" 2
}

# THE PATTERNS THEMSELVES, one per question, each keyed on a line a real server
# really wrote. Extended regular expressions, run through the reader's `-E` form,
# and written out here as literals so that reading this file is how a maintainer
# learns what a named question actually matches.
#
# EVERY ONE OF THEM COMES FROM A CAPTURE, and the file it came from is named. This
# project shipped two production bugs from fixtures written from memory; a pattern
# written from memory is the same mistake with a wider blast radius, because a
# pattern that matches nothing produces the empty answer this whole feature exists
# to make trustworthy.
#
#   rejected   `NOQUEUE: reject:` — a rejection has NO QUEUE ID. The literal
#              NOQUEUE stands where every other line carries one, which is also
#              why a search keyed on a queue id can never find one of these, and a
#              rejected message is exactly what an operator is looking for when
#              they say the mail never arrived.
#   deferred   the status field. Both captured causes — a domain that does not
#              resolve and a host refusing port 25 — write the same word.
#   bounced    the status field OR the notification the bounce daemon writes,
#              because the second names the queue id of the report that went back
#              to the sender and the first does not.
#   delivered  `postfix/lmtp[` — the hop that means a MAILBOX took the message.
#              The first `status=sent` on a Zimbra server only means amavis
#              accepted it, so a question keyed on that would answer "delivered"
#              about a message that never reached anybody.
#   sessions   `cmd=Auth;` — the one field that is on a successful login and on a
#              failed one alike. The level differs (INFO against WARN) and the
#              failure appends an `error=` field, so keying on either half would
#              answer half the question. `cmd=DelegateAuth` is a different command
#              and is deliberately not matched: no line of it has been captured.
#   mboxerror  three shapes, because Zimbra writes an error in three ways and only
#              one of them is a level: a bare stack trace with no timestamp at all,
#              a `handler exception` line at INFO, and the sentence
#              `Error occurred ...` also at INFO. WARN is excluded deliberately —
#              on the lab server every WARN in five days was start-up noise, and a
#              question that filled its cap with those would bury the one line the
#              operator came for.
#
# See docs/research/2026-08-03-log-search-patterns-and-priority.md for the captured
# lines, and docs/research/2026-08-02-mta-queue-and-log.md for the mail log's four
# outcomes.
zro_logsearch_pattern() {
  case ${1-} in
    rejected)  printf 'NOQUEUE: reject:' ;;
    deferred)  printf 'status=deferred' ;;
    bounced)   printf 'status=bounced|postfix/bounce\[' ;;
    delivered) printf 'postfix/lmtp\[' ;;
    sessions)  printf 'cmd=Auth;' ;;
    mboxerror) printf ' (ERROR|FATAL) |[Ee]xception|Error occurred' ;;
    *) return "$ZRO_E_INPUT" ;;
  esac
}

# --- what a search is about to cost ----------------------------------------

# The files one search will read, as "<size in bytes>\t<path>", NEWEST FIRST.
#
#   $1  a name declared in ZRO_INVENTORY
#   $2  window start, an absolute local timestamp in seconds
#   $3  window end, the same
#
# THE SAME SELECTION A DELIVERY TRACE MAKES, through the same pure function: a
# file's coverage interval runs from the previous file's timestamp to its own, and
# rotation fires in the early morning, so the file stamped the 29th holds the
# 28th's afternoon. A second rule here would be the off-by-one this project already
# removed once, put back.
#
# The year zro_inv_select derives is dropped: it exists for a tracer that stamps
# syslog lines with it, and nothing here parses a timestamp at all.
#
# REVERSED, AND THAT IS THE ORDER THE CAP MAKES IMPORTANT. Selection emits oldest
# first, because a file's coverage interval begins at the previous file's
# timestamp; the delivery trace reads it that way so its report runs forwards in
# time. A search cannot afford to. When the cap ends a scan it ends it where the
# scan had got to — so reading oldest first means the files never opened are the
# NEWEST ones, and an operator asking what happened this morning would be answered
# out of last week with today's log unread. Reversed, the cap falls on the oldest
# files instead, which are the ones they are least likely to have meant.
#
# The same reason the viewer lists a log's files newest first, one screen over: the
# file an operator wants is nearly always the one being written.
#
# A file whose size cannot be read is still listed, with a size of zero. It is a
# file the scan will still try to open — and if it cannot, that is a partial scan
# disclosed as one. Dropping it here would hide it from the cost AND from the
# disclosure, which is how a day goes missing without anybody being told.
zro_logsearch_files() {
  local key=${1-} ws=${2-} we=${3-} selected rc=0 line path size i
  local -a listed=()
  selected=$(zro_inv_discover "$key" | zro_inv_select "$ws" "$we") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ -n "$selected" ] || return 0

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path=${line#*"$ZRO_TAB"}
    size=$(zro_inv_size "$path")
    case $size in
      ''|*[!0-9]*) size=0 ;;
    esac
    listed+=("$size$ZRO_TAB$path")
  done <<EOF
$selected
EOF

  # Walked backwards by index rather than reversed by a second sort: the order
  # selection emits is a rule about rotation — a compressed file and the plain one
  # it replaced share a timestamp and are one rotation instant — and re-sorting
  # here would be a second copy of that rule, free to disagree with the first.
  for (( i = ${#listed[@]} - 1; i >= 0; i-- )); do
    printf '%s\n' "${listed[i]}"
  done
}

# What the operator is about to spend, as "<file count>\t<total bytes>".
#
# STATED AND CONFIRMED BEFORE ANYTHING IS READ, which is what cost class 3 means
# on a screen rather than in a table. The number is the size ON DISK: a compressed
# rotation decompresses to several times it, and the screen says so rather than
# this function inventing a multiplier nobody measured.
zro_logsearch_plan() {
  local files rc=0 line n=0 total=0 size
  files=$(zro_logsearch_files "${1-}" "${2-}" "${3-}") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    size=${line%%"$ZRO_TAB"*}
    n=$((n + 1))
    total=$((total + size))
  done <<EOF
$files
EOF
  printf '%s%s%s' "$n" "$ZRO_TAB" "$total"
}

# --- the reader --------------------------------------------------------------

# The two match forms, and the only path from here to the reader.
#
#   $1  the form, as the allowlist spells it     $@  the already-judged arguments
#
# Written out one per line for the reason lib/delivery.sh writes its three filters
# out: tests/test_readonly_scan.sh reads this source and proves that every call
# site names an operation the allowlist approves, and a single call site handing
# the gate a variable would be undecidable to that reader. The form this program
# cannot express is the one that walks a directory, and it cannot be expressed
# because there is nowhere here to write it.
#
# `-a` GOES WITH BOTH, always. A single odd byte makes the reader treat a whole
# file as binary and print nothing at all — measured on the lab server's
# mailbox.log — and "nothing at all" is the one answer this module may not invent.
#
# THAT BYTE IS A NUL, and it leaves a mark this program cannot remove: a matched
# line carrying one makes bash print "ignored null byte in input" on stderr when
# the answer is read back, and drops the byte. Both are acceptable and neither is
# hidden. A shell string cannot hold a NUL at all, so there is no version of this
# that keeps it; the line is shown without it. Stripping it upstream would mean a
# third reader in the pipeline for a byte no screen can display anyway.
#
# THE THIRD FORM IS THE PATTERN FORM WITH CASE FOLDED, and it exists for exactly
# one question. A domain is the same domain whatever case it was written in, at
# both ends: the operator may type `Example.com`, and the sending client may have
# written `MAIL FROM:<x@eXAMPLE.com>`, which Postfix logs as it was given. Folding
# the operator's value would fix only their half; the search itself has to be
# case-blind or it answers "nothing arrived from there" about mail that did.
zro_logsearch_grep() {
  local form=${1-}
  [ "$#" -eq 0 ] || shift
  case $form in
    -F)  zro_exec grep -a -F "$@" ;;
    -E)  zro_exec grep -a -E "$@" ;;
    -Ei) zro_exec grep -a -E -i "$@" ;;
    *)
      zro_log error "denied, no such log search form: $form"
      return "$ZRO_E_DENIED"
      ;;
  esac
}

# One file, searched whole. Prints the matching lines and writes the status of
# every stage of the pipeline to a file.
#
#   $1 path   $2 match form   $3 pattern   $4 literal filter or empty
#   $5 the cap for this file  $6 stderr file  $7 status file
#
# THE STATUSES TRAVEL IN A FILE BECAUSE THE ANSWER TRAVELS ON STDOUT. What has to
# be told apart here is a file that was read and held nothing (status 1) from a
# file that could not be opened at all (status 2) — and, on a compressed file, from
# one whose decompression failed, which leaves the reader downstream succeeding on
# empty input and reporting "nothing matched" about a file nobody read. `pipefail`
# cannot answer that: it reports the rightmost failure, which is the reader's
# honest "no match". PIPESTATUS answers it exactly, and it is written out here
# rather than returned because everything in this function is inside a command
# substitution by the time a caller sees it.
#
# FOUR SHAPES, WRITTEN OUT. Compressed or not, filtered by an address or not.
# Bash cannot build a pipeline from a variable without a shell string, and a shell
# string is the one thing this program does not construct — so the shapes are four
# lines of case rather than one clever line.
#
# THE FILTER IS A SECOND READER RATHER THAN A CLEVERER PATTERN. "This question AND
# this address, on one line" cannot be written as one extended regular expression
# without saying it twice in both orders, and the cap belongs on the last stage
# either way. The literal form is what makes an address match itself.
zro_logsearch_scan_file() {
  local path=${1-} form=${2-} pattern=${3-} filter=${4-} cap=${5-} err=${6-} st=${7-}
  : >"$st"
  if [ -n "$filter" ]; then
    case $path in
      *.gz)
        { zro_exec gzip -dc "$path" 2>"$err" \
          | zro_logsearch_grep "$form" "$pattern" 2>>"$err" \
          | zro_logsearch_grep -F -m "$cap" "$filter" 2>>"$err"
          printf '%s' "${PIPESTATUS[*]}" >"$st"; } ;;
      *)
        { zro_logsearch_grep "$form" "$pattern" "$path" 2>"$err" \
          | zro_logsearch_grep -F -m "$cap" "$filter" 2>>"$err"
          printf '%s' "${PIPESTATUS[*]}" >"$st"; } ;;
    esac
    return 0
  fi
  case $path in
    *.gz)
      { zro_exec gzip -dc "$path" 2>"$err" \
        | zro_logsearch_grep "$form" -m "$cap" "$pattern" 2>>"$err"
        printf '%s' "${PIPESTATUS[*]}" >"$st"; } ;;
    *)
      local rc=0
      zro_logsearch_grep "$form" -m "$cap" "$pattern" "$path" 2>"$err" || rc=$?
      printf '%s' "$rc" >"$st" ;;
  esac
  return 0
}

# Whether the file behind those statuses was really read: 'ok' or 'unreadable'.
#
#   $1  the path, which is what says whether the first stage was a decompression
#   $2  the statuses, space separated, as zro_logsearch_scan_file wrote them
#
# Pure: two strings in, one word out. The rule it encodes is the readers' own,
# measured on the lab server — 0 matched, 1 read and matched nothing, 2 could not
# open — plus the decompression's, where ANY failure means the file was not read
# and the reader downstream then succeeds on empty input, reporting "nothing
# matched" about a file nobody opened.
#
# ONLY ASKED WHEN THE CAP DID NOT STOP THE SCAN, and that is a condition of it
# being right. A reader that stops at its cap closes the pipe under whatever is
# feeding it, so the decompression upstream is killed by SIGPIPE and reports a
# failure it did not have. The caller knows which of the two happened — it counted
# the matches — so it does not ask this about a file whose scan the cap ended.
#
# A missing or empty status is 'unreadable' rather than 'ok'. Not knowing is not
# the same as knowing nothing was there, and this is the function that decides
# whether an empty answer may be presented as one.
zro_logsearch_scan_verdict() {
  local path=${1-} statuses=${2-} first=1 s
  case $statuses in
    ''|*[!0-9\ ]*) printf 'unreadable'; return 0 ;;
  esac
  for s in $statuses; do
    if [ "$first" -eq 1 ] && [ "${path%.gz}" != "$path" ]; then
      # The decompression. It exits 1 on a broken or unreadable file and 2 on a
      # warning, and neither is a file this program may report as empty.
      [ "$s" -eq 0 ] || { printf 'unreadable'; return 0; }
    else
      [ "$s" -le 1 ] || { printf 'unreadable'; return 0; }
    fi
    first=0
  done
  printf 'ok'
}

# A refusal by the gate rather than an answer about a file, or nothing.
#
#   $1  the statuses, space separated
#
# THREE THINGS A READER MAY SAY ABOUT A FILE, and every other number came from
# somewhere else. 0, 1 and 2 are the readers' own; 141 is the death by SIGPIPE
# that a cap downstream causes and is not a failure at all. Anything else is the
# exec gate: a binary this host does not have, an unsupported user, a host that
# cannot reduce priority, an expired clock, an operation the allowlist refused.
#
# NONE OF THOSE IS A LOG THAT CANNOT BE READ, and flattening them into one would
# send an operator to repair a file permission because ionice was missing. So they
# are passed through as themselves, the way the delivery trace passes through
# everything that is not a file it could not open.
zro_logsearch_gate_code() {
  local statuses=${1-} s
  case $statuses in
    ''|*[!0-9\ ]*) return 0 ;;
  esac
  for s in $statuses; do
    case $s in
      0|1|2|141) ;;
      *) printf '%s' "$s"; return 0 ;;
    esac
  done
  return 0
}

# --- the disclosures ---------------------------------------------------------

# Printed above an answer assembled from fewer files than the window selected.
#
# It goes FIRST, above the answer it qualifies, and prints nothing when nothing was
# skipped — the same discipline as the delivery trace's banner, and its own
# function for the same reason: a caveat read after the conclusion has been drawn
# is not a caveat, and a banner printed when nothing was missed is noise that
# teaches an operator to skip the real one.
#
# IT IS TOLD HOW MANY FILES WERE SELECTED rather than adding up the ones it knows
# about. Read plus skipped is the whole selection only when nothing else stopped
# the scan — and something else can: a cap that ended it leaves files that were
# neither read nor skipped, and a banner that summed the two would quietly report
# a smaller window than the operator chose.
zro_logsearch_partial_banner() {
  local selected_n=${1-} skipped_n=${2-} skipped=${3-}
  [ "${skipped_n:-0}" -gt 0 ] || return 0
  printf 'UYARI: EKSIK TARAMA. Secilen %s dosyadan %s tanesi okunamadi ve\n' \
    "$selected_n" "$skipped_n"
  printf '       taranmadi. Asagidaki cevap yalnizca okunabilen dosyalari kapsar:\n'
  printf '       burada kayit bulunmamasi, aranan seyin OLMADIGINI KANITLAMAZ.\n'
  printf '       Okunamayan dosyalar:%s\n' "$skipped"
  # Double-quoted on purpose: the static scanner treats a double-quoted span as
  # data, so this text may name the command it is recommending.
  printf "       Onarim: bu dosyalar zimbra kullanicisi tarafindan okunabilir\n"
  printf "       olmalidir; izinler bozulmussa: zmfixperms\n"
  printf '\n'
}

# Printed above an answer that stopped at the cap.
#
# The other way this screen can be incomplete, and it is a different sentence: the
# files were readable, the scan simply stopped printing — and stopped READING at
# that point too, so any file after it was never opened. Both facts are on the
# screen, because "200 matches" with nothing else said reads like the whole answer.
zro_logsearch_cap_banner() {
  local cap=${1-} unread=${2-}
  printf 'UYARI: SINIRA ULASILDI. En fazla %s eslesme gosterilir ve bu sayiya\n' "$cap"
  printf '       ulasildi. Tarama en yeni dosyadan basladi ve burada durdu; daha\n'
  printf '       ESKI eslesmeler olabilir.\n'
  if [ -n "$unread" ]; then
    printf '       Bu yuzden su ESKI dosyalar hic taranmadi:%s\n' "$unread"
  fi
  printf '       Araligi daraltin ya da soruyu bir adresle sinirlayin.\n'
  printf '\n'
}

# --- the engine --------------------------------------------------------------

# Searches every file an arrival window covers, in full, and stops printing at the
# cap.
#
#   $1  a name declared in ZRO_INVENTORY
#   $2  the match form: -E for a pattern this program owns, -F for operator text
#   $3  the pattern
#   $4  a literal string every matching line must also carry, or empty
#   $5  window start, an absolute local timestamp in seconds
#   $6  window end, the same
#   $7  what to call the search on the report
#
# ONE ENGINE, TWO DOORS, exactly as the delivery trace has one engine and three.
# What changes between a named question and a free-text search is the match form,
# the pattern and the label; the window, the file selection, the cap, the
# disclosures and the exit codes are the same for both, because a second
# implementation of those is a second set of them to get wrong.
#
# THREE ENDINGS, DELIBERATELY DISTINCT, because an operator acts differently on
# each:
#   nothing matched, everything read     $ZRO_E_NO_RESULT — and it MEANS something
#   something was missed                 the answer, a banner, and $ZRO_E_PARTIAL
#   nothing could be read at all         $ZRO_E_NO_LOG and no output whatsoever
#
# $ZRO_E_PARTIAL COVERS BOTH WAYS OF BEING INCOMPLETE — a file that could not be
# opened, and a cap that stopped the scan early. They are different sentences on
# the screen and the same fact to a caller: the answer does not cover everything it
# was meant to, so an empty or short result is not evidence of anything.
zro_logsearch_run() {
  local key=${1-} form=${2-} pattern=${3-} filter=${4-} ws=${5-} we=${6-} label=${7-}
  local cap=$ZRO_LOGSEARCH_MATCHES

  # Judged before anything else: it reaches a command line, and a bound that is
  # not a count is a defect in whatever set it rather than a reason to fall back to
  # a default nobody chose.
  case $cap in
    ''|*[!0-9]*) zro_log error "denied, log search match cap is not a count: $cap"
                 return "$ZRO_E_INPUT" ;;
  esac
  if [ "$cap" -eq 0 ]; then
    zro_log error "denied, log search match cap is zero"
    return "$ZRO_E_INPUT"
  fi

  case $form in
    -E|-F|-Ei) ;;
    *) zro_log error "denied, no such log search form: $form"
       return "$ZRO_E_DENIED" ;;
  esac
  [ -n "$pattern" ] || return "$ZRO_E_INPUT"
  # Every validator in this program refuses a leading '-' already. Refused here
  # too, at the one point both doors pass through, so that a door added later
  # cannot forget it and hand the reader a value it would read as a flag.
  case $pattern in -*) return "$ZRO_E_INPUT" ;; esac
  case $filter in -*) return "$ZRO_E_INPUT" ;; esac
  case $ws in ''|*[!0-9]*) return "$ZRO_E_INPUT" ;; esac
  case $we in ''|*[!0-9]*) return "$ZRO_E_INPUT" ;; esac
  # An end before its start is a caller defect. Searching the empty window it
  # describes would answer "nothing was logged then" to a question nobody asked.
  [ "$ws" -le "$we" ] || return "$ZRO_E_INPUT"

  # The window as the operator will read it, resolved BEFORE any file is opened,
  # for the reason the delivery trace resolves its own first: a clock that stopped
  # answering would otherwise print a report headed by a blank range, in a report
  # whose whole purpose is stating what was searched.
  local from_h to_h
  from_h=$(zro_win_human "$ws") || return "$ZRO_E_UNAVAILABLE"
  to_h=$(zro_win_human "$we") || return "$ZRO_E_UNAVAILABLE"

  local files rc=0
  files=$(zro_logsearch_files "$key" "$ws" "$we") || rc=$?
  # Passed through rather than flattened: a name the inventory does not declare
  # and a root that fails admission are defects in this program, and each has
  # already been logged where it was found.
  [ "$rc" -eq 0 ] || return "$rc"

  if [ -z "$files" ]; then
    # Every window intersects something as long as one file exists — the oldest
    # file in a family has no lower bound and the newest no upper one — so an empty
    # selection means the inventory found no file at all. That is a log this tool
    # could not read, not a window with nothing in it.
    zro_log error "no log file to search: the inventory found none for $(zro_inv_base_path "$key")"
    return "$ZRO_E_NO_LOG"
  fi

  local err st out line path statuses verdict gate said reason
  local bodies='' scanned='' skipped='' unread='' total=0 read_n=0 skipped_n=0
  local remaining=$cap found capped=0 selected_n
  # How many files the window really selected, counted once. Every disclosure
  # below is a fraction of this number, and none of them may derive it by adding
  # up the files it happens to know about.
  selected_n=$(printf '%s\n' "$files" | grep -c .)
  err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"
  st=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # The size is the cost the screen already declared and confirmed; what the
    # scan needs from this line is the path.
    path=${line#*"$ZRO_TAB"}

    # The cap has already been reached, so this file was never opened. Named, not
    # skipped silently: a file nobody read is the difference between "this did not
    # happen" and "I stopped looking".
    if [ "$remaining" -le 0 ]; then
      unread="$unread
                 $path"
      continue
    fi

    # The same admission the inventory applies before reading anything, applied
    # again here. This is the function that hands a path to a program, and a path
    # that arrived some other way must meet the same rule as one that was globbed.
    if ! zro_inv_admit_path "$path"; then
      skipped_n=$((skipped_n + 1))
      skipped="$skipped
         $path
           (bu yol okunabilir yollar kumesinin disinda)"
      continue
    fi

    : >"$err"
    out=$(zro_logsearch_scan_file "$path" "$form" "$pattern" "$filter" "$remaining" "$err" "$st")
    statuses=$(cat -- "$st" 2>/dev/null)

    # A refusal by the gate is not an answer about this file, and it will be the
    # same refusal on the next one. Refused whole, with whatever the tool said, so
    # the failure reaches the operator as its own cause rather than as a log that
    # could not be read — and any file already skipped is named in it, because the
    # one thing this screen may never do is let a skipped file go unmentioned,
    # whichever way the operation ends.
    gate=$(zro_logsearch_gate_code "$statuses")
    if [ -n "$gate" ]; then
      said=$(head -c "$ZRO_ERROR_KEEP_BYTES" -- "$err" 2>/dev/null)
      [ "$skipped_n" -eq 0 ] || said="$said
Okunamayan log dosyalari:$skipped"
      [ -z "$said" ] || zro_set_error "$said"
      rm -f -- "$err" "$st"
      return "$gate"
    fi

    # How much of the cap this file used, which is also what says whether the cap
    # ended its scan. Counted before the verdict below, because that verdict may
    # only be asked about a scan the cap did not stop.
    found=0
    if [ -n "$out" ]; then
      found=$(printf '%s\n' "$out" | wc -l)
      found=${found// /}
    fi

    verdict=ok
    [ "$found" -ge "$remaining" ] || verdict=$(zro_logsearch_scan_verdict "$path" "$statuses")

    if [ "$verdict" != ok ]; then
      # A file the reader could not open, or one whose decompression failed. The
      # tool's own first non-empty line is kept as the reason, because the cause is
      # almost always a permission an administrator can repair and a reason of
      # "could not be read" would send them looking for it. Bounded: a reason of
      # unknown length would push the answer off the screen it qualifies.
      reason=$(grep -m 1 -v '^[[:space:]]*$' -- "$err" 2>/dev/null | cut -c 1-200)
      zro_log warn "log skipped, the search could not read it: $path (${reason:-no message on stderr})"
      [ -n "$reason" ] || reason='(sebep bildirilmedi)'
      skipped_n=$((skipped_n + 1))
      skipped="$skipped
         $path
           $reason"
      continue
    fi

    read_n=$((read_n + 1))
    # EACH FILE'S LINES UNDER THE NAME OF THE FILE THEY CAME FROM. Not decoration:
    # a week's window reaches five files, the lines of a rotated mail log carry no
    # year, and two files' lines run together are a chronology that does not exist.
    # The same heading the delivery trace puts above each file's report, for the
    # same reason.
    [ -z "$out" ] || bodies="$bodies
----- $path -----
$out
"
    total=$((total + found))
    remaining=$((remaining - found))
    scanned="$scanned
                 $path ($found)"
    [ "$remaining" -le 0 ] && capped=1
  done <<EOF
$files
EOF
  rm -f -- "$err" "$st"

  # NOT ONE FILE WAS READ. That is a log this tool could not read, not a partial
  # scan: a partial scan is an answer with a hole in it, and here there is no
  # answer at all. Reported with the reasons kept, so the screen can name the cause
  # and the repair, and with no output whatsoever.
  if [ "$read_n" -eq 0 ]; then
    zro_set_error "$(printf 'Okunamayan log dosyalari:%s' "$skipped" | head -c "$ZRO_ERROR_KEEP_BYTES")"
    return "$ZRO_E_NO_LOG"
  fi
  zro_clear_error

  # AN EMPTY ANSWER IS AN ANSWER HERE, and this is the line that earns it: every
  # file the window selected was opened and read from its first line, so nothing
  # matched means nothing was there. It is only that when nothing was missed —
  # with a file skipped or the cap reached it is a partial scan, reported below as
  # one, because "no records" from a scan that could not open half its files is how
  # an operator concludes something never happened and goes on to be wrong about it.
  if [ "$total" -eq 0 ] && [ "$skipped_n" -eq 0 ]; then
    return "$ZRO_E_NO_RESULT"
  fi

  # FIRST, above the answer they qualify. Both can be true at once — a file that
  # could not be opened and a cap that stopped the rest — and neither may be left
  # out on the strength of the other.
  zro_logsearch_partial_banner "$selected_n" "$skipped_n" "$skipped"
  [ "$capped" -eq 0 ] || zro_logsearch_cap_banner "$cap" "$unread"

  printf 'Arama          : %s\n' "$label"
  [ -z "$filter" ] || printf 'Adres suzgeci  : %s (yalnizca bu metni de iceren satirlar)\n' "$filter"
  printf 'Log            : %s\n' "$(zro_logview_label "$key")"
  printf 'Aralik         : %s - %s\n' "$from_h" "$to_h"
  printf '                 (aralik DOSYA secimine uygulanir; secilen dosyalar\n'
  printf '                  bastan sona taranir, bu yuzden aralik disindaki\n'
  printf '                  satirlar da listelenebilir)\n'
  printf 'Bulunan satir  : %s (ust sinir: %s)\n' "$total" "$cap"
  printf 'Taranan dosya  : %s dosya, TAMAMI okundu (en yeniden eskiye)%s\n' \
    "$read_n" "$scanned"
  # Unmodified, on purpose: what follows is what the file says.
  printf -- '--------------------------------------------------------------------\n'
  printf '%s' "$bodies"

  # The answer is out and it does not cover everything it was meant to. The banners
  # say so to the operator; this says so to the caller, which is how the screen
  # knows to mark its title.
  { [ "$skipped_n" -eq 0 ] && [ "$capped" -eq 0 ]; } || return "$ZRO_E_PARTIAL"
  return 0
}

# --- the two doors -----------------------------------------------------------

# A named question, with the pattern this program owns.
#
#   $1  the question id      $2  an address to narrow it by, or empty
#   $3  window start         $4  window end
#
# THE OPERATOR NEVER TYPES A PATTERN HERE. They choose a question, and at most they
# supply an address — which is matched as the literal it is by a second reader,
# never spliced into the pattern. So there is no text an operator can type that
# changes what the pattern form of the reader is asked to match.
zro_logsearch_named() {
  local id=${1-} filter=${2-} pattern log label
  if ! log=$(zro_logsearch_question_log "$id"); then
    zro_log error "denied, no such log search question: $id"
    return "$ZRO_E_DENIED"
  fi
  if ! pattern=$(zro_logsearch_pattern "$id"); then
    # The two declarations have parted company: a question named in the table with
    # no pattern behind it. A defect in this file, and the suite holds the sets
    # equal precisely so it cannot reach an operator.
    zro_log error "denied, no pattern for log search question: $id"
    return "$ZRO_E_DENIED"
  fi
  label=$(zro_logsearch_question_label "$id")
  # An address is the only value an operator may supply to a named question, and it
  # is judged as one. Anything else is a caller defect: this is not the free-text
  # door and may not become one by way of an unvalidated filter.
  if [ -n "$filter" ]; then
    zro_validate_email "$filter" || return "$ZRO_E_INPUT"
  fi
  zro_logsearch_run "$log" -E "$pattern" "$filter" "${3-}" "${4-}" "$label"
}

# --- the questions that are about everybody ----------------------------------
#
# TWO QUESTIONS THAT ARE NOT ABOUT THE SELECTED ADDRESS AT ALL. Has this message
# passed through the server; has anything arrived from this domain. Asked of the
# accounts they concern, each would be a query per mailbox and a gate check per
# account — a server-wide sweep, which this tool refuses to be. Asked of the logs
# they are ONE SCAN of the window's files, and they open no mailbox.
#
# A SERVER-WIDE QUESTION IS NOT A SERVER-WIDE SWEEP, and the difference is the
# whole reason these can exist here: a sweep's work grows with the number of
# accounts on the server, and this work grows with the window the operator chose.
# One is refused by design; the other is what the log is for.
#
# They live beside the named questions rather than among them because their
# contract is different: a named question is "show me every X" and takes at most an
# address to narrow it, while these take a VALUE and ask whether it is there at
# all. Two tables, each uniform, rather than one with a mode field in it.
#
# THE MAIL LOG ANSWERS BOTH, and only it. Postfix's cleanup stage records every
# message's identifier as it arrives, and its queue manager records every message's
# envelope sender, so a scan of that one family covers every message the server
# took. mailbox.log carries the same identifier again for a message delivered
# locally — that is a second record of a subset, not a second source, and reaching
# it costs a second scan of a second family. An operator who wants it has the
# free-text door.
#
# SC2034: read by NAME through lib/table.sh, never expanded here.
# shellcheck disable=SC2034
ZRO_LOGSEARCH_LOOKUPS='msgid:syslog:Ileti kimligi sunucudan gecti mi
sender-domain:syslog:Bu alan adindan mail geldi mi'

zro_logsearch_lookups() {
  zro_table_keys ZRO_LOGSEARCH_LOOKUPS
}

zro_logsearch_lookup_log() {
  zro_table_field ZRO_LOGSEARCH_LOOKUPS "${1-}" 1
}

zro_logsearch_lookup_label() {
  zro_table_rest ZRO_LOGSEARCH_LOOKUPS "${1-}" 2
}

# Whether one message passed through this server, by its identifier.
#
#   $1  the identifier, as an operator holds it   $2 start   $3 end
#
# MATCHED LITERALLY, AND THE BRACKETS COME OFF FIRST. The log records the same
# identifier in three shapes — `message-id=<X>` where Postfix cleans the message
# up, `Message-ID: <X>` where amavis reports it, and `msgid=<X>` where the mailbox
# server takes delivery — so searching for the bare identifier finds every one of
# them, while searching for any single one of the three forms would find a third of
# the truth. All three are captured; see the two research files.
#
# The value is punctuation from end to end, which is why it is the literal reader
# that gets it: read as a pattern, the dots match anything and the answer is
# somebody else's message.
#
# THIS IS NOT THE DELIVERY TRACE, and the two are worth telling apart. The trace
# asks the tracing binary to assemble a message's hops into a report; this reads
# the log itself, finds every line carrying the identifier, and shows them as they
# were written. The trace is the better answer where it can run; this one answers
# on a host with no tracing binary, and it answers about lines the tracer does not
# parse.
#
# The unwrapping is the delivery trace's, called rather than copied. What an
# operator has in hand is a header line either way, and a second implementation of
# "take off the brackets, but only a matching pair, and only one" is the kind of
# pair that drifts — one screen searching for a value the other would have shown.
zro_logsearch_msgid() {
  local id
  id=$(zro_trace_msgid_bare "${1-}")
  zro_validate_msgid "$id" || return "$ZRO_E_INPUT"
  zro_logsearch_run syslog -F "$id" '' "${2-}" "${3-}" \
    "$(zro_logsearch_lookup_subject msgid "$id")"
}

# What one of these searches is CALLED once it has a value, written once.
#
#   $1  the lookup id      $2  the value it was given
#
# ONE NAME FOR ONE SEARCH. The screen says what it is about to do — in the wait
# notice and on the screen that reports finding nothing — and the report says what
# it did, and those have to be the same words. Built here rather than composed at
# each end, because two ends composing their own name is how an operator ends up
# reading `Bu alan adindan mail geldi mi: x` on one screen and
# `gonderen alan adi: x` on the next and wondering whether they are the same
# search.
zro_logsearch_lookup_subject() {
  case ${1-} in
    msgid)         printf 'ileti kimligi: %s' "${2-}" ;;
    sender-domain) printf 'gonderen alan adi: %s' "${2-}" ;;
    *) return "$ZRO_E_INPUT" ;;
  esac
}

# The pattern that finds one domain in the envelope sender.
#
#   $1  a domain the caller has already validated
#
# THE ONE PLACE IN THIS MODULE WHERE AN OPERATOR'S VALUE REACHES A PATTERN, and it
# is deliberate rather than convenient. The question is whether mail ARRIVED FROM
# this domain, and that is a fact about one field of the line: `from=<user@domain>`.
# A literal search for the domain answers a different question — it matches the
# same domain standing in `to=`, so mail sent TO a correspondent would be reported
# as mail received FROM them, which is the wrong answer to act on. Nothing built
# out of a whole-line match can tell those apart, because the difference is WHERE
# on the line the domain sits.
#
# TWO THINGS MAKE IT SAFE, and they hold together. The value has already been
# judged a domain, which admits letters, digits, dots and hyphens and nothing else
# — no metacharacter survives that. And it is escaped here anyway, so the dots
# match dots: without that, `mail.example.com` would also match `mailXexample.com`,
# which is a different organisation. Neither protection is trusted alone, and the
# suite drives both.
#
# `[^>]*` rather than a mail-shaped pattern: what stands before the '@' is a local
# part, and local parts are far stranger than any pattern this file should claim to
# know. Everything up to the closing bracket is enough, and it cannot run past the
# end of the field.
zro_logsearch_sender_pattern() {
  printf 'from=<[^>]*@%s>' "$(zro_regex_quote "${1-}")"
}

# Whether anything arrived from one domain.
#
#   $1  the domain, as the operator typed it   $2 start   $3 end
#
# EVERY ARRIVAL IS COVERED by the field this matches: Postfix's queue manager
# writes `from=<...>` for every message it queues, and the rejections that never
# reach a queue carry the same field on the line that refuses them. The amavis line
# names the sender in brackets without the field and is therefore not matched —
# which costs nothing, because the message it describes has a queue manager line of
# its own.
# SEARCHED WITHOUT REGARD TO CASE, which is a fact about domains rather than a
# convenience. The same domain is the same domain however the operator typed it and
# however the sending client wrote it into the envelope — Postfix logs that as it
# was given — so a case-sensitive search here would answer "nothing arrived from
# there" about mail that did, on the one screen that presents an empty answer as
# proof. The message-id door beside this one stays case-sensitive, because an
# identifier is a token rather than a name.
zro_logsearch_sender_domain() {
  local domain=${1-}
  zro_validate_domain "$domain" || return "$ZRO_E_INPUT"
  zro_logsearch_run syslog -Ei "$(zro_logsearch_sender_pattern "$domain")" '' \
    "${2-}" "${3-}" "$(zro_logsearch_lookup_subject sender-domain "$domain")"
}

# Free text, matched literally.
#
#   $1  the declared log to search   $2  the text, as the operator typed it
#   $3  window start                 $4  window end
#
# LITERALLY IS THE WHOLE POINT. An address carrying a '.' or a '+' is a regular
# expression that does not match itself, and a queue id, a host name and a
# message-id are all punctuation an engine would read as syntax. The reader's `-F`
# form is what makes the text mean itself — which is also why nothing here escapes
# anything: an escaped literal would be a second, subtly different value from the
# one the screen says was searched for.
zro_logsearch_text() {
  local key=${1-} text=${2-}
  # The log is one this program declares. The screen offers them by name, and this
  # refuses a name it did not — neither check resting on the other, exactly as the
  # viewer refuses a path the inventory does not list.
  if ! zro_logview_label "$key" >/dev/null 2>&1; then
    zro_log error "denied, not a declared log: $key"
    return "$ZRO_E_DENIED"
  fi
  zro_logsearch_validate_text "$text" || return "$ZRO_E_INPUT"
  zro_logsearch_run "$key" -F "$text" '' "${3-}" "${4-}" "$(printf 'duz metin: %s' "$text")"
}

# What free text may be.
#
# PERMISSIVE IN CHARACTER SET, and deliberately: the whole reason this door exists
# is the thing nobody anticipated, and a set narrow enough to be safe would refuse
# the queue ids, host names and header fragments an operator arrives holding. The
# value never becomes a command name and never reaches a shell — it travels as one
# element of an argument vector — so what is refused is not a character set but a
# category, exactly as it is for a message-id:
#
#   empty            would match every line of every file in the window
#   a leading '-'    is read as a flag by any command line it reaches
#   a control character   is a second line in the report that says what was
#                    searched for, and in the log line that records it
#   space at either end   is invisible on the screen that says what was searched
#                    for, so an answer of nothing would have no visible cause
#   longer than the bound   is a pattern an operator cannot check against what
#                    they meant to type
#
# A SPACE IN THE MIDDLE IS ALLOWED, and that is a decision rather than an
# oversight. `Recipient address rejected`, `connection refused` and
# `Delivery OK` are what an operator actually arrives holding, and every one of
# them is a phrase — refusing the space would leave this door open only for values
# that happen to be single tokens, which is not "the thing nobody anticipated".
# Nothing about a space is a hazard here: the text is one element of an argument
# vector, so it is never split, and it is matched literally rather than as a
# pattern.
zro_logsearch_validate_text() {
  local t=${1-}
  [ -n "$t" ] || return "$ZRO_E_INPUT"
  [ "${#t}" -le "$ZRO_LOGSEARCH_TEXT_MAX" ] || return "$ZRO_E_INPUT"
  case $t in -*) return "$ZRO_E_INPUT" ;; esac
  # Control characters, which is also what refuses a newline and a tab: both would
  # make one search term into two lines of every report that names it.
  case $t in *[[:cntrl:]]*) return "$ZRO_E_INPUT" ;; esac
  case $t in ' '*|*' ') return "$ZRO_E_INPUT" ;; esac
  return 0
}
