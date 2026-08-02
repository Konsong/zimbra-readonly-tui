# shellcheck shell=bash
# THE MAIL QUEUE: what is waiting on this server, read with the listing form of
# the queue tool and no other.
#
# It answers the question a delivery trace cannot: a message that is neither
# delivered nor lost but STILL HERE, waiting for a remote host that is refusing,
# a name that does not resolve, or a queue that was put on hold. The trace reads
# what the log says happened; this reads what has not finished happening yet.
[ -n "${ZRO_LIB_QUEUE_LOADED:-}" ] && return 0
ZRO_LIB_QUEUE_LOADED=1

# THE WRITING FORMS LIVE IN THE SAME BINARY, which is the whole reason this
# module is written the way it is. `postqueue -f` flushes the deferred queue,
# `-s` flushes one site, `-i` requeues one message and `-d` deletes: each of them
# makes the transfer agent act — mail leaves, a remote host is contacted, bounces
# are generated — and none of them is on the allowlist. The listing form is
# approved as the whole operation, so nothing an operator does on these screens
# can reach a second form of the tool.
#
# WHAT IT COSTS is one invocation, whatever the queue holds. The tool's own work
# grows with the queue and this program's does not, which is why the screen
# answers with counts first: a queue with thousands of entries is unreadable as a
# list and perfectly readable as four numbers.
#
# ITS ACCESS-CONTROL SETTING IS THE HOST'S ANSWER, NEVER OURS. Postfix reads
# `authorized_mailq_users` inside the binary, after the gate has already approved
# the operation, so a site that has narrowed it gets a tool that is present,
# executable and refuses. That is not an allowlist denial — which in this program
# means a defect — and the two are kept apart below, because they send whoever
# reads the screen to different files.

# How many entries the detail behind the counts may show. Overridable like every
# other bound here, and judged before it is used.
ZRO_QUEUE_DETAIL_MAX="${ZRO_QUEUE_DETAIL_MAX:-50}"

# THE THREE STATUSES A LISTING CAN SAY, and how each is read.
#
# Postfix writes the status as a CHARACTER APPENDED TO THE QUEUE ID: '*' for a
# message the transfer agent is delivering now, '!' for one held back, and
# nothing at all for everything else. Captured from the lab server rather than
# taken from the manual page — a listing of two deferred messages and one placed
# on hold is in tests/fixtures/postqueue_p_deferred_hold.txt.
#
# THE UNMARKED CASE IS NAMED FOR WHAT IT REALLY IS, which is not quite
# 'deferred'. An entry that carries no marker is one that is neither being
# delivered nor held: almost always a deferred message, and possibly one that has
# just arrived and has not been picked up yet. The structured form of this same
# listing carries the queue's real name as a field and would tell those two
# apart; this form cannot, so the label says both rather than picking the likely
# one and being wrong on a busy morning.
zro_queue_status_label() {
  case ${1-} in
    waiting) printf 'Bekleyen (ertelenmis)' ;;
    hold)    printf 'Tutulan (hold)' ;;
    active)  printf 'Gonderilen (active)' ;;
    *) return 1 ;;
  esac
}

# The status an id token declares, or a refusal.
#
# Pure: a token in, a word out. A token that is not an id with an optional marker
# on it is refused rather than read as unmarked — an id this reader cannot make
# sense of is a listing this reader does not understand, and reporting it as a
# waiting message would be inventing an entry.
zro_queue_status() {
  local tok=${1-} status=waiting
  [ -n "$tok" ] || return "$ZRO_E_INPUT"
  case $tok in
    *'*') status=active; tok=${tok%'*'} ;;
    *'!') status=hold;   tok=${tok%'!'} ;;
  esac
  # Short ids are hexadecimal and long ones — on a site that enabled them — are
  # alphanumeric, so the id is judged as alphanumeric text rather than as hex.
  # Nothing else may stand here: a line whose first word carries punctuation is
  # not an entry line.
  case $tok in
    ''|*[!A-Za-z0-9]*) return "$ZRO_E_INPUT" ;;
  esac
  printf '%s' "$status"
}

