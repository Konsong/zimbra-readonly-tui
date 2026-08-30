# shellcheck shell=bash
# Exit codes, logging, temporary files. Depends on nothing.
#
# SC2034 is disabled for the whole file: defining constants that other modules
# consume is precisely this module's job, so "appears unused" is expected here
# and nowhere else.
# shellcheck disable=SC2034

[ -n "${ZRO_LIB_CORE_LOADED:-}" ] && return 0
ZRO_LIB_CORE_LOADED=1

# Success
ZRO_E_OK=0
# Input and lookup
ZRO_E_INPUT=10
ZRO_E_NO_ACCOUNT=11
ZRO_E_NO_MAILBOX=12
ZRO_E_NO_FOLDER=13
ZRO_E_NO_RESULT=14
# A domain the directory does not hold. Its own code rather than NO_RESULT,
# because it is an ANSWER an operator acts on — mail for an address in a domain
# this server does not host was never going to arrive here, and that ends the
# search in Zimbra rather than continuing it.
ZRO_E_NO_DOMAIN=15
# Environment
ZRO_E_PERM=20
# A ZIMBRA SERVICE A READ NEEDED AND THAT DID NOT ANSWER: the mail service behind
# zmprov and zmmailbox, reached over SOAP. That one condition and no other, which
# is what its screen already describes and what makes it an ANSWER an operator
# acts on — the service is stopped, or the certificate that authenticates to it is
# not valid.
#
# NOT A COMMAND THAT RAN AND FAILED for a reason nothing recognised. That reading
# is how an operator whose zmcontrol status had just failed was told to go and run
# zmcontrol status, and it is why the two sinks have codes of their own. Every
# site that once borrowed this one for something the command never reached now has
# a code of its own: a scratch file it could not create is ZRO_E_NO_SCRATCH, a
# system tool that gave no usable answer is ZRO_E_NO_SYSTEM_TOOL, and a host that
# cannot reduce a process's priority is ZRO_E_NO_LOW_PRIORITY, all three below.
# ADR-0016 binds the term, ADR-0017 closed the last of the borrowings, and
# CONTEXT.md carries it under 'Unavailable'.
ZRO_E_UNAVAILABLE=21
ZRO_E_TIMEOUT=22
ZRO_E_NO_LOG=23
# A stored message file this tool was pointed at and could not read. Beside the log
# that cannot be read, and for the same reason it is not folded into it: the two name
# different files with different repairs, and neither is a query that found nothing.
# It is the code a blob read ends on when the failure is not one of the gate's own —
# a file the store no longer has, or one the account every command runs as cannot
# open — so no undocumented status from `head` or `gzip` reaches a caller.
ZRO_E_NO_BLOB=24
# What the service-status read ends on when zmcontrol status ran and failed for a
# reason nothing above it recognised. THE STATUS is what could not be read; the
# services themselves are exactly what this program has learned nothing about, so
# it is not called NO_SERVICE — that is the most alarming reading available on that
# screen, and zro_svc_card already refuses to invent it.
# It is not folded into the code the MAIL QUEUE read ends on, for the reason the
# log and the blob above are kept apart: the two name different tools with
# different repairs. A postqueue that failed sends an operator to Postfix; a
# zmcontrol status that failed sends them to the Zimbra control plane and the
# directory, and one code shared between them would be true about neither.
ZRO_E_NO_STATUS=25
# What the MAIL QUEUE read ends on when postqueue ran and failed for a reason
# nothing above it recognised. Its own code rather than the one above, for the
# reason the log and the blob are kept apart: the two name different tools with
# different repairs. postqueue reads Postfix's own queue on this host and reaches
# no ZIMBRA service — the qualifier is the claim, since it does speak to a Postfix
# daemon of its own — so where to look for it is Postfix; zmcontrol status sends
# an operator to the Zimbra control plane and the directory instead. One code
# shared between them would be true about neither.
# It is not ZRO_E_UNAVAILABLE for the same reason that one is not: no Zimbra
# service was asked, so none of them is what failed to answer.
ZRO_E_NO_QUEUE=26
# What a step ends on when THIS TOOL COULD NOT CREATE THE WORKING FILE it needed,
# so the operation was never started. A scratch file is where a command's error
# stream is captured to, and one is taken before anything is run: the exec gate is
# not reached, no binary is invoked, and there is nothing on the server to have
# changed. The repair is on THIS host — space and permissions under TMPDIR, /tmp
# by default — which is what makes it an ANSWER an operator acts on.
# It is not ZRO_E_UNAVAILABLE for the same reason the two sinks above are not: no
# Zimbra service was asked, so none of them is what failed to answer. That reading
# is how an operator whose /tmp was full came to be told to check mailboxd and the
# admin certificate.
# It is not one of the three the gate keeps for a defect in this tool either — 90,
# 91 and 92 each name a refusal that did not happen here: no list refused this, no
# user was wrong, no binary was missing. lib/settle.sh states that rule in full.
# IT DOES NOT COVER THE SYSTEM TOOLS, which have ZRO_E_NO_SYSTEM_TOOL below. The
# two are kept apart because THE REPAIRS DIFFER AND THE SCREEN IS THE REPAIR: a
# scratch file sends an operator to TMPDIR on this host, where they add space or
# fix a permission; a clock or a formatter that answered nonsense sends them to
# the tool itself, which is installed rather than provisioned and is a different
# afternoon's work. A code broad enough for both would name neither, which is the
# disease ADR-0016 treats and ADR-0017 settled.
# ONE OF THE TWO BORROWERS OF THE OLD CONSTANT THAT NO PREFLIGHT CAN RETIRE:
# TMPDIR fills or goes read-only at minute forty of a session, and a check at
# startup would prove nothing about the read that follows. The other is the
# reduced priority below. ADR-0016 and issue 99.
ZRO_E_NO_SCRATCH=27
# What an operation ends on when it MUST RUN AT REDUCED PRIORITY and this host
# cannot reduce one, so the gate refused it rather than running it at ordinary
# priority. What could not be had is not the binary but the PROMISE — that a
# whole-file read yields to the mail — which is why it is not called NO_NICE: the
# same discipline that keeps ZRO_E_NO_QUEUE from being called NO_POSTQUEUE, and
# the one ADR-0016 enforced when it refused a name that made a claim of its own.
# NOTHING RAN. The refusal happens while the command is still being built, so an
# operator who reads this as 'it ran, just slowly' has been told the opposite of
# what happened, and the screen for it says so outright.
# IT IS NOT A SCAN REFUSAL. ZRO_LOW_PRIORITY holds grep AND gzip, so ADR-0008's
# compressed blob read is refused by the same arm, and a name mentioning scans
# would be false on that path.
# THE OTHER BORROWER OF THE CONSTANT ABOVE THAT NO PREFLIGHT CAN RETIRE, and
# deliberately so: priority is decided per operation, so a host without nice and
# ionice still answers every screen that does not reach for one. Refusing the
# whole session for it would take away far more than it protects. ADR-0017.
ZRO_E_NO_LOW_PRIORITY=28
# What a step ends on when THIS HOST'S OWN BASE TOOLING GAVE THIS PROGRAM NO
# USABLE ANSWER — the clock behind every arrival window and every rotated log's
# year, and the stat behind the log inventory's modification times.
# IT COVERS BOTH the tool that answered something that is not a time and the tool
# that is not there to ask, which is the reading NO_ already has in this band:
# ZRO_E_NO_BLOB above means a file the store no longer has OR one the account
# every command runs as cannot open. One code and not two, although a clock
# talking nonsense and an absent stat are different conditions, because THE REPAIR
# IS THE SAME AFTERNOON'S WORK IN THE SAME PLACE, and the repair is what a code
# has to be true about.
# It is not ZRO_E_NO_SCRATCH, and the two are kept apart because THE SCREEN IS THE
# REPAIR: a scratch file sends an operator to TMPDIR on this host, where they add
# space or fix a permission, while this one sends them to the tooling itself,
# which is installed rather than provisioned. A code broad enough for both would
# name neither. It is not ZRO_E_UNAVAILABLE for the reason the sinks above are
# not — no Zimbra service was asked, so none of them is what failed to answer.
# ADR-0017.
ZRO_E_NO_SYSTEM_TOOL=29
# Partial. The operation ran and answered, but not from everything it was meant to
# read: a delivery trace whose arrival window selected a log file it could not open,
# or a bulk read that could not reach every account. Never returned without saying
# so on the screen as well — an answer assembled from some of its sources reads
# exactly like a complete one.
ZRO_E_PARTIAL=30
# Navigation. Never becomes a process exit status.
ZRO_E_CANCEL=40
# Safety. Any of these is a defect, not operator error.
ZRO_E_DENIED=90
ZRO_E_BADUSER=91
ZRO_E_NOCAP=92

