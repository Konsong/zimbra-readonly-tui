#!/usr/bin/env bash
# Dependency-free test runner. Runs every tests/test_*.sh in its own process.
set -uo pipefail

ZRO_TEST_ROOT=$(cd -- "$(dirname -- "$0")" && pwd)
ZRO_SRC=$(cd -- "$ZRO_TEST_ROOT/.." && pwd)
export ZRO_TEST_ROOT ZRO_SRC

# Windows checkouts do not carry the executable bit; restore it for the mocks.
if [ -d "$ZRO_TEST_ROOT/mocks/bin" ]; then
  chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* 2>/dev/null || true
fi

total_ok=0
total_fail=0
files=0

for f in "$ZRO_TEST_ROOT"/test_*.sh; do
  [ -e "$f" ] || continue
  files=$((files + 1))
  name=$(basename -- "$f")
  output=$(bash "$f" 2>&1)
  result=$(printf '%s\n' "$output" | grep '^__ZRO_RESULT__' | tail -n 1)
  if [ -z "$result" ]; then
    printf '%-28s CRASHED\n' "$name"
    printf '%s\n' "$output" | sed 's/^/    /'
    total_fail=$((total_fail + 1))
    continue
  fi
  ok=$(printf '%s' "$result" | awk '{print $2}')
  fail=$(printf '%s' "$result" | awk '{print $3}')
  total_ok=$((total_ok + ok))
  total_fail=$((total_fail + fail))
  if [ "$fail" -eq 0 ]; then
    printf '%-28s %3d ok\n' "$name" "$ok"
  else
    printf '%-28s %3d ok  %3d FAIL\n' "$name" "$ok" "$fail"
    printf '%s\n' "$output" | grep -v '^__ZRO_RESULT__'
  fi
done

printf -- '----\n%d files, %d ok, %d failed\n' "$files" "$total_ok" "$total_fail"
[ "$total_fail" -eq 0 ]
