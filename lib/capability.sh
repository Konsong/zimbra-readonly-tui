# shellcheck shell=bash
# Runtime facts about this host. The Zimbra version is not pinned anywhere in
# this program; it is observed once per session and cached.
[ -n "${ZRO_LIB_CAPABILITY_LOADED:-}" ] && return 0
ZRO_LIB_CAPABILITY_LOADED=1

ZRO_CAP_VERSION_CACHE=""
# The delivery trace's two probes, each asked once per session. Empty means not
# asked yet, which is why neither cache holds a status: an unasked probe and a
# refusing one have to be told apart, or a cleared cache would read as a refusal.
ZRO_CAP_TRACE_BIN_CACHE=""
ZRO_CAP_TRACE_LOG_CACHE=""

zro_cap_reset() {
  ZRO_CAP_VERSION_CACHE=""
  ZRO_CAP_TRACE_BIN_CACHE=""
  ZRO_CAP_TRACE_LOG_CACHE=""
}

zro_cap_version() {
  if [ -n "${ZRO_CAP_FORCE:-}" ]; then
    printf '%s' "$ZRO_CAP_FORCE"
    return 0
  fi
  if [ -z "$ZRO_CAP_VERSION_CACHE" ]; then
    ZRO_CAP_VERSION_CACHE=$(zro_exec zmcontrol -v 2>/dev/null | head -n 1)
  fi
  printf '%s' "$ZRO_CAP_VERSION_CACHE"
}

# An operation is offered only when the allowlist names it AND the binary is
# actually installed here. Menus grey out what this rejects, instead of letting
# the operator select something that will fail once selected.
#
# There is no recursion risk: availability is a filesystem test, and only the
# version lookup goes back through zro_exec.
zro_cap_op_available() {
  local bin=${1-} token=${2-}
  zro_allowed "$bin" "$token" || return 1
  zro_bin_available "$bin" || return 1
  return 0
}

# --- the delivery trace, and the two things it needs from this host --------
#
# Both are expressed HERE, as capabilities, rather than as checks inside the trace
# screen. That is not tidiness: this module is already the one mechanism for
# suppressing an operation this host cannot perform, and a second concept living
# in the screen would be one an operator meets only after investing a search in it.
# A menu entry marked before it is selected is the whole point of the ticket.
#
# Neither probe is a safety check, and neither is the last word. The exec gate
# still refuses a binary it cannot resolve and the trace still discloses a log it
# could not open, whatever these answer — which is what makes it safe for the suite
# to pin them.

# The account every external command runs as, and therefore whose read access
# decides whether a log can be traced at all.
#
# A literal rather than an overridable variable, deliberately: lib/exec.sh names
# this account literally too, and a variable here would read as though the two
# could be pointed somewhere else together. That is precisely the off switch the
# identity rule may not have.
ZRO_CAP_RUN_ACCOUNT=zimbra

# Whether this build has the tracing binary.
#
# Asked as the OPERATION the allowlist names rather than as a bare file test, so a
# filter that was never approved cannot read as available because the binary
# happens to be installed. Upstream packaging puts it under libexec while an
# upstream mapping still names the bin path — that mapping is stale, which is why
# the root is declared per binary and why this question is worth asking at all.
#
# The override is a yes-or-no because the question is: a binary is there or it is
# not, and there is one repair. The log probe below answers with a REASON instead,
# because that question has three answers with three different repairs. An
# unrecognised forced value is a defect in whatever set it rather than a fact about
# this host, so it is logged and read as the strictest answer there is — a typo can
# only ever hide the feature, never offer one this host cannot perform.
zro_cap_trace_bin() {
  if [ -n "${ZRO_CAP_FORCE_TRACE_BIN:-}" ]; then
    case $ZRO_CAP_FORCE_TRACE_BIN in
      yes) return 0 ;;
      no)  return 1 ;;
    esac
    zro_log error "not a probe answer: ZRO_CAP_FORCE_TRACE_BIN=$ZRO_CAP_FORCE_TRACE_BIN (expected: yes no)"
    return 1
  fi
  if [ -z "$ZRO_CAP_TRACE_BIN_CACHE" ]; then
    if zro_cap_op_available zmmsgtrace --recipient; then
      ZRO_CAP_TRACE_BIN_CACHE=yes
    else
      ZRO_CAP_TRACE_BIN_CACHE=no
      zro_log warn "delivery trace unavailable: the tracing binary is not on this build"
    fi
  fi
  [ "$ZRO_CAP_TRACE_BIN_CACHE" = yes ]
}

