# shellcheck shell=bash
# FINDING A MESSAGE INSIDE A MAILBOX, and listing the messages of one
# conversation. Both run behind the existence gate, through the one function that
# owns the gated binary, and neither of them marks anything read.
[ -n "${ZRO_LIB_SEARCH_LOADED:-}" ] && return 0
ZRO_LIB_SEARCH_LOADED=1

# WHAT THIS FILE IS FOR, in one sentence: it turns criteria an operator chose into
# ONE query in Zimbra's own language, and turns the table that comes back into rows
# this program can act on. Nothing here names a binary — every read leaves through
# zro_mbox_run, which runs the existence oracle first — and nothing here builds a
# command line: the query travels as a single element of an argument vector.
#
# THE READS ARE READS IN EFFECT, measured rather than assumed. On TEST-C the
# account's row in the `mailbox` table was byte-identical either side of a pass of
# both commands — change checkpoint, item id checkpoint, size checkpoint and last
# SOAP access included — and the sharper control held too: the same four message
# ids answered `is:unread` before and after roughly forty searches and five
# conversation listings, and `gaf` reported the same unread count. That is the
# question `gm` fails, which is why `gm` is not on the allowlist and this is. See
# docs/research/2026-08-03-message-search-and-conversations.md §1.
#
# THE SUBCOMMANDS ARE WRITTEN AT THEIR CALL SITES, LITERALLY, exactly as the folder
# reads are, so that a static reader can prove which operations this module is able
# to ask for. The suite holds the set it extracts equal to the allowlist's entries
# for that binary in both directions.

# HOW MANY HITS ONE SEARCH MAY RETURN. The server's own bound is 1 to 1000 and its
# default is 25; this is the number that reaches the operator, so it is declared
# here and disclosed on the screen rather than left as whatever the CLI does today.
#
# A BOUND ON THE OUTPUT IS NOT A BOUND ON THE SEARCH, and the difference is the one
# the log search already turns on: the server examines the whole mailbox and
# returns the newest page of what it found. So a capped answer is not a partial
# scan — nothing went unread — and the screen says `daha var` from the server's own
# `more:` flag instead of leaving the operator to guess whether the list ended.
ZRO_SEARCH_LIMIT="${ZRO_SEARCH_LIMIT:-50}"

# THE QUERY A CONVERSATION LISTING IS MADE WITH, and it is this program's own text
# rather than anything an operator typed. `sc` takes a conversation id AND a query;
# with no query it prints its usage banner on stdout and exits 1, which is not an
# error message and not an answer.
#
# `is:anywhere` because the default scope drops Trash and Junk: a listing that
# claims to show the conversation may not quietly leave out the message somebody
# deleted, which is usually the message the operator is looking for.
ZRO_SEARCH_CONV_QUERY='is:anywhere'

# The longest value this program will search for. Generous for a subject line — the
# transfer agent bounds a header at 998 characters and nobody types one — and
# finite, because the value reaches a command line and a screen.
ZRO_SEARCH_TEXT_MAX=200

# ------------------------------------------------------------- the criteria --
#
# THE ONE LIST OF WHAT MAY BE ASKED, as "<id>:<kind>:<operator>:<label>".
#
# The ID is what the screen hands back, and it is a fixed identifier this program
# wrote. The KIND decides how the value is validated and how it is written into the
# query — that is the whole of the difference between an address and a domain, and
# between a day and a folder. The OPERATOR is the query language's own field name.
# The LABEL is what the operator reads.
#
# ONE TABLE RATHER THAN A FUNCTION PER CRITERION, for the reason the menu's own
# list gives: a criterion cannot arrive without a kind the builder knows, and the
# suite holds the kinds this table names equal to the kinds the builder implements,
# in both directions. A criterion nobody can build fails the build; a kind nobody
# claims does too.
#
# THE OPERATORS ARE MEASURED. Every one of them was run against the lab server on
# 2026-08-03 and answered without a parse error, and the ones that could be made to
# match really matched: research §7. Two are recorded there as answering nothing on
# that server — the envelope pair — and the screen says so, because an empty result
# presented as proof is the worst thing a search screen can do.
ZRO_SEARCH_CRITERIA='sender:address:from:Gonderen adres
sender-domain:domain:from:Gonderen alan adi
recipient:address:to:Alici adres
env-sender:address:envfrom:Zarf gondereni (envelope sender)
env-recipient:address:envto:Zarf alicisi (envelope recipient)
subject:text:subject:Konu
msgid:msgid:msgid:Ileti kimligi (Message-ID)
day:dayspan:after:Tarih (tek gun)
day-from:day:after:Baslangic gunu (dahil)
day-to:dayend:before:Bitis gunu (dahil)
attachment-name:text:filename:Ek dosya adi
attachment-type:atype:attachment:Ek turu
state:state:is:Okundu / okunmadi
folder:folder:in:Klasor
scope:scope:is:Butun mailbox (cop kutusu ve spam dahil)'

# The declared entry for a criterion id, or a refusal. Every lookup goes through
# this, so an id nobody declared has one answer everywhere.
zro_search_criterion() {
  local id=${1-} entry
  [ -n "$id" ] || return "$ZRO_E_INPUT"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ "${entry%%:*}" = "$id" ]; then
      printf '%s' "$entry"
      return 0
    fi
  done <<EOF
$ZRO_SEARCH_CRITERIA
EOF
  return "$ZRO_E_INPUT"
}

zro_search_ids() {
  local entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    printf '%s\n' "${entry%%:*}"
  done <<EOF
$ZRO_SEARCH_CRITERIA
EOF
}

