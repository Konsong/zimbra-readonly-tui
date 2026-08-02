# shellcheck shell=bash
# Address identity: what an address turns out to BE, before any screen assumes
# it is an account. Depends on lib/account.sh for the directory read and the
# attribute reader, which is why the entry point sources it after that module.
[ -n "${ZRO_LIB_IDENTITY_LOADED:-}" ] && return 0
ZRO_LIB_IDENTITY_LOADED=1

# THE MEASUREMENT THIS MODULE EXISTS FOR. On TEST-C on 2026-08-02, `zmprov ga`
# on a distribution list answered:
#
#   ERROR: account.NO_SUCH_ACCOUNT (no such account: tum-personel@sirket.lcl)
#
# — the same sentence, word for word, that an address existing nowhere in the
# directory produces. An operator told "no such account" about a list they can
# see in the address book concludes the tool is broken, or worse, that the
# address is gone. So the question "is this an account" is answered before it is
# assumed, and the four answers that are not "no" are told apart from each other.
#
# COST CLASS 1, DECLARED HERE because resolving an address is not one of the
# operations in the entry point's list — it is what an operator does before
# choosing one, and every entry in that list declares its own class there.
# Bounded by construction all the same: at most two directory reads about
# one address. An account, an alias and a resource cost ONE — `zmprov ga`
# resolves an alias to the account behind it and returns a calendar resource as
# the account it is, both measured rather than assumed. A list and an address
# that is nowhere cost two. Nothing here searches, and no read's work grows with
# the number of accounts on the server.

# What the identity read asks for, beyond existence.
#
# TWO ATTRIBUTES, and neither of them the canonical address: the entry that
# answered is named by the header zmprov prints above its attributes, which is
# the subject of this whole module and is read from there instead. A display
# name makes the answer readable — 'Toplanti Odasi' says more about a resource
# than its address does — and the calendar user type is what separates a
# resource from an ordinary account, since Zimbra stores a resource AS an
# account and `zmprov ga` returns it like one.
ZRO_IDENTITY_ATTRS=(
  displayName
  zimbraAccountCalendarUserType
)

# The entry zmprov says answered, from the header it prints above every record.
#
# ONE SOURCE FOR THE CANONICAL NAME, and this one rather than
# zimbraMailDeliveryAddress, because the header is zmprov's own answer to the
# question being asked — which entry did this name resolve to — while the
# attribute merely usually equals it. Two sources that can disagree is how a
# program ends up reporting an alias that is not one.
#
# Both shapes carry it in the same position: `# name <address>` for an account,
# `# distributionList <address> memberCount=N` for a list. The count after it is
# why this takes the third field rather than the rest of the line.
#
# Present in LDAP mode as well as SOAP — captured both ways on TEST-C — so a
# degraded read does not lose the one thing this module reads.
zro_identity_canonical() {
  local out
  out=$(printf '%s\n' "${1-}" | awk '$1 == "#" && NF >= 3 { print $3; exit }')
  [ -n "$out" ] || return "$ZRO_E_NO_RESULT"
  printf '%s' "$out"
}

# Two addresses naming the same entry.
#
# Case-folded, because a mail address is case-insensitive and zmprov answers in
# the case the directory holds: `zmprov ga ZimScope-Alias-A@Sirket.LCL` returned
# the canonical name in lower case on TEST-C. Comparing literally would report
# every operator who capitalised an address as having typed an alias.
zro_identity_same_address() {
  local a=${1-} b=${2-}
  [ "${a,,}" = "${b,,}" ]
}

# The record, as `key: value` lines — the same shape zmprov itself answers in,
# so the attribute reader already in this program reads it without a parser of
# its own. Absent rather than empty is how a field says it has no value, exactly
# as the directory does.
#
#   kind     one of: account, alias, resource, list, absent
#   address  the address as the operator gave it
#   account  the account behind it, where there is one
#   name     its display name, where the directory carries one
zro_identity_record() {
  printf 'kind: %s\naddress: %s\n' "${1-}" "${2-}"
  [ -n "${3-}" ] && printf 'account: %s\n' "$3"
  [ -n "${4-}" ] && printf 'name: %s\n' "$4"
  return 0
}

zro_identity_kind()    { zro_attr_get "${1-}" kind; }
zro_identity_address() { zro_attr_get "${1-}" address; }
zro_identity_account() { zro_attr_get "${1-}" account; }
zro_identity_name()    { zro_attr_get "${1-}" name; }