# Whether an account may read a file, from the file's own owner, group and mode.
#
#   $1  the file's owner        $2  its group      $3  its mode, in octal
#   $4  the account asked about $5  the groups that account is in, space separated
#
# Pure: five strings in, a status out. No filesystem, no clock, no identity — the
# only facts it uses are the ones handed to it, which is what makes the case this
# whole probe exists for testable for the price of a string.
#
# The three permission classes are tried in the order the kernel tries them and
# the FIRST match decides; no later class is consulted. A file you own with mode
# 0044 is one you cannot read, however wide the group and other bits are. Folding
# the three into an OR would report that file as readable, and would report the
# syslog:adm case as readable too on any host where the account happened to be in
# the file's group for an unrelated reason.
zro_cap_mode_readable() {
  local owner=${1-} group=${2-} mode=${3-} user=${4-} groups=${5-} digits mid
  # Checked before anything else: a nameless account would otherwise match a file
  # owned by nobody, or be read as a member of a group with no name.
  [ -n "$user" ] || return 1
  case $mode in
    [0-7][0-7][0-7])      digits=$mode ;;
    # A leading digit carries setuid, setgid and the sticky bit, none of which has
    # anything to say about who may read.
    [0-7][0-7][0-7][0-7]) digits=${mode#?} ;;
    # Not a mode at all: a stat that answered something unexpected is not knowing,
    # and not knowing is not permission.
    *) return 1 ;;
  esac
  mid=${digits#?}; mid=${mid%?}

  if [ "$owner" = "$user" ]; then
    zro_cap_read_bit "${digits%??}"
    return $?
  fi
  # A group with no name is not a group: without the guard, a file whose group
  # stat could not name and an account in no groups at all would match each other
  # on the empty string, and the group bits would decide a question they know
  # nothing about.
  #
  # Space-padded on both sides so a group name cannot match a longer one it is a
  # prefix or suffix of: 'adm' is not 'sysadm'.
  if [ -n "$group" ]; then
    case " $groups " in
      *" $group "*) zro_cap_read_bit "$mid"; return $? ;;
    esac
  fi
  zro_cap_read_bit "${digits#??}"
}

# Whether one octal permission digit carries the read bit. Written as the four
# values that do rather than as an arithmetic mask, so that a digit which is not
# one is refused instead of silently evaluating to zero.
zro_cap_read_bit() {
  case ${1-} in
    [4-7]) return 0 ;;
  esac
  return 1
}

# Whether the primary mail log can be read BY THE ACCOUNT EVERY COMMAND RUNS AS.
#
# NOT whether we can read it. zro_exec drops to that account whenever the tool is
# run as root, so a file root can read and it cannot is a file no trace can read —
# and a probe that tested its own access would answer yes to exactly the
# misconfiguration this one exists to find: the syslog daemon creating the file
# itself, which leaves it owned syslog:adm and mode 0640.
#
# Asking about the account BY NAME is also what keeps the answer identical under
# both identities. Nothing here branches on who is running the tool, and
# zro_identity_mode is untouched: DIAGNOSE, DO NOT ESCALATE. Reading that file as
# root would work and is refused, because the same ownership breaks Zimbra's own
# tooling — so repairing it is the outcome, and the screen names the tool that
# does.
#
# Only the PRIMARY log is probed. A rotated file that cannot be read is disclosed
# by the trace itself as a partial scan, while this one being unreadable leaves the
# screen with nothing to answer from at all.
#
# TWO THINGS IT CANNOT SEE, both recorded rather than compensated for, because the
# only way to see either is to ask the kernel AS that account — and the one command
# that would do it needs root when the tool is already running as the account,
# which is the per-identity branch this whole design exists without.
#
#   A directory on the way to the file that the account cannot traverse. The file
#   then reads as absent rather than as unreadable, so the screen below says NOT
#   FOUND and names both possibilities. It does not claim the file does not exist.
#
#   A POSIX ACL granting the account read on a file whose mode refuses it. That
#   reads as unreadable, so a host where tracing would work is marked unavailable.
#   The cost runs the visible way round: the screen names the file, its ownership
#   and its mode, so an operator holding an ACL can see what the tool judged and
#   that it judged the mode alone.
zro_cap_trace_log() {
  local forced
  if forced=$(zro_cap_forced_log_reason); then
    [ "$forced" = ok ]
    return $?
  fi
  if [ -z "$ZRO_CAP_TRACE_LOG_CACHE" ]; then
    ZRO_CAP_TRACE_LOG_CACHE=$(zro_cap_probe_log)
  fi
  [ "$ZRO_CAP_TRACE_LOG_CACHE" = ok ]
}

# What the probe above may answer. FOUR reasons rather than one because the repairs
# have nothing in common: naming the permission repair tool for a file that does not
# exist sends an operator looking for a mode that is not the problem, and a path
# this tool refuses to read at all is a setting to correct rather than anything on
# disk.
ZRO_CAP_TRACE_LOG_ANSWERS="ok denied missing unreadable"

