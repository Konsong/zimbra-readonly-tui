# shellcheck shell=bash
# THE EXISTENCE GATE. Whether an account has a mailbox at all, and the one path
# from this program to the binary that would create one if it did not. Depends on
# lib/account.sh for the shared directory read and the card writers, which is why
# the entry point sources it after that module.
[ -n "${ZRO_LIB_MAILBOX_LOADED:-}" ] && return 0
ZRO_LIB_MAILBOX_LOADED=1

# `zmmailbox` provisions a mailbox for an account that has none, during session
# setup rather than inside any subcommand — so no choice of subcommand avoids it,
# and four areas of work depend on that binary. A session may therefore be opened
# only after a command INCAPABLE OF PROVISIONING has proven the mailbox was
# already there.
#
# The oracle is `zmprov gis`, and nothing else. It passes DO_NOT_AUTOCREATE, it
# proxies to the account's home server, it writes neither the mailbox nor the
# index, and it reports a missing account and a missing mailbox in different
# words. `zimbraLastLogonTimestamp` was the cheap first layer of an earlier design
# and is refuted: an authentication that registers no session stamps it and
# creates no mailbox, and the accounts that gets wrong are exactly the accounts
# this gate exists to protect. It stays on the account card as an operational fact
# and carries no weight here. See docs/adr/0003-gis-is-the-existence-oracle.md.

# WHAT THE SESSION REMEMBERS, AND IN WHICH DIRECTION ONLY.
#
# A proof of existence is kept for the session; an ABSENCE VERDICT IS NEVER KEPT.
# The asymmetry is the whole rule: a mailbox appears on first login or first
# delivery, so the next message an operator sends falsifies a "no" — and an
# operator who has just sent a test message must not be told a stale one. A "yes"
# is falsified only by a deliberate administrative deletion, which ADR-0001
# records as a race documented rather than defended against.
#
# A FILE RATHER THAN A VARIABLE, for the reason lib/core.sh gives about the last
# error and the read mode: menu code runs operations inside command substitution,
# and a proof recorded in that subshell would die with it. The gate would then run
# once per screen instead of once per account, at a JVM start each time — which is
# the exact bug lib/capability.sh records having already been fixed once.
ZRO_MBOX_PROOF_FILE="${ZRO_MBOX_PROOF_FILE:-${TMPDIR:-/tmp}/zro-mailbox.$$}"
zro_session_file "$ZRO_MBOX_PROOF_FILE"

# Case-folded, because a mail address is case-insensitive and an operator who
# capitalised one would otherwise pay for the gate twice about one mailbox.
zro_mbox_proven() {
  local acct=${1-}
  [ -n "$acct" ] || return 1
  [ -f "$ZRO_MBOX_PROOF_FILE" ] || return 1
  grep -qxF -- "${acct,,}" "$ZRO_MBOX_PROOF_FILE" 2>/dev/null
}

zro_mbox_prove() {
  local acct=${1-}
  [ -n "$acct" ] || return "$ZRO_E_INPUT"
  zro_mbox_proven "$acct" && return 0
  ( umask 077; printf '%s\n' "${acct,,}" >>"$ZRO_MBOX_PROOF_FILE" ) 2>/dev/null || true
  return 0
}

# Emptied at startup, beside the capability cache and for a reason that cache does
# not have: it lives in variables, so a new process begins with it empty, while
# this lives in a file named after a process id — and process ids are reused. A
# session that inherited one would begin holding a proof nobody in it obtained.
zro_mbox_forget() {
  ( umask 077; : >"$ZRO_MBOX_PROOF_FILE" ) 2>/dev/null || true
}

# THE TWO SENTENCES THE ORACLE FAILS WITH, captured verbatim from the lab server:
#
#   ERROR: service.FAILURE (system failure: mailbox not found for account <id>)
#   ERROR: account.NO_SUCH_ACCOUNT (no such account: <address>)
#
# CLASSIFIED ON THE MESSAGE, NEVER ON THE STATUS, because both of them exit 2 and
# so does every other failure this command has. An exit code cannot tell an
# account that is not there from a mailbox that is not there, and those are
# different answers to different questions — telling them apart is most of what
# this gate is for.
#
# The order the two are tried in decides nothing today: neither message contains
# the other's text. It is written down all the same, so that a Zimbra release
# which changed one of them is caught by a fixture rather than by an operator
# reading the wrong screen.
ZRO_MBOX_TXT_NO_MAILBOX='mailbox not found'
ZRO_MBOX_TXT_NO_ACCOUNT='no such account'

