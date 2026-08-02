#!/usr/bin/env bash
# The operator guide, held against the one list. Nothing here executes the
# program: it reads the declarations in ZRO_MENU_OPS and the operation entries
# in section 3 of docs/operations.md, and fails when the two have parted
# company.
set -uo pipefail

# WHY A TEST AND NOT A HABIT. Section 3 is the operator's account of what the
# tool shows, and it stood three screens behind the tool across three releases —
# each of which added an operation to the one list and left the guide alone. The
# guide is also where the read-only guarantee is explained to the person who has
# to trust it, and section 5 is a verification record they are asked to check
# before pointing the tool at real accounts. A section that is stale costs the
# record next to it some of the confidence it earned. The one list is what every
# operation must already appear in to exist at all, so it is what the guide is
# made to answer to.
#
# IT CHECKS THE SET AND THE ORDER, NOT THE PROSE. What an entry says is a
# judgement no test can make. That it exists, that it names an operation this
# tool actually offers, and that an operator reading down the section meets the
# screens in the order the menu offers them are facts — and they are the three
# things that went wrong.
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"

export ZRO_UI_BACKEND=stub
export ZRO_SOURCED_ONLY=1

# shellcheck source=../zimbra-ro-tui.sh
. "$ZRO_SRC/zimbra-ro-tui.sh"

DOC="$ZRO_SRC/docs/operations.md"

# The two subsections of section 3 that list operations, named as they are
# written. A heading renamed out from under this leaves the extraction empty,
# which fails the first case below rather than passing an empty comparison —
# the one failure mode a check like this must not have.
DOC_SECTIONS='### About the selected address
### About the server'

# Every operation entry in those subsections, in the order the guide writes
# them, as the bold label alone.
#
# The label rather than the whole bullet, because the label is the string the
# menu also draws: an entry whose heading drifted from the label an operator
# picks is an entry describing a screen nobody can find.
doc_labels() {
  awk -v sections="$DOC_SECTIONS" '
    BEGIN { n = split(sections, s, "\n"); for (i = 1; i <= n; i++) want[s[i]] = 1 }
    /^### / { inop = ($0 in want); next }
    /^## /  { inop = 0; next }
    inop && /^- \*\*/ {
      line = substr($0, 5)
      i = index(line, "**")
      if (i > 0) print substr(line, 1, i - 1)
    }
  ' "$DOC"
}

# Every operation the tool declares, in the order it offers them.
menu_labels() {
  local id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    zro_menu_label "$id"
    printf '\n'
  done <<EOF
$(zro_menu_ids)
EOF
}

DOCL=$(doc_labels)
MENUL=$(menu_labels)

# ------------------------------------------ that there was anything to read --

# ASKED FIRST, AND OF EACH HEADING SEPARATELY. Everything below reads the guide
# through these two headings, so one renamed — or demoted to '####' — leaves the
# extraction matching nothing, and the set comparison then reports every
# operation in the tool as undocumented. That is fifteen failures, not one of
# which names the single thing that actually changed. Asked here, the heading
# answers for itself.
it "the guide still carries the section headings this check reads it through"
while IFS= read -r heading; do
  [ -n "$heading" ] || continue
  if grep -qxF -- "$heading" "$DOC"; then
    zro_t_pass
  else
    zro_t_fail "docs/operations.md no longer carries the heading [$heading]; every case below reads the guide through it"
  fi
done <<EOF
$DOC_SECTIONS
EOF

# Both comparisons below iterate a list, so an EMPTY list makes no assertion at
# all and passes by making none. Said once here rather than guarded twice there.
it "and both lists were read"
if [ -n "$DOCL" ] && [ -n "$MENUL" ]; then
  zro_t_pass
else
  zro_t_fail "read nothing out of [${DOC_SECTIONS}] or out of ZRO_MENU_OPS"
fi

# ------------------------------------------------- the set, both ways --

it "every operation the tool declares has an entry in the operator guide"
while IFS= read -r label; do
  [ -n "$label" ] || continue
  if zro_t_has_line "$DOCL" "$label"; then
    zro_t_pass
  else
    zro_t_fail "declared operation missing from docs/operations.md section 3: [$label]"
  fi
done <<EOF
$MENUL
EOF

it "and the guide describes no operation the tool does not declare"
while IFS= read -r label; do
  [ -n "$label" ] || continue
  if zro_t_has_line "$MENUL" "$label"; then
    zro_t_pass
  else
    zro_t_fail "docs/operations.md section 3 describes an undeclared operation: [$label]"
  fi
done <<EOF
$DOCL
EOF

# ------------------------------------------------------------ the order --

# Stated separately from the two above, because a guide that holds the right set
# in the wrong order is a different fault with a different repair — and one the
# two set comparisons would both pass.
it "and it lists them in the order the menu offers them"
assert_eq "$DOCL" "$MENUL"

zro_t_report
