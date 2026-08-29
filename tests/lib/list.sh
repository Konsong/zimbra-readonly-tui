# shellcheck shell=bash
# WHAT A BUILT LIST MUST REFUSE, declared once for every screen that draws one.
#
# A built list is a list this program assembled at run time out of the server's or
# the file system's answer and offered BY POSITION: the folders of a mailbox, the
# conversations a search found, the log files on this host. Whatever comes back
# from the screen is looked up in the array this program built, so the guard in
# front of that lookup carries the whole of the screen's claim that no value from
# the screen becomes an argument.
#
# THE VECTOR IS DECLARED HERE RATHER THAN AT THE CALL SITES, because the guard is
# written out once per screen. Three copies of one rule judged by three different
# vectors are three rules, and the value that gets through is the one the author
# of that copy did not think to try.
[ -n "${ZRO_LIB_LIST_LOADED:-}" ] && return 0
ZRO_LIB_LIST_LOADED=1

# NONE OF THESE IS REACHABLE THROUGH WHIPTAIL TODAY, because this program writes
# the menu tags itself. That is the point rather than the defence: the guard
# exists precisely because what comes back from the screen is not trusted, and a
# guard that is only correct while the menu keeps writing its own tags is correct
# by the assumption it was written in order not to make.
#
# THE TWO THAT ARE NOT ABOUT SHELL METACHARACTERS, and why each is here:
#
#   08 is decimal 8 to `[` and octal to the subscript. An admission that spells
#      its refusal as [!0-9] lets it through, the range check reads it as 8 and
#      agrees, and then `${list[08 - 1]}` cannot be evaluated at all: 8 is not an
#      octal digit. It needs a list of eight or more entries to get that far, and
#      Zimbra's default folder set is twelve.
#
#   The twenty-digit integer is wider than 64 bits, so `[` cannot parse it: it
#      reports an error and BOTH comparisons come back false. The guard does not
#      refuse, it falls through, and the subscript below it then names an element
#      `set -u` finds unset — which takes the whole shell down, not just the screen.
ZRO_T_LIST_HOSTILE=(
  ""                      # nothing at all
  "0"                     # the position before the first
  "-1"                    # a negative
  "99"                    # past the end of every list in this suite
  "08"                    # decimal to the range check, octal to the subscript
  "99999999999999999999"  # wider than 64 bits: `[` cannot read it either way
  "1 2"                   # two positions where one was asked for
  "1;id"                  # a position and a command
  "/etc/passwd"           # a path where a position was expected
)

# assert_list_refuses <driver> [extra answer]...
#
# <driver> is a function of ONE argument, the operator's answer. It queues its own
# screen's way in, that answer, and enough cancels to leave, then runs the screen
# with a fresh transcript and a fresh command log. Each test file writes its own,
# because only it knows how its screen is reached; the extra answers are for the
# values that are hostile only at one screen, such as a path out of that screen's
# own inventory.
#
# THREE CLAIMS PER ANSWER, and only the second is one a needle could make.
#
#   THE PROGRAM IS STILL RUNNING, said by the status of the run itself. This is
#   why the driver is called in a SUBSHELL and not for isolation: a subscript this
#   shell cannot evaluate abandons the whole call stack, helper and loop included,
#   and a vector whose fifth value kills the file running it never judges the
#   sixth — it reports the file as green having stopped asking. In a subshell that
#   value kills a child, the status says so, and the rest of the vector is tried.
#
#   NOTHING WAS READ, judged against the run where the operator picked nothing at
#   all: the driver is called first with a cancel, and whatever commands that run
#   spends is what DRAWING the list costs. A per-screen needle — no gf ran, no sc
#   ran — would only ever catch the read its author thought of; the whole log
#   catches any read at all.
#
#   AND THE OPERATOR IS STILL IN FRONT OF THE LIST. A refusal continues the menu
#   loop, so it draws exactly one menu more than the cancel did. Without this a
#   screen that was ABANDONED mid-answer passes the first claim comfortably — it
#   read nothing because it was no longer running — which is exactly what an
#   unevaluable subscript does to it, and what an operator sees as the screen
#   vanishing under them.
#
# ONE ANSWER PER RUN, judged on its own, so a failure names the value that got
# through instead of reporting that one of ten did.
assert_list_refuses() {
  local driver=${1-}
  shift
  local answer drawn_log drawn_menus drawn_rc=0 got_log got_menus got_rc

  ( "$driver" "__CANCEL__" ) || drawn_rc=$?
  drawn_log=$(cat -- "$ZRO_MOCK_LOG")
  drawn_menus=$(grep -c '^MENU ' -- "$ZRO_UI_OUT")

  for answer in "${ZRO_T_LIST_HOSTILE[@]}" "$@"; do
    got_rc=0
    ( "$driver" "$answer" ) || got_rc=$?
    got_log=$(cat -- "$ZRO_MOCK_LOG")
    got_menus=$(grep -c '^MENU ' -- "$ZRO_UI_OUT")

    if [ "$got_rc" -eq "$drawn_rc" ]; then
      zro_t_pass
    else
      zro_t_fail "the answer [$answer] did not leave the program running: cancelling ended in status $drawn_rc, this answer in $got_rc"
    fi

    if [ "$got_log" = "$drawn_log" ]; then
      zro_t_pass
    else
      zro_t_fail "the answer [$answer] read something drawing the list does not:
        drawing it spent: [$drawn_log]
        this answer spent: [$got_log]"
    fi

    # THE EMPTY ANSWER IS THE ONE THIS BACKEND CANNOT DELIVER. An empty line in
    # the queue IS the stub's cancel, so it never reaches the guard and the screen
    # is left rather than returned to. It stays in the vector because the guard
    # names it and a real backend may yet produce it, and it is judged on the one
    # claim it can carry.
    [ -n "$answer" ] || continue
    if [ "$got_menus" -eq "$((drawn_menus + 1))" ]; then
      zro_t_pass
    else
      zro_t_fail "the answer [$answer] did not return the operator to the list: cancelling drew $drawn_menus menus, this answer drew $got_menus and a refusal draws one more"
    fi
  done
}