zro_search_kind() {
  local entry
  entry=$(zro_search_criterion "${1-}") || return "$ZRO_E_INPUT"
  entry=${entry#*:}
  printf '%s' "${entry%%:*}"
}

zro_search_operator() {
  local entry
  entry=$(zro_search_criterion "${1-}") || return "$ZRO_E_INPUT"
  entry=${entry#*:}
  entry=${entry#*:}
  printf '%s' "${entry%%:*}"
}

zro_search_label() {
  local entry
  entry=$(zro_search_criterion "${1-}") || return "$ZRO_E_INPUT"
  entry=${entry#*:}
  entry=${entry#*:}
  printf '%s' "${entry#*:}"
}

# THE VALUES THIS PROGRAM OWNS, for the two criteria an operator does not type at
# all. They are offered as a menu and come back as one of these words, so nothing
# an operator wrote reaches the query for either.
#
# The attachment types are Zimbra's own friendly names, which it maps to MIME types
# itself. Only the ones a mail administrator asks about are offered: the list in
# the source is longer, and an operation arrives with the question that needs it.
# WHAT THE OPERATOR IS ASKED FOR, ONE PROMPT PER KIND, and the kind is what
# decides it: two criteria that take an address are asked for one the same way.
#
# HERE RATHER THAN ON THE SCREEN, because the kinds are declared here and a kind
# whose prompt lived somewhere else could arrive without one — which is a criterion
# an operator can select and nothing can ask them for. The suite holds this table
# and the kinds equal in both directions, so the two may only disagree loudly.
#
# THREE KINDS ARE ABSENT ON PURPOSE and are named in that same check: the read
# state and the attachment type are MENUS of words this program owns, so nothing is
# typed into them at all, and the whole-mailbox criterion carries no value.
ZRO_SEARCH_PROMPTS='address:Adres (ornek: ali@ornek.com)
domain:Alan adi (ornek: ornek.com)
msgid:Ileti kimligi (ornek: CAabc123@ornek.com)

Baslik satirindaki koseli parantezler (< >) yazilsa da yazilmasa da olur, arac
onlari kaldirir. Buyuk-kucuk harf farki onemlidir.
text:Aranacak metin. Bosluk serbesttir; tirnak isareti de yazilabilir, arac onu
sorgu dili icin kendisi kacisla korur.
day:Gun (ornek: 2026-07-28)

Tarih sunucuya gunun basindaki an olarak, milisaniye sayisi halinde gonderilir:
boylece sunucunun yerel tarih bicimi sonucu degistiremez.
dayend:Gun (ornek: 2026-07-28)

Bitis gunu ARAMAYA DAHILDIR: sunucuya o gunun sonu gonderilir.
dayspan:Gun (ornek: 2026-07-28)

Yalnizca o gun aranir. Sunucuya gunun basi ve sonu iki sinir olarak gonderilir.
folder:Klasor yolu (ornek: /Inbox veya /Projeler/2026)

Yollari "Klasorler" ekranindan gorebilirsiniz. Bir klasor secildiginde arama
YALNIZCA o klasorde yapilir; alt klasorleri kapsamaz.'

# The prompt for a kind, or a refusal for one that is not asked for at all.
#
# A value may run over several lines — a prompt says what the tool will do with
# what is typed — so an entry ends where the next kind begins, and a kind begins a
# new entry only when it is one of the declared kinds. That is the same rule the
# mail settings reader applies to a multi-line attribute: what ends a value is
# DECLARED, never guessed from the shape of a line.
zro_search_prompt() {
  local want=${1-} line key text='' found=1
  [ -n "$want" ] || return "$ZRO_E_INPUT"
  while IFS= read -r line; do
    key=${line%%:*}
    if [ "$key" != "$line" ] && zro_search_kind_declared "$key"; then
      [ "$found" -eq 0 ] && break
      if [ "$key" = "$want" ]; then
        found=0
        text=${line#*:}
      fi
      continue
    fi
    [ "$found" -eq 0 ] && text="$text
$line"
  done <<EOF
$ZRO_SEARCH_PROMPTS
EOF
  [ "$found" -eq 0 ] || return "$ZRO_E_INPUT"
  printf '%s' "$text"
}

# Whether a word is a kind some declared criterion claims. Read by the prompt
# reader above to decide where one entry ends, and by the suite to hold the two
# tables equal.
zro_search_kind_declared() {
  local want=${1-} id
  [ -n "$want" ] || return 1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$(zro_search_kind "$id")" = "$want" ] && return 0
  done <<EOF
$(zro_search_ids)
EOF
  return 1
}

ZRO_SEARCH_STATES='read:Okunmus
unread:Okunmamis'

ZRO_SEARCH_ATTACHMENTS='any:Herhangi bir ek
pdf:PDF
word:Word
excel:Excel
ppt:PowerPoint
image:Resim
none:Eki olmayan iletiler'

# Whether a word is one this program offers, and what it reads as. One lookup for
# both tables, because the question is the same one twice.
zro_search_choice_label() {
  local table=${1-} value=${2-} entry
  [ -n "$value" ] || return "$ZRO_E_INPUT"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ "${entry%%:*}" = "$value" ]; then
      printf '%s' "${entry#*:}"
      return 0
    fi
  done <<EOF
$table
EOF
  return "$ZRO_E_INPUT"
}

# ---------------------------------------------------------- building a term --

# Free text, as a subject or a file name: what an operator types into the two
# criteria that are not an address, a date or a word this program owns.
#
# WHAT IS REFUSED IS WHAT WOULD STOP BEING ONE VALUE, the same rule the folder path
# and the message-id live by. A newline cannot appear inside a quoted term at all;
# a control character is a second line in the report that says what was searched
# for; and a value that is only spaces is a query with a criterion that asks
# nothing. Surrounding spaces are refused rather than trimmed, because a phrase
# search for ' fatura' and for 'fatura' are the same search and only one of them is
# what the operator can see they typed.
#
# EVERYTHING IN BETWEEN IS ADMITTED, punctuation included: a subject is written by
# whoever sent the message, in their own language, and the quoter is what makes
# that safe.
zro_search_validate_text() {
  local s=${1-}
  [ -n "$s" ] || return "$ZRO_E_INPUT"
  [ "${#s}" -le "$ZRO_SEARCH_TEXT_MAX" ] || return "$ZRO_E_INPUT"
  case $s in *[[:cntrl:]]*) return "$ZRO_E_INPUT" ;; esac
  case $s in [[:space:]]*|*[[:space:]]) return "$ZRO_E_INPUT" ;; esac
  return 0
}

# A DAY, AS EPOCH MILLISECONDS, which is the only date form this tool sends.
#
#   $1  a day, as YYYY-MM-DD
#   $2  days to add — 0 for the day itself, 1 for the midnight that ends it
#
# THE ABSOLUTE FORM IS LOCALE-DEPENDENT AND IS NOT USED. Zimbra parses an absolute
# date with the request locale's short format, falling back to mm/dd/yyyy, and
# refuses ISO outright — measured: `date:2026-07-01` is a parse error. A count of
# milliseconds means the same thing in every locale, which is the same reason the
# mailbox size is asked for as a raw byte count rather than as the string the JVM
# formats.
#
# BOTH ENDS LAND ON MIDNIGHT, AND THE SERVER COMPARES THE INSTANT — measured, on a
# mailbox holding messages on two known days: `after:<midnight of the 3rd>`
# answered with every message of the 3rd and `before:<midnight of the 3rd>` with
# none of them. So a range from the start of the first day to the start of the day
# after the last one covers exactly the days the operator named, and neither end
# quietly loses its own day.
#
# The day goes through the same validator and the same clock the arrival window
# uses, so there is one date parser in this program and one calendar: a day the
# calendar does not have — 2026-02-30 — is refused by the clock rather than by a
# table of month lengths kept here.
zro_search_day_ms() {
  local day=${1-} plus=${2-0} secs
  case $plus in ''|*[!0-9]*) return "$ZRO_E_INPUT" ;; esac
  secs=$(zro_win_epoch "$day 00:00") || return "$ZRO_E_INPUT"
  printf '%s' "$(( (secs + plus * 86400) * 1000 ))"
}

# ONE CRITERION AS ONE TERM OF THE QUERY.
#
#   $1  a declared criterion id      $2  its value
#
# The value is validated HERE, by the kind the table declares, and never by the
# screen alone: this is the function that writes operator text into a query, and a
# value that reached it unvalidated would be a defect invisible from the call site.
#
# THE DOMAIN IS THE ONE VALUE THAT IS NOT QUOTED, and that is a decision rather
# than an omission. A leading '@' is what makes the query language read the value
# as a whole domain rather than as text, so it stands outside anything the quoter
# would wrap — and the domain validator admits letters, digits, dots and hyphens
# and nothing else, so there is no character left for quoting to protect. The
# quoted form was not measured, and an unverified assumption is not a green light.
#
# THE WORDS THIS PROGRAM OWNS ARE NOT QUOTED EITHER, for the opposite reason: they
# never came from an operator. They are checked against the table that declares
# them, so a word nobody offered cannot arrive here from a screen.
# The second operator of the one criterion that writes two terms. Declared beside
# the table rather than written into the builder, so that the pair a single day
# becomes is as readable as the criteria whose operator the table names.
ZRO_SEARCH_OP_DAY_END=before

zro_search_term() {
  local id=${1-} value=${2-} kind op quoted ms end
  kind=$(zro_search_kind "$id") || return "$ZRO_E_INPUT"
  op=$(zro_search_operator "$id") || return "$ZRO_E_INPUT"

  case $kind in
    address)
      zro_validate_email "$value" || return "$ZRO_E_INPUT"
      quoted=$(zro_query_quote "$value") || return "$ZRO_E_INPUT"
      printf '%s:%s' "$op" "$quoted" ;;
    domain)
      # A '@' the operator typed in front of it is taken off first: the validator
      # refuses one, and typing the domain marker is the likeliest thing an
      # operator does on a prompt that asks for a domain.
      value=${value#@}
      zro_validate_domain "$value" || return "$ZRO_E_INPUT"
      printf '%s:@%s' "$op" "$value" ;;
    text)
      zro_search_validate_text "$value" || return "$ZRO_E_INPUT"
      quoted=$(zro_query_quote "$value") || return "$ZRO_E_INPUT"
      printf '%s:%s' "$op" "$quoted" ;;
    msgid)
      # The angle brackets a header carries are already refused by the validator,
      # and they matter here rather than only there: measured on the lab server,
      # `msgid:"<id>"` matches nothing while the bare identifier matches.
      zro_validate_msgid "$value" || return "$ZRO_E_INPUT"
      quoted=$(zro_query_quote "$value") || return "$ZRO_E_INPUT"
      printf '%s:%s' "$op" "$quoted" ;;
    day)
      ms=$(zro_search_day_ms "$value" 0) || return "$ZRO_E_INPUT"
      printf '%s:%s' "$op" "$ms" ;;
    dayend)
      ms=$(zro_search_day_ms "$value" 1) || return "$ZRO_E_INPUT"
      printf '%s:%s' "$op" "$ms" ;;
    # ONE DAY IS WRITTEN AS THE BOUNDED PAIR, NOT AS `date:`, and that was
    # measured rather than assumed. `date:` is documented as equality over the
    # whole day and the tool sent it as a count of milliseconds — which the server
    # reads as one INSTANT: on a mailbox holding thirteen messages, eleven of them
    # on the day asked about, `date:<that midnight>` answered with NOTHING, exit 0.
    # A criterion that silently finds nothing is the worst failure this screen has,
    # so the single day is expressed with the two operators that are proven to
    # bound a day exactly.
    dayspan)
      ms=$(zro_search_day_ms "$value" 0) || return "$ZRO_E_INPUT"
      end=$(zro_search_day_ms "$value" 1) || return "$ZRO_E_INPUT"
      printf '%s:%s %s:%s' "$op" "$ms" "$ZRO_SEARCH_OP_DAY_END" "$end" ;;
    folder)
      # A path the folder listing printed, rooted as that listing prints it. Both
      # 'Inbox' and '/Inbox' are accepted by the server and answer identically, so
      # the value is passed as it came rather than adjusted on the way.
      zro_validate_folder_path "$value" || return "$ZRO_E_INPUT"
      quoted=$(zro_query_quote "$value") || return "$ZRO_E_INPUT"
      printf '%s:%s' "$op" "$quoted" ;;
    state)
      zro_search_choice_label "$ZRO_SEARCH_STATES" "$value" >/dev/null || return "$ZRO_E_INPUT"
      printf '%s:%s' "$op" "$value" ;;
    atype)
      zro_search_choice_label "$ZRO_SEARCH_ATTACHMENTS" "$value" >/dev/null || return "$ZRO_E_INPUT"
      printf '%s:%s' "$op" "$value" ;;
    scope)
      # One value, and it is the criterion itself: the operator chose to widen the
      # search rather than supplying anything.
      [ "$value" = anywhere ] || return "$ZRO_E_INPUT"
      printf '%s:anywhere' "$op" ;;
    # A kind the table names and this builder does not implement. Unreachable
    # while the suite holds the two sets equal, and here so that they may only
    # disagree loudly: a criterion whose value nobody validated must never become
    # a term.
    *) zro_log error "search defect, no builder for criterion kind: $kind"
       return "$ZRO_E_INPUT" ;;
  esac
}