# Whether one line opens a queue entry.
#
# THREE THINGS IN THE LISTING ARE NOT ENTRIES and every one of them would be read
# as one by a looser rule: the column header, the closing summary line, and the
# single sentence an empty queue answers with. So an entry line is one that
# begins in column 1 with an id this module can read, followed by a SIZE IN
# DIGITS — which is what 'Mail queue is empty' fails on, and what a reason line
# wrapped to column 1 fails on too.
zro_queue_is_entry() {
  local line=${1-} id size rest
  case $line in
    ''|[!A-Za-z0-9]*) return 1 ;;
  esac
  read -r id size rest <<EOF
$line
EOF
  case $size in
    ''|*[!0-9]*) return 1 ;;
  esac
  zro_queue_status "$id" >/dev/null
}

# ONE ROW PER ENTRY, as the fields this program reads out of the tool's own
# layout:
#
#   status <tab> id <tab> size <tab> arrival <tab> sender <tab> recipients <tab> reason
#
# THE LAYOUT IS THE HARD PART, and the fixture is what settles it. The reason a
# message is waiting sits BETWEEN the sender and the recipient rather than after
# the entry, and its INDENTATION IS NOT STABLE: a long reason wraps the field and
# starts at column 1, a short one is indented twelve spaces. A reader keyed on
# the indent finds one of them and silently misses the other.
#
# So the two lines below an entry are told apart by what they ARE rather than by
# where they sit: a reason begins with '(' once its indentation is removed, and a
# recipient is a single word carrying '@'. Anything else is left alone, because a
# line this reader does not recognise is not an invitation to guess.
zro_queue_rows() {
  local listing=${1-} line trimmed
  local id='' status='' size='' arrival='' sender='' rcpts='' reason=''
  local tok rest dow mon day tim

  while IFS= read -r line; do
    if zro_queue_is_entry "$line"; then
      zro_queue_row "$status" "$id" "$size" "$arrival" "$sender" "$rcpts" "$reason"
      rcpts=''; reason=''
      read -r tok size dow mon day tim rest <<EOF
$line
EOF
      status=$(zro_queue_status "$tok")
      id=${tok%'*'}; id=${id%'!'}
      # The four words of the arrival time, with the listing's column padding
      # gone: the tool pads the day so its columns line up, and a card has no
      # columns to line up with. Nothing here parses the date — there is no year
      # on that line, so any date this program computed from it would be a guess
      # about which one.
      arrival="$dow $mon $day $tim"
      sender=$rest
      continue
    fi
    trimmed=${line#"${line%%[![:space:]]*}"}
    case $trimmed in
      '') continue ;;
      '('*)
        # Quoted, so the parentheses are stripped as the literal characters they
        # are rather than read as pattern syntax by a shell that has extglob on.
        reason=${trimmed#'('}
        reason=${reason%')'}
        continue ;;
    esac
    case $trimmed in
      *' '*|*'	'*) continue ;;
      *@*) rcpts="${rcpts:+$rcpts, }$trimmed" ;;
    esac
  done <<EOF
$listing
EOF
  zro_queue_row "$status" "$id" "$size" "$arrival" "$sender" "$rcpts" "$reason"
}

# One row, or nothing at all when there is no entry in hand yet. Written as a
# function rather than repeated at the two places an entry ends — the next entry
# line and the end of the listing — because a row emitted in one of those places
# and not the other is a queue reported one entry short.
zro_queue_row() {
  [ -n "${2-}" ] || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${1-}" "${2-}" "${3-}" "${4-}" "${5-}" "${6-}" "${7-}"
}

zro_queue_total() {
  local rows=${1-} line n=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$((n + 1))
  done <<EOF
$rows
EOF
  printf '%s' "$n"
}

