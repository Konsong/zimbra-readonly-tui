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

zro_account_fetch() {
  local acct=${1-}
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"

  local err out rc=0
  err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"
  out=$(zro_exec zmprov ga "$acct" "${ZRO_ACCOUNT_ATTRS[@]}" 2>"$err") || rc=$?

  if [ "$rc" -ne 0 ]; then
    if grep -q 'NO_SUCH_ACCOUNT' "$err" 2>/dev/null; then
      rm -f -- "$err"
      return "$ZRO_E_NO_ACCOUNT"
    fi
    rm -f -- "$err"
    return "$rc"
  fi
  rm -f -- "$err"
  printf '%s' "$out"
}

zro_account_summary() {
  local acct=$1 raw rc=0
  raw=$(zro_account_fetch "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  local status name host quota cosid logon logon_h quota_h
  status=$(zro_attr_get "$raw" zimbraAccountStatus)
  name=$(zro_attr_get "$raw" displayName)
  host=$(zro_attr_get "$raw" zimbraMailHost)
  quota=$(zro_attr_get "$raw" zimbraMailQuota)
  cosid=$(zro_attr_get "$raw" zimbraCOSId)
  logon=$(zro_attr_get "$raw" zimbraLastLogonTimestamp)

  logon_h=$(zro_zimbra_time "$logon" 2>/dev/null) || logon_h="-"
  if [ "$quota" = "0" ]; then
    quota_h="sinirsiz"
  else
    quota_h=$(zro_human_bytes "$quota" 2>/dev/null) || quota_h="-"
  fi
  [ -n "$name" ]   || name="-"
  [ -n "$host" ]   || host="-"
  [ -n "$status" ] || status="-"
  # cosid stays as it is: zro_account_cos_name renders an empty or malformed
  # id as "-" itself, and substituting "-" here would send a lone dash to a CLI.

  printf 'Hesap        : %s\n' "$acct"
  printf 'Ad           : %s\n' "$name"
  printf 'Durum        : %s\n' "$status"
  printf 'Mailbox host : %s\n' "$host"
  printf 'Kota limiti  : %s\n' "$quota_h"
  printf 'COS          : %s\n' "$(zro_account_cos_name "$cosid")"
  printf 'Son giris    : %s  (yaklasik; Zimbra bu alani gunde bir kez yeniler)\n' "$logon_h"

  local aliases
  aliases=$(zro_attr_all "$raw" zimbraMailAlias)
  if [ -n "$aliases" ]; then
    printf 'Aliaslar     :\n'
    printf '%s\n' "$aliases" | sed 's/^/               /'
  fi
}

zro_account_mailbox_info() {
  local acct=${1-}
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"

  local err out rc=0
  err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"
  out=$(zro_exec zmprov gmi "$acct" 2>"$err") || rc=$?

  if [ "$rc" -ne 0 ]; then
    if grep -qE 'NO_SUCH_ACCOUNT|NO_SUCH_MAILBOX' "$err" 2>/dev/null; then
      rm -f -- "$err"
      return "$ZRO_E_NO_MAILBOX"
    fi
    rm -f -- "$err"
    return "$rc"
  fi
  rm -f -- "$err"
  printf '%s' "$out"
}

# zmprov gqu is deliberately absent: it takes a SERVER and returns every
# account on it. Per-account usage comes from gmi, which prints
# "mailboxId: 214, used: 1073741824".
zro_account_quota() {
  local acct=$1 raw info rc=0
  raw=$(zro_account_fetch "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  info=$(zro_account_mailbox_info "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  local limit used mbox limit_h used_h
  limit=$(zro_attr_get "$raw" zimbraMailQuota)
  mbox=$(printf '%s' "$info" | sed -n 's/.*mailboxId: *\([0-9]*\).*/\1/p')
  used=$(printf '%s' "$info" | sed -n 's/.*used: *\([0-9]*\).*/\1/p')
  [ -n "$used" ] || used=0
  [ -n "$limit" ] || limit=0

  used_h=$(zro_human_bytes "$used" 2>/dev/null) || used_h="-"

  printf 'Hesap        : %s\n' "$acct"
  printf 'Mailbox ID   : %s\n' "${mbox:--}"
  printf 'Kullanilan   : %s\n' "$used_h"
  if [ "$limit" = "0" ]; then
    printf 'Kota limiti  : sinirsiz\n'
  else
    limit_h=$(zro_human_bytes "$limit" 2>/dev/null) || limit_h="-"
    printf 'Kota limiti  : %s\n' "$limit_h"
    printf 'Doluluk      : %s%%\n' "$(( used * 100 / limit ))"
  fi
}

zro_account_membership() {
  local acct=${1-}
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"

  local out rc=0
  out=$(zro_exec zmprov gam "$acct" 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  out=$(printf '%s' "$out" | grep -v '^[[:space:]]*$')
  [ -n "$out" ] || return "$ZRO_E_NO_RESULT"
  printf '%s\n' "$out"
}

# zimbraCOSId is a UUID; the readable name needs a second lookup. This is the
# only place M1 spends a second JVM start, and only when a COS is actually set.
zro_account_cos_name() {
  local cosid=${1-}
  if [ -z "$cosid" ]; then
    printf '%s' "-"
    return 0
  fi
  # A UUID is hex and dashes. Anything else, or anything a CLI would read as a
  # flag, is reported as unknown rather than sent onward.
  case $cosid in
    -*|*[!A-Za-z0-9-]*) printf '%s' "-"; return 0 ;;
  esac

  local out rc=0
  out=$(zro_exec zmprov gc "$cosid" cn 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s' "-"
    return 0
  fi
  local name
  name=$(zro_attr_get "$out" cn)
  printf '%s' "${name:--}"
}