# THE WHOLE QUERY, from pairs of criterion and value.
#
#   $@  id value id value …
#
# The terms are joined by a space, which the query language reads as an implicit
# AND — measured: four criteria in one query narrow each other exactly as an
# operator expects.
#
# AN EMPTY QUERY IS REFUSED HERE rather than sent. The server answers one with
# `Couldn't parse query:` and exit 2, which would reach the operator as a failure
# of the tool for having asked nothing.
#
# THE ORDER IS THE OPERATOR'S, not the table's. The query is shown on the screen
# beside its answer, so an operator who added a subject and then a folder should
# read them back in that order and recognise what they built.
zro_search_query() {
  local out='' term
  [ $# -ge 2 ] || return "$ZRO_E_INPUT"
  while [ $# -ge 2 ]; do
    term=$(zro_search_term "$1" "$2") || return "$ZRO_E_INPUT"
    if [ -z "$out" ]; then
      out=$term
    else
      out="$out $term"
    fi
    shift 2
  done
  # An odd number of arguments is a caller that lost a value, never a criterion
  # with none: the criterion that asks for nothing still carries the word that
  # says so.
  [ $# -eq 0 ] || return "$ZRO_E_INPUT"
  printf '%s' "$out"
}

# ------------------------------------------------------- reading the table --
#
# THE COLUMN WIDTHS ARE COMPUTED PER PAGE, which is why nothing here is read at a
# fixed offset the way the folder listing is. The index column is as wide as the
# largest index on the page needs and the id column is as wide as the longest id on
# it, so a page of ten hits prints every column one character further right than a
# page of nine — captured both ways on the lab server. What IS fixed is the
# separator behind each of those two fields, and the type column's own width, and
# those are what the reader below steps over.
#
# So the region left of the sender is read field by field, and everything from the
# sender onwards is kept AS THE SERVER PRINTED IT. That is deliberate twice over:
# the widths there are literals in the format string and could be split, but the
# fields hold text in the account holder's own language, and a substring taken by
# character position is a different thing under a UTF-8 locale and under C. A
# misplaced cut in a display column would be a garbled name; a misplaced cut in the
# id would be the wrong message. Only the id is parsed, and the row is shown as it
# came.
ZRO_SEARCH_W_TYPE=4
# The two spaces behind the id field, the three behind the type field, and the one
# space behind the index's dot. Each is the format string's own separator, declared
# rather than trimmed away, so that a row whose sender begins with a space is still
# read at the column the server put it in.
ZRO_SEARCH_SEP_ID=2
ZRO_SEARCH_SEP_TYPE=3
ZRO_SEARCH_SEP_INDEX=1

# The count and the flag the table opens with, as "<num>\t<more>".
#
# Fails when the output carries no such line, which is what tells a search table
# from anything else that might arrive on stdout — the usage banner among them.
zro_search_meta() {
  local raw=${1-} line num more
  while IFS= read -r line; do
    case $line in
      'num: '*', more: '*) ;;
      *) continue ;;
    esac
    num=${line#num: }
    num=${num%%,*}
    more=${line##*more: }
    case $num in ''|*[!0-9]*) return "$ZRO_E_NO_RESULT" ;; esac
    case $more in
      true|false) ;;
      *) return "$ZRO_E_NO_RESULT" ;;
    esac
    printf '%s%s%s' "$num" "$ZRO_TAB" "$more"
    return 0
  done <<EOF
$raw
EOF
  return "$ZRO_E_NO_RESULT"
}

