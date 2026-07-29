#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"

it "exposes the documented exit codes"
assert_eq "$ZRO_E_INPUT" "10"
assert_eq "$ZRO_E_TIMEOUT" "22"
assert_eq "$ZRO_E_CANCEL" "40"
assert_eq "$ZRO_E_DENIED" "90"
assert_eq "$ZRO_E_BADUSER" "91"
assert_eq "$ZRO_E_NOCAP" "92"

it "zro_log writes to stderr, never stdout"
assert_out_eq "" zro_log info "should not appear on stdout"

it "zro_log labels the level"
captured=$(zro_log warn "disk almost full" 2>&1 >/dev/null)
assert_contains "$captured" "warn"
assert_contains "$captured" "disk almost full"

it "zro_first_existing returns the first executable path"
assert_out_eq "/bin/sh" zro_first_existing /nonexistent/zzz /bin/sh

it "zro_first_existing fails when nothing exists"
assert_fail zro_first_existing /nonexistent/aaa /nonexistent/bbb

it "zro_tmpfile creates a file readable only by the owner"
tmp=$(zro_tmpfile)
assert_eq "$(stat -c '%a' "$tmp")" "600"
rm -f -- "$tmp"

it "zro_tmpfile returns a fresh path each call"
a=$(zro_tmpfile); b=$(zro_tmpfile)
assert_not_contains "$a" "$b"
rm -f -- "$a" "$b"

it "zro_human_bytes formats magnitudes"
assert_out_eq "0 B" zro_human_bytes 0
assert_out_eq "1.0 KB" zro_human_bytes 1024
assert_out_eq "1.5 MB" zro_human_bytes 1572864
assert_out_eq "2.0 GB" zro_human_bytes 2147483648

it "zro_human_bytes rejects a non-numeric argument"
assert_status "$ZRO_E_INPUT" zro_human_bytes "12; rm -rf /"

zro_t_report
