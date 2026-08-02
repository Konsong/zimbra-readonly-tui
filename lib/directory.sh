# shellcheck shell=bash
# The two directory entries a selected address routes to that are NOT an
# account: the domain it belongs to, and the distribution list it may turn out
# to be. Depends on lib/account.sh for the read and the attribute reader and on
# lib/identity.sh for the header parser, which is why the entry point sources it
# after both.
[ -n "${ZRO_LIB_DIRECTORY_LOADED:-}" ] && return 0
ZRO_LIB_DIRECTORY_LOADED=1

# COST CLASS 1, both screens, and neither of them by a hair.
#
# The domain card is one directory read about one domain, plus at most one more
# to name the class of service the first one answered with an opaque id. The list
# card is one directory read about one list, plus one per DISTINCT grantee named
# in its grants — bounded below, and bounded by the list's own access control
# rather than by anything on the server.
#
# WHAT IS DELIBERATELY ABSENT FROM THE DOMAIN CARD IS THE ACCOUNT COUNT. It is
# the obvious field and it is the one field that cannot be here: counting entries
# in a domain on a server carrying more than 100,000 accounts is a server-wide
# sweep, which is class 4, and class 4 does not exist in this tool. The screen
# says so where an operator who came looking for the number will read it, rather
# than leaving them to wonder whether it was forgotten.

# ---------------------------------------------------------------- domain --

# EVERY DOMAIN FACT THE CARD SHOWS, REQUESTED AT ONCE, for the reason the
# account card requests sixteen attributes in one go: a JVM start costs the same
# whether four attributes are asked for or forty.
#
# Filtered rather than unfiltered, and here the difference is not a matter of
# taste. `zmprov gd` with no attribute list answered with 111 lines on the lab
# server — every GAL attribute mapping, every web client preference — and among
# them, in plain text, the bind password of the directory this domain
# authenticates against. A screen is a place an operator takes a screenshot of.
#
# Order is alphabetical because that is the order zmprov answers in.
ZRO_DOMAIN_ATTRS=(
  zimbraDomainDefaultCOSId
  zimbraDomainStatus
  zimbraDomainType
  zimbraMailCatchAllAddress
  zimbraMailCatchAllForwardingAddress
)

# The domain an address belongs to.
#
# THE WHOLE ADDRESS IS VALIDATED FIRST, not just split on '@'. The selected
# address has been judged once already, so a value that fails here got past
# selection and is a defect rather than something an operator typed — and the
# answer is about to become an argument to a directory read, which is exactly
# where a guess would turn into a query about a name nobody has.
zro_domain_of() {
  local addr=${1-}
  zro_validate_email "$addr" || return "$ZRO_E_INPUT"
  printf '%s' "${addr##*@}"
}

zro_domain_fetch() {
  local d=${1-}
  zro_validate_domain "$d" || return "$ZRO_E_INPUT"
  zro_prov_read "$ZRO_E_NO_DOMAIN" gd "$d" "${ZRO_DOMAIN_ATTRS[@]}"
}

# What kind of domain this is, in the directory's own word plus what it means.
#
# The word is kept rather than translated away: it is what `zmprov` answers, what
# the administration console shows, and what an operator will type into a search.
# A value this program does not recognise is shown AS IT STANDS — it is a fact
# the directory carries, and rendering it as 'bilinmiyor' would report a Zimbra
# release newer than this tool as a value nobody could read.
zro_domain_type_field() {
  case ${1-} in
    local) printf 'local (postayi bu sunucu tasir)' ;;
    alias) printf 'alias (baska bir alan adinin ikinci adi)' ;;
    '')    printf '%s' "$ZRO_TXT_UNSET" ;;
    *)     printf '%s' "$1" ;;
  esac
}

