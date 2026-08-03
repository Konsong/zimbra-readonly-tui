# shellcheck shell=bash
# Everything that decides what happens to an account's mail, read from the
# directory and opening no mailbox: the filter rules, whether local delivery is
# disabled, the aliases, the send-as identities and the signatures. Depends on
# lib/account.sh for the reads and the attribute readers, which is why the entry
# point sources it after.
[ -n "${ZRO_LIB_MAILSET_LOADED:-}" ] && return 0
ZRO_LIB_MAILSET_LOADED=1

# WHY THIS IS A DIRECTORY SCREEN AND NOT A MAILBOX ONE. Every fact below lives on
# the account entry or on a child entry of it, so all of it answers for an account
# that has never been used — measured on the lab server, where an account with no
# mailbox answered all three reads and `zmprov gis` still reported no mailbox
# afterwards. That is the whole reason these questions are worth asking here: an
# operator investigating "this user's mail is not arriving" needs the filter that
# discards it and the forward that takes it away, and needs them for the account
# that has never logged in as much as for the one that has.
#
# WHAT CLASS 1 MEANS HERE. The card is THREE reads about ONE account: the entry
# itself, its signatures and its send-as identities. Signatures and identities are
# child entries in the directory rather than attributes, so no attribute list on
# the first read could have carried them — this is the same shape as the account
# card paying for a membership lookup, one level further. It is class 1 all the
# same: what the work grows with is entries, and one account costs a fixed three
# reads however large the directory around it gets. The multiple is declared where
# the operation is, and the suite asserts reads-per-entry rather than a total.
#
# The filter screen is one read of its own and pays for none of the other two.

# EVERY MAIL-SETTING THE CARD SHOWS, REQUESTED AT ONCE, for the reason the account
# card requests sixteen attributes in one go: a JVM start costs the same whether
# six attributes are asked for or twenty-six.
#
# Order is alphabetical because that is the order zmprov answers in.
#
# THE TWO FORWARDING ATTRIBUTES ARE HERE ALTHOUGH THE ACCOUNT CARD ALSO SHOWS
# THEM, and that is not duplication for its own sake. Local delivery disabled
# means nothing on its own: an operator reading it has to see, on the same screen,
# whether anything is carrying the mail away instead. Forwarding with local
# delivery left on is a copy; forwarding with local delivery off is the mailbox
# never receiving the message at all, and those are different incidents.
ZRO_MAILSET_ATTRS=(
  zimbraMailAlias
  zimbraMailForwardingAddress
  zimbraMailOutgoingSieveScript
  zimbraMailSieveScript
  zimbraPrefMailForwardingAddress
  zimbraPrefMailLocalDeliveryDisabled
)

# What the filter screen reads, and nothing else. A rule set is a whole script and
# an account can carry two of them; a screen that asked for the card's six
# attributes would be paying to re-read a list of aliases nobody is looking at.
ZRO_FILTER_ATTRS=(
  zimbraMailOutgoingSieveScript
  zimbraMailSieveScript
)

# The signature read: the name and both bodies.
#
# THE BODY IS READ BECAUSE THE NAME DOES NOT ANSWER THE QUESTION. An operator
# reaches this screen to explain what a user's outgoing mail LOOKS like, and a
# list of names says only that something is signed.
#
# THE NAME IS NOT OPTIONAL, and not only because it is displayed: `zmprov` answers
# in alphabetical order, so `zimbraSignatureName` sorts after both bodies and every
# record therefore ENDS with a single-line attribute. That is what makes one record
# separable from the next — a multi-line body standing last would run to the blank
# line and the `# name` header that follow it, and both of those may occur inside a
# body. Dropping the name from this list would not shorten the read; it would make
# the output ambiguous.
ZRO_SIGNATURE_ATTRS=(
  zimbraPrefMailSignature
  zimbraPrefMailSignatureHTML
  zimbraSignatureName
)

