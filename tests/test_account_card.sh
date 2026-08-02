#!/usr/bin/env bash
set -uo pipefail
# The account card: every directory fact about the selected address on one
# screen, from one account read.
#
# EVERY FIXTURE HERE WAS CAPTURED, not written. `zmprov ga` was run on the lab
# server through the card's own attribute filter, so what these tests parse is
# byte-for-byte what the tool will parse in production, with only the names and
# addresses replaced. That rule exists because this repository has already
# shipped two production bugs from invented fixtures — a mailbox holding 485 MB
# reported as 0 B, and every account's last logon shown as '-'.
#
# What could NOT be captured is said out loud rather than invented:
# zimbraTwoFactorAuthEnabled has no TRUE sample anywhere, because TEST-C refuses
# to enable two-factor auth ("the extension is not deployed on this server").
# So the enabled state is exercised against the rendering function directly and
# never smuggled into a fixture pretending Zimbra wrote it.
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

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG
FIX="$ZRO_TEST_ROOT/fixtures"

# An account that belongs to no distribution list: `zmprov gam` prints nothing
# and exits 0, which is a result and not a failure.
EMPTY=$(mktemp); : >"$EMPTY"

# The populated account, read the way the menu reads it: account, class of
# service, membership.
card_full() {
  ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
  ZRO_MOCK_ZMPROV_GC_OUT="$FIX/zmprov_gc_ok.txt" \
  ZRO_MOCK_ZMPROV_GAM_OUT="$FIX/zmprov_gam_ok.txt" \
    zro_account_card 'ahmet.yilmaz@example.com'
}

# The same read against an account whose optional attributes are genuinely
# absent — captured from an account nobody has ever logged into, forwarded from,
# aliased or made an administrator.
card_bare() {
  ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_bare.txt" \
  ZRO_MOCK_ZMPROV_GC_OUT="$FIX/zmprov_gc_ok.txt" \
  ZRO_MOCK_ZMPROV_GAM_OUT="$EMPTY" \
    zro_account_card 'sade@example.com'
}

# ---------------------------------------------------------- the whole card --

it "renders the card from one invocation of the account read"
: >"$ZRO_MOCK_LOG"
card_full >/dev/null
assert_eq "$(grep -c "$(printf '^zmprov\tga\t')" "$ZRO_MOCK_LOG")" "1"

it "carries the directory facts an operator came for"
out=$(card_full)
assert_contains "$out" "Ahmet Yilmaz"
assert_contains "$out" "active"
assert_contains "$out" "mail01.example.com"
assert_contains "$out" "default"
assert_contains "$out" "5.0 GB"
assert_contains "$out" "2026-07-29 18:12:13"

it "names the canonical delivery address, not only the address asked about"
out=$(card_full)
assert_contains "$out" "Teslim adresi"
assert_contains "$out" "ahmet.yilmaz@example.com"

it "shows the class of service by name and never by its raw id"
out=$(card_full)
assert_contains "$out" "default"
assert_not_contains "$out" "e00428a1-0c00-11d9"

it "lists every alias on the account"
out=$(card_full)
assert_contains "$out" "a.yilmaz@example.com"
assert_contains "$out" "ayilmaz@example.com"

it "lists the distribution lists the account belongs to"
out=$(card_full)
assert_contains "$out" "bilgi-islem@example.com"
assert_contains "$out" "tum-personel@example.com"

it "labels last logon as approximate"
assert_contains "$(card_full)" "yaklasik"

# whiptail wraps anything wider than the box, and it wraps mid-sentence. The
# card is the longest screen in this program and its labels are the widest.
it "keeps every line of the card inside the box"
for out in "$(card_full)" "$(card_bare)"; do
  too_long=$(printf '%s\n' "$out" | awk 'length($0) > 72 { print length($0)": "$0 }')
  assert_eq "$too_long" ""
done

# ------------------------------------------------------------- forwarding --

# THE ONE THING THIS CARD HAS TO GET RIGHT. The administrator-set forwarding is
# invisible to the account holder in their own client, which is exactly why an
# operator needs to see it — and why it may never be folded into one line with
# the preference the user set themselves.
it "shows the two kinds of forwarding on separate labelled lines"
out=$(card_full)
user_line=$(printf '%s\n' "$out" | grep '^Kullanici tanimli')
admin_line=$(printf '%s\n' "$out" | grep '^Yonetici tanimli')
assert_contains "$user_line" "kisisel-yedek@example.net"
assert_contains "$admin_line" "denetim@example.net"
assert_not_contains "$user_line" "denetim@example.net"
assert_not_contains "$admin_line" "kisisel-yedek@example.net"

