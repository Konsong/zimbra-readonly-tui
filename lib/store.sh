# shellcheck shell=bash
# WHAT IS INSIDE A MAILBOX, once something incapable of creating one has proven
# there is one. Folders, one folder, one folder's grants, the total size, and the
# quota usage that is the size read against the limit the directory carries.
[ -n "${ZRO_LIB_STORE_LOADED:-}" ] && return 0
ZRO_LIB_STORE_LOADED=1

# lib/mailbox.sh IS THE GATE; this file is everything behind it. The split is the
# same one lib/exec.sh makes between the allowlist and the binary roots: one file
# decides whether a mailbox may be opened at all, and that decision does not get
# easier to reach by being kept next to the screens that depend on it.
#
# Nothing here names a binary. Every read goes out through zro_mbox_run, which
# owns the gated binary's prefix and runs the existence oracle before each one —
# so a screen in this file cannot open a session on an account whose mailbox is
# not already there, and cannot forget to try.
#
# THE FOUR READS ARE READS IN EFFECT, measured rather than assumed. On the lab
# server the account's row in the `mailbox` table came back byte-identical either
# side of all of them — change checkpoint, item id checkpoint, size checkpoint and
# last SOAP access included — while a deliberate grant write in the same session
# moved two of those columns at once. See
# docs/research/2026-08-02-folders-size-and-quota.md.

# EVERY SUBCOMMAND HERE IS WRITTEN AT ITS CALL SITE, LITERALLY, and there are four
# of them. Nothing hands one in and nothing holds one in a variable, which is what
# lets the static scanner read this file and prove which operations it is able to
# ask for — the same way it proves which filters the delivery trace can pass. The
# suite holds the set it extracts equal to the allowlist's entries for that binary
# in both directions, so a fifth operation cannot arrive without being written
# down where a maintainer reads what this tool can do, and an approved operation
# with no call site cannot sit on the list reading as available.
#
# ------------------------------------------------------------- reading rows --
#
# `gaf` prints a FIXED-WIDTH TABLE, and the widths are the format string's, not a
# guess: `%10.10s  %4.4s  %10d  %10d  %s`. That puts the path at column 42 and
# every field before it at a known offset, which is what lets a folder path
# CONTAINING SPACES be read at all — '/Emailed Contacts' exists on every mailbox
# Zimbra creates, so a reader that split on whitespace would be wrong about a
# standard folder on the first account it was pointed at.
#
# The path is taken as the whole rest of the line and never trimmed at the far
# end: it is the last column, so nothing follows it that could be mistaken for
# padding.
ZRO_STORE_COL_ID=0
ZRO_STORE_W_ID=10
ZRO_STORE_COL_VIEW=12
ZRO_STORE_W_VIEW=4
ZRO_STORE_COL_UNREAD=18
ZRO_STORE_W_UNREAD=10
ZRO_STORE_COL_COUNT=30
ZRO_STORE_W_COUNT=10
ZRO_STORE_COL_PATH=42

# `gfg` prints its own fixed-width table, and it is a different one:
# `%11.11s  %8.8s  %s`. Two tables, two sets of offsets, declared apart — sharing
# one set would be a folder listing and a grant listing agreeing by accident.
#
# EACH OFFSET IS THE FORMAT STRING'S OWN, never a field widened to swallow the
# separator beside it. A field that covered its own two spaces would still read
# correctly — the values are trimmed — and it would document a table that is not
# the one above, which is exactly the accident declaring them separately is meant
# to prevent.
ZRO_STORE_COL_PERMS=0
ZRO_STORE_W_PERMS=11
ZRO_STORE_COL_GTYPE=13
ZRO_STORE_W_GTYPE=8
ZRO_STORE_COL_GRANTEE=23

# One level of the folder serializer's indentation. `gf` answers in JSON, pretty
# printed five spaces per level, one key per line — so a key of the folder ITSELF
# stands at exactly this indent and a key of a child stands deeper. That is the
# whole rule the reader below applies, and it is why asking for the root folder
# does not answer with a child's name: '/' carries the entire tree under
# 'subFolders', and every key in it is indented past this.
ZRO_STORE_JSON_INDENT='     '

