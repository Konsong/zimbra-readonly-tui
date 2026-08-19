# shellcheck shell=bash
# Delivery tracing: what the mail transfer agent's log says about a message.
#
# Nothing here opens a mailbox. The trace is assembled by the tracing tool from
# log lines alone, so the existence gate is not involved and this is safe on an
# account that has never logged in.
[ -n "${ZRO_LIB_DELIVERY_LOADED:-}" ] && return 0
ZRO_LIB_DELIVERY_LOADED=1

# How the tracing tool introduces each message it found, at the start of a line.
# Recipient blocks and hop lines below it are indented, so an anchored match
# counts messages and not their contents.
#
# THIS IS THE ONE DEPENDENCY on the report's internal shape in this milestone,
# and it is deliberately the only one: the tool exits successfully whether or not
# anything matched, so the report itself is the sole source for the answer.
# Everything else is rendered as it arrives.
#
# RE-VERIFY THIS AGAINST OUTPUT CAPTURED FROM A REAL SERVER. It comes from the
# tool's print statements as documented in
# docs/research/2026-07-29-zimbra-cli-read-only-reference.md §B.11, read out of
# the source; no capture exists in this repository yet. M1 shipped two production
# bugs from output that had been described rather than captured, and the suite
# agreed with both descriptions. A parsed table view of the report waits on the
# same capture.
ZRO_TRACE_MESSAGE_PREFIX='Message ID '

# How many messages a report introduces. Pure: text in, a number out.
zro_trace_message_count() {
  local n
  # grep exits 1 when it counts nothing, which is not a failure here.
  n=$(printf '%s\n' "${1-}" | grep -c "^$ZRO_TRACE_MESSAGE_PREFIX") || n=0
  printf '%s' "$n"
}

# Maps a failed trace to a documented exit code, or passes the tool's own status
# through when it recognises nothing. Same shape as zro_prov_outcome_code in
# lib/account.sh, and for the same reason: an operator who is shown a bare status
# has to reproduce the command by hand to learn what went wrong.
#
# AN OUTCOME READER AND NOT A FAILURE READER, for the reason the name carries: its
# answer decides whether THIS log file is skipped or the whole scan refused, so it
# is read in the middle of the loop rather than as a read's last step, and the
# status it is handed can still be one of the gate's. ADR-0010 records why this
# seam stays outside the settler.
#
# A log the tool cannot open is the one failure worth naming. It dies with
# "unable to open file" on stderr and no exit status of its own, so the message is
# the only signal there is. That text comes from the tool's source as documented
# in docs/research/2026-07-29-zimbra-cli-read-only-reference.md §B.11 rather than
# from a capture, which is why the match lives here alone and stays this narrow.
zro_trace_outcome_code() {
  local errfile=$1 rc=$2
  if grep -q 'unable to open file' "$errfile" 2>/dev/null; then
    printf '%s' "$ZRO_E_NO_LOG"
    return 0
  fi
  printf '%s' "$rc"
}

# The tracer's own time bound, as its POD documents it: YYYYMM[DD[HH[MM[SS]]]],
# from docs/research/2026-07-29-zimbra-cli-read-only-reference.md §B.11. Written
# out to full precision every time, so that no field is left to a default nobody
# in this project has read.
#
# Local wall clock, like everything else here. The tracer compares this against a
# timestamp it built from a syslog line carrying no zone and the year we hand it,
# so any conversion on this side would be inventing a precision the other side
# does not have.
#
# It stays here rather than in lib/window.sh, where the rest of the clock lives,
# because what it encodes is the TRACER's option format read out of that tool's
# POD — knowledge that belongs with the tool it is for. The window module knows
# what an arrival window is; it should not have to know what zmmsgtrace wants.
zro_trace_stamp() {
  local out
  out=$(zro_clock_fmt '%Y%m%d%H%M%S' "${1-}") || return $?
  # Fourteen digits or nothing. A short or empty bound would be read by the
  # tracer as a different, wider window, and the trace would answer a question
  # the operator did not ask.
  case $out in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) return "$ZRO_E_UNAVAILABLE" ;;
  esac
  printf '%s' "$out"
}