# How many entries carry one declared status. A status this module does not
# declare is refused rather than counted as zero: a screen asking for one is a
# defect in this program, and zero is an answer an operator would believe.
zro_queue_count() {
  local rows=${1-} want=${2-} line n=0
  zro_queue_status_label "$want" >/dev/null || return "$ZRO_E_INPUT"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "${line%%	*}" = "$want" ] && n=$((n + 1))
  done <<EOF
$rows
EOF
  printf '%s' "$n"
}

# ------------------------------------------------------ reaching the tool --

ZRO_QUEUE_TXT_DENIED='not allowed to view the mail queue'
# What Postfix exits with when its own access-control setting refuses the caller.
# EX_NOPERM from sysexits, and the only thing this tool exits it for.
ZRO_QUEUE_RC_DENIED=69

# Whether a failed run was the HOST refusing rather than anything going wrong.
#
#   $1  the status the run came back with   $2  what it said on stderr
#
# EITHER IS ENOUGH. Classification is on the message, as everywhere in this
# program, because a status cannot say which of a command's failures happened —
# but this one command exits 69 for this one reason, and a release that reworded
# the message must not turn a refusal into an unexplained failure. A release that
# changed the status must not either, so both are read.
zro_queue_refused() {
  local rc=${1-} said=${2-}
  [ "$rc" = "$ZRO_QUEUE_RC_DENIED" ] && return 0
  case $said in
    *"$ZRO_QUEUE_TXT_DENIED"*) return 0 ;;
  esac
  return 1
}

# THE LISTING, or the reason there is none.
#
# stdout is whatever the tool printed, unread: what it means is decided by the
# renderers above, and an empty queue is an answer rather than a failure.
#
# FOUR FAILURES, TOLD APART. A tool this build does not have is the gate's
# $ZRO_E_NOCAP and stays that; a refusal by the host's own access-control setting
# becomes $ZRO_E_PERM and is remembered for the session, so the menu can say so
# before an operator spends another one; a timeout is the gate's and travels as
# itself; anything else is a queue that could not be read.
zro_queue_fetch() {
  local out err rc=0 said
  err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"
  out=$(zro_exec postqueue -p 2>"$err") || rc=$?
  said=$(head -c 500 -- "$err" 2>/dev/null)
  rm -f -- "$err"

  if [ "$rc" -ne 0 ]; then
    [ -z "$said" ] || zro_set_error "$said"
    if zro_queue_refused "$rc" "$said"; then
      # Recorded rather than only reported: the menu marks this entry from the
      # capability module, and a refusal learned by running the tool is the only
      # way this one can be learned at all. Reading the setting instead would
      # mean a second binary in the allowlist to answer a question the first one
      # already answers.
      zro_cap_queue_deny_record
      zro_log warn "mail queue refused by the host's own access-control setting"
      return "$ZRO_E_PERM"
    fi
    case $rc in
      "$ZRO_E_DENIED"|"$ZRO_E_BADUSER"|"$ZRO_E_NOCAP"|"$ZRO_E_TIMEOUT")
        return "$rc" ;;
    esac
    zro_log warn "mail queue unreadable (${said:-no message on stderr})"
    return "$ZRO_E_UNAVAILABLE"
  fi
  zro_clear_error
  printf '%s' "$out"
}

# --------------------------------------------------- what an operator reads --

ZRO_QUEUE_TXT_MARKERS="Durum, kuyruk kimliginin yanindaki isaretten okunur: '*' su anda
gonderiliyor, '!' elle tutuluyor, isaretsiz kayit ise ertelenmis ya da
siraya yeni girmistir."

ZRO_QUEUE_TXT_READONLY='Bu ekran kuyrugu YALNIZCA LISTELER. Kuyrugu bosaltan, bir kaydi yeniden
siraya alan, teslimi hemen baslatan veya bir kaydi silen komutlar bu araca
alinmamistir: bunlar teslimi tetikler, yani sunucunun yaptigi isi degistirir.'

