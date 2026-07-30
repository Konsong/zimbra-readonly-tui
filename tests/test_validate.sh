#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/validate.sh
. "$ZRO_SRC/lib/validate.sh"

it "accepts ordinary addresses"
assert_ok zro_validate_email 'ahmet.yilmaz@example.com'
assert_ok zro_validate_email 'a@b.co'
assert_ok zro_validate_email 'user+tag_1%x@mail.example.co.uk'

it "rejects shell metacharacters"
assert_status "$ZRO_E_INPUT" zro_validate_email 'a@b.com; rm -rf /'
assert_status "$ZRO_E_INPUT" zro_validate_email 'a@b.com && id'
assert_status "$ZRO_E_INPUT" zro_validate_email 'a@b.com | tee /tmp/x'
# The single quotes are the point: these payloads must reach the validator
# unexpanded, exactly as an operator would type them into the prompt.
# shellcheck disable=SC2016
assert_status "$ZRO_E_INPUT" zro_validate_email '$(id)@b.com'
# shellcheck disable=SC2016
assert_status "$ZRO_E_INPUT" zro_validate_email '`id`@b.com'
assert_status "$ZRO_E_INPUT" zro_validate_email 'a@b.com > /etc/passwd'

it "rejects quotes and backslashes"
assert_status "$ZRO_E_INPUT" zro_validate_email 'a"b@c.com'
assert_status "$ZRO_E_INPUT" zro_validate_email 'a\b@c.com'
assert_status "$ZRO_E_INPUT" zro_validate_email "a'b@c.com"

it "rejects whitespace and embedded newlines"
assert_status "$ZRO_E_INPUT" zro_validate_email 'a b@c.com'
assert_status "$ZRO_E_INPUT" zro_validate_email $'a@b.com\nrm -rf /'
assert_status "$ZRO_E_INPUT" zro_validate_email $'a@b.com\t-l'
assert_status "$ZRO_E_INPUT" zro_validate_email ' a@b.com'
assert_status "$ZRO_E_INPUT" zro_validate_email 'a@b.com '

it "rejects malformed addresses"
assert_status "$ZRO_E_INPUT" zro_validate_email ''
assert_status "$ZRO_E_INPUT" zro_validate_email 'nobody'
assert_status "$ZRO_E_INPUT" zro_validate_email '@example.com'
assert_status "$ZRO_E_INPUT" zro_validate_email 'a@'
assert_status "$ZRO_E_INPUT" zro_validate_email 'a@b'
assert_status "$ZRO_E_INPUT" zro_validate_email 'a@@b.com'
assert_status "$ZRO_E_INPUT" zro_validate_email 'a@b..com'
assert_status "$ZRO_E_INPUT" zro_validate_email 'a@-b.com'
assert_status "$ZRO_E_INPUT" zro_validate_email 'a@b-.com'
assert_status "$ZRO_E_INPUT" zro_validate_email 'a@b.c'

it "rejects an argument that starts with a dash"
assert_status "$ZRO_E_INPUT" zro_validate_email '-l@b.com'

it "enforces length limits"
long_local=$(printf 'a%.0s' {1..65})
assert_status "$ZRO_E_INPUT" zro_validate_email "${long_local}@b.com"
long_label=$(printf 'a%.0s' {1..64})
assert_status "$ZRO_E_INPUT" zro_validate_email "a@${long_label}.com"

it "accepts a label of exactly the maximum length"
max_label=$(printf 'a%.0s' {1..63})
assert_ok zro_validate_email "a@${max_label}.com"

# Every filter the delivery tracer accepts is a Perl regular expression, so a
# validated address still has to be escaped before it is used as one. One row per
# metacharacter: the text an operator typed, then the pattern it must become.
it "quotes every regular-expression metacharacter"
while IFS='|' read -r input want; do
  [ -n "$input" ] || continue
  assert_out_eq "$want" zro_regex_quote "$input"
done <<'EOF'
a.b|a\.b
a+b|a\+b
a*b|a\*b
a?b|a\?b
a^b|a\^b
a$b|a\$b
a(b|a\(b
a)b|a\)b
a[b|a\[b
a]b|a\]b
a{b|a\{b
a}b|a\}b
a/b|a\/b
a\b|a\\b
EOF
# The alternation metacharacter cannot travel through a pipe-separated table.
assert_out_eq 'a\|b' zro_regex_quote 'a|b'

it "leaves text that is not a metacharacter alone"
assert_out_eq 'ahmet' zro_regex_quote 'ahmet'
assert_out_eq '' zro_regex_quote ''
assert_out_eq '' zro_regex_quote
assert_out_eq 'ahmet_yilmaz-1%x@example' zro_regex_quote 'ahmet_yilmaz-1%x@example'

# The address from ADR-0002: it passes validation, and used unescaped as a
# pattern it fails to match itself — a false negative on the one question the
# delivery trace exists to answer. Bash's own engine is the independent judge
# here, not our escaping code.
it "an address with a quantifier in it matches itself once quoted"
quoted=$(zro_regex_quote 'ali+fatura@example.com')
raw='ali+fatura@example.com'
assert_ok zro_validate_email 'ali+fatura@example.com'
if [[ 'ali+fatura@example.com' =~ ^${quoted}$ ]]; then
  zro_t_pass
else
  zro_t_fail "quoted address does not match itself: $quoted"
fi
if [[ 'ali+fatura@example.com' =~ ^${raw}$ ]]; then
  zro_t_fail "unquoted address matched itself; the table above proves nothing"
else
  zro_t_pass
fi
# Quoted, it is a literal and matches nothing wider than itself.
if [[ 'aliiifatura@example.com' =~ ^${quoted}$ ]]; then
  zro_t_fail "quoted address widened into a pattern: $quoted"
else
  zro_t_pass
fi

it "validates bare domains"
assert_ok zro_validate_domain 'example.com'
assert_ok zro_validate_domain 'mail.example.co.uk'
assert_status "$ZRO_E_INPUT" zro_validate_domain '@example.com'
assert_status "$ZRO_E_INPUT" zro_validate_domain 'example'
assert_status "$ZRO_E_INPUT" zro_validate_domain 'exa mple.com'
assert_status "$ZRO_E_INPUT" zro_validate_domain 'example.com; id'

zro_t_report
