#!/usr/bin/env bash
set -uo pipefail
# The multi-line attribute reader, and the one thing it exists to prevent: a
# filter rule set silently truncated to its first line.
#
# EVERY FIXTURE HERE WAS CAPTURED. A multi-line filter rule set was written onto
# a lab account through the web client's own attribute, then read back with
# `zmprov ga` through the filter screen's attribute list, so what these cases
# parse is byte-for-byte what the tool will parse in production — with only the
# names and addresses replaced.
#
# WHAT MAKES THE FORMAT AMBIGUOUS, and why a sibling reader was needed at all:
# zmprov prints `name: value` and then prints the value's remaining lines RAW,
# with nothing marking them as continuations. Those lines can be blank, they can
# begin with '#', and — measured, in a captured signature — they can look exactly
# like an attribute line:
#
#     zimbraPrefMailSignature: --
#     Ahmet Yilmaz
#     Bilgi Islem
#
#     Tel: 0212 000 00 00
#     zimbraSignatureId: cda8ffdd-...
#
# `Tel: 0212 000 00 00` is the whole reason the terminator set is passed in
# rather than guessed at from the shape of a line.
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/account.sh
. "$ZRO_SRC/lib/account.sh"

FIX="$ZRO_TEST_ROOT/fixtures"

# The attribute list the filter screen reads with, in the order zmprov answers.
SIEVE_ATTRS=(zimbraMailOutgoingSieveScript zimbraMailSieveScript)

# The account read that carries both rule sets and nothing else.
sieve_raw() { cat "$FIX/zmprov_ga_mailset_sieve.txt"; }

# The incoming rule set as it stands in the fixture: two rules, a blank line
# between them, a comment line opening each, and a rule whose comment is followed
# by a blank line before its own body.
WANT_IN=$(cat <<'EOF'
require ["fileinto", "copy", "reject", "tag", "flag", "log"];

# Faturalar
if anyof (header :contains ["subject"] ["fatura"])
{
    fileinto "Faturalar";
    stop;
}

# Duyurular

if anyof (header :contains ["from"] ["duyuru@example.com"])
{
    fileinto "Duyurular";
    tag "otomatik";
    stop;
}
EOF
)

WANT_OUT=$(cat <<'EOF'
require ["fileinto", "copy"];

# Giden kopya
if anyof (header :contains ["to"] ["arsiv@example.com"])
{
    fileinto "Gonderilmis";
    stop;
}
EOF
)

# ------------------------------------------------ the whole value, in full --

it "reads a multi-line value in full rather than to the end of its first line"
assert_eq "$(zro_attr_block "$(sieve_raw)" zimbraMailSieveScript "${SIEVE_ATTRS[@]}")" \
  "$WANT_IN"

# Stated as its own case, because it is the acceptance criterion rather than a
# consequence: the existing reader answers the first line and nothing else, and a
# rule set of nine lines rendered as one is the bug this reader replaces.
it "and the existing single-line reader really does truncate the same value"
assert_eq "$(zro_attr_get "$(sieve_raw)" zimbraMailSieveScript)" \
  'require ["fileinto", "copy", "reject", "tag", "flag", "log"];'

it "preserves the blank lines inside a rule set"
out=$(zro_attr_block "$(sieve_raw)" zimbraMailSieveScript "${SIEVE_ATTRS[@]}")
assert_eq "$(printf '%s\n' "$out" | grep -c '^$')" "3"

it "preserves the comment lines, which are what name each rule"
out=$(zro_attr_block "$(sieve_raw)" zimbraMailSieveScript "${SIEVE_ATTRS[@]}")
assert_contains "$out" "# Faturalar"
assert_contains "$out" "# Duyurular"

# The attribute that comes FIRST in the record, so its value ends where the next
# attribute begins rather than where the output does.
it "stops a value at the line that begins the next declared attribute"
assert_eq "$(zro_attr_block "$(sieve_raw)" zimbraMailOutgoingSieveScript "${SIEVE_ATTRS[@]}")" \
  "$WANT_OUT"

it "and never lets one attribute's value carry the next attribute's line"
out=$(zro_attr_block "$(sieve_raw)" zimbraMailOutgoingSieveScript "${SIEVE_ATTRS[@]}")
assert_not_contains "$out" "zimbraMailSieveScript"

# ------------------------------------- a continuation that looks like a key --

# THE CASE THAT DECIDES THE DESIGN. This fixture is the signature read the mail
# settings card really makes, and the fourth line of the first signature's value is
# `Tel: 0212 000 00 00` — a continuation line indistinguishable, by shape, from an
# attribute line. A reader that ended a value at the first `word: value` line would
# cut a signature off at the telephone number, on the screen that exists to say
# what a user's outgoing mail looks like.
SIG_ATTRS=(zimbraPrefMailSignature zimbraPrefMailSignatureHTML zimbraSignatureName)

sig_raw() { cat "$FIX/zmprov_gsig_bodies.txt"; }

WANT_SIG=$(cat <<'EOF'
--
Ahmet Yilmaz
Bilgi Islem

Tel: 0212 000 00 00
EOF
)

it "keeps a continuation line that is shaped like an attribute line"
assert_eq "$(zro_attr_block "$(sig_raw)" zimbraPrefMailSignature "${SIG_ATTRS[@]}")" \
  "$WANT_SIG"

it "and still stops at the declared attribute that really does follow it"
out=$(zro_attr_block "$(sig_raw)" zimbraPrefMailSignature "${SIG_ATTRS[@]}")
assert_not_contains "$out" "zimbraSignatureName"
assert_not_contains "$out" "Kisa"

# ----------------------------------------------------- absence and repeats --

it "answers nothing, and answers it as success, for an attribute nobody set"
assert_eq "$(zro_attr_block "$(cat "$FIX/zmprov_ga_mailset_bare.txt")" \
  zimbraMailSieveScript "${SIEVE_ATTRS[@]}")" ""
assert_ok zro_attr_block "$(cat "$FIX/zmprov_ga_mailset_bare.txt")" \
  zimbraMailSieveScript "${SIEVE_ATTRS[@]}"

# Said out loud rather than left to a caller to discover: this reader answers for
# the single-valued attributes. A list of aliases is read with zro_attr_all, whose
# values are one line each by construction.
it "answers with the first value of an attribute the entry carries twice"
assert_eq "$(zro_attr_block "$(cat "$FIX/zmprov_ga_mailset_full.txt")" \
  zimbraMailAlias zimbraMailAlias zimbraMailSieveScript)" \
  "a.yilmaz@example.com"

# ------------------------------------------------- the record separator --

# zmprov ends a record with a blank line, so an attribute that stands LAST in the
# output has the separator sitting where its own value would continue. Written
# out here rather than taken from a fixture because the read path strips trailing
# newlines before any parser sees them — this is the reader answering for itself,
# not for what a screen will hand it.
it "drops the blank line zmprov ends a record with"
assert_eq "$(zro_attr_block "$(printf '# name x@example.com\nzimbraMailSieveScript: bir\n\niki\n\n')" \
  zimbraMailSieveScript "${SIEVE_ATTRS[@]}")" \
  "$(printf 'bir\n\niki')"

zro_t_report
