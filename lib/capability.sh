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
# The queue tool's own probe. Same shape and same reason as the tracer's.
ZRO_CAP_QUEUE_BIN_CACHE=""

# THE HOST'S REFUSAL, WHICH IS NOT A PROBE AND CANNOT BE ONE.
#
# `authorized_mailq_users` is read by the queue tool INSIDE ITSELF, so the only
# thing that can answer whether this host permits the read is the read. There is
# no file to stat and no setting this program may go and look at: reading it would
# mean a second binary in the allowlist to answer a question the first one already
# answers, on every menu redraw, for an operator who may never open the screen.
#
# So it is learned the once it can be learned — when the listing is refused — and
# remembered for the session, which is what lets the menu mark the entry from then
# on instead of charging the operator for the same refusal twice.
#
# A FILE RATHER THAN A VARIABLE, for the reason this module already records about
# the version cache: screens run inside command substitution, and a variable set
# in that subshell dies with it. Emptied at startup like every other session file,
# because the name carries a process id and process ids are reused.
ZRO_CAP_QUEUE_DENIED_FILE="${ZRO_CAP_QUEUE_DENIED_FILE:-${TMPDIR:-/tmp}/zro-queue-denied.$$}"
zro_session_file "$ZRO_CAP_QUEUE_DENIED_FILE"

zro_cap_reset() {
  ZRO_CAP_VERSION_CACHE=""
  ZRO_CAP_TRACE_BIN_CACHE=""
  ZRO_CAP_TRACE_LOG_CACHE=""
  ZRO_CAP_QUEUE_BIN_CACHE=""
  rm -f -- "$ZRO_CAP_QUEUE_DENIED_FILE" 2>/dev/null || true
}

# Fills the cache IN THE CALLER'S SHELL, and says whether the host answered.
#
# The version is displayed, so every caller reads it inside command substitution
# — and an assignment made in a subshell dies with it, which left "cached once
# per session" true of a cache that was never written. The server was asked again
# on every redraw of the menu, at a JVM start each time. Callers that are about
# to display it prime the cache through this first; the printer below then finds
# it filled.
zro_cap_version_load() {
  [ -n "$ZRO_CAP_VERSION_CACHE" ] && return 0
  ZRO_CAP_VERSION_CACHE=$(zro_exec zmcontrol -v 2>/dev/null | head -n 1)
  [ -n "$ZRO_CAP_VERSION_CACHE" ]
}

zro_cap_version() {
  if [ -n "${ZRO_CAP_FORCE:-}" ]; then
    printf '%s' "$ZRO_CAP_FORCE"
    return 0
  fi
  zro_cap_version_load || true
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
ZRO_CAP_TRACE_LOG_REASONS="ok denied missing unreadable"

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
  case " $ZRO_CAP_TRACE_LOG_REASONS " in
    *" $ZRO_CAP_FORCE_TRACE_LOG "*) printf '%s' "$ZRO_CAP_FORCE_TRACE_LOG"; return 0 ;;
  esac
  zro_log error \
    "not a log probe reason: ZRO_CAP_FORCE_TRACE_LOG=$ZRO_CAP_FORCE_TRACE_LOG (expected one of: $ZRO_CAP_TRACE_LOG_REASONS)"
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
  if ! zro_inv_admit_path "$path"; then
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

# --- the mail queue, and the two ways this host can have no answer -----------
#
# TWO ANSWERS WITH TWO REPAIRS, and they are kept apart for the reason the trace's
# four reasons are: a screen that said only 'unavailable' would send an operator
# to install a package that is already there, or to a permission setting on a
# server that has no queue tool at all.
#
#   nobin   the mail transfer agent is not on this build. There is no queue here
#           and no setting that would produce one; the repair is a package.
#   denied  the tool is present and refuses. `authorized_mailq_users` does not
#           list the account every command runs as; the repair is that setting.

