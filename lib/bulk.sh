# shellcheck shell=bash
# Bulk queries: one directory read, repeated over a list the operator supplied.
# Reads no mailbox, opens no log, and asks the server nothing about itself.
[ -n "${ZRO_LIB_BULK_LOADED:-}" ] && return 0
ZRO_LIB_BULK_LOADED=1

# WHY THE LIST COMES FROM THE OPERATOR, AND WHY THAT IS THE WHOLE DESIGN.
#
# The questions behind this module — which of these accounts are closed, which of
# them forward their mail somewhere — have an obvious implementation that this
# tool may not have: ask the directory for every account and filter the answer.
# `zmprov gqu` and `gaa -v` do exactly that, and on a server carrying more than a
# hundred thousand mailboxes either of them is a production event. They are not
# bounded and offered here; they do not exist here. What replaces them is this:
# the operator says which accounts they mean, and the work grows with THAT list
# and with nothing else.
#
# So the cost class is 1 and its unit is the ENTRY, exactly as it is on the
# account card. A run of two hundred accounts is two hundred class 1 reads, and it
# costs the same on this server as it would on one with fifty mailboxes. That is
# the property the screen is for, and it is why the list is capped rather than
# merely long: a cap is what keeps 'the operator's list' from quietly becoming
# 'the directory'.
#
# THE BATCH MODE THAT READS COMMANDS FROM A FILE IS NOT USED. `zmprov -f` would
# answer all of this in one JVM start, and it would put what runs outside the
# allowlist's view — the file would carry command names this program never wrote,
# which is the same objection that forbids evaluating strings as commands. The
# cost of refusing it is a JVM start per account, and it is disclosed rather than
# hidden: the screen states the estimate before it spends it and shows the run
# advancing through it.

# HOW MANY ADDRESSES ONE RUN WILL READ. Overridable, because the right number
# depends on how long an operator is willing to sit in front of it, and refused
# rather than defaulted when it is not a count — see the plan below.
#
# Two hundred is roughly seven minutes at the per-account estimate below, which is
# about as long as a screen an operator watches can honestly ask for. Past it the
# list is not read and the number left out is stated.
ZRO_BULK_MAX="${ZRO_BULK_MAX:-200}"

# THE LARGEST LIST FILE THIS TOOL WILL OPEN. The file is the operator's, so its
# size is not something this program chose — and a reader with no bound on it is
# how a tool pointed at the wrong path reads a mail store into memory. A quarter
# of a megabyte holds several thousand addresses, which is far past the cap; a
# file bigger than that is a file that is not a list of accounts, and it is
# refused by name rather than read and mostly discarded.
ZRO_BULK_FILE_BYTES="${ZRO_BULK_FILE_BYTES:-262144}"

# WHAT ONE ACCOUNT IS ASSUMED TO COST BEFORE ANY HAS BEEN READ. A zmprov
# invocation is a JVM start, which is seconds rather than milliseconds and does
# not vary much with what is asked for. It stands in for exactly as long as it
# takes the run to measure itself: from the first completed account onwards the
# estimate is what THIS run has been spending, on THIS server, under whatever
# load it is under.
ZRO_BULK_SECONDS=2

# How many refused entries are listed one by one before the rest become a count.
# A list pasted from the wrong column of a spreadsheet can be four hundred entries
# none of which is an address; naming them all would bury the answer under the
# mistake. The number not shown is stated, so the report never quietly shortens
# itself.
ZRO_BULK_REJECT_SHOW=20

# How much of a refused entry is echoed back. Enough to recognise what was typed,
# short enough that one bad paste cannot take the screen.
ZRO_BULK_ENTRY_SHOW=48

# Where the answer column starts on a status row. Wider than an ordinary address
# and NEVER a truncation: an address longer than this pushes its own answer to the
# right rather than being cut, because the address is what an operator matches
# against their own list.
ZRO_BULK_ADDR_W=36

# THE TWO QUESTIONS, as "<id>:<what the report calls it>".
#
# Both are the same shape — one `zmprov ga` per address, differing only in the
# attributes asked for and how the answer is rendered — which is why they are a
# table here rather than two modules. The set is held equal to the operations the
# menu offers, the way the window presets and the allowlist already are, so a
# question implemented here and offered nowhere fails the build.
ZRO_BULK_QUESTIONS='status:Hesap durumu
mail:Filtre ve yonlendirme'