# THE DOMAIN CARD: what an operator needs to tell a suspended domain from a
# delivery problem, and to say where unrouted mail goes.
zro_domain_card() {
  local d=${1-} raw rc=0
  zro_reset_mode
  raw=$(zro_domain_fetch "$d") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  local name status type catchall fwd cosid
  # The entry zmprov says answered, from the header — the same one source the
  # identity module reads for an account, and for the same reason.
  name=$(zro_identity_canonical "$raw") || name=$d
  status=$(zro_attr_get "$raw" zimbraDomainStatus)
  type=$(zro_attr_get "$raw" zimbraDomainType)
  catchall=$(zro_attr_get "$raw" zimbraMailCatchAllAddress)
  fwd=$(zro_attr_get "$raw" zimbraMailCatchAllForwardingAddress)
  cosid=$(zro_attr_get "$raw" zimbraDomainDefaultCOSId)

  # Read before anything is printed, so that a lookup which had to fall back to
  # LDAP is disclosed by the banner at the top rather than after it.
  local cos_name=$ZRO_TXT_UNSET cos_raw
  if [ -n "$cosid" ]; then
    cos_raw=$(zro_account_cos_fetch "$cosid" 2>/dev/null) || cos_raw=""
    cos_name=$(zro_attr_get "$cos_raw" cn)
    # The id was set, so a name that did not come back is a lookup this program
    # could not complete — not a domain without a default class of service.
    [ -n "$cos_name" ] || cos_name=$ZRO_TXT_UNKNOWN
  fi

  zro_mode_banner

  zro_card_line 'Alan adi' "$name"
  zro_card_line 'Durum' "${status:-$ZRO_TXT_UNSET}"
  zro_card_line 'Tur' "$(zro_domain_type_field "$type")"
  # 'yok' rather than 'tanimsiz', and the difference is the operator's next
  # action. A catch-all is not inherited from anywhere, so an attribute nobody
  # wrote means this domain has no catch-all — which is the answer to "where does
  # mail for an address that does not exist go", not a value nobody could read.
  zro_card_line 'Catch-all adresi' "${catchall:-$ZRO_TXT_NONE}"
  # Only when it is set: it is the second half of a catch-all that forwards to
  # another domain, and a labelled 'yok' on every ordinary domain would be a line
  # nobody needs under a name nobody recognises.
  [ -n "$fwd" ] && zro_card_line 'Catch-all yonlendirme' "$fwd"
  zro_card_line 'Varsayilan COS' "$cos_name"

  printf '\n'
  printf 'Durum active degilse bu alan adina posta teslimi Zimbra tarafindan\n'
  printf 'engellenir; boyle bir durumda sorun teslim yolunda degil buradadir.\n'
  printf '\n'
  if [ -z "$catchall" ]; then
    printf 'Catch-all tanimli degil: bu alan adinda karsiligi olmayan bir adrese\n'
    printf 'gelen posta teslim edilmez.\n'
  else
    printf 'Catch-all tanimli: bu alan adinda karsiligi olmayan adreslere gelen\n'
    printf 'posta yukaridaki adrese teslim edilir.\n'
  fi
  if [ -z "$cosid" ]; then
    printf '\n'
    printf 'Varsayilan COS tanimli degil: bu alan adinda acilan hesaplar sunucu\n'
    printf 'genelindeki varsayilan sinifi alir.\n'
  fi
  printf '\n'
  # Said out loud, because the operator who came for it will otherwise read its
  # absence as an oversight and go looking for the number by hand.
  printf 'Hesap sayisi gosterilmiyor: 100.000 hesabi asan bir sunucuda bu sayim\n'
  printf 'sunucu genelinde bir tarama olur, ve bu araca boyle bir islem alinmaz.\n'
  return 0
}

# --------------------------------------------------- distribution list --

# What the list read asks for, and the reason the ACEs are in it: owners and
# send permissions are not stored on the list as fields of their own. They are
# access control entries on the same entry, so ONE READ answers all three
# questions the operator arrived with.
ZRO_DL_ATTRS=(
  zimbraACE
  zimbraMailForwardingAddress
  zimbraMailStatus
)

# The two rights this card groups. Written down rather than matched loosely,
# because a grant is spelled as its right and a DENIAL is spelled as the same
# right with a leading '-': matching on a prefix would read a denial as
# permission, which answers "why was this message rejected" backwards.
ZRO_DL_RIGHT_OWNER='ownDistList'
ZRO_DL_RIGHT_SEND='sendToDistList'

