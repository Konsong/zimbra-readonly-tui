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
# through when it recognises nothing. Same shape as zro_prov_fail_code in
# lib/account.sh, and for the same reason: an operator who is shown a bare status
# has to reproduce the command by hand to learn what went wrong.
#
# A log the tool cannot open is the one failure worth naming. It dies with
# "unable to open file" on stderr and no exit status of its own, so the message is
# the only signal there is. That text comes from the tool's source as documented
# in docs/research/2026-07-29-zimbra-cli-read-only-reference.md §B.11 rather than
# from a capture, which is why the match lives here alone and stays this narrow.
zro_trace_fail_code() {
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

# Traces delivery for one recipient address inside an arrival window.
#
#   $1  recipient address, as the operator typed it
#   $2  window start, an absolute local timestamp in seconds
#   $3  window end, the same
#
# ONE INVOCATION PER SELECTED FILE, each carrying the year derived from that
# file's own modification time. The tracer guesses the year once, globally, from
# the local clock, so a time-bounded search of a rotated log otherwise returns
# nothing at all — silently. And because it re-initialises its parser state per
# file, handing it several files at once never chained a message across a rotation
# boundary in the first place: splitting the invocation costs no capability and
# removes the year defect outright.
#
# A SELECTED FILE THAT CANNOT BE READ REFUSES THE WHOLE OPERATION. Strict, and
# never silent: a report assembled from two of three files reads exactly like a
# complete answer, and an operator who concludes from it that a message never
# arrived goes on to make the wrong decision. The next ticket replaces this with a
# partial scan, which discloses the skipped files instead of refusing — the same
# rule, kept honest at less cost.
zro_trace_recipient() {
  local addr=${1-} ws=${2-} we=${3-}
  zro_validate_email "$addr" || return "$ZRO_E_INPUT"
  case $ws in ''|*[!0-9]*) return "$ZRO_E_INPUT" ;; esac
  case $we in ''|*[!0-9]*) return "$ZRO_E_INPUT" ;; esac
  # An end before its start is a caller defect. Searching the empty window it
  # describes would answer "nothing arrived" to a question nobody asked.
  [ "$ws" -le "$we" ] || return "$ZRO_E_INPUT"

  # Third escaping layer. The gate already keeps this out of a shell, and the
  # validator has already refused anything that is not an address — but every
  # filter this tool takes is a regular expression, so an address carrying a
  # quantifier would otherwise fail to match itself.
  #
  # Escaped but deliberately NOT anchored. Anchoring would need to be right about
  # what the tool matches the pattern against, and nobody here has read that; get
  # it wrong and every trace silently finds nothing, which is the one failure this
  # screen may not have. Unanchored, the cost runs the other way and is visible:
  # an address that is a substring of another can pull in a neighbour's message,
  # and the report shown below names every recipient it matched. Anchoring waits
  # on the same capture as the table view.
  local pattern from to from_h to_h
  pattern=$(zro_regex_quote "$addr")
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

  local err out mapped line year path
  local bodies='' scanned='' total=0 count files=0
  err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # The shape zro_inv_select emits: the year it derived, then the path.
    year=${line%%"$ZRO_TAB"*}
    path=${line#*"$ZRO_TAB"}
    files=$((files + 1))

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
    out=$(zro_exec zmmsgtrace --recipient "$pattern" \
            --time "$from,$to" --year "$year" "$path" \
            2>"$err" </dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
      # Whatever the tool said, so an unreadable log reaches the operator as its
      # own cause rather than as a bare exit code.
      zro_set_error "$(head -c 500 -- "$err" 2>/dev/null)"
      mapped=$(zro_trace_fail_code "$err" "$rc")
      rm -f -- "$err"
      # Nothing has been printed yet, which is the point: the refusal above is
      # only a refusal if no half-answer escapes with it.
      return "$mapped"
    fi

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
  zro_clear_error

  [ "$total" -gt 0 ] || return "$ZRO_E_NO_RESULT"

  # Said out loud whenever more than one file was read, because that is when the
  # total stops being the number of distinct messages. Not said when one file was
  # read, where it would be a caveat about nothing.
  local caveat=''
  if [ "$files" -gt 1 ]; then
    caveat='
                 (toplam, dosya basina bulunanlarin toplamidir: rotasyon
                  sinirini asan bir ileti her iki dosyada birer kez gorunur)'
  fi

  printf 'Alici          : %s\n' "$addr"
  printf 'Varis araligi  : %s - %s\n' "$from_h" "$to_h"
  printf '                 (aralik iletinin sunucuya VARIS zamanina gore\n'
  printf '                  uygulanir; aralik oncesinde varip aralik icinde\n'
  printf '                  teslim edilen bir ileti bu listede yer almaz)\n'
  printf 'Bulunan ileti  : %s\n' "$total"
  printf 'Taranan log    : %s dosya%s%s\n' "$files" "$scanned" "$caveat"
  # Unmodified, on purpose: what follows is what the server said. Reformatting it
  # would risk dropping something nobody has looked at yet.
  printf '%s\n' "$bodies"
}