# Activity logging is off unless the administrator sets ZRO_LOG_FILE.
ZRO_LOG_FILE="${ZRO_LOG_FILE:-}"

zro_log() {
  local level=$1
  shift
  local line
  line="$(date '+%Y-%m-%dT%H:%M:%S%z') [$level] $*"
  printf '%s\n' "$line" >&2
  if [ -n "$ZRO_LOG_FILE" ]; then
    printf '%s\n' "$line" >>"$ZRO_LOG_FILE" 2>/dev/null || true
  fi
}

# Prints the first argument that is an executable file. Used to resolve system
# binaries explicitly instead of trusting PATH.
zro_first_existing() {
  local p
  for p in "$@"; do
    if [ -x "$p" ]; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

# The clock, behind a variable like every other binary path, and for the reason
# CLAUDE.md gives: that is what makes it mockable. zro_log above calls date bare,
# because a log line's stamp is only ever read by a human. Every other date in
# this program produces a value that reaches a command line and decides whether a
# trace finds anything at all — the year stamped on a rotated log, the bounds of
# an arrival window — so those go through this.
ZRO_DATE_BIN="${ZRO_DATE_BIN:-$(zro_first_existing /usr/bin/date /bin/date)}"

# What an absolute timestamp looks like in a given format, as LOCAL WALL CLOCK.
# The one place this program asks the clock about a moment: the log inventory
# derives a file's year through it, the arrival window renders its bounds, and the
# delivery trace builds the tracer's own time option. Each caller still judges the
# answer it got — a year is four digits, a trace bound is fourteen — because those
# are different guarantees, but none of them repeats how to reach the clock or how
# to refuse a timestamp that is not one.
#
#   $1  a date format, without its leading '+'
#   $2  an absolute timestamp in seconds
zro_clock_fmt() {
  local fmt=${1-} ts=${2-} out
  [ -n "$fmt" ] || return "$ZRO_E_INPUT"
  case $ts in ''|*[!0-9]*) return "$ZRO_E_INPUT" ;; esac
  # THAT THERE IS A CLOCK ON THIS HOST IS ESTABLISHED BY zro_startup_check, which
  # refuses to open a session without `date` and names it in the message. Not
  # re-asked here: the answer this guard used to give was ZRO_E_UNAVAILABLE, which
  # sent an operator to check mailboxd for a binary that is not installed, and a
  # guard standing behind a precondition states it rather than asking it again.
  # ADR-0014 sets the shape and ADR-0017 applies it here.
  out=$("$ZRO_DATE_BIN" -d "@$ts" "+$fmt" 2>/dev/null) || return "$ZRO_E_NO_SYSTEM_TOOL"
  [ -n "$out" ] || return "$ZRO_E_NO_SYSTEM_TOOL"
  printf '%s' "$out"
}

