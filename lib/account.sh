# shellcheck shell=bash
# M1 operations: account, quota, COS, mailbox host, membership.
[ -n "${ZRO_LIB_ACCOUNT_LOADED:-}" ] && return 0
ZRO_LIB_ACCOUNT_LOADED=1

# EVERY DIRECTORY FACT THE CARD SHOWS, REQUESTED AT ONCE. A JVM start costs the
# same whether five attributes are asked for or twenty-five, so the card pays for
# one invocation and displays all of it, rather than growing a second query every
# time a field is added.
#
# Filtered rather than unfiltered for the opposite reason. `zmprov ga` with no
# attribute list returned several hundred lines per account on the lab server —
# every class-of-service preference, mobile policy and zimlet setting the account
# inherits — and the dozen facts an operator came for are somewhere inside it.
#
# Order is alphabetical because that is the order zmprov answers in; keeping the
# two the same makes a captured fixture readable beside this list.
ZRO_ACCOUNT_ATTRS=(
  displayName
  zimbraAccountStatus
  zimbraCOSId
  zimbraFeatureTwoFactorAuthAvailable
  zimbraIsAdminAccount
  zimbraIsDelegatedAdminAccount
  zimbraLastLogonTimestamp
  zimbraMailAlias
  zimbraMailDeliveryAddress
  zimbraMailForwardingAddress
  zimbraMailHost
  zimbraMailQuota
  zimbraPasswordLockoutLockedTime
  zimbraPasswordModifiedTime
  zimbraPrefMailForwardingAddress
  zimbraTwoFactorAuthEnabled
)

# zmprov prints "name: value" lines. Matching the key at position 1 with its
# separator attached is what keeps zimbraMail from also matching
# zimbraMailHost.
#
# THE TEXT ARRIVES ON A HEREDOC RATHER THAN DOWN A PIPE, here and in every reader
# below that stops early. `printf | awk … exit` under `set -o pipefail` returns
# 141: awk exits on the line it wants, and if it wins that race the write at the
# other end gets SIGPIPE and the pipeline reports failure although the answer was
# printed correctly. It costs nothing where only the value is read — and it is
# wrong where the STATUS is the answer, which is what zro_attr_present below is
# for. Written the same way in all of them, so the safe one and the unsafe one do
# not have to be told apart by whoever edits them next.
zro_attr_get() {
  local text=$1 name=$2
  awk -v key="$name" '
    index($0, key ": ") == 1 { print substr($0, length(key) + 3); exit }
  ' <<EOF
$text
EOF
}

zro_attr_all() {
  local text=$1 name=$2
  printf '%s\n' "$text" | awk -v key="$name" '
    index($0, key ": ") == 1 { print substr($0, length(key) + 3) }
  '
}

# THE SIBLING READER, for an attribute whose value has more than one line.
#
#   $1  the output      $2  the attribute      $@  every attribute the read asked for
#
# A filter rule set is one attribute holding a whole script, and zmprov prints
# its remaining lines RAW — nothing marks them as continuations. So the reader
# above answers the first line and stops, which on a nine-line rule set is not a
# short answer but a WRONG one: it shows an operator a filter that files invoices
# into a folder and hides the rule underneath it that discards mail from a
# sender. Absence would have been visible; truncation is not.
#
# WHAT COUNTS AS THE END OF A VALUE IS DECLARED, NEVER GUESSED FROM THE SHAPE OF
# A LINE, and that is the whole design. A continuation line may be blank, it may
# begin with '#' — every rule in a Zimbra filter is introduced by a comment — and
# it may look exactly like an attribute line. Measured, in a signature captured
# from the lab server:
#
#     zimbraPrefMailSignature: --
#     Ahmet Yilmaz
#     Bilgi Islem
#
#     Tel: 0212 000 00 00
#     zimbraSignatureId: cda8ffdd-...
#
# A reader that ended a value at the first `word: value` line would cut that
# signature off at the telephone number. So the caller passes the attribute list
# it ASKED FOR — zmprov answers with those and no others — and a line begins a
# new attribute only when it begins one of THOSE. Every other line is a
# continuation, which is the rule stated as code rather than as a hope about
# what a value will not contain.
#
# THE FIRST VALUE ONLY. A multi-valued attribute is read with zro_attr_all, whose
# values are single lines by construction; this answers for the single-valued
# ones, and a second occurrence is left alone rather than appended to the first.
#
# TRAILING BLANK LINES ARE DROPPED, interior ones kept — and that is not a
# preference, it is the only decidable answer. zmprov ends a record with a blank
# line, so for the attribute that stands LAST in the output the separator and a
# trailing blank line of the value are the same bytes in the same place: nothing
# in the format tells them apart. Interior blanks carry no such ambiguity, they
# are the operator's own, and they are preserved.
#
# The read path happens to strip trailing newlines before this reader sees them —
# zro_prov_read returns a command substitution — so today the ambiguity does not
# arise through it. This does not rest on that: a reader whose answer depended on
# which caller fed it would be a reader nobody can reason about.
zro_attr_block() {
  local text=$1 name=$2
  shift 2
  awk -v key="$name" -v names="$*" '
    # The declared attribute this line begins, or nothing at all. Matched on the
    # separator alone rather than on the space after it, so that an attribute
    # returned with an empty value still ends the value above it.
    function attr_at(line,   i, nm, l) {
      for (i = 1; i <= n; i++) {
        nm = a[i]
        l = length(nm)
        if (substr(line, 1, l + 1) == nm ":" &&
            (length(line) == l + 1 || substr(line, l + 2, 1) == " ")) return nm
      }
      return ""
    }
    BEGIN { n = split(names, a, " "); last = 0 }
    {
      nm = attr_at($0)
      if (nm != "") {
        taking = 0
        if (nm == key && !seen) {
          seen = 1
          taking = 1
          buf[++k] = substr($0, length(key) + 3)
          if (buf[k] != "") last = k
        }
        next
      }
      if (taking) {
        buf[++k] = $0
        if ($0 != "") last = k
      }
    }
    END { for (i = 1; i <= last; i++) print buf[i] }
  ' <<EOF
$text
EOF
}