zro_bulk_question_ids() {
  local entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    printf '%s\n' "${entry%%:*}"
  done <<EOF
$ZRO_BULK_QUESTIONS
EOF
}

zro_bulk_question_label() {
  local id=${1-} entry
  [ -n "$id" ] || return "$ZRO_E_INPUT"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ "${entry%%:*}" = "$id" ]; then
      printf '%s' "${entry#*:}"
      return 0
    fi
  done <<EOF
$ZRO_BULK_QUESTIONS
EOF
  return "$ZRO_E_INPUT"
}

# What each question reads. Alphabetical, because that is the order zmprov answers
# in and keeping the two the same makes a captured fixture readable beside the
# list.
#
# The status question asks for ONE attribute although a JVM start costs the same
# for twenty. That is not the account card's trade: this read happens once per
# address, and every attribute asked for is a line the row would have to either
# render or throw away — two hundred times.
ZRO_BULK_STATUS_ATTRS=(zimbraAccountStatus)

# EVERY ATTRIBUTE HERE IS ONE THE MAIL SETTINGS CARD ALSO ASKS FOR, and the suite
# holds it to that. The rule sets are multi-line values, and what tells a
# continuation line from the line that ends one is the set of attribute names the
# reader is given — so this list being a subset of ZRO_MAILSET_ATTRS is what lets
# one reader answer for both screens. An attribute added here and not there would
# cut a filter off at its first line rather than fail.
ZRO_BULK_MAIL_ATTRS=(
  zimbraMailForwardingAddress
  zimbraMailOutgoingSieveScript
  zimbraMailSieveScript
  zimbraPrefMailForwardingAddress
  zimbraPrefMailLocalDeliveryDisabled
)

# --------------------------------------------------------------- the list --

# WHERE ONE ADDRESS ENDS AND THE NEXT BEGINS.
#
# Every character that separates two entries is one an address cannot contain: a
# comma, a semicolon, a line ending of either kind, a tab and a space. That is a
# decision about what an operator is allowed to paste, and it is deliberately
# generous — a list arrives from a spreadsheet column, from a mail client's
# recipient field, from a file somebody wrote by hand, and refusing one of those
# shapes would be this tool insisting on a format nobody has.
#
# THE CARRIAGE RETURN MATTERS MORE THAN IT LOOKS. A list file written on Windows
# ends every line with one, and left on the address it would be validated,
# refused, and reported back as an entry the operator can see nothing wrong with.
zro_bulk_split() {
  # A newline is not in the set being replaced because it is already what
  # separates two entries; '[\n*]' is the standard spelling for "repeat this
  # character to the length of the set", which is also what keeps a reader from
  # having to count two sets of six against each other.
  printf '%s' "${1-}" | tr ',;\r\t ' '[\n*]' | grep -v '^$'
  # Never the pipeline's status: grep answers 1 for a list that was empty, and an
  # empty list is a fact the plan reports rather than a failure to split it.
  return 0
}

# What a refused entry looks like on the report.
#
# SANITISED AND SHORTENED, because this is the one string on the screen that came
# from a file this program did not write. A control character would be a second
# line in the middle of a report, and a paste of the wrong column can be kilobytes
# on one entry. Enough survives to recognise what was typed, which is what the
# operator needs to find it in their own list.
zro_bulk_entry_text() {
  local out
  out=$(printf '%s' "${1-}" | tr '\001-\037\177' '?')
  zro_ui_shorten "$out" "$ZRO_BULK_ENTRY_SHOW"
}