# The separator every pair this program passes between functions travels on. A
# function answers with a status, so two values have to share one line — the log
# inventory's timestamp-and-path pairs and the arrival window's two bounds alike.
# One constant rather than one per module: two names for one character is how a
# producer and a consumer end up splitting on different things.
ZRO_TAB=$'\t'

# HOW MUCH OF THE UNDERLYING FAILURE MESSAGE IS KEPT, in bytes. Every screen that
# explains a failure prints this tool's own reading of it and, under that, the words
# the command itself printed — and this is the bound on the second, so that a stack
# trace cannot push the explanation off the screen it is the explanation for. It is
# the bound on WHAT REACHES THE ERROR STORE BELOW, and eleven sites apply it: eight
# read a command's captured error stream, two bound the list of log files a scan could
# not open, and one writes a borrowed prefix of a command's stdout into the capture the
# others read. One bound rather than the eleven copies of a number this replaces is
# what keeps one screen from being quietly more talkative than another.
#
# IT IS NOT THE ONLY BOUND ON WHAT A COMMAND SAID, and the other one is deliberately
# left alone. The delivery trace and the log search each keep the first non-empty line
# of a SKIPPED file's message at 200 characters, so that the list naming those files
# stays a list — a bound paid per file rather than once for the whole message, and a
# different question from this one. Folding the two together would be a decision about
# what those banners may cost, not a substitution.
#
# THE NUMBER WAS CHOSEN AND NEVER MEASURED. Nothing in this tree records where 500
# came from, no document states it, and no screen was ever rendered against a wider
# or a narrower one to see which read better. What this name preserves is that every
# screen keeps the SAME amount; what it does not preserve is any claim that this
# amount is the right one. Whoever changes it is overturning a default nobody
# checked, not a finding — and now changes it in one place rather than eleven.
ZRO_ERROR_KEEP_BYTES=500

# The last underlying failure message, kept in a file rather than a variable.
# Menu code runs operations inside command substitution, so a variable set in
# that subshell would never reach the caller — the operator would be left with
# a bare exit code instead of what the command actually said.
ZRO_ERROR_FILE="${ZRO_ERROR_FILE:-${TMPDIR:-/tmp}/zro-error.$$}"

# THE BOUND IS NOT APPLIED HERE, and that is deliberate. Two callers — the delivery
# trace and the log search — bound what the command said and then APPEND the list of
# log files they could not open, because the one thing those two screens may never do
# is let a skipped file go unmentioned. A bound enforced in this function would let a
# long message from the command spend the whole budget and cut that disclosure off
# the end, which turns a bound into a silence. So the bound belongs to the part that
# came from a command, and each caller applies it to that part before adding its own.
zro_set_error() {
  ( umask 077; printf '%s\n' "$1" >"$ZRO_ERROR_FILE" ) 2>/dev/null || true
}