# Whether the output carries a line for this attribute AT ALL, which is not the
# same question as what its value is.
#
# The provenance screen is why it is a question of its own. That screen decides
# from the LINE BEING THERE and never from what is on it: zmprov omits an
# attribute nobody set, so the line's absence is the whole signal.
#
# MATCHED ON THE SEPARATOR ALONE, where the two readers above match on the space
# after it. That is the one place the three may differ, and the difference is the
# point: a line carrying nothing after its colon is a line the directory really
# returned, and this answers that it is there while the readers answer that its
# value is empty. Both are right about the question they were asked. Whether
# zmprov ever writes such a line has not been measured, which is exactly why the
# presence test does not depend on the answer.
#
# The colon is still what keeps zimbraMailForwardingAddress from matching
# zimbraMailForwardingAddressMaxLength, because a name is not a prefix of a longer
# name once the separator is attached.
# THE ONE READER WHOSE STATUS IS ITS ANSWER, which is why the heredoc above
# matters most here: a pipeline losing the SIGPIPE race would report an attribute
# the entry really carries as one the entry does not have, on the screen built to
# tell those two apart.
zro_attr_present() {
  local text=$1 name=$2
  awk -v key="$name" '
    index($0, key ":") == 1 { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' <<EOF
$text
EOF
}

# Zimbra stores timestamps as LDAP generalized time. A production server
# returned 20260728064034.819Z: fourteen digits, then fractional seconds, then
# a zone. The fraction is optional in the standard and absent from some
# attributes, and a zone may be an offset rather than Z, so all three shapes
# are accepted. Only the leading fourteen digits are displayed.
ZRO_RE_GENTIME='^[0-9]{14}(\.[0-9]{1,6})?(Z|[+-][0-9]{4})?$'

zro_zimbra_time() {
  local t=${1-}
  [[ $t =~ $ZRO_RE_GENTIME ]] || return "$ZRO_E_INPUT"
  printf '%s-%s-%s %s:%s:%s' \
    "${t:0:4}" "${t:4:2}" "${t:6:2}" "${t:8:2}" "${t:10:2}" "${t:12:2}"
}

# Interprets what a Zimbra CLI wrote to stderr, and prints the matching exit
# code — or 0 when it recognises nothing.
#
# By default zmprov talks SOAP to mailboxd, so a stopped mailbox service or an
# expired admin certificate fails every single query. Both were seen on real
# test servers on 2026-07-29, and both surfaced to the operator as nothing more
# than "islem basarisiz (kod 1)".
zro_zimbra_error_code() {
  local errfile=$1
  [ -f "$errfile" ] || { printf '0'; return 0; }

  if grep -qE 'zclient\.IO_ERROR|Connection refused|SSLHandshakeException|PKIX|SERVICE_UNAVAILABLE' \
       "$errfile" 2>/dev/null; then
    printf '%s' "$ZRO_E_UNAVAILABLE"
    return 0
  fi
  if grep -qE 'PERM_DENIED|permission denied|AUTH_FAILED' "$errfile" 2>/dev/null; then
    printf '%s' "$ZRO_E_PERM"
    return 0
  fi
  printf '0'
}

# Maps a failure to a documented code. $2 is the code to use when the text
# names a missing object, which differs between an account and a mailbox.
#
# AN OUTCOME READER AND NOT A FAILURE READER, and the name is what says so. A
# failure reader never sees a gate code and travels to the settler as a name; this
# one is handed whatever zro_exec returned, gate codes included, and is consumed
# BEFORE the read returns, because whether the mailbox service was unreachable is
# what decides the LDAP retry below. ADR-0010 records why this seam stays outside
# the settler. The name carries the rest: it also takes the CALLER's missing code,
# so it could not be called the way the settler calls a reader even if the order
# allowed it — and while it wore the reader's name, nothing said so.
#
# NO_SUCH_DISTRIBUTION_LIST is here because a list read is now one of the reads:
# `zmprov gdl` on anything that is not a list answers
# `ERROR: account.NO_SUCH_DISTRIBUTION_LIST (...)`, and without this line that
# would fall through to the raw exit status — which the identity resolver would
# have to read as a question it could not ask rather than as an answer.
#
# NO_SUCH_DOMAIN is here for the same reason and carries more weight: measured on
# TEST-C, `zmprov gd` answers it both for a domain nobody has heard of and for an
# address handed to it in place of a domain. Without this line the domain screen
# would report "islem basarisiz (kod 2)" for the one answer that ends the search.
zro_prov_outcome_code() {
  local errfile=$1 missing_code=$2 rc=$3
  if grep -qE 'NO_SUCH_ACCOUNT|NO_SUCH_MAILBOX|NO_SUCH_COS|NO_SUCH_DISTRIBUTION_LIST|NO_SUCH_DOMAIN' \
       "$errfile" 2>/dev/null; then
    printf '%s' "$missing_code"
    return 0
  fi
  local mapped
  mapped=$(zro_zimbra_error_code "$errfile")
  if [ "$mapped" != "0" ]; then
    printf '%s' "$mapped"
    return 0
  fi
  printf '%s' "$rc"
}

# Subcommands LDAP mode can answer. gmi is deliberately absent: Zimbra replies
# to `zmprov -l gmi` with "can only be used with SOAP", because mailbox usage
# lives in the mailbox database rather than in LDAP.
# gdl is here on evidence, not by analogy: `zmprov -l gdl` answered on TEST-C
# with the same record SOAP returns, members and all. So did `zmprov -l gd`,
# byte for byte with the SOAP answer for the attributes the domain card asks
# for — measured on 2026-08-02, not assumed from the family resemblance.
#
# gis is absent for gmi's reason and not for a reason of its own: index statistics
# are not in the directory either, and `zmprov -l gis` answers with the same
# sentence — measured on TEST-C, captured as a fixture. Being absent HERE is what
# stops the retry from being attempted; being absent from the allowlist is what
# would refuse it if it were. Two independent refusals, and the existence gate
# rests on the second.
#
# gsig and gid are here on evidence too, and the evidence matters more for them
# than for their neighbours: signatures and send-as identities are child entries
# of the account in the directory, so LDAP mode is where they really live.
# Measured on TEST-C on 2026-08-03, `zmprov -l gsig` and `zmprov -l gid` answered
# with the same records SOAP returns for the attributes the mail settings screen
# asks for — captured, not assumed from the family resemblance.
ZRO_LDAP_READS=' ga getAccount gam getAccountMembership gc getCos gdl getDistributionList gd getDomain gsig getSignatures gid getIdentities '

# The complete set of subcommands zro_prov_read may hand to the gate. It exists
# because that one call site passes a variable, which a static reader cannot
# resolve — so the set of values that variable may hold is written down here,
# enforced at runtime, and checked against the allowlist by the scanner.
ZRO_PROV_READS=' ga gam gc gdl gd gis gsig gid '

zro_prov_ldap_capable() {
  [ -n "${1-}" ] || return 1
  case $ZRO_LDAP_READS in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

# Runs one zmprov read and prints its output.
#
#   $1  exit code to use when Zimbra says the object does not exist
#   $2  subcommand
#   $@  already-validated arguments
#
# zmprov talks SOAP to mailboxd by default. When that path is unreachable the
# same read is retried against LDAP, which needs neither a running mailbox
# service nor a valid admin certificate — which is what keeps this tool usable
# during the incident it exists to diagnose. A missing account is not retried:
# LDAP would not find it either.
zro_prov_read() {
  local missing_code=$1 sub=$2
  shift 2

  # The gate below receives a variable, so the values it may hold are pinned
  # here as well. Belt and braces: the allowlist would still refuse anything
  # unapproved, but a reader should not have to trust that alone.
  case $ZRO_PROV_READS in
    *" $sub "*) ;;
    *) zro_log error "denied: $sub is not a declared read subcommand"
       return "$ZRO_E_DENIED" ;;
  esac

  local err out rc=0
  err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"

  out=$(zro_exec zmprov "$sub" "$@" 2>"$err") || rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f -- "$err"
    zro_set_mode soap
    zro_clear_error
    printf '%s' "$out"
    return 0
  fi

  local first_msg mapped
  first_msg=$(head -c "$ZRO_ERROR_KEEP_BYTES" -- "$err" 2>/dev/null)
  mapped=$(zro_prov_outcome_code "$err" "$missing_code" "$rc")

  # TWO QUESTIONS, AND THEY ARE DIFFERENT ONES. The first is whether Zimbra can
  # answer this read from LDAP at all — `gmi` cannot, because mailbox usage does
  # not live there. The second is whether this program is allowed to ask it that
  # way, which only the gate knows: the entry-only account read is approved
  # through mailboxd and in no other spelling, so a retry made without asking
  # would be refused — and an allowlist denial is logged as a defect. Asking
  # first is what keeps an ordinary outage from being reported as one.
  if [ "$mapped" = "$ZRO_E_UNAVAILABLE" ] && zro_prov_ldap_capable "$sub" \
     && zro_ldap_form_allowed "$sub" "$@"; then
    : >"$err"
    rc=0
    out=$(zro_exec zmprov -l "$sub" "$@" 2>"$err") || rc=$?
    if [ "$rc" -eq 0 ]; then
      rm -f -- "$err"
      zro_set_mode ldap
      zro_clear_error
      printf '%s' "$out"
      return 0
    fi
    mapped=$(zro_prov_outcome_code "$err" "$missing_code" "$rc")
  fi

  # The SOAP message is the informative one; a retry failure just repeats it.
  zro_set_error "$first_msg"
  rm -f -- "$err"
  return "$mapped"
}