# Prints the verdict a failure message carries, or refuses when it carries none.
# Pure: a string in, a word out. A message this program does not recognise is not
# an absence — it is a question the gate could not ask, and the caller reports it
# as itself.
zro_mbox_classify() {
  case ${1-} in
    *"$ZRO_MBOX_TXT_NO_MAILBOX"*) printf 'nomailbox'; return 0 ;;
    *"$ZRO_MBOX_TXT_NO_ACCOUNT"*) printf 'noaccount'; return 0 ;;
  esac
  return 1
}

# WHAT THE GATE LEARNED, as one of three words, or a status saying why it learned
# nothing.
#
#   exists      the mailbox is there
#   nomailbox   the account is there and has none
#   noaccount   there is no such account
#
# All three are RESULTS and return 0, exactly as an address that is nowhere in the
# directory is a result rather than a failure. A gate that answered "no mailbox"
# whenever it failed would put this tool's most consequential sentence behind a
# stopped service — and that sentence is what stops an operator looking further.
#
# THE ORACLE'S OUTPUT IS DISCARDED, deliberately. What it prints is the index's
# document count, and the populated fixture account on the lab server — 258
# messages — answers `maxDocs:0` because its mailbox has never been indexed. A
# screen that showed those numbers would be answering a question about the search
# index while looking like an answer about the mailbox. The gate reads the fact
# that the command SUCCEEDED, and nothing else.
zro_mbox_verdict() {
  local acct=${1-} rc=0 verdict
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"

  if zro_mbox_proven "$acct"; then
    printf 'exists'
    return 0
  fi

  zro_prov_read "$ZRO_E_NO_ACCOUNT" gis "$acct" >/dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    zro_mbox_prove "$acct"
    printf 'exists'
    return 0
  fi

  if verdict=$(zro_mbox_classify "$(zro_last_error)"); then
    printf '%s' "$verdict"
    return 0
  fi
  # Anything else is the gate unable to answer, and it travels out with its own
  # code. The one that matters is $ZRO_E_UNAVAILABLE: the oracle speaks SOAP and
  # nothing else, so a stopped mailbox service leaves it SILENT for every account.
  # That costs nothing real — the commands behind the gate would be equally
  # unusable — but it may not surface as a bare refusal, so the screen names it.
  return "$rc"
}

# THE GATE ITSELF, as the question a screen behind it asks: may this account's
# mailbox be opened?
#
# Success means proven. Every other answer is a documented code, so a mailbox
# screen reports an account with no mailbox as the plain result it is rather than
# as a failure of its own — and never has to know which of the three words the
# verdict was.
zro_mbox_require() {
  local acct=${1-} verdict rc=0
  verdict=$(zro_mbox_verdict "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  case $verdict in
    exists)    return 0 ;;
    nomailbox) return "$ZRO_E_NO_MAILBOX" ;;
    noaccount) return "$ZRO_E_NO_ACCOUNT" ;;
  esac
  # Unreachable while this list and the verdict's agree, and here so that they may
  # only disagree loudly. A word neither of them expects must never open a session.
  zro_log error "gate defect, not a verdict: $verdict"
  return "$ZRO_E_DENIED"
}

# THE ONE FUNCTION THAT MAY REACH THE GATED BINARY.
#
#   $1  the account the operation is about
#   $2  the subcommand
#   $@  already-validated arguments
#
# Callers pass an account and a subcommand and never write the binary's own
# prefix: lib/exec.sh owns that, refuses this binary from any caller but this
# function, and puts the prefix back where the binary expects it after the
# allowlist has read the subcommand in a position it can see.
#
# WHAT IS APPROVED BEHIND IT is four reads and no more: the folder listing, one
# folder, one folder's grants, and the mailbox size in bytes. Each arrived with
# the ticket that exposes it, never because the binary it belongs to became
# reachable, and anything else this function is handed is still refused by the
# allowlist one step after the gate has already proven it would have been safe.
#
# A leading dash is refused rather than passed on: the subcommand reaches the gate
# in the token position, where a flag is not data but an operation of its own, and
# nothing an operator types may arrive there.
zro_mbox_run() {
  local acct=${1-} sub=${2-}
  [ $# -ge 2 ] || return "$ZRO_E_INPUT"
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"
  case $sub in
    ''|-*) return "$ZRO_E_INPUT" ;;
  esac
  shift 2

  zro_mbox_require "$acct" || return $?
  zro_exec "$ZRO_GATED_BIN" "$sub" "$acct" "$@"
}

# --------------------------------------------------- what an operator reads --