# How many distinct grantees are looked up by name.
#
# A BOUND ON INVOCATIONS, not on the answer. Every grantee is still shown; past
# this many, they are shown by the identifier the directory holds rather than by
# an address, and the screen says so. A list with fifty owners would otherwise
# cost fifty JVM starts on a screen nobody expected to wait two minutes for.
ZRO_DL_GRANTEE_MAX=20

zro_dl_fetch() {
  local addr=${1-}
  zro_validate_email "$addr" || return "$ZRO_E_INPUT"
  zro_prov_read "$ZRO_E_NO_RESULT" gdl "$addr" "${ZRO_DL_ATTRS[@]}"
}

# How many members the SERVER says the list has, from the header it prints above
# every list record: `# distributionList <address> memberCount=N`.
#
# Read from the header rather than counted here, and shown beside the members
# this card rendered, because the two answer different questions: one is what the
# directory holds, the other is what this program managed to read out of it.
zro_dl_member_count() {
  local out
  out=$(printf '%s\n' "${1-}" | awk '
    $1 == "#" && $2 == "distributionList" {
      for (i = 3; i <= NF; i++) {
        if ($i ~ /^memberCount=/) { sub(/^memberCount=/, "", $i); print $i; exit }
      }
    }')
  case $out in
    ''|*[!0-9]*) return "$ZRO_E_NO_RESULT" ;;
  esac
  printf '%s' "$out"
}

# The addresses mail to this list is delivered to.
#
# From the attribute rather than from the `members` block zmprov prints after
# the record: the attribute is the directory's own field, in the same
# `key: value` shape every other read in this program parses, while the block is
# a rendering. A list with no members has no attribute at all and no lines under
# the block either — measured, both — so an empty answer here is an empty list.
zro_dl_members() {
  zro_attr_all "${1-}" zimbraMailForwardingAddress
}

# The grantees holding exactly one right, as "<type><TAB><id>" lines.
#
# `NF == 3` is the shape every captured ACE had. Anything else is not read as a
# grant of this right — it goes to zro_dl_other_aces below, where an operator can
# see it rather than where this program can quietly misread it.
zro_dl_grantees() {
  local raw=${1-} right=${2-}
  [ -n "$right" ] || return 0
  zro_attr_all "$raw" zimbraACE \
    | awk -v right="$right" 'NF == 3 && $3 == right { printf "%s\t%s\n", $2, $1 }'
}

# Every grantee of a right this card DOES group, once per grant. The table
# below folds the repeats; this is what it folds.
zro_dl_grantees_all() {
  zro_attr_all "${1-}" zimbraACE \
    | awk -v o="$ZRO_DL_RIGHT_OWNER" -v s="$ZRO_DL_RIGHT_SEND" \
        'NF == 3 && ($3 == o || $3 == s) { printf "%s\t%s\n", $2, $1 }'
}

# Every access control entry this card has no group for, as it stands.
#
# IT EXISTS SO THAT NOTHING IS SILENTLY DROPPED. A denial, a right a later Zimbra
# release adds, an entry in a shape nothing here recognises: each is a fact about
# who may use this list, and a card that showed only what it understood would
# report a restricted list as an open one.
zro_dl_other_aces() {
  zro_attr_all "${1-}" zimbraACE \
    | awk -v o="$ZRO_DL_RIGHT_OWNER" -v s="$ZRO_DL_RIGHT_SEND" \
        'NF != 3 || ($3 != o && $3 != s)'
}

# What a grantee this program could not name reads as: the type it is, and the
# identifier the directory holds. Written once, because it is reached from two
# places — a lookup that failed and a lookup the bound above did not spend.
zro_dl_grantee_unresolved() {
  printf '%s (%s)' "${1-}" "${2-}"
}