# COUNTS FIRST, DETAIL BEHIND THEM.
#
# On a busy server this queue holds thousands of entries, and a list of thousands
# is not an answer — it is the same problem in a different window. What an
# operator arrives with is 'is mail piling up', and three numbers answer it.
zro_queue_summary_card() {
  local listing=${1-} rows total
  rows=$(zro_queue_rows "$listing")
  total=$(zro_queue_total "$rows")

  zro_card_line 'Kuyruktaki kayit' "$total"
  printf '\n'
  zro_card_line 'Bekleyen (ertelenmis)' "$(zro_queue_count "$rows" waiting)"
  zro_card_line 'Tutulan (hold)' "$(zro_queue_count "$rows" hold)"
  zro_card_line 'Gonderilen (active)' "$(zro_queue_count "$rows" active)"

  printf '\n'
  if [ "$total" -eq 0 ]; then
    # A RESULT, and one an operator reads as good news. Said as its own paragraph
    # rather than left to a row of zeroes, which reads as a screen that failed to
    # find anything.
    printf 'Kuyruk bos: bu sunucuda teslim edilmeyi bekleyen ileti yok.\n'
    printf '\n'
    printf 'Bu, hicbir iletinin kaybolmadigi anlamina GELMEZ; kuyruktan cikmis bir\n'
    printf 'ileti icin teslim takibi ve log ekranlarina bakin.\n'
  else
    printf '%s\n' "$ZRO_QUEUE_TXT_MARKERS"
  fi
  printf '\n'
  printf '%s\n' "$ZRO_QUEUE_TXT_READONLY"
}

# THE DETAIL, BOUNDED, with the bound said out loud.
#
# A truncation nobody is told about is the same mistake the log viewer's header
# exists to prevent: an operator who reads fifty entries and concludes the
# fifty-first is not there has been misled by this screen rather than by the
# server.
zro_queue_detail_card() {
  local listing=${1-} rows total n=$ZRO_QUEUE_DETAIL_MAX shown=0 line
  local status id size arrival sender rcpts reason human

  case $n in
    ''|*[!0-9]*) zro_log error "denied, queue detail bound is not a count: $n"
                 return "$ZRO_E_INPUT" ;;
  esac
  if [ "$n" -eq 0 ]; then
    zro_log error "denied, queue detail bound is zero"
    return "$ZRO_E_INPUT"
  fi

  rows=$(zro_queue_rows "$listing")
  total=$(zro_queue_total "$rows")
  [ "$total" -gt 0 ] || return "$ZRO_E_NO_RESULT"

  if [ "$total" -gt "$n" ]; then
    printf 'Kuyrukta %s kayit var; ilk %s tanesi gosteriliyor. Geri kalani bu\n' "$total" "$n"
    printf 'ekranda YOKTUR — kuyrugun tamami degil, bir bolumu okunuyor.\n'
  else
    printf 'Kuyrukta %s kayit var; hepsi gosteriliyor.\n' "$total"
  fi
  printf '\n'

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "$shown" -lt "$n" ] || break
    shown=$((shown + 1))
    status=${line%%	*};   line=${line#*	}
    id=${line%%	*};       line=${line#*	}
    size=${line%%	*};     line=${line#*	}
    arrival=${line%%	*};  line=${line#*	}
    sender=${line%%	*};   line=${line#*	}
    rcpts=${line%%	*};    reason=${line#*	}

    human=$(zro_human_bytes "$size") || human="$size"
    zro_card_line 'Kuyruk kimligi' "$id"
    zro_card_line 'Durum' "$(zro_queue_status_label "$status")"
    zro_card_line 'Boyut' "$human"
    zro_card_line 'Varis' "$arrival"
    zro_card_line 'Gonderen' "$sender"
    zro_card_line 'Alici' "$rcpts"
    # ABSENT RATHER THAN INVENTED: an entry that has not been attempted yet
    # carries no reason at all, and a dash under a label an operator is reading
    # for a cause is better than a sentence this program made up.
    [ -n "$reason" ] && zro_card_line 'Sebep' "$reason"
    printf '\n'
  done <<EOF
$rows
EOF
}