# Whether the address the operator gave is a second name for the entry that
# answered — which is what an alias IS, whatever kind the entry turns out to be.
#
# ASKED OF THE RECORD RATHER THAN OF THE KIND, because the two are not the same
# question. A resource can carry an alias too, and it is a resource: the kind
# says what the entry is, this says how it was reached. Every screen that has to
# name both addresses asks this, so none of them repeats the comparison — and
# none of them repeats it WRONGLY, which is the real hazard: a literal `!=` here
# would put a spurious second line on the card of every operator who capitalised
# an address.
zro_identity_aliased() {
  local rec=${1-} account
  account=$(zro_identity_account "$rec")
  [ -n "$account" ] || return 1
  ! zro_identity_same_address "$(zro_identity_address "$rec")" "$account"
}

# What an answered account read means, decided without running anything.
#
#   $1  the address that was asked about
#   $2  what `zmprov ga` answered
#
# A RESOURCE IS AN ACCOUNT to Zimbra — same objectClass tree, same read, and
# `zmprov gcr` is not needed to find one. What separates them is a single
# attribute, so it is that attribute rather than a second invocation that
# decides here.
#
# An alias is what the requested address being something other than the entry
# that answered means: `zmprov ga` resolves an alias to its account and says so
# in the header. Where there is no header there is nothing to compare against,
# and the answer is an account with no canonical name rather than a guess —
# claiming an alias would be claiming evidence this program does not have.
#
# A RESOURCE REACHED THROUGH AN ALIAS IS STILL A RESOURCE. The kind names what
# the entry is, and being reached by a second name does not change that — so the
# resource test comes first and the alias fact is carried by the record instead,
# where zro_identity_aliased finds it whatever the kind. Deciding it here by
# order alone would have made the two facts compete, and one of them would have
# been dropped whichever way the order went.
zro_identity_classify() {
  local addr=${1-} raw=${2-} canonical name kind rec
  canonical=$(zro_identity_canonical "$raw") || canonical=""
  name=$(zro_attr_get "$raw" displayName)
  rec=$(zro_identity_record account "$addr" "$canonical" "$name")

  if [ "$(zro_attr_get "$raw" zimbraAccountCalendarUserType)" = RESOURCE ]; then
    kind='resource'
  elif zro_identity_aliased "$rec"; then
    kind='alias'
  else
    kind='account'
  fi
  zro_identity_record "$kind" "$addr" "$canonical" "$name"
}

# WHAT THIS ADDRESS IS. Prints the record and succeeds for every outcome it
# learned — including the one where the answer is that the directory holds
# nothing under this address.
#
# THAT IS THE WHOLE DISCIPLINE: absence is a result and returns 0, a question
# this program could not ask returns the code for why. A resolver that answered
# "does not exist" whenever it failed would put the tool's worst sentence behind
# a stopped service, and that sentence is what sends an operator to look in the
# wrong place.
#
# So the list read runs ONLY when the account read said, in Zimbra's own words,
# that there is no such account. Any other failure is that failure, and it
# travels out with its own code rather than becoming an absence.
zro_identity_resolve() {
  local addr=${1-} raw rc=0
  zro_validate_email "$addr" || return "$ZRO_E_INPUT"

  raw=$(zro_prov_read "$ZRO_E_NO_ACCOUNT" ga "$addr" "${ZRO_IDENTITY_ATTRS[@]}") || rc=$?
  if [ "$rc" -eq 0 ]; then
    zro_identity_classify "$addr" "$raw"
    return 0
  fi
  [ "$rc" -eq "$ZRO_E_NO_ACCOUNT" ] || return "$rc"

  # The second and last read. Its output is not parsed beyond the header: a list
  # answers with every member it has, which is proportional to the list and not
  # to the server — cost class 1 — but it is the members' screen that displays
  # them, not this one.
  rc=0
  raw=$(zro_prov_read "$ZRO_E_NO_RESULT" gdl "$addr") || rc=$?
  if [ "$rc" -eq 0 ]; then
    zro_identity_record list "$addr"
    return 0
  fi
  # NO_RESULT is what this call site named a missing list, and nothing else may
  # be read as one. A list read that timed out or found no service is that.
  [ "$rc" -eq "$ZRO_E_NO_RESULT" ] || return "$rc"

  zro_identity_record absent "$addr"
}

# THE ADDRESS AN ACCOUNT-SCOPED SCREEN QUERIES. The selected address unless the
# session has learned an account behind it, in which case that one.
#
# It matters for exactly one case and it is the case this module was written for:
# an alias. Both spellings answer — `zmprov ga` and `zmprov gam` were both run
# through an alias on TEST-C and both returned the account's own record — so the
# choice is not about whether the query works. It is about what the answer is
# labelled: a card headed with the alias reads as a card about the alias, and
# there is no such thing.
#
# Lives here rather than in lib/selection.sh because it reads the record, and the
# record's shape belongs to this module. Falls back to the selected address for
# every case where nothing better is known — a resolution that failed, a list, an
# address that is nowhere — so a screen reached anyway queries what the operator
# actually chose rather than nothing at all.
zro_identity_selected_account() {
  local account
  account=$(zro_identity_account "$(zro_sel_identity)")
  [ -n "$account" ] || { zro_sel_address; return 0; }
  printf '%s' "$account"
}