ZRO_TXT_DL_PUBLIC='herkes (kimlik dogrulamasi olmadan)'
# What an EMPTY send permission means, which is the opposite of what an empty
# list of anything usually means. Zimbra enforces this right only when somebody
# holds it: a list nobody was granted send permission on accepts mail from
# everyone. Rendering that as 'yok' would tell an operator that nobody may send
# to a list which in fact accepts mail from the entire internet.
ZRO_TXT_DL_OPEN='kisitlama yok (herkes gonderebilir)'

# The address behind a grantee identifier, or a refusal.
#
# ONE READ, DISPATCHED BY GRANTEE TYPE. `zmprov` answers for a zimbraId exactly
# as it does for a name — measured on TEST-C for both an account and a list — so
# naming a grantee costs the same read this program already makes elsewhere, and
# the header it prints is the address.
#
# THE IDENTIFIER IS JUDGED EVEN THOUGH IT CAME FROM THE DIRECTORY. It is about to
# become an argument, and everything that becomes an argument in this program is
# judged first; a value that would be read as a flag never leaves this function.
zro_dl_grantee_resolve() {
  local type=${1-} id=${2-} raw
  case $id in
    ''|-*|*[!A-Za-z0-9-]*) return "$ZRO_E_INPUT" ;;
  esac
  case $type in
    usr) raw=$(zro_prov_read "$ZRO_E_NO_RESULT" ga "$id" displayName) || return $? ;;
    grp) raw=$(zro_prov_read "$ZRO_E_NO_RESULT" gdl "$id" zimbraMailStatus) || return $? ;;
    # Every other grantee type names something this program has no captured read
    # for — a domain, a guest, an access key. Refused rather than guessed at.
    *) return "$ZRO_E_NO_RESULT" ;;
  esac
  zro_identity_canonical "$raw"
}

# One grantee, as an operator reads it.
#
# The public grantee is named without a lookup, because there is nothing to look
# up: granting to 'pub' writes a fixed sentinel identifier that names no entry in
# the directory. Printing it would put a meaningless UUID on the one line an
# operator reads to find out who may send.
zro_dl_grantee_label() {
  local type=${1-} id=${2-} addr
  if [ "$type" = pub ]; then
    printf '%s' "$ZRO_TXT_DL_PUBLIC"
    return 0
  fi
  addr=$(zro_dl_grantee_resolve "$type" "$id" 2>/dev/null) || addr=""
  [ -n "$addr" ] || { zro_dl_grantee_unresolved "$type" "$id"; return 0; }
  printf '%s' "$addr"
}

# Whether this list has more grantees than the bound will name.
zro_dl_grantee_capped() {
  local n
  n=$(zro_dl_grantees_all "${1-}" | awk '$1 == "usr" || $1 == "grp"' | sort -u | grep -c .)
  [ "$n" -gt "$ZRO_DL_GRANTEE_MAX" ]
}

# EVERY DISTINCT GRANTEE ON THE LIST, NAMED ONCE, as "<type><TAB><id><TAB><name>".
#
# The table exists for the folding. The captured list grants two rights to each of
# two grantees, and a card that resolved per grant rather than per grantee would
# pay two invocations for every one it needed — on the screen where an operator is
# already waiting on a directory read.
zro_dl_grantee_table() {
  local raw=${1-} line type id key seen=" " resolved=0 label
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    type=${line%%"$ZRO_TAB"*}
    id=${line#*"$ZRO_TAB"}
    # Both halves are drawn from a character set with no space in it, so a
    # space-delimited set is a set and not a string that happens to match.
    key="$type:$id"
    case $seen in
      *" $key "*) continue ;;
    esac
    seen="$seen$key "

    case $type in
      usr|grp)
        if [ "$resolved" -lt "$ZRO_DL_GRANTEE_MAX" ]; then
          resolved=$((resolved + 1))
          label=$(zro_dl_grantee_label "$type" "$id")
        else
          label=$(zro_dl_grantee_unresolved "$type" "$id")
        fi ;;
      *) label=$(zro_dl_grantee_label "$type" "$id") ;;
    esac
    printf '%s\t%s\t%s\n' "$type" "$id" "$label"
  done <<EOF
$(zro_dl_grantees_all "$raw")
EOF
  return 0
}