zro_search_meta_count() {
  local meta=${1-}
  printf '%s' "${meta%%"$ZRO_TAB"*}"
}

zro_search_meta_more() {
  local meta=${1-}
  printf '%s' "${meta##*"$ZRO_TAB"}"
}

# Leading and trailing whitespace off a value. The fields are padded to their
# column widths, so every value read out of one arrives wearing spaces.
zro_search_trim() {
  local s=${1-}
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# A row's index prefix, stepped over: "<the rest of the line>" or a refusal.
#
# WHAT IS NOT A ROW IS REFUSED BY WHAT IT IS, never by counting lines. The table
# opens with a count line, a blank line and two header rows, and every one of them
# fails this test: a row begins with an index, which is digits followed by a dot
# and one space. A reader that skipped four lines would take the first hit for a
# header the day the server prints one line more.
zro_search_row_body() {
  local line=${1-} idx rest
  line=${line#"${line%%[![:space:]]*}"}
  idx=${line%%.*}
  case $idx in ''|*[!0-9]*) return 1 ;; esac
  rest=${line#*.}
  [ "${#rest}" -gt "$ZRO_SEARCH_SEP_INDEX" ] || return 1
  case ${rest:0:$ZRO_SEARCH_SEP_INDEX} in
    ' ') ;;
    *) return 1 ;;
  esac
  printf '%s' "${rest:$ZRO_SEARCH_SEP_INDEX}"
}