# Whether this build has the queue tool.
#
# Asked as the OPERATION the allowlist names rather than as a bare file test, so
# that a tool present on a host where the listing form was never approved cannot
# read as available. Forced the same yes-or-no way the tracer's binary probe is,
# and an unrecognised forced value is read as the strictest answer there is.
zro_cap_queue_bin() {
  if [ -n "${ZRO_CAP_FORCE_QUEUE_BIN:-}" ]; then
    case $ZRO_CAP_FORCE_QUEUE_BIN in
      yes) return 0 ;;
      no)  return 1 ;;
    esac
    zro_log error "not a probe answer: ZRO_CAP_FORCE_QUEUE_BIN=$ZRO_CAP_FORCE_QUEUE_BIN (expected: yes no)"
    return 1
  fi
  if [ -z "$ZRO_CAP_QUEUE_BIN_CACHE" ]; then
    if zro_cap_op_available postqueue -p; then
      ZRO_CAP_QUEUE_BIN_CACHE=yes
    else
      ZRO_CAP_QUEUE_BIN_CACHE=no
      zro_log warn "mail queue unavailable: the queue tool is not on this build"
    fi
  fi
  [ "$ZRO_CAP_QUEUE_BIN_CACHE" = yes ]
}

# That this host refused the listing, recorded where a subshell cannot lose it.
zro_cap_queue_deny_record() {
  ( umask 077; : >"$ZRO_CAP_QUEUE_DENIED_FILE" ) 2>/dev/null || true
  return 0
}

# NO FORCED FORM, unlike the two probes above, and that is deliberate: this one
# is not a probe. It records something that HAPPENED, and the suite scripts it by
# making it happen — the mock queue tool refuses exactly as the lab server's did,
# and the screen learns it the way an operator's would.
zro_cap_queue_denied() {
  [ -f "$ZRO_CAP_QUEUE_DENIED_FILE" ]
}

# WHY the queue cannot be read, in one word: 'ok', 'nobin' or 'denied'.
#
# The one place the two are ranked, exactly as the trace's are, so the mark on the
# menu entry and the screen behind it cannot name different causes. A missing tool
# is reported first because it is the repair that has to happen first: on a host
# with no transfer agent, the access-control setting is a setting on a program
# that is not installed.
zro_cap_queue_reason() {
  zro_cap_queue_bin || { printf 'nobin'; return 0; }
  zro_cap_queue_denied && { printf 'denied'; return 0; }
  printf 'ok'
}

zro_cap_queue_available() {
  [ "$(zro_cap_queue_reason)" = ok ]
}

# --- the log search, and the promise it cannot keep without two commands ------
#
# ONE REASON, and it is not about a log at all. Which files a search can read is
# answered file by file by the search itself, disclosed as a partial scan — the
# same arrangement the bounded viewer has, and why neither is marked for a log it
# cannot open. What CAN be known before an operator spends anything is whether this
# host can run a scan the way this tool promises to: at reduced processor priority
# and idle disk priority, so that diagnosing a loaded mail server does not deepen
# the load.
#
# A host without those two commands is offered the entry and then refused by the
# gate, which is the one thing a mark exists to prevent. It is a fact about the
# host, it holds for every question and every window, and there is one repair — a
# package — so it belongs here with the other host facts rather than inside a
# screen.
#
# NO FORCED FORM, unlike the trace's two probes, and deliberately: what this reads
# is already an overridable variable. Pointing ZRO_NICE_BIN at nothing IS a host
# without nice, so the suite scripts this the way an operator would meet it rather
# than through a second switch that could answer differently from the gate.
# ONE WORD, and no table of the words it may answer — unlike the trace's four,
# which exist because a forced value has to be judged against something. There is
# nothing to force here and nothing to typo: the two facts are read from the
# variables that hold them, and the screen behind the mark has a defect branch for
# a word this function does not yet return.
zro_cap_search_reason() {
  if [ -z "$ZRO_NICE_BIN" ] || [ -z "$ZRO_IONICE_BIN" ]; then
    printf 'noprio'
    return 0
  fi
  printf 'ok'
}

zro_cap_search_available() {
  [ "$(zro_cap_search_reason)" = ok ]
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