# The three questions this screen answers, and the only path from here to the
# tracer. A filter is written out LITERALLY, once each, because that is what
# lets tests/test_readonly_scan.sh read the source and prove that every tracing
# call site names a filter the allowlist approves. A single call site handing the
# gate a variable would be undecidable to that reader, and the guarantee it
# enforces is worth four lines of case.
#
# It also means a filter this project has not exposed cannot be expressed at
# all: --srchost and --desthost are not refused here because the gate would
# refuse them, but because there is nowhere to write them. Reaching one is a
# defect in this file, so the refusal is the defect code.
#
#   $1  the filter, as the allowlist spells it
#   $@  the already-quoted pattern and this program's own arguments
zro_trace_exec() {
  local filter=${1-}
  # Called with nothing at all is a defect like any other bad filter, and shift
  # on an empty vector is an error rather than a no-op.
  [ "$#" -eq 0 ] || shift
  case $filter in
    --recipient) zro_exec zmmsgtrace --recipient "$@" ;;
    --sender)    zro_exec zmmsgtrace --sender "$@" ;;
    --id)        zro_exec zmmsgtrace --id "$@" ;;
    *)
      zro_log error "denied, no such delivery trace filter: $filter"
      return "$ZRO_E_DENIED"
      ;;
  esac
}

# What the report calls the value it was searched by. The header line is how an
# operator knows which question the lines below it answer — a sender trace read
# as a recipient trace supports the opposite conclusion from the same output.
#
# One table for the module and the screen alike, so the menu entry an operator
# chose and the header they end up reading cannot drift apart.
zro_trace_label() {
  case ${1-} in
    --recipient) printf 'Alici' ;;
    --sender)    printf 'Gonderen' ;;
    --id)        printf 'Ileti kimligi' ;;
    *) return 1 ;;
  esac
}

# The identifier as the tracer holds it, with the angle brackets a mail header
# wraps it in taken off.
#
# The tracer captures a message-id from 'message-id=<([^>]+)>' and stores what is
# INSIDE the brackets, so a pattern carrying them matches nothing at all. What an
# operator has in hand is the header line, brackets and all — and on this screen
# a filter that cannot match reads as proof the message never arrived.
#
# Only a MATCHING PAIR at the two ends is removed, and never more than one: that
# is unwrapping a delimiter the syntax defines, not repairing a value into
# something nobody typed.
zro_trace_msgid_bare() {
  local id=${1-}
  case $id in
    '<'*'>') id=${id#<}; id=${id%>} ;;
  esac
  printf '%s' "$id"
}

# Printed above a report assembled from fewer log files than the arrival window
# selected — a PARTIAL SCAN.
#
#   $1  how many files were read
#   $2  how many were skipped
#   $3  those files, as the block below prints them
#
# It goes FIRST, above the answer it qualifies, and prints nothing when nothing was
# skipped. Same discipline as zro_mode_banner in lib/account.sh, and its own
# function for the same reason: a degraded read is disclosed at the top of the
# screen rather than beside the line where it happened, because a caveat read after
# the conclusion has already been drawn is not a caveat. A banner printed when
# nothing was missed would be noise, and noise is how a real disclosure stops being
# read.
#
# This is the detail; the screen's TITLE carries the same two words. whiptail keeps
# a title on the box frame while the text scrolls, so the pair together is what
# makes the disclosure sticky for the whole screen rather than for its first page.
zro_trace_partial_banner() {
  local read_n=${1-} skipped_n=${2-} skipped=${3-}
  [ "${skipped_n:-0}" -gt 0 ] || return 0
  printf 'UYARI: EKSIK TARAMA. Secilen %s log dosyasindan %s tanesi okunamadi\n' \
    "$((read_n + skipped_n))" "$skipped_n"
  printf '       ve taranmadi. Asagidaki cevap yalnizca okunabilen dosyalari\n'
  printf '       kapsar: bu aralikta kayit bulunamamasi, iletinin sunucuya hic\n'
  printf '       ulasmadigini KANITLAMAZ.\n'
  printf '       Okunamayan dosyalar:%s\n' "$skipped"
  # The repair, named here as well as on the log-unreadable screen: the cause of a
  # skipped file is the cause of an unreadable log, and it is almost always
  # ownership that Zimbra's own tooling trips over too. Kept to one sentence —
  # the fuller explanation belongs to the screen that has nothing else to say.
  #
  # Double-quoted on purpose: the static scanner treats a double-quoted span as
  # data, so this text may name the command it is recommending.
  printf "       Onarim: bu dosyalar zimbra kullanicisi tarafindan okunabilir\n"
  printf "       olmalidir; izinler bozulmussa: zmfixperms\n"
  printf '\n'
}