# How many lines of a signature body the card shows.
#
# A BOUND ON THE SCREEN, not on the answer, and it is here because a signature is
# the one value on this card whose size nobody controls. A plain-text footer is
# four lines; nothing stops one being forty, and a card that scrolled for a page
# would bury the delivery lines an operator came for. Past this many the body is
# cut and the screen says so, the way every other bound in this tool is disclosed.
ZRO_SIGNATURE_BODY_MAX=8

# The send-as identity read.
#
# 'SEND-AS IDENTITY', NEVER 'IDENTITY' ALONE, throughout this module. This program
# already has an identity: what a selected address turns out to BE — an account, an
# alias, a list. Zimbra's identity is a different thing wearing the same word: a
# persona the account holder may send mail as. Two concepts sharing one noun in one
# tool is how a screen ends up answering the wrong question under the right label,
# so the longer name is used everywhere here and lib/identity.sh keeps the short one.
ZRO_SENDAS_ATTRS=(
  zimbraPrefFromAddress
  zimbraPrefFromDisplay
  zimbraPrefIdentityName
  zimbraPrefReplyToAddress
  zimbraPrefReplyToEnabled
)

# The name Zimbra gives the identity it creates with the account itself. It is not
# something the account holder made, and it carries the account's own address, so
# the card says which one it is rather than listing it beside personas somebody
# chose to create.
ZRO_SENDAS_DEFAULT=DEFAULT

zro_mailset_fetch() {
  local acct=${1-}
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"
  zro_prov_read "$ZRO_E_NO_ACCOUNT" ga "$acct" "${ZRO_MAILSET_ATTRS[@]}"
}

zro_filter_fetch() {
  local acct=${1-}
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"
  zro_prov_read "$ZRO_E_NO_ACCOUNT" ga "$acct" "${ZRO_FILTER_ATTRS[@]}"
}

zro_signature_fetch() {
  local acct=${1-}
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"
  zro_prov_read "$ZRO_E_NO_ACCOUNT" gsig "$acct" "${ZRO_SIGNATURE_ATTRS[@]}"
}

zro_sendas_fetch() {
  local acct=${1-}
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"
  zro_prov_read "$ZRO_E_NO_ACCOUNT" gid "$acct" "${ZRO_SENDAS_ATTRS[@]}"
}

# --------------------------------------------------------- the rule sets --

# ONE RULE SET, IN FULL, for both screens.
#
# The attribute list is handed to the reader because that is what tells a
# continuation line from the line that ends the value — see the note above
# zro_attr_block, and the captured signature that would otherwise be cut off at a
# telephone number.
#
# THE WIDER OF THE TWO LISTS IS PASSED, WHICHEVER READ THIS IS. What the reader
# needs is a set containing every attribute that may appear in the output, and the
# filter screen's two are a subset of the card's six — so one set answers for both
# and a rule set is taken apart in one place. Two functions differing only in which
# array they handed over was two chances to hand over the wrong one, which fails by
# truncating a rule set rather than by failing.
zro_mailset_script() {
  zro_attr_block "${1-}" "${2-}" "${ZRO_MAILSET_ATTRS[@]}"
}

# What the CARD says about a rule set, which is deliberately not the rule set.
#
# A summary rather than the script, because a filter is the longest thing on this
# screen and the card is a place to find out THAT there is one. The line count is
# the summary that cannot mislead: it is the one number an operator can check the
# full screen against, and a rule set truncated to its first line would say '1'
# here — which is what makes this line a witness to the bug this ticket is about
# rather than a decoration.
zro_filter_summary() {
  local script=${1-} n
  [ -n "$script" ] || { printf '%s' "$ZRO_TXT_NONE"; return 0; }
  # Every line, blank ones included: they are what the rule set is made of, and a
  # count that skipped them would disagree with the screen that shows them.
  n=$(printf '%s\n' "$script" | awk 'END { print NR }')
  printf 'tanimli (%s satir)' "$n"
}

# ------------------------------------------------------- local delivery --

