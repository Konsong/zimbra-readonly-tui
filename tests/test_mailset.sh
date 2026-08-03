#!/usr/bin/env bash
set -uo pipefail
# The mail settings screens: everything that decides what happens to an account's
# mail, read from the directory and opening no mailbox.
#
# EVERY FIXTURE HERE WAS CAPTURED. A lab account was given two filter rule sets,
# two signatures, a send-as identity, two aliases, both kinds of forwarding and a
# disabled local delivery, and then read through each screen's own attribute
# list — so what these cases parse is byte-for-byte what the tool will parse in
# production, with only the names and addresses replaced.
#
# The account those fixtures came from has NO MAILBOX, and that is not incidental:
# `zmprov gis` reported no mailbox for it before the reads and again after them, so
# the claim these screens rest on was measured rather than reasoned.
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/validate.sh
. "$ZRO_SRC/lib/validate.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
export ZRO_MOCK_ID_USER=zimbra
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* 2>/dev/null || true

# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"
# shellcheck source=../lib/account.sh
. "$ZRO_SRC/lib/account.sh"
# shellcheck source=../lib/mailset.sh
. "$ZRO_SRC/lib/mailset.sh"

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG
FIX="$ZRO_TEST_ROOT/fixtures"

ADDR='ahmet.yilmaz@example.com'
BARE='sade@example.com'

# An account with no signatures: `zmprov gsig` prints nothing and exits 0, which
# is a result and not a failure. Captured on the lab server against an account
# that has never defined one.
EMPTY=$(mktemp); : >"$EMPTY"

# The account carrying everything, read the way the screen reads it: the entry,
# its signatures, its send-as identities.
card_full() {
  ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_mailset_full.txt" \
  ZRO_MOCK_ZMPROV_GSIG_OUT="$FIX/zmprov_gsig_bodies.txt" \
  ZRO_MOCK_ZMPROV_GID_OUT="$FIX/zmprov_gid_two.txt" \
    zro_mailset_card "$ADDR"
}

# An account with forwarding and aliases but no filter, no signature and no
# identity of its own — the ordinary case.
card_plain() {
  ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_mailset_plain.txt" \
  ZRO_MOCK_ZMPROV_GSIG_OUT="$EMPTY" \
  ZRO_MOCK_ZMPROV_GID_OUT="$FIX/zmprov_gid_default.txt" \
    zro_mailset_card "$ADDR"
}

# The account with no mailbox and nothing set on it at all.
card_bare() {
  ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_mailset_bare.txt" \
  ZRO_MOCK_ZMPROV_GSIG_OUT="$EMPTY" \
  ZRO_MOCK_ZMPROV_GID_OUT="$FIX/zmprov_gid_default.txt" \
    zro_mailset_card "$BARE"
}

filters_full() {
  ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_mailset_sieve.txt" zro_mailset_filters_card "$ADDR"
}

filters_none() {
  ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_mailset_bare.txt" zro_mailset_filters_card "$BARE"
}

# --------------------------------------------------------------- the cost --

it "reads the account entry, its signatures and its identities, once each"
: >"$ZRO_MOCK_LOG"
card_full >/dev/null
assert_eq "$(grep -c "$(printf '^zmprov\tga\t')" "$ZRO_MOCK_LOG")" "1"
assert_eq "$(grep -c "$(printf '^zmprov\tgsig\t')" "$ZRO_MOCK_LOG")" "1"
assert_eq "$(grep -c "$(printf '^zmprov\tgid\t')" "$ZRO_MOCK_LOG")" "1"
# And nothing else of Zimbra's: three reads, not three plus whatever a field
# reached for on its own.
assert_eq "$(grep -c '^zmprov' "$ZRO_MOCK_LOG")" "3"

it "and the filter screen reads the entry once and nothing else"
: >"$ZRO_MOCK_LOG"
filters_full >/dev/null
assert_eq "$(grep -c '^zmprov' "$ZRO_MOCK_LOG")" "1"
assert_eq "$(grep -c "$(printf '^zmprov\tga\t')" "$ZRO_MOCK_LOG")" "1"

# THE CLAIM THE WHOLE SCREEN RESTS ON. Every fact it shows lives in the directory,
# so nothing here may reach a mailbox — not the gated binary, and not the oracle
# that guards it. An account with no mailbox is answered in full rather than
# refused, which is the acceptance criterion said as a cost.
it "opens no mailbox: neither screen runs the mailbox binary or the existence oracle"
: >"$ZRO_MOCK_LOG"
card_bare >/dev/null
filters_none >/dev/null
assert_eq "$(grep -c '^zmmailbox' "$ZRO_MOCK_LOG")" "0"
assert_eq "$(grep -c "$(printf '^zmprov\tgis')" "$ZRO_MOCK_LOG")" "0"