ZRO_TXT_MBOX_EXISTS='Bu hesabin mailboxu var.'
ZRO_TXT_MBOX_NONE='Bu hesabin mailboxu yok.'
ZRO_TXT_MBOX_NO_ACCOUNT='Boyle bir hesap yok.'

# THE GATE AS A SCREEN: three outcomes, three closing paragraphs.
#
# Each kind gets its own, because what an operator does next differs for each and
# one sentence covering all three would cover none. The middle one carries the
# most: an account with no mailbox is a RESULT and reads as one, it says what
# creates a mailbox so that "never used" is an answer rather than a puzzle, and it
# says out loud that this tool will not create one — which is the guarantee being
# visible at the single point where breaking it would be most tempting.
#
# The read mode is reset and no banner follows it, which is the one card in this
# program without one. There is no degraded answer to disclose: the oracle has no
# LDAP form, so a mailbox service that is down does not produce a worse answer
# here, it produces no answer at all — and that has a screen of its own.
#
# THREE SWITCHES ON ONE VERDICT, and only the first of them is exhaustive. It is
# the layout that repeats, not the decision: a headline, then the fields, then the
# closing paragraph, in the order every other card in this program uses. The first
# switch refuses a word this file does not know, so the two below it cannot be
# reached by one — which is why they carry no default arm and why folding all
# three into one arm-per-verdict would buy nothing but the loss of the shape.
zro_mbox_card() {
  local acct=${1-} verdict rc=0
  zro_reset_mode
  verdict=$(zro_mbox_verdict "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  zro_mbox_verdict_card "$acct" "$verdict"
}

# THE SCREEN, GIVEN A VERDICT SOMEBODY ELSE OBTAINED. Pure: an account and a word
# in, a report out, and nothing read.
#
# Split from the card above so that a screen BEHIND the gate can show an absence
# as the result it is. Those screens learn of it as a status — the gate refused,
# and the operation never ran — and reporting that through the shared failure box
# would answer 'Mailbox bulunamadi' where this whole design says the answer is
# 'this account has never been used'. Rendering it here costs nothing: the verdict
# is already in hand, and asking again would spend a second invocation to be told
# what the caller already knows.
zro_mbox_verdict_card() {
  local acct=${1-} verdict=${2-}

  case $verdict in
    exists)    printf '%s\n\n' "$ZRO_TXT_MBOX_EXISTS" ;;
    nomailbox) printf '%s\n\n' "$ZRO_TXT_MBOX_NONE" ;;
    noaccount) printf '%s\n\n' "$ZRO_TXT_MBOX_NO_ACCOUNT" ;;
    *) zro_log error "gate defect, no screen for verdict: $verdict"
       return "$ZRO_E_INPUT" ;;
  esac

  zro_card_line 'Hesap' "$acct"
  case $verdict in
    exists)    zro_card_line 'Mailbox' 'var' ;;
    nomailbox) zro_card_line 'Mailbox' 'yok' ;;
  esac

  printf '\n'
  case $verdict in
    exists)
      printf 'Mailbox ekranlari bu hesap icin calisir. Bu ekran mailboxun icine\n'
      printf 'bakmaz; yalnizca var olup olmadigini sorar.\n' ;;
    nomailbox)
      printf 'Bu bir hata degil, bir sonuc. Hesap dizinde duruyor, mailboxu ise\n'
      printf 'henuz yaratilmamis: mailbox ilk giriste veya ilk teslimde yaratilir,\n'
      printf 'yani bu hesaba bugune kadar ne giris yapildi ne de posta geldi.\n'
      printf '\n'
      printf 'Mailbox ekranlari bu hesap icin calismaz, ve BU ARAC MAILBOXU\n'
      printf 'YARATMAZ. Mailbox acan bir komut calistirmak, olmayan mailboxu\n'
      printf 'yaratirdi; salt-okunur garantisi buna izin vermez.\n' ;;
    noaccount)
      printf 'Sorgu calisti ve yanit verdi: dizinde bu adla bir hesap yok, bu\n'
      printf 'yuzden mailbox sorusu da sorulamaz.\n'
      printf '\n'
      printf 'Adres bir alias, bir dagitim listesi veya bir kaynak olabilir. Ana\n'
      printf 'menuden adresi yeniden secerek ne oldugunu gorebilirsiniz.\n' ;;
  esac

  # Double-quoted on purpose: the static scanner treats a double-quoted span as
  # data, so this line may name the command it was answered by. It is named
  # because the guarantee is what this screen is really about — an operator who
  # can see which command answered can check for themselves that it creates
  # nothing.
  printf '\n'
  printf "(Bu yanit zmprov gis ile alindi: mailbox yaratmaz, dizini yazmaz.)\n"
}
