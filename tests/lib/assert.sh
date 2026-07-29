# shellcheck shell=bash
# Assertion library. Sourced by every tests/test_*.sh file.
[ -n "${ZRO_LIB_ASSERT_LOADED:-}" ] && return 0
ZRO_LIB_ASSERT_LOADED=1

ZRO_T_OK=0
ZRO_T_FAIL=0
ZRO_T_CURRENT="(unnamed)"

it() { ZRO_T_CURRENT=$1; }

zro_t_pass() { ZRO_T_OK=$((ZRO_T_OK + 1)); }

zro_t_fail() {
  ZRO_T_FAIL=$((ZRO_T_FAIL + 1))
  printf '  FAIL: %s\n        %s\n' "$ZRO_T_CURRENT" "$1" >&2
}

assert_ok() {
  if "$@" >/dev/null 2>&1; then
    zro_t_pass
  else
    zro_t_fail "expected success, got status $? from: $*"
  fi
}

assert_fail() {
  if "$@" >/dev/null 2>&1; then
    zro_t_fail "expected failure, got success from: $*"
  else
    zro_t_pass
  fi
}

assert_status() {
  local want=$1 got=0
  shift
  "$@" >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then
    zro_t_pass
  else
    zro_t_fail "expected status $want, got $got from: $*"
  fi
}

assert_eq() {
  if [ "$1" = "$2" ]; then
    zro_t_pass
  else
    zro_t_fail "expected [$2], got [$1]"
  fi
}

assert_contains() {
  case $1 in
    *"$2"*) zro_t_pass ;;
    *)      zro_t_fail "expected to contain [$2], got [$1]" ;;
  esac
}

assert_not_contains() {
  case $1 in
    *"$2"*) zro_t_fail "expected NOT to contain [$2], got [$1]" ;;
    *)      zro_t_pass ;;
  esac
}

assert_out_eq() {
  local want=$1 got
  shift
  got=$("$@" 2>/dev/null)
  assert_eq "$got" "$want"
}

zro_t_report() {
  printf '__ZRO_RESULT__ %d %d\n' "$ZRO_T_OK" "$ZRO_T_FAIL"
  [ "$ZRO_T_FAIL" -eq 0 ]
}
