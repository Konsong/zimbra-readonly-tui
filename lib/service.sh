# shellcheck shell=bash
# SERVICE STATUS: which of this server's services are running, and which are not.
#
# It answers the question every other screen in this tool eventually leads back
# to — is the server itself the problem — and it is the one operation here whose
# command WRITES.
[ -n "${ZRO_LIB_SERVICE_LOADED:-}" ] && return 0
ZRO_LIB_SERVICE_LOADED=1

# THE ONE COMMAND IN THIS TOOL THAT LEAVES SOMETHING BEHIND, admitted as a
# DECLARED ARTIFACT and not as an exception anybody may repeat.
#
# `zmcontrol status` starts and stops nothing. What it does do is create the
# localconfig temp directory when it is missing, leave temp files in it, and
# rewrite `/opt/zimbra/log/.zmcontrol.cache` on every successful directory
# lookup. None of that is domain state — no account, no mailbox, no folder, no
# flag, no configuration and no service changes — but all of it is a write, and a
# guarantee that quietly rounded it down to nothing would be a guarantee nobody
# should trust with the next borderline command.
#
# THREE CONDITIONS ADMIT IT, AND THEY HOLD TOGETHER: it changes no domain state,
# THE SCREEN SAYS WHAT IT WRITES, and docs/adr/0005 records the judgement. The
# second one is this file's business, and it is why the disclosure below is part
# of the card rather than a line in the manual: an operator who is told what a
# command writes can trust the read-only claim precisely instead of vaguely, and
# a screen is where they are standing when they need to.
#
# IT CAN BLOCK BEFORE ITS OWN ALARM ARMS. The command wraps each service it asks
# in an alarm and wraps the directory lookup that runs first in nothing, so a
# hung directory server leaves it waiting with nothing of its own to interrupt
# it. What bounds it is the wall-clock timeout every command in this program runs
# under, and the screen reports the expiry as itself — a command that was cut
# off, naming the directory as the place to look — rather than as a server that
# answered nothing.

# WHAT A SERVICE'S STATE IS CALLED HERE, and what the tool called it.
#
# TWO STATES WERE OBSERVED and a third is admitted without being named: the lab
# server answered `Running` and `Stopped`, and anything else is carried through
# as the word the tool printed. Reading an unknown state as stopped would be this
# program inventing an outage; reading it as running would be inventing calm.
zro_svc_state() {
  case ${1-} in
    Running) printf 'running' ;;
    Stopped) printf 'stopped' ;;
    '') return 1 ;;
    *) printf 'other' ;;
  esac
}

zro_svc_state_label() {
  case ${1-} in
    running) printf 'Calisiyor' ;;
    # Upper case, and the only thing on this screen that is. A stopped service is
    # what an operator came to find, and it has to be findable in a list of ten
    # without reading every line.
    stopped) printf 'DURMUS' ;;
    other)   printf '%s' "${2-}" ;;
    *) return 1 ;;
  esac
}

# The host the answer is about, as the command named it.
#
# READ RATHER THAN ASSUMED. This tool is built for one server, and the day it is
# pointed at a second the screen has to say which one answered — a status page
# read about the wrong host is worse than none.
zro_svc_host() {
  local line
  while IFS= read -r line; do
    case $line in
      'Host '*) printf '%s' "${line#Host }"; return 0 ;;
    esac
  done <<EOF
${1-}
EOF
  return 1
}

# ONE ROW PER SERVICE: "state <tab> name <tab> the word the tool printed".
#
# A SERVICE LINE IS AN INDENTED ONE. The host line begins in column 1 and every
# service hangs under it behind a tab, which is what tells them apart without
# this reader having to know the names of Zimbra's services.
#
# THE NAME IS EVERYTHING BUT THE LAST WORD, and that is the whole difficulty:
# four of the ten services on the lab server are called `service webapp`,
# `zimbra webapp`, `zimbraAdmin webapp` and `zimlet webapp`. A reader that split
# on whitespace and took the second field as the state would report four services
# in a state that does not exist.
zro_svc_rows() {
  local line trimmed name word state
  while IFS= read -r line; do
    case $line in
      [[:space:]]*) ;;
      *) continue ;;
    esac
    trimmed=${line#"${line%%[![:space:]]*}"}
    trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
    [ -n "$trimmed" ] || continue
    word=${trimmed##* }
    name=${trimmed% *}
    name=${name%"${name##*[![:space:]]}"}
    # A line with one word on it names no service and reports no state. Left out
    # rather than guessed at from which half is missing: stripping the last word
    # off a single-word line leaves the line itself, which is how that case is
    # recognised.
    if [ -z "$name" ] || [ "$name" = "$trimmed" ]; then
      continue
    fi
    state=$(zro_svc_state "$word") || continue
    printf '%s\t%s\t%s\n' "$state" "$name" "$word"
  done <<EOF
${1-}
EOF
}

zro_svc_count() {
  local rows=${1-} want=${2-} line n=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "${line%%	*}" = "$want" ] && n=$((n + 1))
  done <<EOF
$rows
EOF
  printf '%s' "$n"
}