zro_account_fetch() {
  local acct=${1-}
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"
  zro_prov_read "$ZRO_E_NO_ACCOUNT" ga "$acct" "${ZRO_ACCOUNT_ATTRS[@]}"
}

# WHAT ABSENCE IS ALLOWED TO LOOK LIKE ON THIS CARD.
#
# zmprov simply omits an attribute nobody set — an account whose card asks for
# sixteen attributes and receives nine is the ordinary case, measured on the lab
# server rather than assumed. So every field below can arrive as nothing at all,
# and the one thing nothing may ever become is a value.
#
# Two words, because absence has two causes and they call for different actions.
# 'tanimsiz' says the directory carries no such value. 'bilinmiyor' says this
# program could not read one — a malformed timestamp, a quota nothing answered
# for. Neither is a default and neither is zero.
ZRO_TXT_UNSET='tanimsiz'
ZRO_TXT_UNKNOWN='bilinmiyor'

# A third word, for the fields that are LISTS. An account carries its own
# aliases and its own forwarding — neither is inherited from anywhere — so an
# attribute that is absent there means the list is empty, which is a fact and
# reads as one. 'Yonetici tanimli: tanimsiz' says "administrator-defined:
# undefined" and makes an operator read the label twice; 'yok' answers the
# question they asked. It is still absence and still never a default.
ZRO_TXT_NONE='yok'

