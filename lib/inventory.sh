# shellcheck shell=bash
# The log inventory: which of this host's logs are readable by this tool, and
# which of them an arrival window covers. Reads no log content, runs no Zimbra
# binary, and opens no mailbox.
[ -n "${ZRO_LIB_INVENTORY_LOADED:-}" ] && return 0
ZRO_LIB_INVENTORY_LOADED=1

# Two parts, deliberately split.
#
# SELECTION is pure: path-and-timestamp pairs and an arrival window in, the files
# to read and the year to stamp on each out. It opens no file and asks nothing
# what time it is now — the only clock it consults is the one in its input — which
# is what makes the off-by-one this module exists to prevent testable for the
# price of a string rather than a fixture tree.
#
# DISCOVERY is a thin shell around a glob. It stats what is on disk and emits the
# same shape, and it decides nothing.
#
# Base names are declared HERE, in code. The environment decides WHERE the logs
# are; it never decides WHICH ones are read. That is the same split as
# ZRO_ZIMBRA_BIN versus ZRO_ALLOW in lib/exec.sh, and it is required rather than
# tidy: the tracer opens a compressed file by interpolating its name into a
# /bin/sh command line, unescaped.
#
# stat, sort and date are called directly rather than through the exec gate, for
# the reason ADR-0002 gives for timeout and id: they are this program's own
# plumbing, not an operation an operator chose. Everything an operator picks — the
# tracer, the tail, the decompression — still goes through the gate.

# Where the logs are. Production defaults, overridable so the suite can point at
# a fixture tree. The first is a file because that is what the tracer defaults to
# and what an operator overrides; the second is a directory.
ZRO_SYSLOG_FILE="${ZRO_SYSLOG_FILE:-/var/log/zimbra.log}"
ZRO_LOG_DIR="${ZRO_LOG_DIR:-/opt/zimbra/log}"
ZRO_STAT_BIN="${ZRO_STAT_BIN:-$(zro_first_existing /usr/bin/stat /bin/stat)}"

# The inventory, as "<base name>:<root variable>[/<path under it>]". The value
# names a VARIABLE, never a path, so every root stays overridable after this file
# has been sourced. A name absent from this table cannot be reached: there is no
# default root to fall back to, exactly as in ZRO_BIN_ROOTS.
#
# Three files, and the reasons for each:
#   syslog   the primary trace — Postfix, amavis and auth all land here
#   mailbox  mailboxd's own account, and the only sink LMTP delivery lines have
#   audit    authentication successes and failures
#
# The proxy log is deliberately ABSENT. Its rotation configuration is the only one
# that delays compression, so its most recent rotated file is plain text while
# every other file's is already gzipped. Excluding it keeps that inversion — the
# likeliest off-by-one in this area — out of the code entirely. The ActiveSync log
# and raw mailboxd output are absent for want of a reader, not a reason.
ZRO_INVENTORY='
syslog:ZRO_SYSLOG_FILE
mailbox:ZRO_LOG_DIR/mailbox.log
audit:ZRO_LOG_DIR/audit.log
'

zro_inv_entries() {
  printf '%s' "$ZRO_INVENTORY" | grep -v '^[[:space:]]*$'
}

zro_inv_keys() {
  zro_inv_entries | sed 's/:.*$//'
}

# Prints the absolute base path of one declared log, and fails when the name is
# not declared or the root it names is empty. Failure is never a fallback.
#
# Both failures are logged here rather than by the caller, for the same reason
# zro_bin_path logs its own: an inventory that quietly resolves to nothing reaches
# the operator as an empty answer, which is the one thing this feature may not
# produce.
zro_inv_base_path() {
  local key=${1-} entry spec=''
  [ -n "$key" ] || return 1

  while IFS= read -r entry; do
    # Quoted, so the comparison is literal text: a name carrying a glob
    # character cannot borrow another log's root.
    case $entry in
      "$key":?*) spec=${entry#*:}; break ;;
    esac
  done <<EOF
$(zro_inv_entries)
EOF
  if [ -z "$spec" ]; then
    zro_log error "denied, not a declared log: $key"
    return 1
  fi

  local var=${spec%%/*} under=''
  case $spec in
    */*) under="/${spec#*/}" ;;
  esac

  # Indirect expansion, not a nameref: namerefs are bash 4.3 and the floor is
  # 4.2. The name comes from the table above, never from anything an operator
  # typed, and the guard above is what keeps an empty name out of it.
  local root=${!var-}
  if [ -z "$root" ]; then
    zro_log error "denied, log root variable is empty: $var"
    return 1
  fi
  printf '%s%s' "$root" "$under"
}