it "lists every administrator-set forwarding address, not just the first"
out=$(card_full)
assert_contains "$out" "denetim@example.net"
assert_contains "$out" "arsiv@example.net"

it "says that administrator-set forwarding is hidden from the account holder"
assert_contains "$(card_full)" "kendi arayuzunde gorunmez"

it "says nothing about hidden forwarding when there is none"
assert_not_contains "$(card_bare)" "kendi arayuzunde gorunmez"

it "renders absent forwarding as none on both lines"
out=$(card_bare)
assert_eq "$(printf '%s\n' "$out" | grep '^Kullanici tanimli')" "Kullanici tanimli    : yok"
assert_eq "$(printf '%s\n' "$out" | grep '^Yonetici tanimli')"  "Yonetici tanimli     : yok"

# --------------------------------------------------------------- security --

it "shows when the password was last changed"
assert_contains "$(card_full)" "2026-07-30 21:29:37"

it "shows administrative rights the account really holds"
out=$(card_full)
assert_contains "$(printf '%s\n' "$out" | grep '^Yonetici yetkisi')" "evet"
assert_contains "$(printf '%s\n' "$out" | grep '^Yonetici yetkisi')" "delege"

it "reports an account that is locked out, and since when"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_lockout.txt" \
      ZRO_MOCK_ZMPROV_GC_OUT="$FIX/zmprov_gc_ok.txt" \
      ZRO_MOCK_ZMPROV_GAM_OUT="$EMPTY" \
      zro_account_card 'kilitlenen@example.com')
assert_contains "$out" "lockout"
line=$(printf '%s\n' "$out" | grep '^Kilitlenme')
assert_contains "$line" "evet"
assert_contains "$line" "2026-08-01 09:15:00"

it "reports an account that is not locked out as not locked out"
assert_contains "$(printf '%s\n' "$(card_full)" | grep '^Kilitlenme')" "hayir"

it "says the feature is out of reach rather than calling two-factor auth off"
# Captured state: the extension is not deployed on the lab server, so
# zimbraTwoFactorAuthEnabled is absent on every account while
# zimbraFeatureTwoFactorAuthAvailable is present and FALSE.
line=$(printf '%s\n' "$(card_full)" | grep '^Iki adimli')
assert_contains "$line" "tanimsiz"
assert_contains "$line" "kullanilamiyor"

# ------------------------------------------- absence is never a default --

# The rule the whole card turns on: zmprov omits an attribute nobody set, and
# absence must reach the operator as absence. A default in any of these fields
# is an answer to a question the directory never answered.
it "renders every absent attribute as unset, never as a default"
out=$(card_bare)
for field in 'Son giris' 'Yonetici yetkisi' 'Iki adimli'; do
  assert_contains "$(printf '%s\n' "$out" | grep "^$field")" "tanimsiz"
done

# The list fields say 'none' rather than 'not set': aliases, forwarding and
# membership are never inherited from anywhere, so an absent attribute there
# means the list is empty — which is an answer, and still not a default.
it "renders an absent list as empty rather than as something unreadable"
out=$(card_bare)
for field in 'Kullanici tanimli' 'Yonetici tanimli' 'Aliaslar' 'Dagitim listeleri'; do
  line=$(printf '%s\n' "$out" | grep "^$field")
  assert_contains "$line" "yok"
  assert_not_contains "$line" "bilinmiyor"
done

it "never reports an absent quota as unlimited"
# An account whose read carried no quota AND whose class of service carries none
# either. Rendering that as Zimbra's 0 would report an unknown limit as no limit.
noquota=$(mktemp)
printf '# name x@example.com\nzimbraAccountStatus: active\n' >"$noquota"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$noquota" \
      ZRO_MOCK_ZMPROV_GAM_OUT="$EMPTY" \
      zro_account_card 'x@example.com')
line=$(printf '%s\n' "$out" | grep '^Kota limiti')
assert_contains "$line" "bilinmiyor"
assert_not_contains "$line" "sinirsiz"
rm -f -- "$noquota"