# The id field and what follows it. The id is right-aligned in a column as wide as
# the longest id on the page, so its padding stands in front of it and exactly two
# spaces stand behind it.
#
# A LEADING MINUS IS PART OF AN ID HERE. The conversation form of this table names
# a conversation holding one message with the negation of that message's id, and a
# reader that dropped the sign would offer the operator an id that names a
# different thing. What may not be SENT is decided by the validator, not by the
# reader: this is what the server printed.
zro_search_row_id() {
  local body=${1-} id
  body=${body#"${body%%[![:space:]]*}"}
  id=${body%% *}
  case $id in
    ''|-) return 1 ;;
    -*) case ${id#-} in ''|*[!0-9]*) return 1 ;; esac ;;
    *[!0-9]*) return 1 ;;
  esac
  printf '%s' "$id"
}

# What stands after the id field, with its separator stepped over.
zro_search_row_after_id() {
  local body=${1-} id rest
  body=${body#"${body%%[![:space:]]*}"}
  id=${body%% *}
  rest=${body#"$id"}
  [ "${#rest}" -ge "$ZRO_SEARCH_SEP_ID" ] || return 1
  printf '%s' "${rest:$ZRO_SEARCH_SEP_ID}"
}

# THE SEARCH TABLE, as rows this program can act on:
#
#   stdin   whatever the search printed
#   stdout  "<id>\t<type>\t<the rest of the row>", one hit per line
#
# Six columns: index, id, type, sender, subject, date. The message form and the
# conversation form of the search print the same table; only the type differs, and
# it is kept because it is the one field that says which of the two a row is.
zro_search_parse_rows() {
  local line body id type rest
  while IFS= read -r line; do
    body=$(zro_search_row_body "$line") || continue
    id=$(zro_search_row_id "$body") || continue
    rest=$(zro_search_row_after_id "$body") || continue
    [ "${#rest}" -ge $((ZRO_SEARCH_W_TYPE + ZRO_SEARCH_SEP_TYPE)) ] || continue
    type=$(zro_search_trim "${rest:0:$ZRO_SEARCH_W_TYPE}")
    [ -n "$type" ] || continue
    rest=${rest:$((ZRO_SEARCH_W_TYPE + ZRO_SEARCH_SEP_TYPE))}
    printf '%s\t%s\t%s\n' "$id" "$type" "$(zro_search_row_trail "$rest")"
  done
}

# THE CONVERSATION TABLE, which is the same table MINUS THE TYPE COLUMN:
#
#   stdin   whatever the conversation listing printed
#   stdout  "<id>\t<the rest of the row>", one message per line
#
# Declared as its own reader rather than as a flag on the one above, for the reason
# lib/store.sh gives about its two fixed-width tables: two tables read by one
# function are two tables that agree by accident, and the day one of them grows a
# column the other one silently reads it as something else.
zro_search_parse_conv_rows() {
  local line body id rest
  while IFS= read -r line; do
    body=$(zro_search_row_body "$line") || continue
    id=$(zro_search_row_id "$body") || continue
    rest=$(zro_search_row_after_id "$body") || continue
    printf '%s\t%s\n' "$id" "$(zro_search_row_trail "$rest")"
  done
}

# The display part of a row: what the server printed from the sender column on,
# with the padding at the far end taken off. Nothing else is touched — the two
# columns inside it are the server's, at the widths the server chose.
zro_search_row_trail() {
  local s=${1-}
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# A ROW'S FIELDS, FOR A CALLER THAT WANTS ONE OF THEM. The rows above are
# positional, and a caller stepping over the fields it does not want would be a
# second reader of this format.
zro_search_field_id() {
  local row=${1-}
  printf '%s' "${row%%"$ZRO_TAB"*}"
}

# What one hit reads as on a screen an operator picks from. The id first, because
# it is the one field that survives being taken to another screen.
zro_search_row_label() {
  local row=${1-} rest
  rest=${row#*"$ZRO_TAB"}
  printf '%s  %s' "$(zro_search_field_id "$row")" "$rest"
}

# Whether a conversation id names a VIRTUAL conversation: one message, with the
# conversation named by the negation of that message's id.
#
# Asked before anything runs, because the answer is a refusal this program owes the
# operator in its own words. The value is flag-shaped, so the exec gate would
# refuse it as an allowlist denial — which in this program means a defect — and the
# operator would be told the tool is broken when what they picked is simply a
# conversation with nothing to list.
zro_search_conv_virtual() {
  local id=${1-}
  case $id in
    -[0-9]*) return 0 ;;
  esac
  return 1
}

# The message a virtual conversation is: the id without its sign.
zro_search_conv_message() {
  printf '%s' "${1#-}"
}

# --------------------------------------------------------------- the reads --

# What the two reads fail with, captured verbatim from the lab server:
#
#   ERROR: mail.QUERY_PARSE_ERROR (Couldn't parse query: is:sarmasik)
#   ERROR: mail.NO_SUCH_FOLDER (no such folder path: //YokBoyleKlasor)
#   ERROR: mail.NO_SUCH_CONV (no such conversation: 999999)
#   ERROR: service.INVALID_REQUEST (invalid request: malformed item ID: abc)
#
# CLASSIFIED ON THE MESSAGE, NEVER ON THE STATUS, for the reason the existence gate
# gives about its own two sentences: all four exit 2, and so does a service that
# stopped answering. An exit code cannot tell a folder that is not there from a
# server that is not there.
ZRO_SEARCH_TXT_NO_FOLDER='no such folder path'
ZRO_SEARCH_TXT_NO_CONV='no such conversation'
ZRO_SEARCH_TXT_PARSE='QUERY_PARSE_ERROR'
ZRO_SEARCH_TXT_BAD_ID='malformed item ID'

zro_search_fail_code() {
  local errfile=${1-} rc=${2-1} mapped
  if grep -qF -- "$ZRO_SEARCH_TXT_NO_FOLDER" "$errfile" 2>/dev/null; then
    printf '%s' "$ZRO_E_NO_FOLDER"
    return 0
  fi
  # A conversation the server does not have is an ANSWER and not a failure: the
  # conversation was deleted, or its messages were, between the search and the
  # listing. It travels as no-result so the screen can say that in those words.
  if grep -qF -- "$ZRO_SEARCH_TXT_NO_CONV" "$errfile" 2>/dev/null; then
    printf '%s' "$ZRO_E_NO_RESULT"
    return 0
  fi
  # Both of these mean this program built something the server would not take,
  # which is a defect in the builder rather than something the operator did — and
  # it is reported as input rather than swallowed, so the screen can show the query
  # it sent beside what the server said about it.
  if grep -qF -- "$ZRO_SEARCH_TXT_PARSE" "$errfile" 2>/dev/null ||
     grep -qF -- "$ZRO_SEARCH_TXT_BAD_ID" "$errfile" 2>/dev/null; then
    printf '%s' "$ZRO_E_INPUT"
    return 0
  fi
  mapped=$(zro_zimbra_error_code "$errfile")
  if [ "$mapped" != "0" ]; then
    printf '%s' "$mapped"
    return 0
  fi
  printf '%s' "$rc"
}

# What a finished gated read costs the caller: the code to return, with the
# underlying message kept where the error screen can find it. The message is only
# replaced when there is one, for the reason lib/store.sh gives: a read the gate
# refused never ran, and the sentence already in the file is the oracle's.
zro_search_settle() {
  local errfile=${1-} rc=${2-0} msg mapped
  if [ "$rc" -eq 0 ]; then
    rm -f -- "$errfile"
    zro_clear_error
    printf '0'
    return 0
  fi
  msg=$(head -c 500 -- "$errfile" 2>/dev/null)
  mapped=$(zro_search_fail_code "$errfile" "$rc")
  [ -n "$msg" ] && zro_set_error "$msg"
  rm -f -- "$errfile"
  printf '%s' "$mapped"
}

# OUTPUT THAT IS NOT A TABLE AT ALL, told apart from an answer with no hits — and
# LOGGED, because the two are different facts and only one of them is about the
# mailbox. A search that answered always prints its count line, even for zero hits;
# what has none is the usage banner, which this binary puts on STDOUT with exit 1
# when an argument is missing. That is a defect in this program, and a screen
# reporting it as "there is nothing there" would be answering a question about the
# mailbox with a fact about the tool.
zro_search_no_table() {
  local raw=${1-}
  zro_search_meta "$raw" >/dev/null && return 1
  zro_log error "search defect, the answer carried no result table: $(printf '%.120s' "$raw")"
  return 0
}

# ONE SEARCH, ONE INVOCATION.
#
#   $1  the account          $2  the query this program built
#
# `-t message` IS NOT OPTIONAL AND IS NOT A PREFERENCE. The search type defaults to
# conversation, and the ids in that answer are conversation ids — so a screen that
# left it out would print an identifier that names a different thing under a column
# headed with the message's.
#
# THE QUERY IS ONE ELEMENT OF THE VECTOR and reaches the binary as itself. Nothing
# is assembled into a string anywhere on this path: the one-shot form of this
# command passes its arguments straight through, which is what keeps the query
# language's quoting the only quoting the value has to survive.
zro_search_fetch() {
  local acct=${1-} query=${2-} err out rc=0
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"
  [ -n "$query" ] || return "$ZRO_E_INPUT"
  # A query is built from criteria and every criterion begins with its operator, so
  # this can only be reached by a caller that built one some other way. Refused
  # here rather than at the gate, where a leading dash is an allowlist denial and
  # an allowlist denial means a defect.
  case $query in -*) return "$ZRO_E_INPUT" ;; esac
  zro_reset_mode
  err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"

  out=$(zro_mbox_run "$acct" s -t message -l "$ZRO_SEARCH_LIMIT" "$query" 2>"$err") || rc=$?
  rc=$(zro_search_settle "$err" "$rc")
  [ "$rc" -eq 0 ] || return "$rc"

  # A search that answered always prints its count line, even when the count is
  # zero. Output without one is not a search table at all — the usage banner is
  # what that looks like — and it is refused rather than drawn as an empty result,
  # which would say the mailbox holds nothing matching when nobody asked it.
  zro_search_no_table "$out" && return "$ZRO_E_NO_RESULT"
  printf '%s\n' "$out"
}

# THE SAME SEARCH, ASKED FOR CONVERSATIONS. One invocation, and the only difference
# is the type: without `-t` the server searches conversations, which is its own
# default and the only way to obtain a conversation id at all.
#
# It is a second call site of one subcommand rather than a second operation: the
# allowlist approves `zmmailbox:s` and the type flag under it, and what decides
# which of the two questions is asked is which of these two functions a screen
# called.
zro_search_conv_fetch() {
  local acct=${1-} query=${2-} err out rc=0
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"
  [ -n "$query" ] || return "$ZRO_E_INPUT"
  case $query in -*) return "$ZRO_E_INPUT" ;; esac
  zro_reset_mode
  err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"

  out=$(zro_mbox_run "$acct" s -l "$ZRO_SEARCH_LIMIT" "$query" 2>"$err") || rc=$?
  rc=$(zro_search_settle "$err" "$rc")
  [ "$rc" -eq 0 ] || return "$rc"

  zro_search_no_table "$out" && return "$ZRO_E_NO_RESULT"
  printf '%s\n' "$out"
}

# THE MESSAGES OF ONE CONVERSATION. One invocation.
#
#   $1  the account          $2  a conversation id the search printed
#
# The id is validated as digits, which is also what refuses the virtual
# conversation the screen answers for itself. The query is this program's own
# constant: `sc` requires one, and an operator never supplies it.
zro_search_conv_messages() {
  local acct=${1-} conv=${2-} err out rc=0
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"
  zro_validate_item_id "$conv" || return "$ZRO_E_INPUT"
  zro_reset_mode
  err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"

  out=$(zro_mbox_run "$acct" sc -l "$ZRO_SEARCH_LIMIT" "$conv" "$ZRO_SEARCH_CONV_QUERY" 2>"$err") || rc=$?
  rc=$(zro_search_settle "$err" "$rc")
  [ "$rc" -eq 0 ] || return "$rc"

  # The usage banner arrives on STDOUT with exit 1, which is the shape a missing
  # query has. It carries no count line, so this is what tells it from an answer.
  zro_search_no_table "$out" && return "$ZRO_E_NO_RESULT"
  printf '%s\n' "$out"
}

# ------------------------------------------------- what an operator reads --

ZRO_TXT_SEARCH_NO_HITS='Bu sorguya uyan ileti bulunamadi.'
ZRO_TXT_SEARCH_NO_CONV='Bu konusma sunucuda bulunamadi.'

# WHAT THE COLUMNS ARE AND WHAT THEY ARE NOT, said on every screen that shows one.
#
# THE SENDER COLUMN IS THE ONE THAT MISLEADS. What the server prints there is a
# DISPLAY NAME, not an address, and it is cut to twenty characters with no mark
# saying it was cut — so two different people can appear under one string, and no
# address can be recovered from it. An operator who read it as an address would
# take the wrong name to the next screen, which is why this is stated rather than
# implied. The subject is cut at fifty the same way.
ZRO_TXT_SEARCH_COLUMNS='Kimden sutunu ADRES DEGILDIR: sunucu oraya gorunen adi yazar ve 20 karakterde
keser, kesildigini de belirtmez. O sutundan adres cikarilamaz; ayni ada sahip iki
kisi ayni satirla gorunebilir. Konu sutunu de 50 karakterde kesilir. Kesme
sunucunun kendi bicimidir, bu aracin degil.'

ZRO_TXT_SEARCH_READONLY='Arama hicbir iletiyi okundu isaretlemez: kullanilan komutlar yalnizca listeler,
ileti govdesi acilmaz.'

# The criteria an operator chose, as they were chosen, so the answer can be read
# against the question. Pairs in, one line per criterion out.
zro_search_criteria_body() {
  local id label
  while [ $# -ge 2 ]; do
    id=$1
    if label=$(zro_search_label "$id"); then
      zro_card_line "$label" "$(zro_search_value_label "$id" "$2")"
    else
      zro_card_line "$id" "$2"
    fi
    shift 2
  done
}

# A value as the operator chose it rather than as the query carries it. The two
# differ for exactly the criteria whose value this program owns — a word out of a
# menu reads as the label that menu offered — and for a day, which travels as a
# count of milliseconds and would be unreadable as one.
zro_search_value_label() {
  local id=${1-} value=${2-} kind label
  kind=$(zro_search_kind "$id") || { printf '%s' "$value"; return 0; }
  case $kind in
    state) label=$(zro_search_choice_label "$ZRO_SEARCH_STATES" "$value") || label=$value
           printf '%s' "$label" ;;
    atype) label=$(zro_search_choice_label "$ZRO_SEARCH_ATTACHMENTS" "$value") || label=$value
           printf '%s' "$label" ;;
    scope) printf 'evet (cop kutusu ve spam dahil)' ;;
    *)     printf '%s' "$value" ;;
  esac
}