# Where a card value starts, as the width of the label column. One number, used
# by both writers below, because the labels are Turkish and nobody adding the
# next field counts spaces the same way twice — least of all twice in a row.
ZRO_CARD_LABEL_W=21

# One card line: the label padded to that column, then its value.
zro_card_line() {
  printf '%-*s: %s\n' "$ZRO_CARD_LABEL_W" "${1-}" "${2-}"
}

# A line that continues the value above it, indented to the value column so that
# a list of aliases reads as belonging to the label it hangs under. The indent is
# derived rather than typed: the label column plus the ': ' that follows it.
zro_card_more() {
  printf '%*s%s\n' "$((ZRO_CARD_LABEL_W + 2))" '' "${1-}"
}

zro_card_head() {
  printf '\n%s\n' "${1-}"
}

# A field whose value may have several lines, or none. The first value goes on
# the labelled line and the rest hang under it, so a list never loses its label.
zro_card_list() {
  local label=$1 values=$2 empty=$3 first=1 v
  if [ -z "$values" ]; then
    zro_card_line "$label" "$empty"
    return 0
  fi
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    if [ "$first" -eq 1 ]; then
      zro_card_line "$label" "$v"
      first=0
    else
      zro_card_more "$v"
    fi
  done <<EOF
$values
EOF
}

# A generalized timestamp as the operator reads it.
#
# An attribute that is absent and one that is malformed are told apart, because
# they call for different actions: the first is a fact about the account, the
# second is a fact about this program. That distinction is not theoretical —
# every account on a production server once showed a last logon of '-' because a
# real value carrying fractional seconds failed a validator written from memory.
zro_time_field() {
  local raw=${1-} out
  [ -n "$raw" ] || { printf '%s' "$ZRO_TXT_UNSET"; return 0; }
  out=$(zro_zimbra_time "$raw") || { printf '%s' "$ZRO_TXT_UNKNOWN"; return 0; }
  printf '%s' "$out"
}

# A Zimbra boolean as the operator reads it. ABSENCE IS NOT FALSE: an attribute
# nobody set is missing from the output entirely, and rendering that as 'hayir'
# would answer a question — is this account an administrator — that nothing
# actually answered.
#
# TRUE and FALSE are matched in the spelling the directory really writes: RFC
# 4517 boolean syntax is upper case, and that is what the lab server returned.
# Anything else is a value this program does not understand, which is not the
# same as a value that is not there.
zro_flag_field() {
  case ${1-} in
    TRUE)  printf 'evet' ;;
    FALSE) printf 'hayir' ;;
    '')    printf '%s' "$ZRO_TXT_UNSET" ;;
    *)     printf '%s' "$ZRO_TXT_UNKNOWN" ;;
  esac
}

# Whether the account holds administrative rights, from the two attributes that
# grant them.
#
# A compromised account's blast radius is why this is on the card at all, so
# 'hayir' is only said when something said it: both attributes absent reads as
# unset, never as an account without rights.
zro_admin_field() {
  local full=${1-} delegated=${2-} kinds=""
  [ "$full" = TRUE ] && kinds="tam yonetici"
  if [ "$delegated" = TRUE ]; then
    [ -n "$kinds" ] && kinds="$kinds, "
    kinds="${kinds}delege yonetici"
  fi
  if [ -n "$kinds" ]; then
    printf 'evet (%s)' "$kinds"
    return 0
  fi
  if [ -z "$full" ] && [ -z "$delegated" ]; then
    printf '%s' "$ZRO_TXT_UNSET"
    return 0
  fi
  printf 'hayir'
}

# Whether two-factor authentication is on.
#
# TWO ATTRIBUTES, because a server can put the feature out of reach entirely, and
# on such a server an absent enablement attribute means something different from
# what it means where the feature works. An operator diagnosing a login failure
# needs to be able to tell "this user has not set it up" from "nobody here can".
#
# The enabled rendering has no captured sample: TEST-C answers `ma
# zimbraTwoFactorAuthEnabled TRUE` with "cannot enable two-factor auth because it
# is not available on this account", and making it available fails in turn with
# "the extension is not deployed on this server" — the twofactorauth extension is
# present under lib/ext but not loaded. So the fixture carries the state that was
# really observed, and this function is exercised directly for the rest.
zro_twofactor_field() {
  local enabled=${1-} available=${2-}
  case $enabled in
    TRUE)  printf 'acik';   return 0 ;;
    FALSE) printf 'kapali'; return 0 ;;
  esac
  if [ "$available" = FALSE ]; then
    printf '%s (bu hesapta kullanilamiyor)' "$ZRO_TXT_UNSET"
    return 0
  fi
  printf '%s' "$ZRO_TXT_UNSET"
}