# THE PLAN: every entry judged, before anything runs.
#
#   $1   the operator's text, from a file or typed
#   out  one record per entry, as "<tag><TAB><position><TAB><value>"
#
# FOUR TAGS, because an entry can fail to be read for four different reasons and
# an operator acts differently on each:
#
#   ok    an address this run will read
#   bad   not an address at all — reported with its position and skipped
#   dup   an address already on the list — read once, and the repeat recorded
#   cut   past the cap — not read, and counted
#
# THE POSITION IS THE ENTRY'S OWN, counted among the entries rather than the lines
# of a file: three addresses can be written on one line, and a line number would
# name all three when only one of them was refused.
#
# A REPEATED ADDRESS IS READ ONCE. It costs a JVM start and answers the same thing
# both times, which is the same discipline the cost classes are: what an operation
# spends has to be what the question costs. Case is not what makes two addresses
# different — Zimbra folds them — so the comparison folds them too, and the
# spelling that is read is the one the operator wrote first.
zro_bulk_plan() {
  local raw=${1-} entry n=0 accepted=0 seen='' key
  case $ZRO_BULK_MAX in
    ''|*[!0-9]*)
      zro_log error "denied, the bulk list cap is not a count: $ZRO_BULK_MAX"
      return "$ZRO_E_INPUT" ;;
  esac
  if [ "$ZRO_BULK_MAX" -eq 0 ]; then
    zro_log error "denied, the bulk list cap is zero"
    return "$ZRO_E_INPUT"
  fi

  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    n=$((n + 1))
    if ! zro_validate_email "$entry"; then
      printf 'bad%s%s%s%s\n' "$ZRO_TAB" "$n" "$ZRO_TAB" "$(zro_bulk_entry_text "$entry")"
      continue
    fi
    key=${entry,,}
    case $seen in
      *"|$key|"*)
        printf 'dup%s%s%s%s\n' "$ZRO_TAB" "$n" "$ZRO_TAB" "$entry"
        continue ;;
    esac
    seen="$seen|$key|"
    if [ "$accepted" -ge "$ZRO_BULK_MAX" ]; then
      printf 'cut%s%s%s%s\n' "$ZRO_TAB" "$n" "$ZRO_TAB" "$entry"
      continue
    fi
    accepted=$((accepted + 1))
    printf 'ok%s%s%s%s\n' "$ZRO_TAB" "$n" "$ZRO_TAB" "$entry"
  done <<EOF
$(zro_bulk_split "$raw")
EOF
  return 0
}

zro_bulk_plan_addresses() {
  local rec
  while IFS= read -r rec; do
    case $rec in
      "ok$ZRO_TAB"*) ;;
      *) continue ;;
    esac
    rec=${rec#*"$ZRO_TAB"}
    printf '%s\n' "${rec#*"$ZRO_TAB"}"
  done <<EOF
${1-}
EOF
  return 0
}

zro_bulk_plan_count() {
  local plan=${1-} tag=${2-} n=0 rec
  [ -n "$tag" ] || return "$ZRO_E_INPUT"
  while IFS= read -r rec; do
    case $rec in
      "$tag$ZRO_TAB"*) n=$((n + 1)) ;;
    esac
  done <<EOF
$plan
EOF
  printf '%s' "$n"
}

# One entry that will not be read, as the operator reads it.
zro_bulk_reject_line() {
  case ${1-} in
    bad) printf '%s. oge gecersiz adres: %s\n' "${2-}" "${3-}" ;;
    dup) printf '%s. oge tekrar eden adres: %s\n' "${2-}" "${3-}" ;;
    cut) printf '%s. oge sinira takildi: %s\n' "${2-}" "${3-}" ;;
    *) return "$ZRO_E_INPUT" ;;
  esac
}