# Traces delivery inside an arrival window, by whichever filter it was given.
#
#   $1  the filter, as the allowlist spells it
#   $2  the value to search for, validated by the caller and NOT yet quoted
#   $3  window start, an absolute local timestamp in seconds
#   $4  window end, the same
#
# ONE ENGINE, THREE DOORS. Which question is being asked changes the filter, the
# value and the header label and nothing else: the window, the file selection,
# the per-file year, the counting, the partial-scan disclosure and the exit codes
# are the same for all three. A filter with a rule of its own would be a second
# implementation of every one of those, and the pair that drifted would be the
# quoting — which is the one that fails silently, as a trace that finds nothing.
#
# The VALUE ARRIVES UNQUOTED and is quoted here. Quoting in the wrappers would
# put the third escaping layer three times where a fourth filter could forget it
# once; here it is not a rule to remember but the only path there is.
#
# ONE INVOCATION PER SELECTED FILE, each carrying the year derived from that
# file's own modification time. The tracer guesses the year once, globally, from
# the local clock, so a time-bounded search of a rotated log otherwise returns
# nothing at all — silently. And because it re-initialises its parser state per
# file, handing it several files at once never chained a message across a rotation
# boundary in the first place: splitting the invocation costs no capability and
# removes the year defect outright.
#
# A SELECTED FILE THAT CANNOT BE OPENED IS SKIPPED AND DISCLOSED — a PARTIAL SCAN.
# The answer that could be found is worth having, so it is shown; and because a
# report assembled from two of three files reads exactly like a complete answer, it
# arrives under a banner naming what was missed, and the operation reports
# $ZRO_E_PARTIAL rather than success.
#
# Three cases, deliberately distinct, because an operator acts differently on each:
#   some files read, some not   the answer, plus the banner, plus $ZRO_E_PARTIAL
#   no file read at all         nothing scanned: $ZRO_E_NO_LOG and no output
#   every file read             exactly as before, success or $ZRO_E_NO_RESULT
#
# NOTHING FOUND IN A PARTIAL SCAN IS NOT AN EMPTY RESULT. It is reported as the
# partial scan it is, because an operator who reads "no records" from a scan that
# could not open half its files will conclude the message never arrived — the exact
# wrong decision this whole screen exists to prevent.
#
# Only a file the tracer COULD NOT OPEN is skippable. A timeout, or a status
# nobody here recognises, says nothing about which files were covered, so no honest
# partial answer can be assembled from it and the operation is still refused.
zro_trace_run() {
  local filter=${1-} subject=${2-} ws=${3-} we=${4-} label
  # A filter with no label is one no wrapper below should have asked for, and it
  # would print a report headed by nothing. Refused here as well as at the gate,
  # since this is where the two tables are read together — and logged, because a
  # denial is a defect in this program rather than something the operator did.
  if ! label=$(zro_trace_label "$filter"); then
    zro_log error "denied, no such delivery trace filter: $filter"
    return "$ZRO_E_DENIED"
  fi
  [ -n "$subject" ] || return "$ZRO_E_INPUT"
  # Every validator above refuses a leading '-' already. Refused here too, at the
  # one point all three filters pass through, so that a filter added later cannot
  # forget it and hand the tracer a value it would read as a flag.
  case $subject in -*) return "$ZRO_E_INPUT" ;; esac
  case $ws in ''|*[!0-9]*) return "$ZRO_E_INPUT" ;; esac
  case $we in ''|*[!0-9]*) return "$ZRO_E_INPUT" ;; esac
  # An end before its start is a caller defect. Searching the empty window it
  # describes would answer "nothing arrived" to a question nobody asked.
  [ "$ws" -le "$we" ] || return "$ZRO_E_INPUT"

  # Third escaping layer, on EVERY filter rather than on the first one written.
  # The gate already keeps this out of a shell, and a validator has already
  # refused anything that is not the kind of value it claims to be — but every
  # filter this tool takes is a regular expression, so a value carrying a
  # quantifier would otherwise fail to match itself.
  #
  # Escaped but deliberately NOT anchored. Anchoring would need to be right about
  # what the tool matches the pattern against, and nobody here has read that; get
  # it wrong and every trace silently finds nothing, which is the one failure this
  # screen may not have. Unanchored, the cost runs the other way and is visible:
  # a value that is a substring of another can pull in a neighbour's message, and
  # the report shown below names every recipient it matched. Anchoring waits on
  # the same capture as the table view.
  local pattern from to from_h to_h
  pattern=$(zro_regex_quote "$subject")
  from=$(zro_trace_stamp "$ws") || return "$ZRO_E_UNAVAILABLE"
  to=$(zro_trace_stamp "$we") || return "$ZRO_E_UNAVAILABLE"
  # The window as the operator will read it, resolved BEFORE any file is opened.
  # Interpolating these into the header instead would let a clock that stopped
  # answering print a report headed by a blank range — in a report whose whole
  # purpose is stating which window was searched. Better to refuse than to answer
  # about a window nobody can see.
  from_h=$(zro_win_human "$ws") || return "$ZRO_E_UNAVAILABLE"
  to_h=$(zro_win_human "$we") || return "$ZRO_E_UNAVAILABLE"

  # Which files the window covers. The syslog family only: the tracer parses
  # postfix and amavis lines, and those land in no other log in the inventory.
  #
  # Selection is what turns the window into a file list, and it is pure — the
  # off-by-one that rotation's early-morning schedule invites is checked in
  # tests/test_inventory.sh without a filesystem, not here.
  local selected rc=0
  selected=$(zro_inv_discover syslog | zro_inv_select "$ws" "$we") || rc=$?
  # Passed through rather than flattened: a name the inventory does not declare
  # and a root that fails admission are defects in this program, and each has
  # already been logged where it was found.
  [ "$rc" -eq 0 ] || return "$rc"

  if [ -z "$selected" ]; then
    # Every window intersects something as long as one file exists — the oldest
    # file in a family has no lower bound and the newest no upper one — so an
    # empty selection means the inventory found no file at all. That is a log
    # this tool could not read, not a window with nothing in it, and answering
    # "no records" here would be exactly the ambiguity this feature exists to
    # remove. The ticket after next probes this before the menu entry is offered.
    zro_log error "no log file to trace: the inventory found none for $(zro_inv_base_path syslog)"
    return "$ZRO_E_NO_LOG"
  fi

  local err out mapped said line year path reason
  local bodies='' scanned='' total=0 count files=0
  # The skipped files as the banner prints them, and how many there are. Two names
  # for one fact, and no third: what the error file needs is this same list, so it
  # is derived below rather than accumulated a second way that could disagree.
  local skipped='' skipped_n=0
  err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # The shape zro_inv_select emits: the year it derived, then the path.
    year=${line%%"$ZRO_TAB"*}
    path=${line#*"$ZRO_TAB"}

    rc=0
    : >"$err"
    # The filter comes first, because it is the operation the allowlist approves;
    # the window, the year and the file follow it as this program's own arguments.
    # The path needs no '--' before it: nothing enters the inventory that does not
    # begin with '/'.
    #
    # stdin is closed for the child. This loop reads the selection from a
    # heredoc, and a program that read from it would consume the files it has not
    # been asked about yet.
    out=$(zro_trace_exec "$filter" "$pattern" \
            --time "$from,$to" --year "$year" "$path" \
            2>"$err" </dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
      mapped=$(zro_trace_outcome_code "$err" "$rc")
      if [ "$mapped" != "$ZRO_E_NO_LOG" ]; then
        # Not a file the tracer could not open, so nothing is known about what was
        # covered. Refused whole, with whatever the tool said, so the failure
        # reaches the operator as its own cause rather than as a bare exit code.
        # Nothing has been printed yet, which is what makes that a refusal.
        said=$(head -c "$ZRO_ERROR_KEEP_BYTES" -- "$err" 2>/dev/null)
        # A refusal may abandon the answer; it may not abandon the disclosure. Any
        # file already skipped is named in the failure the operator is shown,
        # because the one thing this screen may never do is let a skipped file go
        # unmentioned — whichever way the operation ends.
        [ "$skipped_n" -eq 0 ] || said="$said
Okunamayan log dosyalari:$skipped"
        zro_set_error "$said"
        rm -f -- "$err"
        return "$mapped"
      fi

      # A file the tracer could not open: skipped, and said out loud three times
      # over — here in the activity log for whoever reads it afterwards, in the
      # banner above the answer, and in the title of the screen that carries it.
      #
      # The tool's own first non-empty line is kept as the reason, because the cause
      # is almost always a permission an administrator can repair and a reason of
      # "could not be read" would send them looking for it. Bounded: the tracer
      # writes one line, but a reason of unknown length would push the answer off
      # the screen this banner exists to qualify.
      reason=$(grep -m 1 -v '^[[:space:]]*$' -- "$err" 2>/dev/null | cut -c 1-200)
      # The log line stays English like every other line in it; the banner's
      # fallback below is operator-facing and therefore Turkish. One variable
      # serving both would have to pick a language for the wrong reader.
      zro_log warn "log skipped, the tracer could not open it: $path (${reason:-no message on stderr})"
      [ -n "$reason" ] || reason='(sebep bildirilmedi)'
      skipped_n=$((skipped_n + 1))
      skipped="$skipped
         $path
           $reason"
      continue
    fi
    files=$((files + 1))

    count=$(zro_trace_message_count "$out")
    total=$((total + count))
    # Each file with what was found in it, so the total below is visibly a sum
    # rather than a claim about distinct messages. It cannot be a claim about
    # distinct messages: the tracer re-initialises per file, so a message whose
    # hops straddle a rotation is introduced once in each file and counted twice.
    # Telling them apart would mean parsing the report further, and no output from
    # a real server has been captured to parse against.
    scanned="$scanned
                 $path ($count)"
    # Each file's report is rendered as it arrived, under a line naming the file
    # it came from. That heading is not decoration: the tracer re-initialises per
    # file, so a message whose hops straddle a rotation is reported as fragments,
    # and an operator who cannot see which file a fragment came from has no way
    # to know that is what they are looking at.
    bodies="$bodies
----- $path -----
$out
"
  done <<EOF
$selected
EOF
  rm -f -- "$err"

  # NOT ONE FILE WAS READ. That is a log this tool could not read, not a partial
  # scan: a partial scan is an answer with a hole in it, and here there is no
  # answer at all. Reported as the log failure, with the tool's own words kept so
  # the screen can name the cause and the repair, and with no output whatsoever.
  if [ "$files" -eq 0 ]; then
    # The same list the banner would have printed, so the cause reaches the screen
    # named file by file rather than as "the log could not be read".
    zro_set_error "$(printf 'Okunamayan log dosyalari:%s' "$skipped" | head -c "$ZRO_ERROR_KEEP_BYTES")"
    return "$ZRO_E_NO_LOG"
  fi
  zro_clear_error

  # An empty answer is an empty answer only when nothing was missed. With a file
  # skipped it is a partial scan, disclosed below and reported as one — because
  # "no records" from a scan that could not open half its files is how an operator
  # concludes a message never arrived and goes on to make the wrong decision.
  if [ "$total" -eq 0 ] && [ "$skipped_n" -eq 0 ]; then
    return "$ZRO_E_NO_RESULT"
  fi

  # Said out loud whenever more than one file was read, because that is when the
  # total stops being the number of distinct messages. Not said when one file was
  # read, where it would be a caveat about nothing.
  local caveat=''
  if [ "$files" -gt 1 ]; then
    caveat='
                 (toplam, dosya basina bulunanlarin toplamidir: rotasyon
                  sinirini asan bir ileti her iki dosyada birer kez gorunur)'
  fi

  # FIRST, above the answer it qualifies, for the reason the function says.
  zro_trace_partial_banner "$files" "$skipped_n" "$skipped"

  # Padded to the width the lines below it use, so the labels line up whichever
  # question was asked.
  printf '%-15s: %s\n' "$label" "$subject"
  printf 'Varis araligi  : %s - %s\n' "$from_h" "$to_h"
  printf '                 (aralik iletinin sunucuya VARIS zamanina gore\n'
  printf '                  uygulanir; aralik oncesinde varip aralik icinde\n'
  printf '                  teslim edilen bir ileti bu listede yer almaz)\n'
  printf 'Bulunan ileti  : %s\n' "$total"
  printf 'Taranan log    : %s dosya%s%s\n' "$files" "$scanned" "$caveat"
  # Unmodified, on purpose: what follows is what the server said. Reformatting it
  # would risk dropping something nobody has looked at yet.
  printf '%s\n' "$bodies"

  # The answer is out, and it is not a complete one. The banner says so to the
  # operator; this says so to the caller, which is how the screen knows to mark its
  # title. $ZRO_E_PARTIAL has been defined in lib/core.sh since M1 with no user;
  # this is it.
  [ "$skipped_n" -eq 0 ] || return "$ZRO_E_PARTIAL"
  return 0
}

# The three questions, each with its own validator and nothing else of its own.
#
#   $1  the value, as the operator typed it
#   $2  window start, an absolute local timestamp in seconds
#   $3  window end, the same
#
# A wrapper is thin on purpose: it decides what a valid value IS for its
# question, and hands the rest to the engine above. Nothing here re-decides how
# a window is searched, and nothing here quotes — the engine does that for every
# filter, once.
#
# The window is left to the engine to judge as well, so that a malformed one is
# the same refusal whichever door it arrives at.
#
# A path is never taken from a caller: the files come from the log inventory, so
# a fourth argument is ignored rather than trusted.
zro_trace_recipient() {
  zro_validate_email "${1-}" || return "$ZRO_E_INPUT"
  zro_trace_run --recipient "${1-}" "${2-}" "${3-}"
}

# Whether a user's own message actually left. The same validator as the
# recipient: a sender is an address, and the tracer matches it case-insensitively
# just as it does a recipient.
zro_trace_sender() {
  zro_validate_email "${1-}" || return "$ZRO_E_INPUT"
  zro_trace_run --sender "${1-}" "${2-}" "${3-}"
}

# The precise question, for an operator holding a bounce report or a forwarded
# header. The identifier is unwrapped before it is validated, so that the value
# judged is the value that will actually be searched for — '<>' and nothing else
# is refused rather than turned into a filter matching everything.
#
# CASE-SENSITIVE, alone among the three, and untouched here: the screen says so,
# because an operator who retypes an identifier in the wrong case would otherwise
# get an empty result that reads as a definitive answer.
zro_trace_msgid() {
  local id
  id=$(zro_trace_msgid_bare "${1-}")
  zro_validate_msgid "$id" || return "$ZRO_E_INPUT"
  zro_trace_run --id "$id" "${2-}" "${3-}"
}