# Whether the account is locked out, and since when.
#
# Two signals answering different halves of one question: the status says whether
# it is locked out NOW, the timestamp says when a lockout last began. A stamp left
# behind by a lockout that has since expired is not a locked account, and
# reporting it as one sends an operator to unlock something already open.
zro_lockout_field() {
  local status=${1-} locked_at=${2-} when=""
  [ -n "$locked_at" ] && when=$(zro_time_field "$locked_at")
  case $status in
    lockout) printf 'evet%s' "${locked_at:+ ($when tarihinden beri)}"; return 0 ;;
    '')      printf '%s' "$ZRO_TXT_UNKNOWN"; return 0 ;;
  esac
  printf 'hayir%s' "${locked_at:+ (son kilitlenme: $when)}"
}

# The quota limit an account is subject to, together with WHICH READ ANSWERED IT,
# as "<bytes><TAB><source>". An account can inherit its limit from a class of
# service, and a directory read that did not carry one is retried against the COS
# record rather than reported as no limit at all.
#
# ABSENCE IS NOT ZERO. Zimbra writes zimbraMailQuota: 0 for unlimited, so a value
# nobody could read, rendered as 0, would report an account whose limit is unknown
# as an account with no limit — the single most misleading thing this field can
# say. Nothing is printed and a status is returned instead.
#
# $2 is an already-fetched COS record, so a caller that needed one anyway does not
# pay for a second lookup.
zro_account_quota_limit() {
  local raw=$1 cos_raw=${2-} limit cosid
  limit=$(zro_attr_get "$raw" zimbraMailQuota)
  if [ -n "$limit" ]; then
    printf '%s%saccount' "$limit" "$ZRO_TAB"
    return 0
  fi

  if [ -z "$cos_raw" ]; then
    cosid=$(zro_attr_get "$raw" zimbraCOSId)
    if [ -n "$cosid" ]; then
      cos_raw=$(zro_account_cos_fetch "$cosid" 2>/dev/null) || cos_raw=""
    fi
  fi
  limit=$(zro_attr_get "$cos_raw" zimbraMailQuota)
  [ -n "$limit" ] || return "$ZRO_E_NO_RESULT"
  printf '%s%scos' "$limit" "$ZRO_TAB"
}

# What the operator reads for a quota limit, and which read answered it.
#
# 'hesap sorgusundan' means the account read carried the value. IT DOES NOT MEAN
# THE VALUE IS SET ON THE ACCOUNT: zmprov expands what a class of service provides
# in both SOAP and LDAP mode — measured on the lab server, not assumed — so
# presence proves nothing about where a value came from. That question costs a
# second invocation and has a screen of its own.
# The limit out of the pair above, for a caller that needs the NUMBER rather than
# the sentence. It exists so that the pair's shape is known in one module: the
# quota screen computes a proportion from it, and a second hand-written split
# there would be two places that have to agree about a TAB.
#
# Prints nothing and fails when the pair carries no readable limit, which is the
# same refusal zro_account_quota_limit makes for the same reason: absence is not
# zero, and zero means unlimited.
zro_quota_limit_bytes() {
  local pair=${1-} bytes
  [ -n "$pair" ] || return "$ZRO_E_NO_RESULT"
  bytes=${pair%%"$ZRO_TAB"*}
  case $bytes in
    ''|*[!0-9]*) return "$ZRO_E_NO_RESULT" ;;
  esac
  printf '%s' "$bytes"
}

zro_quota_field() {
  local pair=${1-} bytes source human
  [ -n "$pair" ] || { printf '%s' "$ZRO_TXT_UNKNOWN"; return 0; }
  bytes=${pair%%"$ZRO_TAB"*}
  source=${pair#*"$ZRO_TAB"}
  case $source in
    cos) source='COS kaydindan' ;;
    *)   source='hesap sorgusundan' ;;
  esac
  if [ "$bytes" = "0" ]; then
    printf 'sinirsiz (%s)' "$source"
    return 0
  fi
  human=$(zro_human_bytes "$bytes") || { printf '%s' "$ZRO_TXT_UNKNOWN"; return 0; }
  printf '%s (%s)' "$human" "$source"
}