it "and answers in full for an account that has no mailbox"
assert_ok card_bare
assert_ok filters_none

# -------------------------------------------------------- the whole card --

it "carries the mail settings an operator came for"
out=$(card_full)
assert_contains "$out" "kapali"
assert_contains "$out" "kisisel-yedek@example.net"
assert_contains "$out" "arsiv@example.net"
assert_contains "$out" "denetim@example.net"
assert_contains "$out" "a.yilmaz@example.com"
assert_contains "$out" "ayilmaz@example.com"

# whiptail wraps anything wider than the box, and it wraps mid-sentence.
it "keeps every line of the card inside the box"
for out in "$(card_full)" "$(card_plain)" "$(card_bare)"; do
  too_long=$(printf '%s\n' "$out" | awk 'length($0) > 72 { print length($0)": "$0 }')
  assert_eq "$too_long" ""
done

# ------------------------------------------------------- local delivery --

it "names a disabled local delivery as the alarming answer it is"
assert_contains "$(card_full)" "Yerel teslim"
assert_contains "$(card_full)" "posta yerel kutuya birakilmiyor"

it "and says what it means, beside the forward that is carrying the mail away"
out=$(card_full)
assert_contains "$out" "Yerel teslim KAPALI"
assert_contains "$out" "Yonetici tanimli yonlendirme kullanicinin kendi arayuzunde GORUNMEZ"

# ABSENCE IS NOT 'acik'. An attribute nobody set is unset like every other, and
# what Zimbra then does is said as a fact about Zimbra rather than as this
# account's value.
it "renders an absent local delivery setting as unset, never as enabled"
out=$(card_plain)
delivery=$(printf '%s\n' "$out" | grep '^Yerel teslim')
assert_contains "$delivery" "$ZRO_TXT_UNSET"
assert_not_contains "$delivery" "acik"
assert_contains "$out" "Zimbra postayi hesabin kendi kutusuna birakir"

it "renders the field itself from the value alone"
assert_out_eq "acik" zro_local_delivery_field FALSE
assert_out_eq "$ZRO_TXT_UNSET" zro_local_delivery_field ''
assert_out_eq "$ZRO_TXT_UNKNOWN" zro_local_delivery_field yes

# ------------------------------------------------------ the filter summary --

# The line count is what makes this summary a witness rather than a decoration: a
# rule set truncated to its first line would say '1 satir' here, on the card, and
# the operator would never open the screen that shows the rest.
it "summarises each rule set by the number of lines it really has"
out=$(card_full)
assert_contains "$(printf '%s\n' "$out" | grep '^Gelen')" "tanimli (17 satir)"
assert_contains "$(printf '%s\n' "$out" | grep '^Giden')" "tanimli (8 satir)"

it "and says 'yok' for an account with no rules, which is not a failure"
out=$(card_bare)
assert_contains "$(printf '%s\n' "$out" | grep '^Gelen')" "$ZRO_TXT_NONE"
assert_contains "$(printf '%s\n' "$out" | grep '^Giden')" "$ZRO_TXT_NONE"

it "points at the screen that carries the full text"
assert_contains "$(card_full)" "tam metin icin filtre kurallari ekranina bakin"

# ------------------------------------------------------------ signatures --

it "lists the signatures by name"
out=$(card_full)
assert_contains "$out" "Kurumsal"
assert_contains "$out" "Kisa"

# THE NAME DOES NOT ANSWER THE QUESTION AN OPERATOR ARRIVED WITH. They are
# explaining what a user's outgoing mail LOOKS like, so the footer itself is on
# the screen — read through the multi-line reader, blank line and telephone number
# and all.
it "and shows what a plain-text signature really puts at the foot of a message"
out=$(card_full)
assert_contains "$out" "Ahmet Yilmaz"
assert_contains "$out" "Bilgi Islem"
assert_contains "$out" "Tel: 0212 000 00 00"

it "and never cuts that body off at the line that merely looks like an attribute"
# `Tel: 0212 000 00 00` is the last line of the captured signature. A reader that
# ended the value at the first `word: value` line would drop it, and the card
# would show a footer the user does not have.
out=$(card_full)
tel_line=$(printf '%s\n' "$out" | grep -c 'Tel: 0212 000 00 00')
assert_eq "$tel_line" "1"

# A Zimbra HTML signature routinely carries an embedded image as a data URI, so
# the markup is not a footer anybody can read off a terminal.
it "says an HTML signature is HTML and how big it is, rather than dumping markup"
out=$(card_full)
assert_contains "$out" "Kisa"
assert_contains "$out" "(HTML imza, 19 karakter; icerigi gosterilmez)"
assert_not_contains "$out" "<p>"

