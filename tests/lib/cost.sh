# shellcheck shell=bash
# What a screen spent, judged against the cost class its entry in the one list
# declares. Sourced by the test files that drive whole screens, AFTER the program
# itself: everything here reads the declaration rather than restating it.
[ -n "${ZRO_LIB_COST_LOADED:-}" ] && return 0
ZRO_LIB_COST_LOADED=1

# assert_cost <operation-id> <invocations observed> <how many units the run named>
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
# The count and the units are compared as equals because one invocation is what
# one unit costs — a JVM start per directory entry, a scan per log file. That is
# the claim each class makes, and it is the claim worth breaking a build over.
assert_cost() {
  local id=${1-} got=${2-} units=${3-} class unit
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
  if [ "$got" -eq "$units" ]; then
    zro_t_pass
  else
    zro_t_fail "$id is cost class $class, one invocation per ${unit}: $units of them named, and $got invocations spent"
  fi
}