# The other two questions a screen asks about the selection, so that no screen
# walks from the session to the record to a field itself. Empty when nothing has
# been resolved, which every caller reads as "not known" rather than as a kind.
zro_identity_selected_kind() {
  zro_identity_kind "$(zro_sel_identity)"
}

zro_identity_selected_aliased() {
  zro_identity_aliased "$(zro_sel_identity)"
}

# ------------------------------------------------------ what an operator reads --

ZRO_TXT_IDENTITY_ACCOUNT='Bu adres bir hesap.'
ZRO_TXT_IDENTITY_ALIAS='Bu adres bir alias: baska bir hesabin ikinci adresi.'
ZRO_TXT_IDENTITY_RESOURCE='Bu adres bir kaynak (toplanti odasi veya ekipman).'
ZRO_TXT_IDENTITY_LIST='Bu adres bir dagitim listesi, hesap degil.'
ZRO_TXT_IDENTITY_ABSENT='Bu adres dizinde bulunamadi.'

# The identity as a screen.
#
# Every kind gets its own closing paragraph, because what an operator should do
# next differs for each and a single sentence covering all five would be a
# sentence covering none. The list one says out loud what this program would
# otherwise have said wrong — an account read on a list address fails with
# "no such account", and that is not what is wrong.
#
# A record naming no kind is a defect in this program rather than something an
# address is, so it is refused instead of drawn with a blank first line.
zro_identity_card() {
  local rec=${1-} kind addr account name
  kind=$(zro_identity_kind "$rec")
  addr=$(zro_identity_address "$rec")
  account=$(zro_identity_account "$rec")
  name=$(zro_identity_name "$rec")
  [ -n "$kind" ] || return "$ZRO_E_INPUT"

  case $kind in
    account)  printf '%s\n\n' "$ZRO_TXT_IDENTITY_ACCOUNT" ;;
    alias)    printf '%s\n\n' "$ZRO_TXT_IDENTITY_ALIAS" ;;
    resource) printf '%s\n\n' "$ZRO_TXT_IDENTITY_RESOURCE" ;;
    list)     printf '%s\n\n' "$ZRO_TXT_IDENTITY_LIST" ;;
    absent)   printf '%s\n\n' "$ZRO_TXT_IDENTITY_ABSENT" ;;
    *) zro_log error "identity defect, no card for kind: $kind"
       return "$ZRO_E_INPUT" ;;
  esac

  zro_card_line 'Adres' "$addr"
  # BOTH NAMED, always, and decided by how the address reached the entry rather
  # than by the kind: a screen that showed only the account would answer a
  # question the operator did not ask, and one that showed only the address they
  # typed would hide the entry every later screen is really about.
  zro_identity_aliased "$rec" && zro_card_line 'Hesap' "$account"
  [ "$kind" = resource ] && zro_card_line 'Tur' 'kaynak'
  [ -n "$name" ] && zro_card_line 'Ad' "$name"

  printf '\n'
  case $kind in
    alias)
      printf 'Hesap islemleri alias uzerinden de calisir; sonuclar yukaridaki\n'
      printf 'hesap hakkindadir.\n' ;;
    resource)
      printf 'Zimbra kaynaklari hesap olarak saklar, bu yuzden hesap islemleri\n'
      printf 'bu adres icin de calisir.\n' ;;
    list)
      # The sentence this module was written to replace, said correctly — and
      # then the screen that does answer for this kind, because being told what
      # an address is not is only half of what an operator came for.
      printf 'Hesap islemleri bu adres icin calismaz ve bunu "hesap bulunamadi"\n'
      printf 'diye bildirirler; bu bir hata degil, adresin bir liste olmasidir.\n'
      printf 'Dagitim listesi karti ve teslim takibi bu adres icin calisir.\n' ;;
    absent)
      printf 'Ne hesap, ne alias, ne kaynak, ne de dagitim listesi olarak kayitli.\n'
      printf 'Sorgular calisti ve yanit verdi: bu, dizinde boyle bir kayit\n'
      printf 'olmadigi anlamina gelir. Adresi kontrol edin.\n'
      # The one screen that can still say something about this address: whether
      # the server carries its domain's mail at all. An address that is nowhere
      # in a domain the server does not host is not a missing account.
      printf 'Alan adi karti, bu sunucunun bu alan adini tasiyip tasimadigini\n'
      printf 'gosterir.\n' ;;
  esac
  return 0
}