# Leading and trailing whitespace off a fixed-width field. The fields are padded
# to their column widths, so every value read out of one arrives wearing spaces.
zro_store_trim() {
  local s=${1-}
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# The folder table as rows this program can act on:
#
#   stdin   whatever the folder listing printed
#   stdout  "<id>\t<view>\t<unread>\t<item count>\t<path>", one folder per line
#
# WHAT IS NOT A ROW IS DROPPED SILENTLY, and that is the decision. The listing
# opens with two header lines, and both fail the same test a malformed row would:
# the id column has to be a number, the two counts have to be numbers, and the
# path has to begin with '/'. A reader that skipped exactly two lines instead
# would be reading the header by counting, and would take the first folder for a
# header the day Zimbra prints a blank line above it.
zro_store_parse_folders() {
  local line id view unread count path
  while IFS= read -r line; do
    [ "${#line}" -gt "$ZRO_STORE_COL_PATH" ] || continue
    id=$(zro_store_trim "${line:$ZRO_STORE_COL_ID:$ZRO_STORE_W_ID}")
    view=$(zro_store_trim "${line:$ZRO_STORE_COL_VIEW:$ZRO_STORE_W_VIEW}")
    unread=$(zro_store_trim "${line:$ZRO_STORE_COL_UNREAD:$ZRO_STORE_W_UNREAD}")
    count=$(zro_store_trim "${line:$ZRO_STORE_COL_COUNT:$ZRO_STORE_W_COUNT}")
    path=${line:$ZRO_STORE_COL_PATH}
    case $id in ''|*[!0-9]*) continue ;; esac
    case $unread in ''|*[!0-9]*) continue ;; esac
    case $count in ''|*[!0-9]*) continue ;; esac
    case $path in /*) ;; *) continue ;; esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$view" "$unread" "$count" "$path"
  done
}

# The grant table as rows:
#
#   stdin   whatever the grant listing printed
#   stdout  "<permissions>\t<grantee kind>\t<grantee>", one grant per line
#
# NOTHING IS DROPPED FOR NOT BEING UNDERSTOOD, which is the rule the distribution
# list card already lives by and matters more here: a card that showed only the
# grantee kinds this program has seen would report a folder shared with a domain
# as a folder shared with nobody. Only the listing's own two header lines are
# refused, and they are refused by what they say rather than by their position.
#
# The grantee is allowed to be EMPTY. A public grant names nobody — it is the
# 'anyone with the link' grant — and the empty column is that fact rather than a
# value nobody read.
zro_store_parse_grants() {
  local line perms kind grantee
  while IFS= read -r line; do
    # Long enough to carry a grantee KIND, which every row has and the shortest
    # possible row ends with: a public grant names nobody, so its line stops where
    # that field does. A bound written as a column offset would be a length by
    # coincidence rather than by meaning.
    [ "${#line}" -ge $((ZRO_STORE_COL_GTYPE + ZRO_STORE_W_GTYPE)) ] || continue
    perms=$(zro_store_trim "${line:$ZRO_STORE_COL_PERMS:$ZRO_STORE_W_PERMS}")
    kind=$(zro_store_trim "${line:$ZRO_STORE_COL_GTYPE:$ZRO_STORE_W_GTYPE}")
    grantee=$(zro_store_trim "${line:$ZRO_STORE_COL_GRANTEE}")
    [ -n "$perms" ] || continue
    [ -n "$kind" ] || continue
    # The header, by its own words, and the rule under it, by having no letter in
    # the column that always carries one.
    [ "$perms" = 'Permissions' ] && [ "$kind" = 'Type' ] && continue
    case $perms in *[A-Za-z]*) ;; *) continue ;; esac
    printf '%s\t%s\t%s\n' "$perms" "$kind" "$grantee"
  done
}

# A ROW'S FIELDS, FOR A CALLER THAT WANTS ONE OF THEM. The rows above are
# positional, and a caller stepping over the fields it does not want is a second
# reader of this format — so the two the menu needs are read here, in the module
# that decides what a row is. The screens that draw the whole table take it apart
# themselves, because they want every field and would gain nothing.
zro_store_row_path() {
  local row=${1-}
  printf '%s' "${row##*"$ZRO_TAB"}"
}

# What one folder reads as on the screen an operator picks from: the path, then
# what is in it. The counts are the reason the label exists at all — a list of
# bare paths gives nobody a reason to choose one.
zro_store_row_label() {
  local row=${1-} rest unread count
  rest=${row#*"$ZRO_TAB"}          # past the id
  rest=${rest#*"$ZRO_TAB"}         # past the view
  unread=${rest%%"$ZRO_TAB"*}
  rest=${rest#*"$ZRO_TAB"}
  count=${rest%%"$ZRO_TAB"*}
  printf '%s (%s oge, %s okunmamis)' "$(zro_store_row_path "$row")" "$count" "$unread"
}

# One key of the folder the operator asked about, and never a key of a child.
#
#   $1  the key
#   $2  the JSON the folder read printed
#
# Fails when the key is not there, so a field nobody could read reaches the screen
# as 'this program could not read it' rather than as a value. That is also what
# happens if a future release changes the indentation this depends on: every field
# reads as unreadable, which is visible, rather than a child's value reading as
# the parent's, which is not.
zro_store_json_field() {
  local key=${1-} json=${2-} line value
  [ -n "$key" ] || return "$ZRO_E_INPUT"
  while IFS= read -r line; do
    case $line in
      "$ZRO_STORE_JSON_INDENT\"$key\": "*) ;;
      *) continue ;;
    esac
    value=${line#*: }
    value=${value%,}
    case $value in
      '"'*'"') value=${value#\"}; value=${value%\"} ;;
    esac
    printf '%s' "$value"
    return 0
  done <<EOF
$json
EOF
  return "$ZRO_E_NO_RESULT"
}

# A BYTE COUNT, AND NOTHING THAT MERELY LOOKS LIKE ONE.
#
# The size command prints a human-readable string by default and the raw byte
# count under `-v`. This program asks for the raw form and this function refuses
# everything else — because the default form is built with the JVM's default
# locale, so the same mailbox answers '1.44 GB' on one host and '1,44 GB' on the
# next. A reader that took the digits it found would report a mailbox holding
# 1.44 GB as one holding 144 GB on a Turkish, German or French server, which is
# every server this tool is written for.
#
# So the refusal is the point: if anything ever answers this read in the formatted
# shape, the screen says the value could not be read instead of reporting a number
# that is wrong by a factor nobody can see.
zro_store_parse_size() {
  local raw=${1-} line
  while IFS= read -r line; do
    line=$(zro_store_trim "$line")
    [ -n "$line" ] || continue
    case $line in
      ''|*[!0-9]*) return "$ZRO_E_NO_RESULT" ;;
    esac
    printf '%s' "$line"
    return 0
  done <<EOF
$raw
EOF
  return "$ZRO_E_NO_RESULT"
}

# --------------------------------------------------------------- the reads --

# What a folder read says when the path names nothing. Captured from the lab
# server: `ERROR: zclient.CLIENT_ERROR (unknown folder: /YokBoyleKlasor)`, exit 2.
#
# CLASSIFIED ON THE MESSAGE, NEVER ON THE STATUS, for the reason the existence
# gate gives about its own two sentences: this command exits 2 for a folder that
# is not there and for everything else it fails at, so the status cannot tell a
# missing folder from a service that stopped answering.
ZRO_STORE_TXT_NO_FOLDER='unknown folder'

zro_store_fail_code() {
  local errfile=${1-} mapped
  # A GATE CODE NEVER ARRIVES HERE, and neither does the existence gate's refusal.
  # lib/settle.sh asks zro_exec_own_code before it calls this, and each read below
  # asks the existence gate before it runs anything, so everything that arrives
  # here is a failure of a command that REALLY RAN.
  if grep -qF -- "$ZRO_STORE_TXT_NO_FOLDER" "$errfile" 2>/dev/null; then
    printf '%s' "$ZRO_E_NO_FOLDER"
    return 0
  fi
  # The shared reader of a Zimbra failure: a stopped service and a refused
  # permission say the same things whichever binary was asked.
  mapped=$(zro_zimbra_error_code "$errfile")
  if [ "$mapped" != "0" ]; then
    printf '%s' "$mapped"
    return 0
  fi
  # ANYTHING ELSE IS THE SERVICE THIS READ NEEDED, NOT A NUMBER. This function used
  # to end by returning the status it was handed, which was a pass-through by
  # accident: right for a code the gate produced, and wrong for everything else,
  # because the mailbox binary's own exit status then reached the operator as
  # "islem basarisiz (kod 2)" — a number this program does not define and cannot
  # explain. Nothing arrives here now but a failure of a command that ran and that
  # nothing above recognised, so the answer is the one lib/message.sh already gives
  # for the same situation: the mail service this read goes through is unreachable,
  # and the screen for that code names it.
  printf '%s' "$ZRO_E_UNAVAILABLE"
}

# THE EXISTENCE GATE IS ASKED HERE, AND ASKED FIRST, in each of the four reads
# below. zro_mbox_run asks it too and keeps asking it — that precondition is what
# makes it the only path to the gated binary — but a caller that learned of the
# refusal only from a status could not tell it from the command failing. Both
# arrive as one non-zero number, and only one of them is about a mailbox.
#
# WHY NO PREDICATE CAN ANSWER THIS INSTEAD. lib/settle.sh keeps a failure reader
# away from a code the exec gate produced by asking zro_exec_own_code, whose
# membership is read off zro_exec's return set. The existence gate's refusals — no
# mailbox, no account — are not in that set and may not be added to it. Nor can the
# existence gate own the same kind of predicate: zro_mbox_verdict forwards whatever
# the oracle's read returned, so its return set is not bounded by anything it wrote
# itself. Asking first is what bounds it, and it is the whole reason these lines
# exist: everything after one of them is a failure of a command that RAN.
#
# IT COSTS NO INVOCATION WHILE THE PROOF IS KEPT, which is the ordinary case and the
# one the suite pins: a mailbox proven once is proven for the session, and the proof
# is a file rather than a variable, so the second ask inside zro_mbox_run returns
# without reading anything. THE EXCEPTION IS NAMED RATHER THAN GLOSSED. zro_mbox_prove
# swallows a write it could not make, by design, and a proof that was never written
# costs a second oracle read on every read here — one server, one of everything, so
# that is worth knowing. The scratch file is not even created for a read the gate
# refused now, which it used to be.

# Every folder in the mailbox, as parsed rows. One invocation.
#
# The subcommand is written literally here and at the three call sites below, and
# never handed in by a caller: a static reader can then prove which operations
# this module is able to ask for, exactly as it proves which filters the delivery
# trace can pass. The suite extracts those four words and holds them equal to the
# allowlist's entries for that binary, in both directions.
zro_store_folders_fetch() {
  local acct=${1-} err out rows rc=0
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"
  zro_mbox_require "$acct" || return $?
  err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"

  out=$(zro_mbox_run "$acct" gaf 2>"$err") || rc=$?
  rc=$(zro_settle "$err" "$rc" zro_store_fail_code)
  [ "$rc" -eq 0 ] || return "$rc"

  rows=$(zro_store_parse_folders <<EOF
$out
EOF
)
  # A mailbox always has a root folder, so nothing to parse means the answer was
  # not a folder table at all. Reported as no result rather than drawn as an empty
  # list: an empty list would say this mailbox has no folders, which is not a state
  # Zimbra can be in.
  [ -n "$rows" ] || return "$ZRO_E_NO_RESULT"
  printf '%s\n' "$rows"
}

zro_store_folder_fetch() {
  local acct=${1-} path=${2-} err out rc=0
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"
  zro_validate_folder_path "$path" || return "$ZRO_E_INPUT"
  zro_mbox_require "$acct" || return $?
  err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"

  out=$(zro_mbox_run "$acct" gf "$path" 2>"$err") || rc=$?
  rc=$(zro_settle "$err" "$rc" zro_store_fail_code)
  [ "$rc" -eq 0 ] || return "$rc"
  [ -n "$out" ] || return "$ZRO_E_NO_RESULT"
  printf '%s\n' "$out"
}

zro_store_grants_fetch() {
  local acct=${1-} path=${2-} err out rc=0
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"
  zro_validate_folder_path "$path" || return "$ZRO_E_INPUT"
  zro_mbox_require "$acct" || return $?
  err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"

  out=$(zro_mbox_run "$acct" gfg "$path" 2>"$err") || rc=$?
  rc=$(zro_settle "$err" "$rc" zro_store_fail_code)
  [ "$rc" -eq 0 ] || return "$rc"

  # NO GRANTS IS AN ANSWER AND RETURNS SUCCESS. The listing prints its two header
  # lines and stops, exactly as it does for a folder shared with three parties
  # minus the rows — so an empty result here means the folder is shared with
  # nobody, and the screen says so in those words.
  zro_store_parse_grants <<EOF
$out
EOF
}

# The mailbox's total size in bytes. One invocation, and the raw form of it.
zro_store_size_fetch() {
  local acct=${1-} err out rc=0
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"
  zro_mbox_require "$acct" || return $?
  err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"

  out=$(zro_mbox_run "$acct" gms -v 2>"$err") || rc=$?
  rc=$(zro_settle "$err" "$rc" zro_store_fail_code)
  [ "$rc" -eq 0 ] || return "$rc"
  zro_store_parse_size "$out"
}

# ------------------------------------------------- what an operator reads --

ZRO_TXT_STORE_NO_GRANTS='Bu klasor kimseyle paylasilmamis.'
ZRO_TXT_STORE_PUBLIC='(herkes)'

# A size in both forms, always. The human form is what an operator reads and the
# byte count is what they can check against anything else — a quota, a previous
# reading, a colleague's number — and neither is enough on its own.
#
# A VALUE THIS PROGRAM COULD NOT READ IS A FIELD, NOT A FAILURE. It reaches the
# operator as 'bilinmiyor', which is the word this tool reserves for a fact about
# ITSELF — the size arrived in a shape the reader refuses — as against 'tanimsiz',
# which is a fact about the account. The distinction is CONTEXT.md's and it is
# what keeps the rest of a screen readable when one number is not.
zro_store_size_field() {
  local bytes=${1-} human
  human=$(zro_human_bytes "$bytes") || { printf '%s' "$ZRO_TXT_UNKNOWN"; return 0; }
  printf '%s (%s bayt)' "$human" "$bytes"
}

# Said where a size should have been, and only there. The screen still draws.
ZRO_TXT_STORE_SIZE_UNREADABLE='Sunucu boyutu sayi olarak vermedi; bu arac bicimlenmis bir degeri
okumaz, cunku ondalik ayraci sunucunun yerel ayarina baglidir.'

# THE FOLDER LIST, with the counts read off the rows rather than asked for again.
#
# The item count is labelled 'Oge' and not 'Ileti', and that is not pedantry: the
# column Zimbra prints under 'Msg Count' is the folder's ITEM count. A contacts
# folder counts contacts there and a calendar counts appointments, so a column
# headed 'messages' would be a wrong answer on five of the folders every mailbox
# is created with.
zro_store_folders_body() {
  local acct=${1-} rows=${2-} line id view unread count path
  local folders=0 items=0 unreads=0

  zro_card_line 'Hesap' "$acct"

  local body=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id=${line%%"$ZRO_TAB"*};      line=${line#*"$ZRO_TAB"}
    view=${line%%"$ZRO_TAB"*};    line=${line#*"$ZRO_TAB"}
    unread=${line%%"$ZRO_TAB"*};  line=${line#*"$ZRO_TAB"}
    count=${line%%"$ZRO_TAB"*};   path=${line#*"$ZRO_TAB"}
    folders=$((folders + 1))
    items=$((items + count))
    unreads=$((unreads + unread))
    body="$body$(printf '%6s  %-4s %8s %10s  %s' "$id" "$view" "$count" "$unread" "$path")
"
  done <<EOF
$rows
EOF

  zro_card_line 'Klasor sayisi' "$folders"
  zro_card_line 'Toplam oge' "$items"
  zro_card_line 'Okunmamis' "$unreads"

  printf '\n'
  printf '%6s  %-4s %8s %10s  %s\n' 'Id' 'Tur' 'Oge' 'Okunmamis' 'Klasor'
  printf '%s' "$body"

  printf '\n'
  printf 'Oge sayisi ILETI SAYISI DEGILDIR: kisiler klasorunde kisileri, takvimde\n'
  printf 'randevulari sayar. Tur sutunu Zimbranin kendi dort harfli kisaltmasidir\n'
  printf '(mess ileti, cont kisi, appo randevu, task gorev, docu belge).\n'
}

# ONE FOLDER, AND THE ONE THING THE LIST CANNOT SHOW: its size. The listing counts
# items; this is the only screen that says how many bytes a folder is holding.
zro_store_folder_body() {
  local acct=${1-} path=${2-} json=${3-} field
  zro_card_line 'Hesap' "$acct"
  zro_card_line 'Klasor' "$(zro_store_json_field path "$json" || printf '%s' "$path")"
  zro_card_line 'Klasor id' "$(zro_store_json_field id "$json" || printf '%s' "$ZRO_TXT_UNKNOWN")"
  zro_card_line 'Tur' "$(zro_store_json_field defaultView "$json" || printf '%s' "$ZRO_TXT_UNKNOWN")"
  zro_card_line 'Oge sayisi' "$(zro_store_json_field itemCount "$json" || printf '%s' "$ZRO_TXT_UNKNOWN")"
  zro_card_line 'Okunmamis' "$(zro_store_json_field unreadCount "$json" || printf '%s' "$ZRO_TXT_UNKNOWN")"

  if field=$(zro_store_json_field size "$json"); then
    zro_card_line 'Boyut' "$(zro_store_size_field "$field")"
  else
    zro_card_line 'Boyut' "$ZRO_TXT_UNKNOWN"
  fi

  case $(zro_store_json_field isSystemFolder "$json") in
    true)  zro_card_line 'Sistem klasoru' 'evet' ;;
    false) zro_card_line 'Sistem klasoru' 'hayir' ;;
    *)     zro_card_line 'Sistem klasoru' "$ZRO_TXT_UNKNOWN" ;;
  esac

  # WHETHER, NEVER WHO. The folder record names a grantee by identifier and
  # nothing else, so answering 'who' from here would print a UUID at an operator.
  # The grant screen asks the question that answers in names.
  case $(zro_store_json_field grants "$json") in
    '[]') zro_card_line 'Paylasim' "$ZRO_TXT_NONE" ;;
    '[')  zro_card_line 'Paylasim' 'var (Klasor paylasimlari ekraninda)' ;;
    *)    zro_card_line 'Paylasim' "$ZRO_TXT_UNKNOWN" ;;
  esac

  printf '\n'
  printf 'Bu ekran klasorun kendisini okur; icindeki iletileri acmaz.\n'
}

# WHO MAY REACH THIS FOLDER, in the words the server itself used.
#
# Every row is shown, whatever kind of grantee it names. A card that displayed
# only the kinds this program recognises would report a folder shared with a
# domain — or with everyone — as a folder shared with nobody, which is the one
# error a sharing screen may not make.
zro_store_grants_body() {
  local acct=${1-} path=${2-} rows=${3-} line perms kind grantee count=0
  zro_card_line 'Hesap' "$acct"
  zro_card_line 'Klasor' "$path"

  local body=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    perms=${line%%"$ZRO_TAB"*};  line=${line#*"$ZRO_TAB"}
    kind=${line%%"$ZRO_TAB"*};   grantee=${line#*"$ZRO_TAB"}
    [ -n "$grantee" ] || grantee=$ZRO_TXT_STORE_PUBLIC
    count=$((count + 1))
    body="$body$(printf '%-6s  %-9s %s' "$perms" "$kind" "$grantee")
"
  done <<EOF
$rows
EOF

  zro_card_line 'Paylasim sayisi' "$count"
  printf '\n'
  if [ "$count" -eq 0 ]; then
    printf '%s\n' "$ZRO_TXT_STORE_NO_GRANTS"
    printf '\n'
    printf 'Sorgu calisti ve yanit verdi: bu klasorde tanimli bir paylasim yok.\n'
    return 0
  fi

  printf '%-6s  %-9s %s\n' 'Izin' 'Tur' 'Kime'
  printf '%s' "$body"
  printf '\n'
  printf 'Izin harfleri Zimbranin kendi harfleridir: r okuma, w yazma, i ekleme,\n'
  printf 'd silme, a yonetme, x eylem. Tur, paylasimin kime verildigini soyler;\n'
  printf 'public satiri baglantiyi bilen herkesi kapsar ve kimseyi adlandirmaz.\n'
}

# THE MAILBOX SIZE, in bytes and in the form an operator reads.
zro_store_size_body() {
  local acct=${1-} bytes=${2-}
  zro_card_line 'Hesap' "$acct"
  zro_card_line 'Boyut' "$(zro_store_size_field "$bytes")"
  printf '\n'
  if [ -z "$bytes" ]; then
    printf '%s\n' "$ZRO_TXT_STORE_SIZE_UNREADABLE"
    printf '\n'
  fi
  printf 'Bu deger mailboxun tamamini kapsar: butun klasorler, cop kutusu ve\n'
  printf 'gonderilenler dahil.\n'
  printf '\n'
  # Double-quoted on purpose: the static scanner reads a double-quoted span as
  # data, so this line may name the option it is about.
  printf "Deger sunucudan HAM BAYT olarak istenir (gms -v). Komutun varsayilan\n"
  printf "ciktisi sunucunun yerel ayarina gore bicimlenir ve ondalik ayraci virgul\n"
  printf "olabilir; bu arac o bicimi okumaz, kendisi bicimlendirir.\n"
}

# QUOTA USAGE: the size read behind the gate, against the limit the directory
# carries. Two reads, and they are of different things — which is why this screen
# says where each number came from.
#
# The whole-server quota command is not used and is not on the allowlist. It takes
# a server rather than an account and answers for every account on it, which on a
# server carrying more than 100,000 mailboxes is the class 4 sweep this tool does
# not have.
zro_store_quota_body() {
  local acct=${1-} host=${2-} limit=${3-} bytes=${4-} limit_bytes pct

  zro_card_line 'Hesap' "$acct"
  zro_card_line 'Mailbox host' "${host:-$ZRO_TXT_UNSET}"
  zro_card_line 'Kota limiti' "$(zro_quota_field "$limit")"
  zro_card_line 'Kullanilan' "$(zro_store_size_field "$bytes")"

  # A PROPORTION NEEDS BOTH NUMBERS, and each can be missing for its own reason.
  # Neither absence may become a figure: an unreadable limit rendered as zero
  # would report an account as unlimited, and an unreadable usage rendered as zero
  # would report a full mailbox as empty. So the field names which of the two is
  # missing and computes nothing.
  #
  # The limit comes out of the pair through the accessor that owns its shape,
  # rather than by splitting it a second time here.
  limit_bytes=$(zro_quota_limit_bytes "$limit") || limit_bytes=""
  case $bytes in
    ''|*[!0-9]*)
      zro_card_line 'Doluluk' "$ZRO_TXT_UNKNOWN (kullanim okunamadi)" ;;
    *)
      case $limit_bytes in
        '')
          zro_card_line 'Doluluk' "$ZRO_TXT_UNKNOWN (limit okunamadi)" ;;
        0)
          zro_card_line 'Doluluk' 'oran yok (kota sinirsiz)' ;;
        *)
          pct=$(( bytes * 100 / limit_bytes ))
          if [ "$pct" -eq 0 ] && [ "$bytes" -gt 0 ]; then
            zro_card_line 'Doluluk' "%1'den az"
          else
            zro_card_line 'Doluluk' "%$pct"
          fi ;;
      esac ;;
  esac

  printf '\n'
  if [ -z "$bytes" ]; then
    printf '%s\n' "$ZRO_TXT_STORE_SIZE_UNREADABLE"
    printf '\n'
  fi
  # The closing paragraph deliberately does not begin with a field's own label:
  # a prose line starting 'Kota limiti' reads as another card line, and a case
  # asserting on the field would match the explanation instead of the value.
  printf 'Limit dizin kaydindan, kullanim ise mailboxun kendisinden okundu.\n'
  printf 'Sifir bir limit degil, sinirsiz demektir; okunamayan bir limit ise\n'
  printf 'sinirsiz DEGILDIR, bilinmiyor demektir.\n'
  printf '\n'
  # Double-quoted on purpose, as above: the scanner treats this as the data it is.
  printf "Sunucu genelindeki kota komutu (zmprov gqu) bu araca alinmadi: bir hesabi\n"
  printf "degil, sunucudaki butun hesaplari tarar.\n"
}

# ------------------------------------------------------------- the screens --
#
# Read, then render. Each one is the whole of what a menu entry does, and each
# fails with a documented code rather than a screen of its own — the entry point
# turns a gate refusal into the RESULT it is, in one place, for every screen here.
#
# NO DEGRADED-READ BANNER ON ANY OF THEM, and that is not an omission. The banner
# says an answer came from the directory because the mailbox service was
# unreachable; nothing here has a directory form, so an unreachable service leaves
# these screens with no answer at all rather than a worse one — which is the
# silent gate, and it has a screen of its own. The read mode is still reset, so a
# screen reached after a degraded one does not inherit its banner.

zro_store_folders_card() {
  local acct=${1-} rows rc=0
  zro_reset_mode
  rows=$(zro_store_folders_fetch "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  zro_store_folders_body "$acct" "$rows"
}

zro_store_folder_card() {
  local acct=${1-} path=${2-} json rc=0
  zro_reset_mode
  json=$(zro_store_folder_fetch "$acct" "$path") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  zro_store_folder_body "$acct" "$path" "$json"
}

zro_store_grants_card() {
  local acct=${1-} path=${2-} rows rc=0
  zro_reset_mode
  rows=$(zro_store_grants_fetch "$acct" "$path") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  zro_store_grants_body "$acct" "$path" "$rows"
}

# A SIZE NOBODY COULD READ IS STILL THIS SCREEN'S ANSWER. The read ran and the
# server replied; what came back was a formatted string rather than a number, and
# that is a fact about this program's refusal to guess at it — so the field says
# 'bilinmiyor' and the screen explains, instead of a failure box saying the query
# found no result. Every other status is a real failure and travels out as itself.
zro_store_size_card() {
  local acct=${1-} bytes rc=0
  zro_reset_mode
  bytes=$(zro_store_size_fetch "$acct") || rc=$?
  case $rc in
    0) ;;
    "$ZRO_E_NO_RESULT") bytes="" ;;
    *) return "$rc" ;;
  esac
  zro_store_size_body "$acct" "$bytes"
}

# THE MAILBOX IS ASKED FIRST, and the account entry only afterwards. The order is
# the difference between two screens: an account with no mailbox is answered by
# the gate for the price of the gate, and never by a card showing a limit above a
# usage figure that does not exist. The directory read is the cheaper of the two
# and it is still second, because what makes a read worth making here is that the
# screen it belongs to can be drawn.
zro_store_quota_card() {
  local acct=${1-} bytes raw host limit="" rc=0
  zro_reset_mode
  bytes=$(zro_store_size_fetch "$acct") || rc=$?
  case $rc in
    0) ;;
    # A usage figure nobody could read must not take the LIMIT down with it: the
    # limit is a real answer to half the operator's question, and this screen is
    # the one place both halves are shown together.
    "$ZRO_E_NO_RESULT") bytes=""; rc=0 ;;
    *) return "$rc" ;;
  esac

  raw=$(zro_account_fetch "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  host=$(zro_attr_get "$raw" zimbraMailHost)
  # A limit the directory does not carry is not an error on this screen: the
  # usage is still worth reading, and the field says the limit could not be read
  # rather than reporting it as unlimited.
  limit=$(zro_account_quota_limit "$raw") || limit=""

  zro_store_quota_body "$acct" "$host" "$limit" "$bytes"
}
