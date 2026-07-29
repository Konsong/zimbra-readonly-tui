#!/usr/bin/env bash
# The floor is Bash 4.2: CentOS 7 and Zimbra 8.8 are still in the field, and
# this suite is meant to run on the server itself. Development happens on 5.x,
# where a 4.3-only construct would pass silently.
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"

SOURCES=()
for f in "$ZRO_SRC/zimbra-ro-tui.sh" "$ZRO_SRC"/lib/*.sh \
         "$ZRO_SRC"/tests/*.sh "$ZRO_SRC"/tests/lib/*.sh \
         "$ZRO_SRC"/tests/mocks/*.sh "$ZRO_SRC"/tests/mocks/bin/*; do
  case $f in
    # This file has to spell out every construct it bans, so scanning it would
    # always report itself.
    */test_bash_compat.sh) continue ;;
  esac
  SOURCES+=("$f")
done

code=""
for f in "${SOURCES[@]}"; do
  code="$code
$(sed 's/[[:space:]]*#.*$//' "$f")"
done

it "uses no bash 4.3 nameref"
assert_not_contains "$code" "local -n"
assert_not_contains "$code" "declare -n"
assert_not_contains "$code" "typeset -n"

it "uses no bash 4.4 parameter transformation"
assert_not_contains "$code" '@Q'
assert_not_contains "$code" '@A'
assert_not_contains "$code" '@E'
assert_not_contains "$code" '@P'

it "uses no bash 4.3 wait -n"
assert_not_contains "$code" "wait -n"

it "uses no bash 5 epoch variables"
assert_not_contains "$code" "EPOCHSECONDS"
assert_not_contains "$code" "EPOCHREALTIME"

it "every executable script disables errexit and enables nounset"
for f in "$ZRO_SRC/zimbra-ro-tui.sh" "$ZRO_SRC/tests/run.sh" \
         "$ZRO_SRC"/tests/test_*.sh "$ZRO_SRC"/tests/mocks/bin/*; do
  # Comments stripped: the entry point explains in prose why errexit is absent,
  # and that explanation is not a setting.
  header=$(head -n 12 "$f" | sed 's/[[:space:]]*#.*$//')
  assert_contains "$header" "set -uo pipefail"
  assert_not_contains "$header" "set -e"
  assert_not_contains "$header" "errexit"
done

it "every library declares its shell and guards against reloading"
for f in "$ZRO_SRC"/lib/*.sh; do
  header=$(head -n 15 "$f")
  assert_contains "$header" "shellcheck shell=bash"
  assert_contains "$header" "_LOADED"
done

it "the entry point refuses to run on an interpreter below the floor"
assert_contains "$(cat "$ZRO_SRC/zimbra-ro-tui.sh")" "BASH_VERSINFO"

zro_t_report