# Everything the run will not read, in the order it was written, bounded.
zro_bulk_plan_rejects() {
  local plan=${1-} rec tag pos text shown=0 hidden=0
  while IFS= read -r rec; do
    tag=${rec%%"$ZRO_TAB"*}
    case $tag in
      bad|dup|cut) ;;
      *) continue ;;
    esac
    rec=${rec#*"$ZRO_TAB"}
    pos=${rec%%"$ZRO_TAB"*}
    text=${rec#*"$ZRO_TAB"}
    if [ "$shown" -ge "$ZRO_BULK_REJECT_SHOW" ]; then
      hidden=$((hidden + 1))
      continue
    fi
    shown=$((shown + 1))
    zro_bulk_reject_line "$tag" "$pos" "$text"
  done <<EOF
$plan
EOF
  if [ "$hidden" -gt 0 ]; then
    printf '(ve %s girdi daha)\n' "$hidden"
  fi
  return 0
}

# --------------------------------------------------------------- the file --

# WHAT IS WRONG WITH THIS PATH, IN ONE WORD, or 'ok'.
#
# Seven answers rather than a yes and a no, because the screen behind this says
# what to do about each and they are not the same thing: a path that is not one
# this tool will open, a file that is not there, a directory named where a file
# was meant, a file this account cannot read, an empty file, and a file too large
# to be a list. Only the first is about what the operator typed.
#
# THE SIZE IS PART OF ADMISSION, not something checked while reading. A bound
# applied afterwards is a file already in memory.
zro_bulk_file_verdict() {
  local p=${1-} size
  zro_validate_list_path "$p" || { printf 'shape'; return 0; }
  [ -e "$p" ] || { printf 'missing'; return 0; }
  [ -f "$p" ] || { printf 'notfile'; return 0; }
  [ -r "$p" ] || { printf 'unreadable'; return 0; }
  # The same stat the log inventory makes, from the module that owns every stat in
  # this program. A size nothing could answer for is a file this tool will not
  # read: it cannot say what it would be reading.
  size=$(zro_inv_size "$p")
  case $size in
    ''|*[!0-9]*) printf 'unreadable'; return 0 ;;
  esac
  if [ "$size" -eq 0 ]; then
    printf 'empty'
    return 0
  fi
  if [ "$size" -gt "$ZRO_BULK_FILE_BYTES" ]; then
    printf 'toobig'
    return 0
  fi
  printf 'ok'
}

# The file, or a refusal. Judged again here rather than only by the caller,
# because this is the function that opens it and a path that reached it unjudged
# would be a defect invisible from the call site.
zro_bulk_read_file() {
  local p=${1-} verdict
  verdict=$(zro_bulk_file_verdict "$p")
  if [ "$verdict" != ok ]; then
    zro_log error "denied, list file refused as $verdict: $p"
    return "$ZRO_E_INPUT"
  fi
  cat -- "$p"
}

# ------------------------------------------------------------ the estimate --

# HOW LONG THE REST OF THIS RUN WILL TAKE.
#
#   $1  accounts read so far   $2  accounts on the list   $3  seconds so far
#
# Measured rather than declared, from the second account onwards: a JVM start on a
# server under load is not the same as one on an idle one, and the number an
# operator is deciding on is how long THIS run will take on THIS server. The
# declared per-account estimate stands in only until the run has something of its
# own to say.
#
# ROUNDED UP, so that a run with work left never reports nothing left.
zro_bulk_eta() {
  local done_n=${1-} total=${2-} elapsed=${3-} left
  case $done_n in ''|*[!0-9]*) return "$ZRO_E_INPUT" ;; esac
  case $total in ''|*[!0-9]*) return "$ZRO_E_INPUT" ;; esac
  case $elapsed in ''|*[!0-9]*) return "$ZRO_E_INPUT" ;; esac
  [ "$done_n" -le "$total" ] || return "$ZRO_E_INPUT"

  left=$((total - done_n))
  if [ "$left" -le 0 ]; then
    printf '0'
    return 0
  fi
  if [ "$done_n" -le 0 ] || [ "$elapsed" -le 0 ]; then
    printf '%s' "$((left * ZRO_BULK_SECONDS))"
    return 0
  fi
  printf '%s' "$(( (elapsed * left + done_n - 1) / done_n ))"
}

# A number of seconds as an operator reads a clock. The seconds are dropped past
# an hour: a run that long is one somebody walks away from, and a precision of one
# second in it would be a precision this estimate does not have.
zro_bulk_duration() {
  local s=${1-}
  case $s in ''|*[!0-9]*) return "$ZRO_E_INPUT" ;; esac
  if [ "$s" -ge 3600 ]; then
    printf '%s sa %s dk' "$((s / 3600))" "$(( (s % 3600) / 60 ))"
    return 0
  fi
  if [ "$s" -ge 60 ]; then
    printf '%s dk %s sn' "$((s / 60))" "$((s % 60))"
    return 0
  fi
  printf '%s sn' "$s"
}

