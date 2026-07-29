# shellcheck shell=bash
# M1 operations: account, quota, COS, mailbox host, membership.
[ -n "${ZRO_LIB_ACCOUNT_LOADED:-}" ] && return 0
ZRO_LIB_ACCOUNT_LOADED=1

# Only what the M1 screens display. Asking for everything costs the same JVM
# start but returns several hundred lines per account.
ZRO_ACCOUNT_ATTRS=(
  displayName
  mail
  zimbraAccountStatus
  zimbraCOSId
  zimbraLastLogonTimestamp
  zimbraMailAlias
  zimbraMailHost
  zimbraMailQuota
)

# zmprov prints "name: value" lines. Matching the key at position 1 with its
# separator attached is what keeps zimbraMail from also matching
# zimbraMailHost.
zro_attr_get() {
  local text=$1 name=$2
  printf '%s\n' "$text" | awk -v key="$name" '
    index($0, key ": ") == 1 { print substr($0, length(key) + 3); exit }
  '
}

zro_attr_all() {
  local text=$1 name=$2
  printf '%s\n' "$text" | awk -v key="$name" '
    index($0, key ": ") == 1 { print substr($0, length(key) + 3) }
  '
}

# Zimbra stores timestamps as LDAP generalized time: 20260715103012Z
zro_zimbra_time() {
  local t=${1-}
  [[ $t =~ ^[0-9]{14}Z?$ ]] || return "$ZRO_E_INPUT"
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
zro_prov_fail_code() {
  local errfile=$1 missing_code=$2 rc=$3
  if grep -qE 'NO_SUCH_ACCOUNT|NO_SUCH_MAILBOX|NO_SUCH_COS' "$errfile" 2>/dev/null; then
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
ZRO_LDAP_READS=' ga getAccount gam getAccountMembership gc getCos '

# The complete set of subcommands zro_prov_read may hand to the gate. It exists
# because that one call site passes a variable, which a static reader cannot
# resolve — so the set of values that variable may hold is written down here,
# enforced at runtime, and checked against the allowlist by the scanner.
ZRO_PROV_READS=' ga gam gc gmi '

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
  first_msg=$(head -c 500 -- "$err" 2>/dev/null)
  mapped=$(zro_prov_fail_code "$err" "$missing_code" "$rc")

  if [ "$mapped" = "$ZRO_E_UNAVAILABLE" ] && zro_prov_ldap_capable "$sub"; then
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
    mapped=$(zro_prov_fail_code "$err" "$missing_code" "$rc")
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

# The quota limit an account is subject to. An account can inherit it from its
# COS, and LDAP mode does not expand that — without the fallback an inheriting
# account would read as unlimited, which is worse than reading as unknown.
# $2 is an already-fetched COS record, so a caller that needed one anyway does
# not pay for a second lookup.
zro_account_quota_limit() {
  local raw=$1 cos_raw=${2-} limit cosid
  limit=$(zro_attr_get "$raw" zimbraMailQuota)
  if [ -n "$limit" ]; then
    printf '%s' "$limit"
    return 0
  fi

  if [ -z "$cos_raw" ]; then
    cosid=$(zro_attr_get "$raw" zimbraCOSId)
    if [ -n "$cosid" ]; then
      cos_raw=$(zro_account_cos_fetch "$cosid" 2>/dev/null) || cos_raw=""
    fi
  fi
  limit=$(zro_attr_get "$cos_raw" zimbraMailQuota)
  printf '%s' "${limit:-0}"
}

zro_account_summary() {
  local acct=$1 raw rc=0
  zro_reset_mode
  raw=$(zro_account_fetch "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  local status name host quota cosid logon logon_h quota_h
  status=$(zro_attr_get "$raw" zimbraAccountStatus)
  name=$(zro_attr_get "$raw" displayName)
  host=$(zro_attr_get "$raw" zimbraMailHost)
  quota=$(zro_attr_get "$raw" zimbraMailQuota)
  cosid=$(zro_attr_get "$raw" zimbraCOSId)
  logon=$(zro_attr_get "$raw" zimbraLastLogonTimestamp)

  # One COS lookup serves both the name and the quota fallback below.
  local cos_raw="" cos_name="-"
  if [ -n "$cosid" ]; then
    cos_raw=$(zro_account_cos_fetch "$cosid" 2>/dev/null) || cos_raw=""
    cos_name=$(zro_attr_get "$cos_raw" cn)
    [ -n "$cos_name" ] || cos_name="-"
  fi

  quota=$(zro_account_quota_limit "$raw" "$cos_raw")

  logon_h=$(zro_zimbra_time "$logon" 2>/dev/null) || logon_h="-"
  if [ "$quota" = "0" ]; then
    quota_h="sinirsiz"
  else
    quota_h=$(zro_human_bytes "$quota" 2>/dev/null) || quota_h="-"
  fi
  [ -n "$name" ]   || name="-"
  [ -n "$host" ]   || host="-"
  [ -n "$status" ] || status="-"

  zro_mode_banner

  printf 'Hesap        : %s\n' "$acct"
  printf 'Ad           : %s\n' "$name"
  printf 'Durum        : %s\n' "$status"
  printf 'Mailbox host : %s\n' "$host"
  printf 'Kota limiti  : %s\n' "$quota_h"
  printf 'COS          : %s\n' "$cos_name"
  printf 'Son giris    : %s  (yaklasik; Zimbra bu alani gunde bir kez yeniler)\n' "$logon_h"

  local aliases
  aliases=$(zro_attr_all "$raw" zimbraMailAlias)
  if [ -n "$aliases" ]; then
    printf 'Aliaslar     :\n'
    printf '%s\n' "$aliases" | sed 's/^/               /'
  fi
}

# Printed above a result when the answer did not come from the mailbox service.
zro_mode_banner() {
  [ "$(zro_mode)" = ldap ] || return 0
  printf 'UYARI: mailboxd yanit vermedi; degerler LDAP uzerinden okundu.\n'
  printf '       COS uzerinden miras alinan ayarlar eksik gorunebilir.\n'
  printf '\n'
}

zro_account_mailbox_info() {
  local acct=${1-}
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"
  zro_prov_read "$ZRO_E_NO_MAILBOX" gmi "$acct"
}

# zmprov gqu is deliberately absent: it takes a SERVER and returns every
# account on it. Per-account usage comes from gmi, which prints
# "mailboxId: 214, used: 1073741824".
zro_account_quota() {
  local acct=$1 raw info rc=0
  zro_reset_mode
  raw=$(zro_account_fetch "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  # Usage lives in the mailbox database, so a stopped mailbox service costs the
  # usage figure — not the whole screen. The limit comes from LDAP and is still
  # worth showing. Any other failure is a real failure.
  local info_rc=0
  info=$(zro_account_mailbox_info "$acct") || info_rc=$?
  if [ "$info_rc" -ne 0 ] && [ "$info_rc" != "$ZRO_E_UNAVAILABLE" ]; then
    return "$info_rc"
  fi

  local limit used mbox limit_h used_h
  limit=$(zro_account_quota_limit "$raw")
  mbox=$(printf '%s' "$info" | sed -n 's/.*mailboxId: *\([0-9]*\).*/\1/p')
  used=$(printf '%s' "$info" | sed -n 's/.*used: *\([0-9]*\).*/\1/p')
  [ -n "$used" ] || used=0

  if [ "$info_rc" -ne 0 ]; then
    used_h="okunamadi (mailboxd yanit vermiyor)"
  else
    used_h=$(zro_human_bytes "$used" 2>/dev/null) || used_h="-"
  fi

  zro_mode_banner

  printf 'Hesap        : %s\n' "$acct"
  printf 'Mailbox ID   : %s\n' "${mbox:--}"
  printf 'Kullanilan   : %s\n' "$used_h"
  if [ "$limit" = "0" ]; then
    printf 'Kota limiti  : sinirsiz\n'
  else
    limit_h=$(zro_human_bytes "$limit" 2>/dev/null) || limit_h="-"
    printf 'Kota limiti  : %s\n' "$limit_h"
    if [ "$info_rc" -eq 0 ]; then
      printf 'Doluluk      : %s%%\n' "$(( used * 100 / limit ))"
    fi
  fi
}

zro_account_membership() {
  local acct=${1-} out rc=0
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"
  zro_reset_mode

  out=$(zro_prov_read "$ZRO_E_NO_ACCOUNT" gam "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  out=$(printf '%s' "$out" | grep -v '^[[:space:]]*$')
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