zro_clear_error() {
  ( umask 077; : >"$ZRO_ERROR_FILE" ) 2>/dev/null || true
}

zro_last_error() {
  [ -f "$ZRO_ERROR_FILE" ] || return 0
  cat -- "$ZRO_ERROR_FILE" 2>/dev/null
}

# Which path answered the last read: soap or ldap. Same file-backed reason as
# the error message above. It matters to the operator, because LDAP does not
# expand values a COS provides.
ZRO_MODE_FILE="${ZRO_MODE_FILE:-${TMPDIR:-/tmp}/zro-mode.$$}"

# Degrading is sticky for the duration of an operation. A screen that made
# three reads, one of which fell back to LDAP, is an LDAP answer as a whole —
# reporting the mode of whichever read happened to run last would hide that.
zro_set_mode() {
  [ "$(zro_mode)" = ldap ] && return 0
  ( umask 077; printf '%s' "$1" >"$ZRO_MODE_FILE" ) 2>/dev/null || true
}

zro_reset_mode() {
  ( umask 077; printf 'soap' >"$ZRO_MODE_FILE" ) 2>/dev/null || true
}

zro_mode() {
  [ -f "$ZRO_MODE_FILE" ] || { printf 'soap'; return 0; }
  cat -- "$ZRO_MODE_FILE" 2>/dev/null
}

# The two files above outlive a subshell on purpose, and a later module needing
# one of its own needs it for exactly the same reason: menu code runs operations
# inside command substitution, so anything the session has to remember across one
# cannot be a variable. They are removed at exit by name, so a module that adds
# one REGISTERS IT rather than being known to this file — which is what keeps this
# module, which depends on nothing, from having to know what a mailbox is.
ZRO_SESSION_FILES=("$ZRO_ERROR_FILE" "$ZRO_MODE_FILE")

# Registered at load time, in the shell that sources the module. Anywhere else it
# would be an append made inside a subshell, which is the very failure the file
# being registered exists to avoid.
zro_session_file() {
  [ -n "${1-}" ] || return "$ZRO_E_INPUT"
  ZRO_SESSION_FILES+=("$1")
}

ZRO_TMPFILES=()

# THE CODE FOR A SCRATCH FILE LIVES HERE, not at the seventeen places that ask for
# one. A bare 1 made each of those translate for itself, which is seventeen copies
# of one decision and was the wrong copy in every case — the reason is on the
# constant above. One place owns the meaning, it cannot drift per site, and the
# eighteenth site inherits it for free. Every caller reads this function through
# $( ), so $? carries the status through. ADR-0016.
#
# AND IT WRITES A LINE, as lib/service.sh and lib/queue.sh do before answering with
# codes of their own. mktemp's own words go to stderr, behind whiptail, so without
# this the screen would be the only account of the failure anywhere. The line
# carries what the screen deliberately does not: the directory mktemp was actually
# given. The screen names TMPDIR, which is where an operator looks; the log names
# what TMPDIR held, which is what a session that set it for itself needs.
zro_tmpfile() {
  local f
  if ! f=$(umask 077; mktemp "${TMPDIR:-/tmp}/zro.XXXXXXXX"); then
    zro_log warn "scratch file could not be created under ${TMPDIR:-/tmp}"
    return "$ZRO_E_NO_SCRATCH"
  fi
  ZRO_TMPFILES+=("$f")
  printf '%s' "$f"
}

zro_cleanup() {
  local f
  # Bash before 4.4 treats "${arr[@]}" on an empty array as an unbound variable
  # under `set -u`; the ${arr[@]+...} guard keeps this safe on the 4.2 floor.
  for f in ${ZRO_TMPFILES[@]+"${ZRO_TMPFILES[@]}"}; do
    [ -e "$f" ] && rm -f -- "$f"
  done
  ZRO_TMPFILES=()
  for f in ${ZRO_SESSION_FILES[@]+"${ZRO_SESSION_FILES[@]}"}; do
    [ -e "$f" ] && rm -f -- "$f"
  done
  return 0
}

zro_human_bytes() {
  local n=$1
  case $n in
    ''|*[!0-9]*) return "$ZRO_E_INPUT" ;;
  esac
  if [ "$n" -lt 1024 ]; then
    printf '%s B' "$n"
    return 0
  fi
  local units=(KB MB GB TB PB)
  local unit value=$n scaled=0
  for unit in "${units[@]}"; do
    scaled=$(( value * 10 / 1024 ))
    value=$(( value / 1024 ))
    if [ "$value" -lt 1024 ]; then
      printf '%s.%s %s' "$value" "$(( scaled % 10 ))" "$unit"
      return 0
    fi
  done
  printf '%s.%s PB' "$value" "$(( scaled % 10 ))"
}