# THE RESULT, WITH THE QUESTION ABOVE IT.
#
#   $1  the account   $2  the query as sent   $3  the raw output   $@  the criteria
#
# The query this program built is shown in full. It is the one thing on the screen
# an operator can check the answer against — and on the day a criterion means
# something other than what its label promised, it is the only thing that would
# show it.
zro_search_body() {
  local acct=${1-} query=${2-} raw=${3-} meta num more rows count=0 line
  shift 3

  meta=$(zro_search_meta "$raw") || meta=""
  num=$(zro_search_meta_count "$meta")
  more=$(zro_search_meta_more "$meta")
  rows=$(zro_search_parse_rows <<EOF
$raw
EOF
)

  zro_card_line 'Hesap' "$acct"
  zro_card_line 'Sorgu' "$query"
  printf '\n'
  zro_search_criteria_body "$@"
  printf '\n'

  local body=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    count=$((count + 1))
    body="$body$(printf '%8s  %-4s  %s' \
      "$(zro_search_field_id "$line")" \
      "$(zro_search_row_type "$line")" \
      "$(zro_search_row_rest "$line")")
"
  done <<EOF
$rows
EOF

  zro_card_line 'Sunucunun bildirdigi' "${num:-$ZRO_TXT_UNKNOWN}"
  zro_card_line 'Ekranda gosterilen' "$count"
  zro_card_line 'Ust sinir' "$ZRO_SEARCH_LIMIT"

  if [ "$count" -eq 0 ]; then
    printf '\n%s\n\n' "$ZRO_TXT_SEARCH_NO_HITS"
    printf 'Sorgu calisti ve yanit verdi: bu mailboxta bu olcutlere uyan ileti yok.\n'
    printf 'Bu bir hata degil, bir sonuc.\n'
    printf '\n'
    printf 'Aramanin varsayilan kapsami COP KUTUSUNU VE SPAMI DISARIDA BIRAKIR.\n'
    printf 'Ileti silinmis veya spam klasorune dusmus olabilir: "Butun mailbox"\n'
    printf 'olcutunu ekleyip aramayi yineleyin.\n'
    printf '\n%s\n' "$ZRO_TXT_SEARCH_READONLY"
    return 0
  fi

  printf '\n'
  printf '%8s  %-4s  %s\n' 'Id' 'Tur' 'Kimden / Konu / Tarih'
  printf '%s' "$body"

  printf '\n'
  if [ "$more" = true ]; then
    printf 'SUNUCUDA DAHA FAZLASI VAR: bu liste %s satirla sinirlandi ve sunucu daha\n' "$ZRO_SEARCH_LIMIT"
    printf 'fazla eslesme oldugunu bildirdi. En yeniler gosterilir; daha fazla olcut\n'
    printf 'ekleyerek daralttiginizda liste tamamlanir.\n'
    printf '\n'
  fi
  # Said only when the two really differ, because on a message search they cannot:
  # the hit kinds the server drops from this table are wiki, voice and call hits,
  # and none of them can answer a message search. It costs nothing to ask, and the
  # day it happens is a day this screen would otherwise be quietly short a row.
  if [ -n "$num" ] && [ "$num" -ne "$count" ]; then
    printf 'Sunucu %s eslesme bildirdi, tabloda %s satir var. Fark, sunucunun bu\n' "$num" "$count"
    printf 'tabloya yazmadigi bir kayit turunden gelir.\n'
    printf '\n'
  fi
  printf '%s\n' "$ZRO_TXT_SEARCH_COLUMNS"
  printf '\n%s\n' "$ZRO_TXT_SEARCH_READONLY"
}