# WHERE THE RUN HAS GOT TO, drawn before each account rather than after it: the
# address on the screen is the one being read, so a run that stops on a slow
# account says which one.
#
# The way out is on it. A screen that spends minutes and says nothing about
# stopping is a screen an operator abandons with Ctrl-C, which loses everything it
# had found.
zro_bulk_progress() {
  local done_n=${1-} total=${2-} eta=${3-} addr=${4-}
  printf 'Toplu sorgu calisiyor: %s / %s\n\n' "$((done_n + 1))" "$total"
  printf 'Siradaki adres: %s\n' "$addr"
  printf 'Tahmini kalan sure: %s\n\n' "$(zro_bulk_duration "$eta")"
  printf 'Durdurmak icin ESC tusuna basin. Durdurulan sorgu o ana kadar\n'
  printf 'bulduklarini korur ve sonucu EKSIK olarak isaretler.'
}

# ---------------------------------------------------------------- the read --

# ONE ACCOUNT, ONE DIRECTORY READ. The only function in this module that runs
# anything, which is what leaves everything below it pure and drivable without a
# server.
zro_bulk_read() {
  local q=${1-} acct=${2-}
  # The question first: an id this tool does not ask must reach no directory at
  # all, whatever address it was given.
  zro_bulk_question_label "$q" >/dev/null || return "$ZRO_E_INPUT"
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"
  case $q in
    status) zro_prov_read "$ZRO_E_NO_ACCOUNT" ga "$acct" "${ZRO_BULK_STATUS_ATTRS[@]}" ;;
    mail)   zro_prov_read "$ZRO_E_NO_ACCOUNT" ga "$acct" "${ZRO_BULK_MAIL_ATTRS[@]}" ;;
    # Unreachable while this list agrees with the table above, and here so that
    # they may only disagree loudly.
    *) zro_log error "denied, no bulk read for question: $q"
       return "$ZRO_E_INPUT" ;;
  esac
}

# ---------------------------------------------------------------- the rows --
#
# Pure. What an account turned out to hold, rendered — held apart from the read
# above so that what an operator sees can be asserted without a directory.

# WHY AN ACCOUNT HAS NO ANSWER, in the words the summary counts it under.
#
# A MISSING ACCOUNT IS AN ANSWER AND A FAILED READ IS NOT, and that difference
# decides whether the whole run is reported as incomplete. An address on an
# operator's list that the directory does not hold is exactly what a list audit is
# for; a read that could not run means nothing was learned about that address, and
# the run may not be presented as covering it.
zro_bulk_failure_word() {
  case ${1-} in
    "$ZRO_E_NO_ACCOUNT") printf 'HESAP YOK' ;;
    *) printf 'OKUNAMADI (kod %s)' "${1-}" ;;
  esac
}

# One account on the status list, as "<address> <status>".
#
# THE STATUS IS THE SERVER'S OWN WORD, untranslated: `active`, `closed`, `locked`,
# `maintenance`, `pending`, `lockout`. It is what `zmprov` prints, what the account
# card shows, and what an operator will type into whatever they do next.
zro_bulk_status_row() {
  local acct=${1-} rc=${2-} raw=${3-} status
  if [ "$rc" -ne 0 ]; then
    printf '%-*s %s\n' "$ZRO_BULK_ADDR_W" "$acct" "$(zro_bulk_failure_word "$rc")"
    return 0
  fi
  status=$(zro_attr_get "$raw" zimbraAccountStatus)
  printf '%-*s %s\n' "$ZRO_BULK_ADDR_W" "$acct" "${status:-$ZRO_TXT_UNSET}"
}

# A field of one account's mail block: the first value on the labelled line, the
# rest hanging under it, so a second forwarding address never loses its label.
zro_bulk_mail_lines() {
  local label=${1-} values=${2-} first=1 v
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    if [ "$first" -eq 1 ]; then
      printf '  %s: %s\n' "$label" "$v"
      first=0
    else
      printf '  %*s  %s\n' "${#label}" '' "$v"
    fi
  done <<EOF
$values
EOF
  return 0
}