# The name this table holds for one grantee.
zro_dl_grantee_lookup() {
  local table=${1-} type=${2-} id=${3-} line
  while IFS= read -r line; do
    case $line in
      "$type$ZRO_TAB$id$ZRO_TAB"*) printf '%s' "${line##*"$ZRO_TAB"}"; return 0 ;;
    esac
  done <<EOF
$table
EOF
  # A grantee in a group and not in the table is a defect in this file rather
  # than anything about the list, so the identifier is kept rather than the line
  # being dropped.
  zro_dl_grantee_unresolved "$type" "$id"
}

# The grantees of one right, one readable name per line.
zro_dl_grantee_render() {
  local table=${1-} raw=${2-} right=${3-} line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' \
      "$(zro_dl_grantee_lookup "$table" "${line%%"$ZRO_TAB"*}" "${line#*"$ZRO_TAB"}")"
  done <<EOF
$(zro_dl_grantees "$raw" "$right")
EOF
  return 0
}

# THE DISTRIBUTION LIST CARD: who receives mail sent here, who owns the list, and
# who is permitted to send to it — the three facts a rejected message to a list
# is explained by, from one read of the list plus one per grantee.
zro_dl_card() {
  local addr=${1-} raw rc=0
  zro_reset_mode
  raw=$(zro_dl_fetch "$addr") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  local name count status members owners senders others table
  name=$(zro_identity_canonical "$raw") || name=$addr
  # A header with no count is a shape no capture has ever shown, so it is a fact
  # about this program rather than about the list — and it is said as one.
  count=$(zro_dl_member_count "$raw") || count=$ZRO_TXT_UNKNOWN
  status=$(zro_attr_get "$raw" zimbraMailStatus)
  members=$(zro_dl_members "$raw")

  # Every lookup happens before the first line is printed, so that one which had
  # to fall back to LDAP is disclosed by the banner above the card rather than
  # somewhere the operator has already scrolled past.
  table=$(zro_dl_grantee_table "$raw")
  owners=$(zro_dl_grantee_render "$table" "$raw" "$ZRO_DL_RIGHT_OWNER")
  senders=$(zro_dl_grantee_render "$table" "$raw" "$ZRO_DL_RIGHT_SEND")
  others=$(zro_dl_other_aces "$raw")

  zro_mode_banner

  zro_card_line 'Liste' "$name"
  zro_card_line 'Durum' "${status:-$ZRO_TXT_UNSET}"

  zro_card_head 'Uyelik'
  zro_card_line 'Uye sayisi' "$count"
  zro_card_list 'Uyeler' "$members" "$ZRO_TXT_NONE"

  zro_card_head 'Yetkiler'
  zro_card_list 'Sahipler' "$owners" "$ZRO_TXT_NONE"
  zro_card_list 'Gonderim izni' "$senders" "$ZRO_TXT_DL_OPEN"
  if [ -n "$others" ]; then
    # Shown only when there is something to show, and never folded into the two
    # groups above: an entry this program does not recognise may be a denial.
    zro_card_list 'Diger yetkiler' "$others" "$ZRO_TXT_NONE"
  fi

  printf '\n'
  if zro_dl_grantee_capped "$raw"; then
    printf 'Bu listede %s taneden fazla yetkili var: ilk %s tanesi adresiyle,\n' \
      "$ZRO_DL_GRANTEE_MAX" "$ZRO_DL_GRANTEE_MAX"
    printf 'digerleri dizindeki kimligiyle gosterildi. Hicbiri atlanmadi.\n'
    printf '\n'
  fi
  if [ -z "$senders" ]; then
    printf 'Gonderim izni tanimli degil: listeye herkes gonderebilir.\n'
  else
    printf 'Gonderim izni tanimli: listeye yalnizca yukaridakiler gonderebilir.\n'
    printf 'Reddedilen bir ileti icin once bu satirlara bakin.\n'
  fi
  printf '\n'
  printf 'Uyeler dizinden okunur. Uye olarak baska bir liste varsa kendi\n'
  printf 'adresiyle gorunur; o listenin uyeleri burada acilmaz.\n'
  return 0
}