# The two fields of a parsed row a screen draws beside the id. Read through the
# module that decides what a row is, rather than split a second time at the call
# site.
zro_search_row_type() {
  local row=${1-} rest
  rest=${row#*"$ZRO_TAB"}
  printf '%s' "${rest%%"$ZRO_TAB"*}"
}

zro_search_row_rest() {
  local row=${1-}
  printf '%s' "${row##*"$ZRO_TAB"}"
}

# THE MESSAGES OF ONE CONVERSATION, as its own card.
#
# Five columns rather than six: the conversation listing does not print a type,
# because every row of it is a message.
zro_search_conv_body() {
  local acct=${1-} conv=${2-} raw=${3-} meta num more rows count=0 line body=""

  meta=$(zro_search_meta "$raw") || meta=""
  num=$(zro_search_meta_count "$meta")
  more=$(zro_search_meta_more "$meta")
  rows=$(zro_search_parse_conv_rows <<EOF
$raw
EOF
)

  zro_card_line 'Hesap' "$acct"
  zro_card_line 'Konusma id' "$conv"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    count=$((count + 1))
    body="$body$(printf '%8s  %s' \
      "$(zro_search_field_id "$line")" "$(zro_search_row_rest "$line")")
"
  done <<EOF
$rows
EOF

  zro_card_line 'Sunucunun bildirdigi' "${num:-$ZRO_TXT_UNKNOWN}"
  zro_card_line 'Ekranda gosterilen' "$count"

  if [ "$count" -eq 0 ]; then
    printf '\n%s\n\n' "$ZRO_TXT_SEARCH_NO_CONV"
    printf 'Konusma listelendikten sonra silinmis veya iletileri baska bir yere\n'
    printf 'tasinmis olabilir.\n'
    return 0
  fi

  printf '\n'
  printf '%8s  %s\n' 'Id' 'Kimden / Konu / Tarih'
  printf '%s' "$body"

  printf '\n'
  if [ "$more" = true ]; then
    printf 'Bu konusmada %s iletiden fazlasi var; liste sinirlandi.\n\n' "$ZRO_SEARCH_LIMIT"
  fi
  # Double-quoted on purpose: the static scanner reads a double-quoted span as
  # data, so this line may name the query it was answered with.
  printf "Konusma is:anywhere ile listelenir: cop kutusuna veya spam klasorune tasinmis\n"
  printf "iletiler de gorunur.\n"
  printf '\n%s\n' "$ZRO_TXT_SEARCH_COLUMNS"
  printf '\n%s\n' "$ZRO_TXT_SEARCH_READONLY"
}

# A CONVERSATION OF ONE MESSAGE, ANSWERED WITHOUT ASKING ANYTHING.
#
# Zimbra names such a conversation with the negation of its only message's id, and
# that value cannot leave this program: a token shaped like a flag standing in the
# data position is looked up in the allowlist, and no list can carry an entry per
# id. So this is a refusal — and it is a refusal that costs the operator nothing,
# because the listing would have shown them the one message whose id they are
# already holding.
zro_search_virtual_body() {
  local conv=${1-} msg
  msg=$(zro_search_conv_message "$conv")
  printf 'Bu konusmada tek ileti var.\n\n'
  zro_card_line 'Konusma id' "$conv"
  zro_card_line 'Ileti id' "$msg"
  printf '\n'
  printf 'Zimbra tek iletilik bir konusmayi, o iletinin id degerinin EKSILISI ile\n'
  printf 'adlandirir. Listelenecek baska ileti olmadigi icin bu ekran sunucuya hic\n'
  printf 'sorgu gondermez: aradiginiz ileti yukaridaki id ile listede zaten var.\n'
  printf '\n'
  printf 'Bu arac eksi ile baslayan bir degeri komut satirina koymaz; boyle bir deger\n'
  printf 'komutlarda secenek olarak okunur ve calistirma kapisi bunu reddeder.\n'
}