# THE ACCOUNT CARD: every directory fact about the selected address, on one
# screen, from one account read.
#
# Two further invocations sit behind it and neither is a field this list could
# have carried: the class of service is named by an opaque id that has to be
# resolved, and membership does not live on the account entry at all. Both are
# allowed to fail without taking the card with them — an operator who came for
# the status of a locked account should not be handed a failure screen because a
# list lookup timed out.
zro_account_card() {
  local acct=$1 raw rc=0
  zro_reset_mode
  raw=$(zro_account_fetch "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  local status name delivery host cosid
  status=$(zro_attr_get "$raw" zimbraAccountStatus)
  name=$(zro_attr_get "$raw" displayName)
  delivery=$(zro_attr_get "$raw" zimbraMailDeliveryAddress)
  host=$(zro_attr_get "$raw" zimbraMailHost)
  cosid=$(zro_attr_get "$raw" zimbraCOSId)

  # One COS lookup serves both the name and the quota fallback below.
  local cos_raw cos_name
  cos_raw=$(zro_cos_record "$cosid")
  cos_name=$(zro_cos_name_field "$cosid" "$cos_raw")

  local quota=""
  quota=$(zro_account_quota_limit "$raw" "$cos_raw") || quota=""

  # Read before anything is printed, so that a membership lookup which had to
  # fall back to LDAP is disclosed by the banner at the top rather than after it.
  local dls="" dl_rc=0
  dls=$(zro_account_dl_list "$acct") || dl_rc=$?

  zro_mode_banner

  zro_card_line 'Hesap' "$acct"
  zro_card_line 'Teslim adresi' "${delivery:-$ZRO_TXT_UNSET}"
  zro_card_line 'Ad' "${name:-$ZRO_TXT_UNSET}"
  zro_card_line 'Durum' "${status:-$ZRO_TXT_UNSET}"
  zro_card_line 'Mailbox host' "${host:-$ZRO_TXT_UNSET}"
  zro_card_line 'COS' "$cos_name"
  zro_card_line 'Kota limiti' "$(zro_quota_field "$quota")"
  zro_card_line 'Son giris' "$(zro_time_field "$(zro_attr_get "$raw" zimbraLastLogonTimestamp)")"
  # The caveat goes on its own line: joined to the value it runs past the box
  # edge, and whiptail wraps mid-sentence.
  zro_card_more '(yaklasik: Zimbra bu alani gunde bir kez yeniler)'

  zro_card_head 'Guvenlik'
  zro_card_line 'Parola degisimi' \
    "$(zro_time_field "$(zro_attr_get "$raw" zimbraPasswordModifiedTime)")"
  zro_card_line 'Kilitlenme' \
    "$(zro_lockout_field "$status" "$(zro_attr_get "$raw" zimbraPasswordLockoutLockedTime)")"
  zro_card_line 'Iki adimli dogrulama' \
    "$(zro_twofactor_field "$(zro_attr_get "$raw" zimbraTwoFactorAuthEnabled)" \
                           "$(zro_attr_get "$raw" zimbraFeatureTwoFactorAuthAvailable)")"
  zro_card_line 'Yonetici yetkisi' \
    "$(zro_admin_field "$(zro_attr_get "$raw" zimbraIsAdminAccount)" \
                       "$(zro_attr_get "$raw" zimbraIsDelegatedAdminAccount)")"

  # TWO ATTRIBUTES, TWO LABELLED LINES, NEVER MERGED. The administrator-set
  # forwarding is invisible to the account holder in their own client, which is
  # exactly why an operator needs to see it — and why a card that folded the two
  # into one 'forwarding' line would hide the only one of them that is a
  # compromise indicator.
  local admin_fwd
  admin_fwd=$(zro_attr_all "$raw" zimbraMailForwardingAddress)
  zro_card_head 'Yonlendirme'
  zro_card_list 'Kullanici tanimli' \
    "$(zro_attr_all "$raw" zimbraPrefMailForwardingAddress)" "$ZRO_TXT_NONE"
  zro_card_list 'Yonetici tanimli' "$admin_fwd" "$ZRO_TXT_NONE"
  if [ -n "$admin_fwd" ]; then
    zro_card_more '(kullanicinin kendi arayuzunde gorunmez)'
  fi

  zro_card_head 'Adresler'
  zro_card_list 'Aliaslar' "$(zro_attr_all "$raw" zimbraMailAlias)" "$ZRO_TXT_NONE"
  if [ "$dl_rc" -eq 0 ]; then
    zro_card_list 'Dagitim listeleri' "$dls" "$ZRO_TXT_NONE"
  else
    # Said rather than left blank: an empty membership list and a membership
    # lookup that failed are different answers, and only one of them means the
    # account belongs to nothing.
    zro_card_line 'Dagitim listeleri' "$ZRO_TXT_UNKNOWN (uyelik sorgusu basarisiz)"
  fi
}

# Printed above a result when the answer did not come from the mailbox service.
# Printed above a result when the answer did not come from the mailbox service.
#
# It deliberately does NOT claim that COS-inherited values are missing: zmprov
# expands them in both modes (getAttrs(expandCos) -> setAccountDefaults(true)),
# and only `-e` suppresses that. What LDAP mode really costs is anything held
# outside the directory — mailbox facts above all.
zro_mode_banner() {
  [ "$(zro_mode)" = ldap ] || return 0
  printf 'UYARI: mailboxd yanit vermedi; degerler dogrudan LDAP uzerinden okundu.\n'
  printf '       Dizinde tutulmayan bilgiler bu ekranda gorunmez.\n'
  printf '\n'
}

# zro_account_mailbox_info used to live here and read `zmprov gmi`. It is gone
# because that command creates a mailbox for an account that has none — see the
# note above ZRO_ALLOW in lib/exec.sh.
#
# zro_account_quota lived here too, and showed a limit above the word
# 'gosterilmiyor' because nothing safe could answer the usage. That screen is now
# in lib/store.sh, where usage is read from the mailbox itself BEHIND THE
# EXISTENCE GATE — which is what makes it answerable at all, and what makes it a
# mailbox screen rather than a directory one. The whole-server quota command it
# used to point at as the safe replacement is still nowhere in this tool: it takes
# a server, not an account, and answers for every account on it.
#
# What stayed here is what belongs to the directory: the LIMIT, which the account
# card reads as one of its own fields, and which the quota screen asks this module
# for rather than reading a second way.

# WHERE A VALUE CAME FROM, which is a different question from what it is.
#
# An operator reading a quota is deciding what to change next, and that turns on
# whether the limit is set on this account or inherited by it: one of those is
# repaired on the account and the other on a class of service every account on it
# shares. PRESENCE PROVES NOTHING about which. zmprov expands what a class of
# service provides in both SOAP and LDAP mode — getAttrs(expandCos) ->
# setAccountDefaults(true), measured on the lab server rather than read off the
# source — so the ordinary read answers with the value in force and says nothing
# whatever about its origin.
#
# `zmprov ga -e` is the only thing that answers, and it cannot answer alone. It
# returns the attributes set on the entry itself and expands nothing, so an
# attribute missing from it is either inherited or set nowhere at all — and those
# are different facts about the account. The entry is therefore read TWICE, once
# in each form, and the difference between the two is the answer:
#
#   in both          the value is set on this account
#   effective only   the account inherits it
#   in neither       nobody set it, here or anywhere this account inherits from
#
# THE SECOND FORM IS WHY THIS IS NOT A FIELD ON THE CARD. A JVM start costs the
# same whether five attributes are requested or twenty-five, which is what lets
# the card show everything it shows from one invocation — but a second FORM of the
# same read is a second invocation however few attributes it names, and a card
# that doubled its own cost to caveat one line would spend that on every operator
# who never asked the question. So it is a screen an operator asks for, and it
# says what it will spend before it spends it.

# The three answers, in the operator's words.
#
# 'tanimsiz' is reused from the card rather than invented, but NOT because the two
# screens are saying the same thing. The card has two words for absence: an
# attribute nobody set is 'tanimsiz', and an absent LIST is 'yok', because there
# absence is a fact about the value — nobody is on it. This screen has one word
# for all sixteen, because it is not answering what the value is. It is answering
# where a value was set, and 'set nowhere' is one answer whether the attribute
# holds a quota or a list of aliases.
ZRO_TXT_ON_ENTRY='hesapta tanimli'
ZRO_TXT_INHERITED='devralinmis'

# The attributes set on the account entry itself, with nothing expanded into it.
#
# THE SAME ATTRIBUTE LIST THE CARD ASKS FOR, deliberately. This screen answers
# "where did the value I am looking at come from", and a list of its own would
# answer about attributes the operator has never seen — while quietly failing to
# answer about one they had.
zro_account_entry_fetch() {
  local acct=${1-}
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"
  zro_prov_read "$ZRO_E_NO_ACCOUNT" ga -e "$acct" "${ZRO_ACCOUNT_ATTRS[@]}"
}

# One attribute's provenance, as a state this file decides and the renderer names.
#
#   $1  the effective read
#   $2  the entry-only read
#   $3  the attribute
#
# THE ORDER OF THE TWO TESTS IS THE ANSWER. An attribute carried by the entry is
# set here whatever the effective read says. One the effective read carries and
# the entry does not is inherited. One that NEITHER carries is set nowhere — and
# that case is written out rather than left to fall through to 'inherited',
# because an attribute nobody set anywhere is not a value waiting on a class of
# service, and telling an operator it was inherited would send them to read a COS
# that has nothing to say about it either.
zro_provenance_state() {
  local effective=${1-} entry=${2-} name=${3-}
  if zro_attr_present "$entry" "$name"; then
    printf 'entry'
    return 0
  fi
  if zro_attr_present "$effective" "$name"; then
    printf 'inherited'
    return 0
  fi
  printf 'unset'
}

zro_provenance_word() {
  case ${1-} in
    entry)     printf '%s' "$ZRO_TXT_ON_ENTRY" ;;
    inherited) printf '%s' "$ZRO_TXT_INHERITED" ;;
    unset)     printf '%s' "$ZRO_TXT_UNSET" ;;
    # Unreachable while this list and the one above agree, and here so that they
    # may only disagree loudly: a state added there and missed here would
    # otherwise reach the operator as an empty column.
    *)         printf '%s' "$ZRO_TXT_UNKNOWN" ;;
  esac
}