it "still reports a quota Zimbra really set to zero as unlimited"
# 0 is a value, not an absence: Zimbra writes it to mean no limit.
line=$(printf '%s\n' "$(card_bare)" | grep '^Kota limiti')
assert_contains "$line" "sinirsiz"

it "distinguishes an empty membership from a membership lookup that failed"
assert_eq "$(printf '%s\n' "$(card_bare)" | grep '^Dagitim listeleri')" \
          "Dagitim listeleri    : yok"

out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_bare.txt" \
      ZRO_MOCK_ZMPROV_GC_OUT="$FIX/zmprov_gc_ok.txt" \
      ZRO_MOCK_ZMPROV_GAM_ERR="$FIX/zmprov_io_error_refused.err" \
      ZRO_MOCK_ZMPROV_GAM_RC=1 \
      ZRO_MOCK_ZMPROV__L_GAM_ERR="$FIX/zmprov_io_error_refused.err" \
      ZRO_MOCK_ZMPROV__L_GAM_RC=1 \
      zro_account_card 'sade@example.com')
line=$(printf '%s\n' "$out" | grep '^Dagitim listeleri')
assert_contains "$line" "bilinmiyor"
assert_contains "$line" "uyelik sorgusu basarisiz"

it "renders the card even when the membership lookup fails"
# An operator who came for the status of a locked account is not handed a
# failure screen because a list lookup broke.
assert_contains "$out" "active"
assert_contains "$out" "mail01.example.com"

# ------------------------------------------------------- quota provenance --

it "says the quota came from the account read when it did"
assert_contains "$(printf '%s\n' "$(card_full)" | grep '^Kota limiti')" "hesap sorgusundan"

it "falls back to the class-of-service quota and says which it used"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_l_ga_no_quota.txt" \
      ZRO_MOCK_ZMPROV_GC_OUT="$FIX/zmprov_gc_10gb.txt" \
      ZRO_MOCK_ZMPROV_GAM_OUT="$EMPTY" \
      zro_account_card 'kotasiz@example.com')
line=$(printf '%s\n' "$out" | grep '^Kota limiti')
assert_contains "$line" "10.0 GB"
assert_contains "$line" "COS kaydindan"

# ----------------------------------------------------- the failure screens --

it "a missing account is its own answer"
ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_ga_no_such_account.err" \
ZRO_MOCK_ZMPROV_GA_RC=1 \
  assert_status "$ZRO_E_NO_ACCOUNT" zro_account_card 'yok@example.com'

it "an unreachable mailbox service is its own answer"
ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_io_error_refused.err" \
ZRO_MOCK_ZMPROV_GA_RC=1 \
ZRO_MOCK_ZMPROV__L_GA_ERR="$FIX/zmprov_io_error_refused.err" \
ZRO_MOCK_ZMPROV__L_GA_RC=1 \
  assert_status "$ZRO_E_UNAVAILABLE" zro_account_card 'a@b.com'

it "an invalid address is its own answer, and runs nothing"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_INPUT" zro_account_card 'a@b.com; id'
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

# --------------------------------------------------------- degraded read --

# When mailboxd is down EVERY SOAP call fails, not just the first. Scripted
# faithfully, or the fallback would only look tested.
it "answers from the directory when the mailbox service is down"
out=$(ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_io_error_refused.err" \
      ZRO_MOCK_ZMPROV_GA_RC=1 \
      ZRO_MOCK_ZMPROV_GC_ERR="$FIX/zmprov_io_error_refused.err" \
      ZRO_MOCK_ZMPROV_GC_RC=1 \
      ZRO_MOCK_ZMPROV_GAM_ERR="$FIX/zmprov_io_error_refused.err" \
      ZRO_MOCK_ZMPROV_GAM_RC=1 \
      ZRO_MOCK_ZMPROV__L_GA_OUT="$FIX/zmprov_ga_active.txt" \
      ZRO_MOCK_ZMPROV__L_GC_OUT="$FIX/zmprov_gc_ok.txt" \
      ZRO_MOCK_ZMPROV__L_GAM_OUT="$FIX/zmprov_l_gam_ok.txt" \
      zro_account_card 'ahmet.yilmaz@example.com')
assert_contains "$out" "Ahmet Yilmaz"
assert_contains "$out" "active"
assert_contains "$out" "5.0 GB"
assert_contains "$out" "denetim@example.net"
assert_contains "$out" "sistem@example.com"

it "discloses the degraded read above the card, not after it"
# The banner has to be the first thing on the screen: whiptail scrolls the text,
# and a disclosure below fifteen fields is a disclosure nobody reads. A
# membership lookup that fell back after the account read succeeded still
# degrades the whole card, so it is read before anything is printed.
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
      ZRO_MOCK_ZMPROV_GC_OUT="$FIX/zmprov_gc_ok.txt" \
      ZRO_MOCK_ZMPROV_GAM_ERR="$FIX/zmprov_io_error_refused.err" \
      ZRO_MOCK_ZMPROV_GAM_RC=1 \
      ZRO_MOCK_ZMPROV__L_GAM_OUT="$FIX/zmprov_l_gam_ok.txt" \
      zro_account_card 'ahmet.yilmaz@example.com')
