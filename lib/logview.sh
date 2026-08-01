# shellcheck shell=bash
# The bounded log viewer: the last portion of one file from the log inventory.
#
# It exists for the lines the delivery trace does not parse — mailboxd's own
# account of what it did with a message, an authentication failure, a Postfix
# line the tracer's regexes ignore. Nothing here opens a mailbox and nothing here
# reaches a Zimbra binary.
[ -n "${ZRO_LIB_LOGVIEW_LOADED:-}" ] && return 0
ZRO_LIB_LOGVIEW_LOADED=1

# TWO PROPERTIES, AND THE WHOLE MODULE IS THEM.
#
# WHICH FILE. Every path read here has to be one the log inventory found under a
# declared root, listed under the name it was found by. The operator never types
# a path — the screen offers a list and hands back a position in it — and this
# module refuses a path the inventory does not list even so. Without that second
# check the viewer is a general-purpose file reader wearing a menu, and a glob, a
# symbolic link or an oddly named neighbour is all it would take.
#
# HOW MUCH OF IT. A BOUNDED READ: the last lines only, with the bound applied by
# the command that reads the file rather than afterwards. A mail log on a busy
# server is measured in hundreds of megabytes; reading one whole and trimming it
# here would hang the tool and take the server's memory with it.
#
# A COMPRESSED ROTATED FILE IS READ THROUGH `gzip -dc` AND NOTHING ELSE. That is
# the one form which writes to stdout and leaves the file where it was. The bare
# command and the in-place decompression are absent from the allowlist and
# therefore refused, because both replace the file and delete the original — a
# write, by a command nobody suspects. See the allowlist in lib/exec.sh.

# How many lines a bounded read is. Overridable like every other bound here,
# and judged before it is used: this value reaches a command line.
ZRO_LOGVIEW_LINES="${ZRO_LOGVIEW_LINES:-500}"

# What each declared log is called on screen, and what it holds.
#
# The inventory owns WHICH logs exist; this owns what they are called. Neither
# can check the other at run time without reaching into its business, so the
# suite holds the two sets equal instead — the same arrangement as the arrival
# window's presets and the menu that offers them.
zro_logview_label() {
  case ${1-} in
    syslog)  printf 'Mail logu (postfix, amavis, kimlik dogrulama)' ;;
    mailbox) printf 'Mailbox logu (mailboxd: LMTP teslimi ve hatalar)' ;;
    audit)   printf 'Kimlik dogrulama logu (girisler ve basarisiz denemeler)' ;;
    *) return 1 ;;
  esac
}

# One declared log's files, NEWEST FIRST.
#
#   $1      a name declared in ZRO_INVENTORY
#   stdout  "<modification time>\t<path>", newest first
#
# The opposite order to the inventory's, and deliberately: selection reads a
# family oldest-first because a file's coverage interval starts at the previous
# file's timestamp, while an operator opening a log almost always wants the one
# being written. Reversed here rather than in the inventory, so that the order a
# screen finds convenient cannot change what a trace selects.
zro_logview_files() {
  local listed rc=0
  listed=$(zro_inv_discover "${1-}") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ -n "$listed" ] || return 0
  # Reversed by the module that owns the format, not by a second sort here that
  # could be left behind when the tie-break changes.
  printf '%s\n' "$listed" | zro_inv_sort_pairs_desc
}

# One file as an operator picks it: when it was last written to, its name, and
# whether it is compressed.
#
#   $1  the file's modification time      $2  its path
#
# The TIME is what makes the list usable. A list of paths alone would leave an
# operator working out which rotation holds yesterday — the very thing the
# inventory exists to save them — and the numbering says nothing, since rotation
# runs in the early morning and .1 holds the day before its own date.
#
# Rendered through the clock accessor directly rather than through
# zro_win_human: that one renders an arrival window's bounds to the second,
# because a window is an argument to a search. This is a file in a list.
zro_logview_file_label() {
  local mtime=${1-} path=${2-} when name
  when=$(zro_clock_fmt '%Y-%m-%d %H:%M' "$mtime") || when='(zaman okunamadi)'
  name=${path##*/}
  case $path in
    *.gz) printf '%s  %s  (sikistirilmis)' "$when" "$name" ;;
    *)    printf '%s  %s' "$when" "$name" ;;
  esac
}

# Whether the inventory lists this exact path under this exact name.
#
#   $1  a name declared in ZRO_INVENTORY   $2  an absolute path
#
# The PAIR has to agree, not just the path. A file is read as a rotation of the
# log it was listed under; a caller that named the wrong one is a defect in this
# program, and answering it would mean this module deciding for itself which log
# a path belongs to.
#
# Whole-line comparison, never a prefix: every rotation variant of a log begins
# with the base name, so "starts with" would admit exactly the neighbours the
# inventory refused.
zro_logview_declared() {
  local key=${1-} path=${2-} listed rc=0 line
  listed=$(zro_inv_discover "$key") || rc=$?
  # A name the inventory does not declare, or a root that fails admission. Both
  # have already been logged where they were found.
  [ "$rc" -eq 0 ] || return "$rc"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "${line#*"$ZRO_TAB"}" = "$path" ] && return 0
  done <<EOF