# WHETHER MAIL IS LEFT IN THIS ACCOUNT'S OWN MAILBOX.
#
# 'kapali' is the alarming answer and the reason the field exists: with it set,
# Zimbra delivers nowhere locally, so a mailbox can be empty while the account
# looks perfectly healthy on every other screen. It is normally set together with
# a forward, and the card puts the two side by side for that reason.
#
# ABSENCE IS NOT 'acik'. Zimbra omits an attribute nobody set, so an absent value
# reads as unset like every other absent attribute in this tool — and what Zimbra
# then does is said in the paragraph under the card, as a fact about Zimbra rather
# than as a value nobody read. The two are different claims and only one of them
# is about this account.
zro_local_delivery_field() {
  case ${1-} in
    TRUE)  printf 'kapali (posta yerel kutuya birakilmiyor)' ;;
    FALSE) printf 'acik' ;;
    '')    printf '%s' "$ZRO_TXT_UNSET" ;;
    *)     printf '%s' "$ZRO_TXT_UNKNOWN" ;;
  esac
}

# ---------------------------------------------- signatures and identities --

# ONE SIGNATURE, AS AN OPERATOR READS IT: its name, then what it puts at the foot
# of a message.
#
#   $1  the name      $2  the plain-text body      $3  the HTML body
#
# THE PLAIN TEXT WHERE THERE IS ANY, AND NEVER THE MARKUP. A Zimbra HTML signature
# routinely carries an embedded image as a data URI, so the markup is not a footer
# an operator can read — it is kilobytes of base64 in a terminal box, and the
# screen would be worse than the one that showed nothing. Where the account has an
# HTML signature and no plain-text one, the card says that it is HTML and how big
# it is, which is what an operator needs to know before going to look at it in a
# client.
#
# The body lines are indented by two, blank lines included: the indent is what
# keeps a blank line inside a footer from being dropped by the list writer, and
# what makes the whole block read as belonging to the name above it.
zro_signature_label() {
  local name=${1-} body=${2-} html=${3-} line n=0
  if [ -z "$body" ]; then
    printf '%s\n' "$name"
    # On its own line, under the name, exactly where a plain-text body would
    # stand — so an operator reads it as "this is what is there" rather than as a
    # decoration on the name, and so the line stays inside the box whatever the
    # signature is called.
    [ -n "$html" ] && printf '  (HTML imza, %s karakter; icerigi gosterilmez)\n' "${#html}"
    return 0
  fi

  printf '%s\n' "$name"
  while IFS= read -r line; do
    n=$((n + 1))
    if [ "$n" -gt "$ZRO_SIGNATURE_BODY_MAX" ]; then
      printf '  (imzanin ilk %s satiri gosterildi)\n' "$ZRO_SIGNATURE_BODY_MAX"
      return 0
    fi
    printf '  %s\n' "$line"
  done <<EOF
$body
EOF
  return 0
}

# Every signature on this account, as a block per signature, or nothing at all.
#
# READ AS RECORDS, SEQUENTIALLY, because a signature body is a multi-line value and
# the two things that would separate one record from the next both occur INSIDE
# one: a blank line, and a line beginning `#`. So the same rule zro_attr_block
# works by is applied here — a line that does not begin a declared attribute is a
# continuation of the value above it — and the record is closed by the NAME, which
# zmprov answers last because it sorts last. Nothing is decided by a blank line.
#
# Not zro_attr_block itself: that reader answers for ONE attribute of ONE record,
# and this is several records whose fields have to stay together. What they share
# is the rule, which is stated in both places and tested in both.
zro_signature_records() {
  local raw=${1-} line collecting='' name='' body='' html=''
  while IFS= read -r line; do
    case $line in
      'zimbraSignatureName: '*)
        # The last attribute of a record, so this both names the signature and
        # ends it. A record with no name is not one this program can render, and
        # zmprov has never answered with one.
        name=${line#zimbraSignatureName: }
        zro_signature_label "$name" "$body" "$html"
        collecting=''; name=''; body=''; html='' ;;
      'zimbraPrefMailSignature: '*)
        body=${line#zimbraPrefMailSignature: }; collecting=text ;;
      'zimbraPrefMailSignatureHTML: '*)
        html=${line#zimbraPrefMailSignatureHTML: }; collecting=html ;;
      *)
        # A record header, a blank separator, or a continuation — and which it is
        # depends entirely on whether a value is open. Outside one, there is
        # nothing here to keep.
        case $collecting in
          text) body="$body
