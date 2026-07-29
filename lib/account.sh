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
  [ -n "$cosid" ]  || cosid="-"

  printf 'Hesap        : %s\n' "$acct"
  printf 'Ad           : %s\n' "$name"
  printf 'Durum        : %s\n' "$status"
  printf 'Mailbox host : %s\n' "$host"
  printf 'Kota limiti  : %s\n' "$quota_h"
  printf 'COS ID       : %s\n' "$cosid"
  printf 'Son giris    : %s  (yaklasik; Zimbra bu alani gunde bir kez yeniler)\n' "$logon_h"

  local aliases
  aliases=$(zro_attr_all "$raw" zimbraMailAlias)
  if [ -n "$aliases" ]; then
    printf 'Aliaslar     :\n'
    printf '%s\n' "$aliases" | sed 's/^/               /'
  fi
}