# One account's mail settings, as a block — and as ONE LINE when there is nothing
# to report.
#
# THAT SHAPE IS THE POINT OF THIS SCREEN. An audit run after an incident is two
# hundred accounts of which four have a forward, and a report that spent four
# lines on each of the other hundred and ninety-six would bury them. What is
# printed is what is SET: an account with nothing set says so in one line, and
# every line that appears is a fact somebody has to explain.
#
# THE TWO KINDS OF FORWARDING STAY SEPARATE, as they are on the account card and
# on the mail settings card. The administrator-set one does not appear in the
# account holder's own client, which is exactly why an audit is looking for it.
zro_bulk_mail_row() {
  local acct=${1-} rc=${2-} raw=${3-} admin user local_d incoming outgoing said=0
  if [ "$rc" -ne 0 ]; then
    printf '%s\n  %s\n' "$acct" "$(zro_bulk_failure_word "$rc")"
    return 0
  fi

  admin=$(zro_attr_all "$raw" zimbraMailForwardingAddress)
  user=$(zro_attr_all "$raw" zimbraPrefMailForwardingAddress)
  local_d=$(zro_attr_get "$raw" zimbraPrefMailLocalDeliveryDisabled)
  # The whole rule set, through the reader that knows a continuation line from the
  # line that ends a value. What is shown is the count it comes to; the rule set
  # itself belongs to the screen an operator opens for one account.
  incoming=$(zro_mailset_script "$raw" zimbraMailSieveScript)
  outgoing=$(zro_mailset_script "$raw" zimbraMailOutgoingSieveScript)

  printf '%s\n' "$acct"
  if [ -n "$admin" ]; then
    zro_bulk_mail_lines 'Yonetici tanimli yonlendirme' "$admin"
    said=1
  fi
  if [ -n "$user" ]; then
    zro_bulk_mail_lines 'Kullanici tanimli yonlendirme' "$user"
    said=1
  fi
  if [ "$local_d" = TRUE ]; then
    printf '  Yerel teslim: %s\n' "$(zro_local_delivery_field "$local_d")"
    said=1
  fi
  if [ -n "$incoming" ]; then
    printf '  Gelen filtre: %s\n' "$(zro_filter_summary "$incoming")"
    said=1
  fi
  if [ -n "$outgoing" ]; then
    printf '  Giden filtre: %s\n' "$(zro_filter_summary "$outgoing")"
    said=1
  fi
  if [ "$said" -eq 0 ]; then
    # 'kapatilmamis' and never 'acik': an absent attribute is not FALSE, and what
    # Zimbra does when nobody set it is a fact about Zimbra rather than a value
    # read off this account.
    printf '  yonlendirme yok, filtre yok, yerel teslim kapatilmamis\n'
  fi
  return 0
}

zro_bulk_row() {
  local q=${1-}
  shift
  case $q in
    status) zro_bulk_status_row "$@" ;;
    mail)   zro_bulk_mail_row "$@" ;;
    *) zro_log error "denied, no bulk row for question: $q"
       return "$ZRO_E_INPUT" ;;
  esac
}

# WHAT ONE ACCOUNT IS COUNTED AS IN THE SUMMARY, as zero or more words.
#
# The words are what the summary is written in, so they are produced here beside
# the row rather than derived from it: a summary parsed back out of rendered text
# would agree with the rendering by construction and with the account by luck.
#
# A STATUS RUN COUNTS EACH ACCOUNT ONCE and a mail run may count one account
# several times, which is not an inconsistency: the questions are different. One
# asks what an account IS, and an account has one status. The other asks what is
# happening to its mail, and an account can have a forward AND a filter AND local
# delivery off — which is the combination an audit is looking for.
zro_bulk_tally() {
  local q=${1-} rc=${2-} raw=${3-} status admin user local_d
  case $q in
    status|mail) ;;
    *) return "$ZRO_E_INPUT" ;;
  esac

  if [ "$rc" -ne 0 ]; then
    case $rc in
      "$ZRO_E_NO_ACCOUNT") printf 'hesap yok\n' ;;
      *) printf 'okunamadi\n' ;;
    esac
    return 0
  fi

  if [ "$q" = status ]; then
    status=$(zro_attr_get "$raw" zimbraAccountStatus)
    printf '%s\n' "${status:-$ZRO_TXT_UNSET}"
    return 0
  fi

  admin=$(zro_attr_all "$raw" zimbraMailForwardingAddress)
  user=$(zro_attr_all "$raw" zimbraPrefMailForwardingAddress)
  local_d=$(zro_attr_get "$raw" zimbraPrefMailLocalDeliveryDisabled)
  if [ -n "$admin" ] || [ -n "$user" ]; then
    printf 'yonlendirmesi olan\n'
  fi
  if [ -n "$admin" ]; then
    printf 'yonetici tanimli yonlendirmesi olan\n'
  fi
  if [ -n "$(zro_mailset_script "$raw" zimbraMailSieveScript)" ] ||
     [ -n "$(zro_mailset_script "$raw" zimbraMailOutgoingSieveScript)" ]; then
    printf 'filtresi olan\n'
  fi
  if [ "$local_d" = TRUE ]; then
    printf 'yerel teslimi kapali\n'
  fi
  return 0
}