# The column the answers start in, as the longest attribute name allows.
#
# DERIVED RATHER THAN COUNTED. The names are Zimbra's, the list they come from
# grows, and a width somebody measured once is a width that is wrong the next time
# an attribute is added — on the one screen whose readability is a tidy column.
zro_provenance_label_w() {
  local a w=0
  for a in "${ZRO_ACCOUNT_ATTRS[@]}"; do
    [ "${#a}" -gt "$w" ] && w=${#a}
  done
  printf '%s' "$w"
}

# One line of the answer, in that column. It is not zro_card_line: these labels
# are Zimbra's attribute names and they are longer than any Turkish label on any
# card, so they carry a width of their own rather than shrinking the one every
# other screen shares. Written once here so the loop below states what it shows
# instead of restating how to print it.
zro_provenance_line() {
  printf '%-*s: %s\n' "${1-0}" "${2-}" "${3-}"
}

# THE PROVENANCE SCREEN: for every attribute the card shows, whether the account
# carries the value itself or inherits it.
#
# Attribute names rather than the card's Turkish labels, and that is the one place
# this program shows an operator a Zimbra name. What they do next is read or
# change that attribute somewhere this tool cannot reach, and a screen that named
# it 'Kota limiti' would have answered the question and withheld the word the
# answer is about.
zro_account_provenance() {
  local acct=$1 entry effective rc=0
  zro_reset_mode

  # THE ENTRY-ONLY READ FIRST, which is not arbitrary. It is the read with no
  # approved LDAP form, so it is the one that fails when the mailbox service is
  # down — and failing on the first invocation instead of the second is one JVM
  # start an operator does not spend to be told the same thing.
  entry=$(zro_account_entry_fetch "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  effective=$(zro_account_fetch "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  zro_mode_banner

  zro_card_line 'Hesap' "$acct"

  local w attr
  w=$(zro_provenance_label_w)
  zro_card_head 'Deger nereden geliyor (Zimbra oznitelik adlariyla)'
  for attr in "${ZRO_ACCOUNT_ATTRS[@]}"; do
    zro_provenance_line "$w" "$attr" \
      "$(zro_provenance_word "$(zro_provenance_state "$effective" "$entry" "$attr")")"
  done

  # Each word explained where it is read, because the difference between the three
  # is the entire content of this screen and none of them says it alone.
  #
  # In the CARD's column rather than the one above, deliberately. This block is a
  # legend and not more answers, and setting it in the width every other screen in
  # the tool uses is what stops it being read as four more attributes.
  zro_card_head 'Bu ne demek'
  zro_card_line "$ZRO_TXT_ON_ENTRY" 'deger bu hesabin kendi kaydinda duruyor;'
  zro_card_more 'degistirmek yalnizca bu hesabi etkiler.'
  zro_card_line "$ZRO_TXT_INHERITED" 'deger hesabin kendi kaydinda YOK; COS veya'
  zro_card_more 'alan adi varsayilanindan geliyor. O kayit'
  zro_card_more 'degisirse bu hesabin degeri de degisir.'
  zro_card_line "$ZRO_TXT_UNSET" 'iki sorgunun ikisinde de yok; hicbir'
  zro_card_more 'yerde tanimli degil.'
}

# The distribution lists an account belongs to, one per line, or nothing at all.
#
# A SECOND INVOCATION, and one no attribute list could have saved: membership is
# recorded on the list rather than on the account, so `zmprov ga` has nothing to
# say about it however many attributes it is asked for. The card pays for it
# because "what else delivers to this address" is part of the same question as
# "what is this address", and an operator sent to another screen for it would pay
# a menu round trip and this same JVM start anyway.
#
# An account that belongs to nothing answers with no lines and status 0. That is
# a result, not a failure — telling the two apart is the caller's business, and
# they mean different things on the card.
zro_account_dl_list() {
  local acct=${1-} out rc=0
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"

  out=$(zro_prov_read "$ZRO_E_NO_ACCOUNT" gam "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  printf '%s' "$out" | grep -v '^[[:space:]]*$'
  return 0
}

zro_account_membership() {
  local acct=${1-} out rc=0
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"
  zro_reset_mode

  out=$(zro_account_dl_list "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ -n "$out" ] || return "$ZRO_E_NO_RESULT"

  zro_mode_banner
  printf '%s\n' "$out"
}

# zimbraCOSId is a UUID; both the readable name and any inherited quota need a
# second lookup. One call fetches both, so a summary costs at most two JVM
# starts even when a COS is set.
zro_account_cos_fetch() {
  local cosid=${1-}
  [ -n "$cosid" ] || return "$ZRO_E_INPUT"
  # A UUID is hex and dashes. Anything else, or anything a CLI would read as a
  # flag, never leaves this function.
  case $cosid in
    -*|*[!A-Za-z0-9-]*) return "$ZRO_E_INPUT" ;;
  esac
  zro_prov_read "$ZRO_E_NO_RESULT" gc "$cosid" cn zimbraMailQuota
}

zro_account_cos_name() {
  local out
  out=$(zro_account_cos_fetch "${1-}" 2>/dev/null) || { printf '%s' "-"; return 0; }
  local name
  name=$(zro_attr_get "$out" cn)
  printf '%s' "${name:--}"
}

# The class of service record an entry points at, or nothing at all.
#
# AN ENTRY THAT NAMES NO CLASS OF SERVICE COSTS NO INVOCATION, which is the whole
# reason this is a function rather than a call: both cards ask, and a guard
# written twice is a guard one of them will one day be missing.
zro_cos_record() {
  local cosid=${1-} raw
  [ -n "$cosid" ] || return 0
  raw=$(zro_account_cos_fetch "$cosid" 2>/dev/null) || return 0
  printf '%s' "$raw"
}

# THE NAME OF A CLASS OF SERVICE, AS A CARD FIELD. Two screens ask — an account's
# and a domain's — and the three-way answer is the same on both, which is why it
# is decided once rather than beside each of them.
#
# Absence and failure are different words here, as they are everywhere else on a
# card. No id at all is 'tanimsiz': the entry names no class of service, and on a
# domain that is an ordinary state with a consequence worth reading. An id that
# WAS set and did not resolve is 'bilinmiyor': a lookup this program could not
# complete, never a class of service the entry does not have.
#
# It takes the record rather than fetching one, so the caller that needs the rest
# of it — the account card reads the quota out of the same lookup — pays for one
# invocation instead of two.
zro_cos_name_field() {
  local cosid=${1-} raw=${2-} name
  [ -n "$cosid" ] || { printf '%s' "$ZRO_TXT_UNSET"; return 0; }
  name=$(zro_attr_get "$raw" cn)
  printf '%s' "${name:-$ZRO_TXT_UNKNOWN}"
}