# Why the probe answered as it did.
zro_cap_trace_log_reason() {
  local forced
  if forced=$(zro_cap_forced_log_reason); then
    printf '%s' "$forced"
    return 0
  fi
  # A caller that asks why before asking whether gets the probe run for it. An
  # empty cache means nobody has asked yet, and answering that with silence would
  # read as nothing being wrong.
  zro_cap_trace_log || :
  printf '%s' "$ZRO_CAP_TRACE_LOG_CACHE"
}

# The forced answer, when the suite has pinned one. Fails when nothing is pinned,
# which is what tells the two functions above to ask the host instead.
#
# An unrecognised value is a defect in whatever set it rather than a fact about this
# host: logged, and read as the strictest answer there is. Echoing it verbatim would
# let a typo pick a screen — and the screen it picks names a repair for a cause
# nobody diagnosed.
zro_cap_forced_log_reason() {
  [ -n "${ZRO_CAP_FORCE_TRACE_LOG:-}" ] || return 1
  case " $ZRO_CAP_TRACE_LOG_ANSWERS " in
    *" $ZRO_CAP_FORCE_TRACE_LOG "*) printf '%s' "$ZRO_CAP_FORCE_TRACE_LOG"; return 0 ;;
  esac
  zro_log error \
    "not a log probe answer: ZRO_CAP_FORCE_TRACE_LOG=$ZRO_CAP_FORCE_TRACE_LOG (expected one of: $ZRO_CAP_TRACE_LOG_ANSWERS)"
  printf 'unreadable'
}

# Asks the host, once. Prints the reason zro_cap_trace_log caches.
zro_cap_probe_log() {
  local path perms owner group mode groups
  # Which file is the primary mail log is the inventory's business, and a name it
  # does not declare has already been logged there. A log this tool cannot name is
  # a setting to correct, not a file that is missing.
  if ! path=$(zro_inv_base_path syslog); then
    printf 'denied'
    return 0
  fi
  # The same admission the inventory applies before reading anything, applied here
  # so that the menu and the search cannot disagree. Without it an inadmissible
  # override would offer the entry and then refuse the search — the operator would
  # be told the operation is not on the allowlist, about a path.
  if ! zro_inv_path_ok "$path"; then
    zro_log error "denied, log path outside the permitted set: $path"
    printf 'denied'
    return 0
  fi
  # Absent, or in a directory this tool cannot look into: the two are
  # indistinguishable from here, and the screen says so rather than picking one.
  if [ ! -f "$path" ]; then
    zro_log warn "delivery trace unavailable: no primary mail log found at $path"
    printf 'missing'
    return 0
  fi
  perms=$(zro_inv_file_perms "$path")
  if [ -z "$perms" ]; then
    # A stat that answered nothing is not a fact about the mode: it is not knowing.
    # Refused rather than assumed readable, so the operator is told before a search
    # instead of after one.
    zro_log warn "delivery trace unavailable: cannot read the mode of $path"
    printf 'unreadable'
    return 0
  fi
  owner=${perms%% *}
  mode=${perms##* }
  group=${perms#* }; group=${group%% *}

  # An account whose groups cannot be listed is treated as being in none, which can
  # only ever make this answer stricter — and it is said out loud, because a host
  # without the account every command runs as has a larger problem than a log.
  if ! groups=$(zro_user_groups "$ZRO_CAP_RUN_ACCOUNT" 2>/dev/null); then
    zro_log warn "cannot list the groups of $ZRO_CAP_RUN_ACCOUNT; assuming none"
    groups=""
  fi

  if zro_cap_mode_readable "$owner" "$group" "$mode" "$ZRO_CAP_RUN_ACCOUNT" "$groups"; then
    printf 'ok'
    return 0
  fi
  zro_log warn \
    "delivery trace unavailable: $path is $owner:$group $mode and $ZRO_CAP_RUN_ACCOUNT cannot read it"
  printf 'unreadable'
}

# Both probes, as the one question a menu asks: can a delivery trace answer
# anything at all on this host?
#
# Two probes and one question, because the menu entry they gate is one entry. An
# AND, so the order it reads them in decides nothing — which of them refused is
# answered once, below.
zro_cap_trace_available() {
  zro_cap_trace_bin || return 1
  zro_cap_trace_log || return 1
  return 0
}

# WHY it cannot, in one word: 'ok', 'nobin', or whichever reason the log probe gave.
#
# The one place the two probes are ranked. A screen that asked each probe again to
# find out which refused would be a second ranking, and the pair that drifted would
# be the mark on the menu entry and the message behind it — an entry marked for one
# cause and explained by another. Both come from here instead.
#
# A missing binary is reported first because it is the repair that has to happen
# first: on a host with neither, repairing the log permission changes nothing until
# the binary is there.
zro_cap_trace_reason() {
  zro_cap_trace_bin || { printf 'nobin'; return 0; }
  zro_cap_trace_log_reason
}