it "renders one signature from its own fields, whichever bodies it has"
assert_out_eq "$(printf 'Bos\n')" zro_signature_label 'Bos' '' ''
assert_out_eq "$(printf 'Duz\n  bir\n  \n  iki\n')" \
  zro_signature_label 'Duz' "$(printf 'bir\n\niki')" ''
# The plain text wins where a signature carries both: it is the one a person can
# read, and the markup says the same thing with tags around it.
assert_out_eq "$(printf 'Ikisi\n  duz\n')" zro_signature_label 'Ikisi' 'duz' '<p>duz</p>'

# A BOUND ON THE SCREEN, DISCLOSED. A signature is the one value on this card
# whose size nobody controls.
it "bounds a very long signature body and says that it did"
long=$(awk 'BEGIN { for (i = 1; i <= 20; i++) print "satir " i }')
out=$(zro_signature_label 'Uzun' "$long" '')
assert_eq "$(printf '%s\n' "$out" | grep -c '^  satir ')" "$ZRO_SIGNATURE_BODY_MAX"
assert_contains "$out" "ilk $ZRO_SIGNATURE_BODY_MAX satiri gosterildi"

# Records, not lines: a body's blank line and its '#' line are what would split
# one signature into two for a reader that went by either.
it "keeps each signature's body with its own name"
records=$(zro_signature_records "$(cat "$FIX/zmprov_gsig_bodies.txt")")
assert_eq "$(printf '%s\n' "$records" | grep -c '^Kurumsal$')" "1"
assert_eq "$(printf '%s\n' "$records" | grep -c '^Kisa$')" "1"
# Everything between the two names belongs to the first signature.
first=$(printf '%s\n' "$records" | sed -n '/^Kurumsal$/,/^Kisa$/p')
assert_contains "$first" "Tel: 0212 000 00 00"

# AN EMPTY RESULT IS A RESULT. The lab server answers an account with no
# signatures with no output and status 0, and that must never reach the operator
# as the word this tool keeps for a question nobody could ask.
it "renders an account with no signatures as 'yok', never as unreadable"
sig_line=$(printf '%s\n' "$(card_plain)" | grep '^Imzalar' | tail -n 1)
assert_contains "$sig_line" "$ZRO_TXT_NONE"
assert_not_contains "$sig_line" "$ZRO_TXT_UNKNOWN"

it "and a signature lookup that failed as 'bilinmiyor', which is the other answer"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_mailset_full.txt" \
      ZRO_MOCK_ZMPROV_GSIG_RC=2 \
      ZRO_MOCK_ZMPROV_GID_OUT="$FIX/zmprov_gid_two.txt" \
        zro_mailset_card "$ADDR")
sig_line=$(printf '%s\n' "$out" | grep '^Imzalar' | tail -n 1)
assert_contains "$sig_line" "$ZRO_TXT_UNKNOWN"
assert_contains "$sig_line" "imza sorgusu basarisiz"

it "and the card still renders everything else when that lookup failed"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_mailset_full.txt" \
      ZRO_MOCK_ZMPROV_GSIG_RC=2 \
      ZRO_MOCK_ZMPROV_GID_OUT="$FIX/zmprov_gid_two.txt" \
        zro_mailset_card "$ADDR")
assert_contains "$out" "tanimli (17 satir)"

# ------------------------------------------------- the send-as identities --

it "lists each send-as identity with the address a message under it comes from"
out=$(card_full)
assert_contains "$out" "Destek"
assert_contains "$out" "Destek Masasi"
assert_contains "$out" "<a.yilmaz@example.com>"

# The one place in the tool that could have joined two pieces of the directory's
# own free text on one line, and does not: a display name and an address together
# came to 95 characters on the lab server, and whiptail wraps mid-word.
it "and never joins a display name and an address on one line"
out=$(card_full)
assert_not_contains "$out" "Destek Masasi <"

it "carries the reply-to address only where Zimbra says it is enabled"
out=$(card_full)
assert_contains "$out" "yanit adresi: destek@example.com"
assert_eq "$(printf '%s\n' "$out" | grep -c 'yanit adresi')" "1"

# The identity Zimbra creates with the account carries the account's own address.
# Naming it is what keeps an operator from reading it as a persona somebody made.
it "says which identity is the one Zimbra made with the account"
assert_contains "$(card_full)" "DEFAULT (hesabin kendi kimligi)"

it "pairs each field with the identity it was printed under, never across records"
rows=$(zro_sendas_rows "$(cat "$FIX/zmprov_gid_two.txt")")
assert_eq "$(printf '%s\n' "$rows" | head -n 1)" \
  "$(printf 'Destek\ta.yilmaz@example.com\tDestek Masasi\tdestek@example.com')"
assert_eq "$(printf '%s\n' "$rows" | tail -n 1)" \
  "$(printf 'DEFAULT\tahmet.yilmaz@example.com\tAhmet Yilmaz\t')"