# ------------------------------------------------------ reaching the tool --

# THE STATUS, or the reason there is none.
#
# The output is handed on unread: what it means is the renderer's business, and
# an answer this reader could not make sense of is a screen that says so rather
# than a fetch that failed.
#
# THE TIMEOUT TRAVELS AS ITSELF. It is the only bound this command has, so the
# screen has something specific to say about it, and flattening it into a general
# failure would take away the one message that names the directory server.
zro_svc_fetch() {
  local out err rc=0 said
  err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"
  out=$(zro_exec zmcontrol status 2>"$err") || rc=$?
  said=$(head -c 500 -- "$err" 2>/dev/null)
  rm -f -- "$err"

  if [ "$rc" -ne 0 ]; then
    [ -z "$said" ] || zro_set_error "$said"
    case $rc in
      "$ZRO_E_DENIED"|"$ZRO_E_BADUSER"|"$ZRO_E_NOCAP"|"$ZRO_E_TIMEOUT")
        return "$rc" ;;
    esac
    zro_log warn "service status unreadable (${said:-no message on stderr})"
    return "$ZRO_E_UNAVAILABLE"
  fi
  zro_clear_error
  printf '%s' "$out"
}

# --------------------------------------------------- what an operator reads --

# WHAT THIS COMMAND WRITES, SAID ON THE SCREEN THAT RUNS IT. One of the three
# conditions that admit it at all, and the only one that lives in code.
#
# DOUBLE-QUOTED ON PURPOSE, as the gate's own card is: the static scanner reads a
# double-quoted span as data rather than as something the program runs, so this
# text may name the command it is about. Naming it is the point — an operator who
# can see which command wrote the file can go and look at it, which is the
# difference between trusting the read-only claim precisely and trusting it
# vaguely.
ZRO_TXT_SVC_ARTIFACT="Bu ekran servisleri yalnizca SORAR: hicbir servisi BASLATMAZ, DURDURMAZ veya
yeniden baslatmaz, ve hicbir hesap, mailbox, klasor veya ayar degismez.

Yine de bu komut diske bir sey yazar, ve bu acikca soylenir: zmcontrol status
Zimbranin kendi agaci icinde .zmcontrol.cache dosyasini her calismada yeniden
yazar ve gecici dosya birakir. Bunlar Zimbranin yonettigi veriler degildir;
bu araca 'bildirilmis artifact' olarak, uc kosul birlikte saglandigi icin
alinmistir: alan durumu degismez, ekran ne yazdigini soyler, ve karar bir ADR
kaydinda durur."

# THE CARD: the host, the counts, then every service with the state it is in.
#
# COUNTS BEFORE THE LIST, as on the queue screen and for the same reason: what an
# operator arrives with is 'is something down', and one number answers it. The
# list is what they read next, and a stopped service is the only thing on it in
# upper case.
zro_svc_card() {
  local out=${1-} rows host running stopped other total line state name word
  rows=$(zro_svc_rows "$out")
  # NO SERVICE LINE AT ALL IS NOT A HOST WITH NO SERVICES. The command answered
  # something this reader could not make sense of, and reporting that as a row of
  # zeroes would be the most alarming screen in the tool, invented.
  if [ -z "$rows" ]; then
    zro_log warn "service status: no service line in the command's output"
    return "$ZRO_E_NO_RESULT"
  fi
  host=$(zro_svc_host "$out") || host='(bilinmiyor)'
  running=$(zro_svc_count "$rows" running)
  stopped=$(zro_svc_count "$rows" stopped)
  other=$(zro_svc_count "$rows" other)
  total=$((running + stopped + other))

  zro_card_line 'Sunucu' "$host"
  zro_card_line 'Servis sayisi' "$total"
  zro_card_line 'Calisan' "$running"
  zro_card_line 'Durmus' "$stopped"
  [ "$other" -gt 0 ] && zro_card_line 'Taninmayan durum' "$other"

  printf '\n'
  printf '%-26s%s\n' 'Servis' 'Durum'
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    state=${line%%	*};  line=${line#*	}
    name=${line%%	*};   word=${line#*	}
    printf '%-26s%s\n' "$name" "$(zro_svc_state_label "$state" "$word")"
  done <<EOF
$rows
EOF

  printf '\n'
  printf '%s\n' "$ZRO_TXT_SVC_ARTIFACT"
}
