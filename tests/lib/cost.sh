# shellcheck shell=bash
# What a screen spent, judged against the cost class its entry in the one list
# declares. Sourced by the test files that drive whole screens, AFTER the program
# itself: everything here reads the declaration rather than restating it.
[ -n "${ZRO_LIB_COST_LOADED:-}" ] && return 0
ZRO_LIB_COST_LOADED=1

# assert_cost <operation-id> <invocations observed> <how many units the run named> [reads per unit]
#
# TWO THINGS THIS DOES THAT assert_eq CANNOT. It fails when the operation declares
# no cost class, or declares one this tool does not — so a screen whose cost nobody
# decided cannot pass by spending a plausible number. And it reads the UNIT out of
# the class, which is what lets a case count the run's own answer instead of
# writing down what the code happens to do: the entries a record points at, the
# files a window covers. A case that could only say "3" would be describing the
# implementation back to itself, and would go on passing after the screen started
# reading one entry per account.
#
# READS PER UNIT IS THE FOURTH ARGUMENT AND DEFAULTS TO ONE, because one invocation
# is normally what one unit costs — a JVM start per directory entry, a scan per log
# file. It is an argument rather than an assumption because exactly one screen pays
# a multiple: provenance reads one entry twice, once with the class of service
# expanded into it and once without, since the difference between those answers is
# the question it asks.
#
# THE MULTIPLE IS DECLARED, NOT ABSORBED. A case still counts UNITS out of the
# fixture and states the multiple separately, so the two claims stay legible: a
# screen that reached for a second entry fails against the unit it named, and a
# screen that quietly stopped making its second read fails against the multiple.
# A total written as one number would have hidden both.
assert_cost() {
  local id=${1-} got=${2-} units=${3-} per=${4-1} class unit want
  if ! class=$(zro_menu_cost "$id"); then
    zro_t_fail "no declared cost class for operation: $id"
    return 0
  fi
  # Unreachable while the lookup above refuses an undeclared class, and here so
  # that the two may only disagree loudly: were they ever to part company, this
  # would otherwise report a cost in a unit nobody declared.
  if ! unit=$(zro_cost_unit "$class"); then
    zro_t_fail "operation $id claims cost class $class, which is not declared"
    return 0
  fi
  case $per in
    ''|*[!0-9]*|0) zro_t_fail "$id: reads per $unit must be a positive number, got [$per]"
                   return 0 ;;
  esac
  want=$((units * per))
  if [ "$got" -eq "$want" ]; then
    zro_t_pass
  else
    zro_t_fail "$id is cost class $class, $per invocation(s) per ${unit}: $units of them named, so $want expected, and $got invocations spent"
  fi
}