# The counts, one line per word, in an order that does not depend on the order the
# list happened to be written in.
zro_bulk_summary() {
  local words=${1-} line n label
  [ -n "$words" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # uniq -c pads its count with leading spaces.
    line=${line#"${line%%[![:space:]]*}"}
    n=${line%% *}
    label=${line#* }
    zro_card_line "$label" "$n"
  done <<EOF
$(printf '%s\n' "$words" | grep -v '^$' | LC_ALL=C sort | uniq -c)
EOF
  return 0
}

# ---------------------------------------------------------- the disclosures --

# Printed above a run the operator ended.
#
# IT GOES FIRST, above the answer it qualifies, exactly as the log search's own
# banner does and for the same reason: a caveat read after the conclusion has been
# drawn is not a caveat. What it has to carry is the number of addresses that were
# never read, because a report of forty rows on a list of two hundred reads as an
# answer about two hundred accounts.
zro_bulk_stopped_banner() {
  local read_n=${1-} total=${2-}
  printf 'UYARI: SORGU DURDURULDU. Listedeki %s adresten %s tanesi sorgulandi;\n' \
    "$total" "$read_n"
  printf '       kalan %s adres HIC OKUNMADI. Asagidaki sonuc EKSIKTIR: burada\n' \
    "$((total - read_n))"
  printf '       bir sey gorunmemesi, o adreslerde bir sey OLMADIGINI KANITLAMAZ.\n'
  printf '\n'
}

# Printed above a run that reached every address and could not read some of them.
# The other way a bulk answer can be incomplete, and a different sentence: nothing
# was skipped, the server did not answer.
zro_bulk_missed_banner() {
  local missed=${1-}
  printf 'UYARI: EKSIK SONUC. %s adres okunamadi ve o adresler hakkinda hicbir\n' "$missed"
  printf '       sey ogrenilemedi. Asagida OKUNAMADI olarak isaretlidirler.\n'
  printf '\n'
}

# ----------------------------------------------------------------- the run --

# EVERY ADDRESS ON THE PLAN, READ ONE AT A TIME, and the report of what they said.
#
#   $1  a declared question   $2  where the list came from   $3  the plan
#   out the report
#
# THREE ENDINGS, as the log search has three, because an operator acts differently
# on each:
#   every address read                    0
#   stopped, or an address unreadable     the answer, a banner, and $ZRO_E_PARTIAL
#   nothing to read at all                $ZRO_E_INPUT and no report
#
# $ZRO_E_PARTIAL COVERS BOTH WAYS OF BEING INCOMPLETE — a run the operator ended
# and an address the directory would not answer for. They are different sentences
# on the screen and the same fact to a caller: the answer does not cover the whole
# list, so a row that is not in it proves nothing.
#
# THE STOP IS ASKED BEFORE EACH READ AND NEVER DURING ONE. A JVM start is not
# interruptible from here, so the granularity of stopping is one account — which
# is what an operator means by stopping anyway, and what keeps a half-read answer
# from ever reaching the report.
zro_bulk_run() {
  local q=${1-} source=${2-} plan=${3-}
  local label addresses total read_n=0 addr raw rc row
  local bodies='' tally='' missed=0 stopped=0 t0 now elapsed eta
  local bad dup cut rejects

  label=$(zro_bulk_question_label "$q") || return "$ZRO_E_INPUT"
  addresses=$(zro_bulk_plan_addresses "$plan")
  if [ -z "$addresses" ]; then
    # Not a failure of the run: a list with no address on it is a fact about the
    # list, and the screen says which of the reasons it was. Refused here so that
    # no report is ever drawn over an empty run.
    return "$ZRO_E_INPUT"
  fi
  total=$(printf '%s\n' "$addresses" | grep -c .)

  zro_reset_mode
  t0=$(zro_win_now) || t0=0

  while IFS= read -r addr; do
    [ -n "$addr" ] || continue
    if zro_ui_stop_requested; then
      stopped=1
      break
    fi

    elapsed=0
    if [ "$t0" -gt 0 ]; then
      now=$(zro_win_now) || now=$t0
      if [ "$now" -gt "$t0" ]; then
        elapsed=$((now - t0))
      fi
    fi
    eta=$(zro_bulk_eta "$read_n" "$total" "$elapsed") || eta=0
    zro_ui_notice "Toplu sorgu" "$(zro_bulk_progress "$read_n" "$total" "$eta" "$addr")"

    rc=0
    raw=$(zro_bulk_read "$q" "$addr") || rc=$?
    row=$(zro_bulk_row "$q" "$addr" "$rc" "$raw")
    bodies="$bodies$row
"
    tally="$tally$(zro_bulk_tally "$q" "$rc" "$raw")
"
    # A missing account is an answer; anything else is an address this run did not
    # cover, and the report may not present itself as covering it.
    if [ "$rc" -ne 0 ] && [ "$rc" -ne "$ZRO_E_NO_ACCOUNT" ]; then
      missed=$((missed + 1))
    fi
    read_n=$((read_n + 1))
  done <<EOF
$addresses
EOF

  # --- the report ---
  zro_mode_banner
  if [ "$stopped" -eq 1 ]; then
    zro_bulk_stopped_banner "$read_n" "$total"
  fi
  if [ "$missed" -gt 0 ]; then
    zro_bulk_missed_banner "$missed"
  fi

  zro_card_line 'Soru' "$label"
  zro_card_line 'Liste kaynagi' "$source"
  zro_card_line 'Sorgulanan adres' "$read_n"

  bad=$(zro_bulk_plan_count "$plan" bad)
  dup=$(zro_bulk_plan_count "$plan" dup)
  cut=$(zro_bulk_plan_count "$plan" cut)
  if [ "$bad" -gt 0 ]; then
    zro_card_line 'Gecersiz girdi' "$bad"
  fi
  if [ "$dup" -gt 0 ]; then
    zro_card_line 'Tekrar eden adres' "$dup"
  fi
  if [ "$cut" -gt 0 ]; then
    # THE CAP IS STATED WHEREVER IT APPLIED, never applied silently. A list that
    # was shortened is a list whose answer is about fewer accounts than the
    # operator handed over.
    zro_card_line 'Sinira takilan' "$cut (en fazla $ZRO_BULK_MAX adres sorgulanir)"
  fi

  rejects=$(zro_bulk_plan_rejects "$plan")
  if [ -n "$rejects" ]; then
    zro_card_head 'Sorgulanmayan girdiler'
    printf '%s\n' "$rejects"
  fi

  zro_card_head "$label"
  printf '%s' "$bodies"

  zro_card_head 'Ozet'
  # A MAIL RUN CAN COUNT NOTHING AT ALL, and that is the answer an audit hopes
  # for: no account on the list forwards anything, filters anything or has local
  # delivery switched off. Said in words rather than left as a heading with
  # nothing under it, which reads as a summary that failed to render. A status run
  # never lands here — every account contributes a word, if only 'hesap yok'.
  local summary
  summary=$(zro_bulk_summary "$tally")
  if [ -n "$summary" ]; then
    printf '%s\n' "$summary"
  else
    printf 'Sayilacak bir sey cikmadi: sorgulanan hesaplarda bu ekranin\n'
    printf 'listeledigi ayarlardan hicbiri tanimli degil.\n'
  fi

  printf '\n'
  printf 'Her adres icin dizinde BIR sorgu calisti. Hicbir mailbox acilmadi ve\n'
  printf 'sunucu genelinde hicbir tarama yapilmadi: bu ekranin maliyeti listenin\n'
  printf 'uzunlugu kadardir, sunucudaki hesap sayisi kadar degil.\n'

  if [ "$stopped" -eq 1 ] || [ "$missed" -gt 0 ]; then
    return "$ZRO_E_PARTIAL"
  fi
  return 0
}
