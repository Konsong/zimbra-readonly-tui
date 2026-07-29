#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"

it "assert_eq passes on equal values"
assert_eq "abc" "abc"

it "assert_eq increments the failure counter on different values"
observed=$( ZRO_T_FAIL=0; assert_eq "abc" "xyz" 2>/dev/null; printf '%s' "$ZRO_T_FAIL" )
assert_eq "$observed" "1"

it "assert_status matches an exact exit status"
assert_status 3 bash -c 'exit 3'

it "assert_contains finds a substring"
assert_contains "hello world" "lo wo"

it "assert_out_eq compares stdout"
assert_out_eq "hi" printf 'hi'

zro_t_report