assert_contains "$out" "LDAP"
assert_contains "$(printf '%s\n' "$out" | head -n 1)" "UYARI"

it "no warning when every read came from the mailbox service"
assert_not_contains "$(card_full)" "LDAP"

# ------------------------------------------------- the rendering functions --

# The card's fields are rendered by functions that take a value and answer with
# text. Testing them directly is how the states no fixture could carry are
# covered without inventing output and calling it captured.

it "renders a Zimbra boolean, and absence as neither true nor false"
assert_out_eq "evet"       zro_flag_field TRUE
assert_out_eq "hayir"      zro_flag_field FALSE
assert_out_eq "tanimsiz"   zro_flag_field ""
assert_out_eq "bilinmiyor" zro_flag_field "maybe"

it "renders two-factor authentication in every state it can be in"
# The enabled state has no captured sample and is therefore asserted here and
# nowhere else. See the header of this file.
assert_out_eq "acik"   zro_twofactor_field TRUE FALSE
assert_out_eq "acik"   zro_twofactor_field TRUE TRUE
assert_out_eq "kapali" zro_twofactor_field FALSE TRUE
assert_out_eq "tanimsiz" zro_twofactor_field "" TRUE
assert_out_eq "tanimsiz (bu hesapta kullanilamiyor)" zro_twofactor_field "" FALSE

it "renders administrative rights without turning silence into a denial"
assert_out_eq "tanimsiz" zro_admin_field "" ""
assert_out_eq "hayir" zro_admin_field FALSE FALSE
assert_out_eq "hayir" zro_admin_field FALSE ""
assert_out_eq "evet (tam yonetici)" zro_admin_field TRUE FALSE
assert_out_eq "evet (delege yonetici)" zro_admin_field FALSE TRUE
assert_out_eq "evet (tam yonetici, delege yonetici)" zro_admin_field TRUE TRUE

it "tells a current lockout from a stamp left behind by an expired one"
assert_out_eq "evet (2026-08-01 09:15:00 tarihinden beri)" \
  zro_lockout_field lockout 20260801091500.000Z
assert_out_eq "evet" zro_lockout_field lockout ""
assert_out_eq "hayir (son kilitlenme: 2026-08-01 09:15:00)" \
  zro_lockout_field active 20260801091500.000Z
assert_out_eq "hayir" zro_lockout_field active ""
assert_out_eq "bilinmiyor" zro_lockout_field "" ""

it "tells an absent timestamp from one it could not read"
assert_out_eq "tanimsiz"   zro_time_field ""
assert_out_eq "bilinmiyor" zro_time_field "2026-07-15"
assert_out_eq "2026-07-28 06:40:34" zro_time_field "20260728064034.819Z"

it "tells an unreadable quota from one Zimbra set to zero"
assert_out_eq "bilinmiyor" zro_quota_field ""
assert_out_eq "sinirsiz (hesap sorgusundan)" \
  zro_quota_field "0${ZRO_TAB}account"
assert_out_eq "5.0 GB (COS kaydindan)" \
  zro_quota_field "5368709120${ZRO_TAB}cos"
assert_out_eq "bilinmiyor" zro_quota_field "not-a-number${ZRO_TAB}account"

it "answers with nothing when no quota can be read at all"
assert_status "$ZRO_E_NO_RESULT" zro_account_quota_limit "zimbraAccountStatus: active" ""
assert_out_eq "" zro_account_quota_limit "zimbraAccountStatus: active" ""

rm -f -- "$ZRO_MOCK_LOG" "$EMPTY"
zro_t_report