$line" ;;
          html) html="$html
$line" ;;
        esac ;;
    esac
  done <<EOF
$raw
EOF
  return 0
}

# The signatures on this account, ready to render, or nothing at all.
#
# AN ACCOUNT WITH NO SIGNATURES ANSWERS WITH NO LINES AND STATUS 0 — measured on
# the lab server, where `zmprov gsig` on an account that has never defined one
# printed nothing and exited 0. That is a result and not a failure, and telling
# the two apart is the caller's business: one means the account has no signatures,
# the other means nobody managed to ask.
zro_signatures() {
  local acct=${1-} raw rc=0
  raw=$(zro_signature_fetch "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  zro_signature_records "$raw"
  return 0
}

# Every send-as identity, as "<name><TAB><from address><TAB><display name><TAB><reply-to>".
#
# READ AS RECORDS, because a field belongs to the identity it was printed under
# and a reader that collected every from-address on its own would pair the wrong
# address with the wrong name. zmprov separates one record from the next with a
# blank line, which is what paragraph mode reads — and it is only safe here
# because this read is FILTERED to attributes whose values are single lines. An
# unfiltered identity read carries a signature body, whose own blank lines would
# split one record into three.
#
# The reply-to address is carried only when Zimbra says it is enabled: the
# attribute survives the preference being switched off, so a card that showed it
# regardless would report a reply-to that nothing applies.
zro_sendas_rows() {
  printf '%s\n' "${1-}" | awk -F'\n' '
    BEGIN { RS = ""; OFS = "\t" }
    {
      name = ""; from = ""; disp = ""; rt = ""; rte = ""
      for (i = 1; i <= NF; i++) {
        p = index($i, ": ")
        if (p == 0) continue
        k = substr($i, 1, p - 1)
        v = substr($i, p + 2)
        if (k == "zimbraPrefIdentityName")      name = v
        else if (k == "zimbraPrefFromAddress")  from = v
        else if (k == "zimbraPrefFromDisplay")  disp = v
        else if (k == "zimbraPrefReplyToAddress") rt = v
        else if (k == "zimbraPrefReplyToEnabled") rte = v
      }
      if (name == "") next
      if (rte != "TRUE") rt = ""
      print name, from, disp, rt
    }
  '
}

# One identity as an operator reads it: what it is called, and what a message sent
# under it says in its From line.
#
# ONE VALUE PER LINE, NEVER TWO JOINED. whiptail wraps anything wider than the box
# and it wraps mid-word, so a line carrying a display name AND an address is a line
# whose address can break in half — and this is the only place in the tool that
# would have joined two pieces of free text the directory holds separately.
# Measured on the lab server, where an ordinary display name and an ordinary
# address came to 95 characters on one line. Each is its own line; the
# continuations are indented by two, so the card's own hanging indent reads as one
# identity rather than as four list entries.
zro_sendas_label() {
  local row=${1-} name from disp rt rest
  name=${row%%"$ZRO_TAB"*}
  rest=${row#*"$ZRO_TAB"}
  from=${rest%%"$ZRO_TAB"*}
  rest=${rest#*"$ZRO_TAB"}
  disp=${rest%%"$ZRO_TAB"*}
  rt=${rest#*"$ZRO_TAB"}

  if [ "$name" = "$ZRO_SENDAS_DEFAULT" ]; then
    printf '%s (hesabin kendi kimligi)\n' "$name"
  else
    printf '%s\n' "$name"
  fi
  [ -n "$disp" ] && printf '  %s\n' "$disp"
  [ -n "$from" ] && printf '  <%s>\n' "$from"
  [ -n "$rt" ] && printf '  yanit adresi: %s\n' "$rt"
  return 0
}

zro_sendas_list() {
  local raw=${1-} row
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    zro_sendas_label "$row"
  done <<EOF
$(zro_sendas_rows "$raw")
EOF
  return 0
}

# Every send-as identity on this account, ready to render, or a refusal.
#
# The sibling of zro_signatures, and written as one so that the card asks its two
# child-entry questions the same way. A caller that got a rendered list from one
# and raw output from the other has to remember which is which, and the one it
# forgets is the one that reaches the operator as a card field full of attribute
# names.
zro_sendas_identities() {
  local acct=${1-} raw rc=0
  raw=$(zro_sendas_fetch "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  zro_sendas_list "$raw"
  return 0
}

# ------------------------------------------------------------- the cards --

# THE MAIL SETTINGS CARD: everything that decides what happens to this account's
# mail, from three directory reads and no mailbox at all.
#
# The two reads behind the account read are allowed to fail without taking the
# card with them, exactly as the account card's membership lookup is: an operator
# who came to find out why mail is disappearing should not be handed a failure
# screen because a signature lookup timed out. What they must never be handed is
# an empty list where a failure happened, so each says which of the two it is.
zro_mailset_card() {
  local acct=$1 raw rc=0
  zro_reset_mode
  raw=$(zro_mailset_fetch "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  local local_delivery admin_fwd user_fwd aliases incoming outgoing
  local_delivery=$(zro_attr_get "$raw" zimbraPrefMailLocalDeliveryDisabled)
  admin_fwd=$(zro_attr_all "$raw" zimbraMailForwardingAddress)
  user_fwd=$(zro_attr_all "$raw" zimbraPrefMailForwardingAddress)
  aliases=$(zro_attr_all "$raw" zimbraMailAlias)
  incoming=$(zro_mailset_script "$raw" zimbraMailSieveScript)
  outgoing=$(zro_mailset_script "$raw" zimbraMailOutgoingSieveScript)

  # Both lookups happen before the first line is printed, so that one which had to
  # fall back to LDAP is disclosed by the banner above the card rather than
  # somewhere the operator has already scrolled past.
  local sigs="" sig_rc=0 sendas="" sendas_rc=0
  sigs=$(zro_signatures "$acct") || sig_rc=$?
  sendas=$(zro_sendas_identities "$acct") || sendas_rc=$?

  zro_mode_banner

  zro_card_line 'Hesap' "$acct"

  zro_card_head 'Teslim'
  zro_card_line 'Yerel teslim' "$(zro_local_delivery_field "$local_delivery")"
  # THE TWO KINDS OF FORWARDING, SEPARATE HERE AS THEY ARE ON THE ACCOUNT CARD.
  # The administrator-set one does not appear in the account holder's own client,
  # which is exactly why it belongs beside the local-delivery line: together they
  # are the pair that empties a mailbox without anybody being told.
  zro_card_list 'Kullanici tanimli' "$user_fwd" "$ZRO_TXT_NONE"
  zro_card_list 'Yonetici tanimli' "$admin_fwd" "$ZRO_TXT_NONE"

  zro_card_head 'Filtre kurallari'
  zro_card_line 'Gelen' "$(zro_filter_summary "$incoming")"
  zro_card_line 'Giden' "$(zro_filter_summary "$outgoing")"
  zro_card_more '(tam metin icin filtre kurallari ekranina bakin)'

  zro_card_head 'Adresler'
  zro_card_list 'Aliaslar' "$aliases" "$ZRO_TXT_NONE"

  # THE LABEL SAYS 'GONDERIM KIMLIKLERI' AND NEVER 'KIMLIKLER'. `Kimlik` is the
  # word lib/identity.sh owns for what an address turns out to BE, and a field on
  # this card reading `Kimlikler` is that word answering a different question one
  # screen away. The glossary keeps the two apart; this is the line where an
  # operator would otherwise meet them merged.
  zro_card_head 'Gonderim'
  if [ "$sendas_rc" -eq 0 ]; then
    zro_card_list 'Gonderim kimlikleri' "$sendas" "$ZRO_TXT_NONE"
  else
    # Said rather than left blank: an account with no extra identity and an
    # identity lookup that failed are different answers.
    zro_card_line 'Gonderim kimlikleri' \
      "$ZRO_TXT_UNKNOWN (gonderim kimligi sorgusu basarisiz)"
  fi
  if [ "$sig_rc" -eq 0 ]; then
    # 'yok' rather than 'tanimsiz': signatures are not inherited from anywhere, so
    # an account that answered with nothing has no signatures — which is an answer
    # to the question, not a value nobody could read.
    zro_card_list 'Imzalar' "$sigs" "$ZRO_TXT_NONE"
  else
    zro_card_line 'Imzalar' "$ZRO_TXT_UNKNOWN (imza sorgusu basarisiz)"
  fi

  printf '\n'
  if [ "$local_delivery" = TRUE ]; then
    printf 'Yerel teslim KAPALI: bu hesaba gelen posta bu sunucudaki kutusuna\n'
    printf 'birakilmiyor. Yukarida bir yonlendirme varsa posta oraya gidiyor;\n'
    printf 'yoksa posta hicbir yere teslim edilmiyor.\n'
  elif [ -z "$local_delivery" ]; then
    printf 'Yerel teslim ayari tanimli degil. Bu oznitelik tanimli olmadiginda\n'
    printf 'Zimbra postayi hesabin kendi kutusuna birakir.\n'
  fi
  if [ -n "$admin_fwd" ]; then
    printf '\n'
    printf 'Yonetici tanimli yonlendirme kullanicinin kendi arayuzunde GORUNMEZ:\n'
    printf 'kullanici postasinin baska bir adrese gittigini bilmiyor olabilir.\n'
  fi
  printf '\n'
  printf 'Bu ekran mailboxa hic bakmaz: butun degerler dizinden okunur ve\n'
  printf 'mailboxu olmayan bir hesap icin de yanit verir.\n'
  return 0
}

# THE FILTER RULES SCREEN: both rule sets, in full, exactly as the directory
# carries them.
#
# ITS OWN SCREEN because a rule set is a script and a card is a list of fields. A
# summary is what the card can honestly show; this is where the operator reads the
# rule that is discarding the message they were asked about — blank lines, comment
# lines and all, because every rule in a Zimbra filter is introduced by a comment
# and a rule set stripped of them is a rule set nobody can match against what the
# web client shows.
zro_mailset_filters_card() {
  local acct=$1 raw rc=0
  zro_reset_mode
  raw=$(zro_filter_fetch "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  local incoming outgoing
  incoming=$(zro_mailset_script "$raw" zimbraMailSieveScript)
  outgoing=$(zro_mailset_script "$raw" zimbraMailOutgoingSieveScript)

  zro_mode_banner

  zro_card_line 'Hesap' "$acct"

  zro_card_head 'Gelen posta kurallari'
  if [ -n "$incoming" ]; then
    printf '%s\n' "$incoming"
  else
    printf '%s\n' "$ZRO_TXT_NONE"
  fi

  zro_card_head 'Giden posta kurallari'
  if [ -n "$outgoing" ]; then
    printf '%s\n' "$outgoing"
  else
    printf '%s\n' "$ZRO_TXT_NONE"
  fi

  printf '\n'
  printf 'Kurallar dizinde tek bir oznitelikte, cok satirli metin olarak durur ve\n'
  printf 'burada oldugu gibi gosterilir: bos satirlar ve kural adlarini tasiyan\n'
  printf '# satirlari dahil. Web arayuzundeki sira ile ayni siradir.\n'
  return 0
}