it "and an identity lookup that failed says so rather than showing an empty list"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_mailset_full.txt" \
      ZRO_MOCK_ZMPROV_GSIG_OUT="$FIX/zmprov_gsig_bodies.txt" \
      ZRO_MOCK_ZMPROV_GID_RC=2 \
        zro_mailset_card "$ADDR")
id_line=$(printf '%s\n' "$out" | grep '^Gonderim kimlikleri')
assert_contains "$id_line" "$ZRO_TXT_UNKNOWN"
assert_contains "$id_line" "gonderim kimligi sorgusu basarisiz"

# The label is 'Gonderim kimlikleri' and never 'Kimlikler': `Kimlik` is the word
# this tool keeps for what an address turns out to BE, one screen away, and the
# glossary exists to stop the two meeting on a card.
it "and never labels a send-as identity with the word address identity owns"
assert_not_line "$(card_full)" "$(printf 'Kimlikler%*s: DEFAULT' 12 '')"
assert_eq "$(printf '%s\n' "$(card_full)" | grep -c '^Kimlik')" "0"

# --------------------------------------------------- the filter rules screen --

# THE ACCEPTANCE CRITERION, ASSERTED AS A WHOLE VALUE. Anything less than the
# entire rule set is the bug this screen exists to fix, and a case that checked
# for a couple of lines would pass on a rule set cut off after them.
WANT_IN=$(cat <<'EOF'
require ["fileinto", "copy", "reject", "tag", "flag", "log"];

# Faturalar
if anyof (header :contains ["subject"] ["fatura"])
{
    fileinto "Faturalar";
    stop;
}

# Duyurular

if anyof (header :contains ["from"] ["duyuru@example.com"])
{
    fileinto "Duyurular";
    tag "otomatik";
    stop;
}
EOF
)

it "renders the incoming rule set in full, blank and comment lines preserved"
out=$(filters_full)
assert_contains "$out" "$WANT_IN"

it "renders the outgoing rule set too, under its own heading"
out=$(filters_full)
assert_contains "$out" "Gelen posta kurallari"
assert_contains "$out" "Giden posta kurallari"
assert_contains "$out" 'fileinto "Gonderilmis";'

it "never shows one rule set's text under the other's heading"
out=$(filters_full)
incoming=$(printf '%s\n' "$out" | sed -n '/^Gelen posta kurallari/,/^Giden posta kurallari/p')
assert_not_contains "$incoming" "Gonderilmis"

it "and says 'yok' where an account carries no rules at all"
out=$(filters_none)
assert_contains "$out" "Gelen posta kurallari"
assert_contains "$out" "$ZRO_TXT_NONE"
assert_not_contains "$out" "fileinto"

it "says where the rules come from and that nothing was tidied away"
assert_contains "$(filters_full)" "bos satirlar ve kural adlarini tasiyan"

# ----------------------------------------------------------- the refusals --

it "refuses an address that is not an address, before running anything"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_INPUT" zro_mailset_fetch 'not-an-address'
assert_status "$ZRO_E_INPUT" zro_filter_fetch '-flag@example.com'
assert_status "$ZRO_E_INPUT" zro_signature_fetch ''
assert_status "$ZRO_E_INPUT" zro_sendas_fetch 'bos bosluk@example.com'
assert_eq "$(grep -c . "$ZRO_MOCK_LOG")" "0"

card_missing() {
  ZRO_MOCK_ZMPROV_GA_RC=2 \
  ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_ga_no_such_account.err" \
    zro_mailset_card "$ADDR"
}

it "reports an account the directory does not have as exactly that"
assert_status "$ZRO_E_NO_ACCOUNT" card_missing

# ------------------------------------------------ the degraded read path --

# Both new reads answer from LDAP, measured on the lab server, so both are
# declared LDAP-capable and the allowlist approves the mode. Without all three of
# those, this screen would be the one directory screen that goes dark during a
# mailboxd outage — and it would go dark as an ALLOWLIST DENIAL, which in this
# program means a defect rather than an outage.
it "the two child-entry reads keep working when mailboxd does not"
for sub in gsig gid getSignatures getIdentities; do
  assert_ok zro_prov_ldap_capable "$sub"
done
assert_ok zro_ldap_form_allowed gsig 'ahmet.yilmaz@example.com'
assert_ok zro_ldap_form_allowed gid 'ahmet.yilmaz@example.com'

it "and the write-named siblings one letter away are refused in both modes"
for sub in csig msig dsig cid mid did createSignature modifySignature \
           deleteSignature createIdentity modifyIdentity deleteIdentity; do
  assert_fail zro_allowed zmprov "$sub"
  assert_fail zro_allowed zmprov -l "$sub"
  assert_fail zro_prov_ldap_capable "$sub"
done

zro_t_report
