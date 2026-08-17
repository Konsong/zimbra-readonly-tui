# shellcheck shell=bash
# Shared behaviour for the fake Zimbra and system binaries.

# Appends one TAB-separated line: the binary name followed by each argument.
# Tests assert on this line, which is what proves no word splitting and no
# unintended flag reached the real command.
zro_mock_record() {
  local name=$1
  shift
  local line=$name arg
  for arg in "$@"; do
    line="$line	$arg"
  done
  if [ -n "${ZRO_MOCK_LOG:-}" ]; then
    printf '%s\n' "$line" >>"$ZRO_MOCK_LOG"
  fi
  return 0
}

# Replies according to ZRO_MOCK_<BIN>_<TOKEN>_{OUT,ERR,RC}, where <TOKEN> has
# every character outside [A-Za-z0-9_] replaced by an underscore and the whole
# name is upper-cased. So `zmcontrol -v` reads ZRO_MOCK_ZMCONTROL__V_OUT.
# Mirrors the gate's rule: a flag-shaped token is keyed together with the
# subcommand behind it, so a test can script `zmprov ga` and `zmprov -l ga`
# with different answers.
#
# AND THE MIRROR RUNS THE OTHER WAY TOO. A flag standing in the data position is
# not data — it changes what the command does, which is why the allowlist names
# `zmprov:ga:-e` as an operation of its own. So the reply is keyed on it as well,
# and `zmprov ga -e <acct>` reads ZRO_MOCK_ZMPROV_GA__E_OUT rather than answering
# out of the ordinary account read. Without that the provenance screen's two reads
# would be scripted by one variable and would return the same text, which is the
# one thing that screen exists to tell apart — a fixture pair proving nothing, and
# the case passing whatever the code did.
zro_mock_token() {
  case ${1:-} in
    -*)
      if [ -n "${2:-}" ]; then
        printf '%s %s' "$1" "$2"
      else
        printf '%s' "$1"
      fi
      ;;
    *)
      case ${2:-} in
        -*) printf '%s %s' "$1" "$2" ;;
        *)  printf '%s' "${1:-}" ;;
      esac
      ;;
  esac
}

zro_mock_key() {
  local key="ZRO_MOCK_$1"
  key=${key//[^A-Za-z0-9_]/_}
  printf '%s' "${key^^}"
}

# A THIRD PART TO THE KEY, FOR THE SCREENS THAT READ SEVERAL ACCOUNTS IN ONE RUN.
# Keyed on the subcommand alone, every account in a bulk query reads one variable
# and answers the same text — so a case could not tell a run of three accounts
# from one account read three times, and could not stage the one thing those
# screens exist to survive: an address in the list the directory does not hold.
#
# The scoped variable wins when it is set and the plain one answers when it is
# not, so every case written before this is untouched by it.
zro_mock_respond() {
  local name=$1 token=${2:-} scope=${3:-}
  local key
  key=$(zro_mock_key "${name}_${token}")

  if [ -n "$scope" ]; then
    local skey s_out s_err s_rc
    skey=$(zro_mock_key "${name}_${token}_${scope}")
    s_out="${skey}_OUT"; s_err="${skey}_ERR"; s_rc="${skey}_RC"
    if [ -n "${!s_out:-}" ] || [ -n "${!s_err:-}" ] || [ -n "${!s_rc:-}" ]; then
      key=$skey
    fi
  fi

  local out_var="${key}_OUT" err_var="${key}_ERR" rc_var="${key}_RC"
  local out=${!out_var:-} err=${!err_var:-} rc=${!rc_var:-0}

  if [ -n "$out" ] && [ -f "$out" ]; then
    cat -- "$out"
  fi
  if [ -n "$err" ] && [ -f "$err" ]; then
    cat -- "$err" >&2
  fi
  exit "$rc"
}