# --- admission -------------------------------------------------------------

# The character set a path must match before it may be read. Absolute, and
# nothing outside [A-Za-z0-9._/-].
#
# A quote is the character that matters: the tracer opens compressed input as a
# /bin/sh command line with the filename interpolated inside single quotes and no
# escaping, so a quote in a path turns a log reader into a shell. The rest are
# refused on the same grounds every validator here refuses them — no log this tool
# reads needs them, and admitting a character means owning every program that
# will later see it.
zro_inv_path_ok() {
  local p=${1-}
  [ -n "$p" ] || return 1
  [ "${#p}" -le 4096 ] || return 1
  case $p in
    /*) ;;
    *) return 1 ;;
  esac
  case $p in
    *[!A-Za-z0-9._/-]*) return 1 ;;
  esac
  # A parent-directory component would let a root reach outside itself, which is
  # the environment deciding which files are read instead of where they live.
  case $p in
    ..|../*|*/..|*/../*) return 1 ;;
  esac
  return 0
}

# The rotation variants of a base name, and nothing else. Three schemes reach
# these files, so all three are named:
#
#   .1, .2.gz            logrotate, numbered — Zimbra's own tooling assumes this
#   -20260728[.gz]       logrotate with dateext, which Zimbra sets neither way,
#                        so the distribution's default decides at runtime
#   .2026-07-29[.gz]     log4j2, whose compression is a separate 02:50 cron, so
#                        both forms of one file exist for part of every day
#
# The numbered form is bounded to three digits so that a twelve-digit timestamp
# suffix written by something else cannot pass as a rotation of ours.
#
# xz, zstd and bzip2 are absent on purpose: the tracer would read them as garbage
# rather than refuse them.
ZRO_INV_RE_VARIANT='^(\.[0-9]{1,3}|\.[0-9]{4}-[0-9]{2}-[0-9]{2}|-[0-9]{8})(\.gz)?$'

zro_inv_variant_ok() {
  local base=${1-} candidate=${2-} suffix
  [ -n "$base" ] || return 1
  [ -n "$candidate" ] || return 1
  case $candidate in
    "$base")   return 0 ;;    # the file still being written
    "$base"?*) suffix=${candidate#"$base"} ;;
    *)         return 1 ;;
  esac
  # Held in a variable because bash only reads the right-hand side of =~ as a
  # regular expression when it is unquoted.
  local re=$ZRO_INV_RE_VARIANT
  [[ $suffix =~ $re ]]
}

# A compression format the tracer cannot read. Kept apart from the check above so
# that skipping one can be said out loud: an unrecognised neighbour is ordinary,
# but a rotated log this tool will not open is a day the operator would otherwise
# never learn was missing.
zro_inv_unsupported_compression() {
  case ${1-} in
    *.xz|*.zst|*.zstd|*.bz2|*.lz4|*.Z) return 0 ;;
  esac
  return 1
}

# --- selection: pure -------------------------------------------------------

# Stands in for "still being appended to". The newest file in a family has no
# upper bound, and a pure function may not ask the clock what time it is.
ZRO_INV_OPEN_END=99999999999

ZRO_INV_TAB=$'\t'

# The year a timestamp falls in, as local wall clock.
#
# Behind a variable like every other binary path, and for the reason CLAUDE.md
# gives: that is what makes it mockable. lib/core.sh calls date bare, but that
# call only stamps a log line, while this one produces a value that reaches a
# command line and decides whether a trace finds anything at all.
ZRO_DATE_BIN="${ZRO_DATE_BIN:-$(zro_first_existing /usr/bin/date /bin/date)}"

zro_inv_year() {
  [ -n "$ZRO_DATE_BIN" ] || return 1
  "$ZRO_DATE_BIN" -d "@${1-}" '+%Y' 2>/dev/null
}

# Oldest first, and for one timestamp the longest path first.
#
# The tie-break is not cosmetic. logrotate creates the replacement file in the
# same second it renames the original, so on a quiet server the file still being
# written and the file it replaced can carry the same timestamp — and the live
# file's name is the shortest in its family, so putting the longest first makes it
# last, which it is by definition. The same rule puts the compressed copy of a
# rotated file ahead of the plain one, so it is the plain duplicate that is
# dropped as empty below.
zro_inv_sort_pairs() {
  LC_ALL=C sort -t "$ZRO_INV_TAB" -k1,1n -k2,2r
}

# Which files an arrival window covers, and the year to stamp on each.
#
#   $1  window start, absolute local timestamp in seconds
#   $2  window end, the same
#   stdin   "<modification time>\t<path>" pairs for ONE rotation family, in any
#           order. Mixing families would compute one file's coverage from
#           another's rotation and is the caller's error; zro_inv_discover emits
#           one family per call so that no caller has to remember it.
#   stdout  "<year>\t<path>", oldest first
#
# A file's COVERAGE INTERVAL is the span between the previous file's modification
# time and its own, left-open and right-closed, and the window selects every file
# whose interval it intersects. Rotation fires from cron.daily in the early
# morning, so a file's lines mostly PREDATE its own timestamp: the file rotated on
# the 29th holds the 28th's afternoon. Selecting by the date in a filename, or by
# a file's own timestamp alone, is a one-day error and a trace that silently finds
# nothing.
#
# The year comes from the file's own modification time, which is what removes the
# tracer's defect of guessing it once from the local clock. One residual remains
# and is inherent: the file rotated on 1 January carries the new year for lines
# written on 31 December. A file straddling a year boundary needs two years and
# the tracer takes one, so no rule fixes it here.
zro_inv_select() {
  local ws=${1-} we=${2-}
  case $ws in ''|*[!0-9]*) return "$ZRO_E_INPUT" ;; esac
  case $we in ''|*[!0-9]*) return "$ZRO_E_INPUT" ;; esac
  # An end before its start is a caller defect. Answering it with an empty
  # selection would read as "nothing was logged then", which is the ambiguity
  # this whole feature exists to remove.
  [ "$ws" -le "$we" ] || return "$ZRO_E_INPUT"

  local sorted
  sorted=$(zro_inv_sort_pairs)

  local -a mtimes=() paths=()
  local line mtime path
  # The line is read whole and split here rather than by IFS, so that a pair
  # arriving with no timestamp at all is refused BY NAME below instead of being
  # dropped as though it were the blank line this heredoc always ends with.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    mtime=${line%%"$ZRO_INV_TAB"*}
    path=${line#*"$ZRO_INV_TAB"}
    case $mtime in
      ''|*[!0-9]*)
        zro_log error "denied, log timestamp is not a number: $line"
        continue ;;
    esac
    if ! zro_inv_path_ok "$path"; then
      zro_log error "denied, log path outside the permitted set: $path"
      continue
    fi
    mtimes+=("$mtime")
    paths+=("$path")
  done <<EOF
$sorted
EOF

  local n=${#paths[@]}
  [ "$n" -gt 0 ] || return 0

  local i lo=0 hi year
  for (( i = 0; i < n; i++ )); do
    if [ $(( i + 1 )) -eq "$n" ]; then
      hi=$ZRO_INV_OPEN_END
    else
      hi=${mtimes[i]}
    fi

    # An interval of zero width holds no line. Two files can only share a
    # timestamp by being the same rotation instant — the compressed and plain
    # forms of one file, which exist together for part of every day — and reading
    # both would report every message twice.
    #
    # That rests on compression preserving the modification time, which is what
    # gzip does. Where it did not, both forms would be selected and each message
    # would appear twice in one report. The residual runs in the visible
    # direction: a doubled report reads as a doubled report, while a file dropped
    # by a name-based rule would read as a message that never arrived.
    if [ "$lo" -lt "$hi" ] &&
       [ "$ws" -le "$hi" ] &&
       [ "$we" -gt "$lo" ]; then
      # A year that could not be derived must never be printed. The tracer would
      # take an empty one and answer nothing found, which is precisely the defect
      # deriving it per file exists to remove.
      year=$(zro_inv_year "${mtimes[i]}")
      case $year in
        [0-9][0-9][0-9][0-9]) printf '%s\t%s\n' "$year" "${paths[i]}" ;;
        *) zro_log error "denied, cannot derive the year of: ${paths[i]}" ;;
      esac
    fi
    lo=${mtimes[i]}
  done
  return 0
}

# --- discovery: thin -------------------------------------------------------

zro_inv_mtime() {
  "$ZRO_STAT_BIN" -c '%Y' -- "${1-}" 2>/dev/null
}

# Every file on disk belonging to one declared log, as the pairs selection reads.
#
#   $1      a name declared in ZRO_INVENTORY
#   stdout  "<modification time>\t<path>", oldest first
#
# Emits nothing and succeeds when the log simply is not there: a host without a
# proxy or without the audit log is ordinary. It refuses, loudly, when the name is
# not declared or a path fails admission, because those are defects in this file
# or in an override rather than facts about the host.
#
# Readability is NOT tested here. A file the tracer cannot open must still appear,
# or the ticket that discloses a partial scan would have nothing to disclose and
# an unreadable day would look like a quiet one.
zro_inv_discover() {
  local key=${1-}
  if [ -z "$ZRO_STAT_BIN" ]; then
    # Silence here would be indistinguishable from an empty inventory.
    zro_log error "cannot read log modification times: stat not found"
    return "$ZRO_E_UNAVAILABLE"
  fi

  local base
  base=$(zro_inv_base_path "$key") || return "$ZRO_E_DENIED"
  if ! zro_inv_path_ok "$base"; then
    zro_log error "denied, log path outside the permitted set: $base"
    return "$ZRO_E_DENIED"
  fi

  # The base has passed admission, so it carries no glob character and the two
  # patterns below can only reach its own rotation variants. This is the only
  # place in the program that expands a glob.
  local restore_nullglob=0
  shopt -q nullglob || restore_nullglob=1
  shopt -s nullglob
  local -a candidates=("$base" "$base".* "$base"-*)
  if [ "$restore_nullglob" -eq 1 ]; then
    shopt -u nullglob
  fi

  local c mtime
  for c in ${candidates[@]+"${candidates[@]}"}; do
    # Admission comes FIRST, before the name is judged as a rotation. Both globs
    # above can match a neighbour carrying a quote or a space, and a refusal is
    # worth saying out loud: it is the one thing standing between this list and a
    # filename reaching the /bin/sh command line the tracer builds. Judging the
    # rotation shape first would drop that file as a merely unrecognised name and
    # say nothing.
    if ! zro_inv_path_ok "$c"; then
      zro_log error "denied, log path outside the permitted set: $c"
      continue
    fi
    if ! zro_inv_variant_ok "$base" "$c"; then
      if zro_inv_unsupported_compression "$c"; then
        zro_log warn "log skipped, compression the tracer cannot read: $c"
      fi
      continue
    fi
    # Tested before -f, which follows a link. A link is refused rather than
    # resolved: the inventory is what makes a log viewer a log viewer instead of
    # a general-purpose file reader, and a link is a name for a file somewhere
    # else. The cost is a refusal an operator can see in the log.
    if [ -L "$c" ]; then
      zro_log error "denied, log path is a symbolic link: $c"
      continue
    fi
    [ -f "$c" ] || continue
    mtime=$(zro_inv_mtime "$c")
    case $mtime in
      ''|*[!0-9]*)
        zro_log warn "log skipped, modification time unreadable: $c"
        continue ;;
    esac
    printf '%s\t%s\n' "$mtime" "$c"
  done | zro_inv_sort_pairs

  # Deliberately not the pipeline's status. A loop whose last candidate was
  # skipped ends on the test that skipped it, so its status reports whether the
  # newest neighbour happened to be a rotation of this log — which is not a
  # question anyone asked. Everything that can really fail here has already been
  # refused above, and by name.
  return 0
}