$listed
EOF
  zro_log error "denied, not a file the inventory lists for $key: $path"
  return "$ZRO_E_DENIED"
}

# The last lines of one declared log file.
#
#   $1      a name declared in ZRO_INVENTORY
#   $2      a path that name's discovery listed
#   stdout  a header naming the file and the bound, then the lines
#
# THE HEADER IS PART OF THE ANSWER. A bounded read taken for a whole file is an
# absence nobody claimed: an operator who does not find a message in the last
# five hundred lines and concludes it never arrived has made exactly the mistake
# the delivery trace's banners exist to prevent, one screen over.
#
# An EMPTY FILE is an empty answer and reported as one. It is not a file that
# could not be read, and the two must not arrive as the same screen: a log the
# tool could not open says nothing about the server, while an empty one says the
# server wrote nothing there.
#
# A GATE REFUSAL IS PASSED THROUGH RATHER THAN FLATTENED. A binary this host does
# not have, an unsupported user, a timeout — none of those is a log that cannot
# be read, and an operator sent to zmfixperms over a missing `tail` would repair
# nothing.
zro_logview_read() {
  local key=${1-} path=${2-} n=$ZRO_LOGVIEW_LINES

  # Judged before anything else: it reaches a command line, and a bound that is
  # not a count is a defect in whatever set it rather than a reason to fall back
  # to a default nobody chose.
  case $n in
    ''|*[!0-9]*) zro_log error "denied, log line bound is not a count: $n"
                 return "$ZRO_E_INPUT" ;;
  esac
  if [ "$n" -eq 0 ]; then
    zro_log error "denied, log line bound is zero"
    return "$ZRO_E_INPUT"
  fi

  if [ -z "$key" ]; then
    zro_log error "denied, no log name given to the viewer"
    return "$ZRO_E_DENIED"
  fi
  # The inventory's own admission, applied here as well as where the path was
  # found. This is the function that hands a path to a program, and a path that
  # arrived some other way must meet the same rule as one that was globbed.
  if ! zro_inv_path_ok "$path"; then
    zro_log error "denied, log path outside the permitted set: $path"
    return "$ZRO_E_DENIED"
  fi
  zro_logview_declared "$key" "$path" || return $?

  local out err rc=0 said
  err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"
  case $path in
    *.gz)
      # Two gated commands, and the bound is the second one. The whole file is
      # decompressed — there is no way to read the end of a gzip stream without
      # it — but it is streamed through a reader that keeps only the last lines,
      # so what this costs is time on a large file and never memory.
      #
      # The path needs no '--' before it: nothing enters the inventory that does
      # not begin with '/'.
      #
      # pipefail is set HERE rather than relied on from the entry point. Without
      # it the status of this pipeline is the reader's, and the reader succeeds
      # on the empty input a failed decompression leaves it — so a file that
      # could not be decompressed would arrive as an empty log, which is the one
      # answer this module may not invent.
      out=$( set -o pipefail
             zro_exec gzip -dc "$path" 2>"$err" | zro_exec tail -n "$n" 2>>"$err" ) || rc=$?
      ;;
    *)
      out=$(zro_exec tail -n "$n" "$path" 2>"$err") || rc=$?
      ;;
  esac
  said=$(head -c 500 -- "$err" 2>/dev/null)
  rm -f -- "$err"

  if [ "$rc" -ne 0 ]; then
    [ -z "$said" ] || zro_set_error "$said"
    case $rc in
      "$ZRO_E_DENIED"|"$ZRO_E_BADUSER"|"$ZRO_E_NOCAP"|"$ZRO_E_TIMEOUT"|"$ZRO_E_UNAVAILABLE")
        return "$rc" ;;
    esac
    zro_log warn "log unreadable: $path (${said:-no message on stderr})"
    return "$ZRO_E_NO_LOG"
  fi
  zro_clear_error
  [ -n "$out" ] || return "$ZRO_E_NO_RESULT"

  printf 'Dosya          : %s\n' "$path"
  printf 'Gosterilen     : son %s satir (dosyanin TAMAMI DEGILDIR; aranan kayit\n' "$n"
  printf '                 bu satirlarin oncesinde olabilir)\n'
  printf -- '--------------------------------------------------------------------\n'
  # Unmodified, on purpose: what follows is what the file says.
  printf '%s\n' "$out"
}
