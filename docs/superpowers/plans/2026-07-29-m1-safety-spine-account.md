# M1 — Safety Spine + Account/Quota Menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the complete read-only safety spine of the Zimbra TUI plus one working menu (account, quota, COS, mailbox host, last logon, distribution-list membership), so the read-only guarantee can be proven on a real server before any further menu is written.

**Architecture:** Every external command passes through one gate, `zro_exec`, which checks the `(binary, second-token)` pair against a central allowlist, confirms the binary exists, selects the identity wrapper, and builds an argv array — no string assembly anywhere. Screen I/O passes through `lib/ui.sh`, which has a whiptail backend and a stub backend so navigation is testable headlessly. Binary locations come from `ZRO_*` variables with production defaults, which is what lets the test suite substitute mocks that record the exact argument vector they received.

**Tech Stack:** Bash (floor 4.2), whiptail, a dependency-free test runner written for this repo. No package manager, no test framework, no runtime libraries.

## Global Constraints

- **Bash floor is 4.2.** No namerefs (`local -n`), no `${var@Q}`, no `wait -n`. Enforced by `tests/test_bash_compat.sh`.
- **`set -uo pipefail` in every executable script. Never `set -e`/`errexit`.** whiptail returns non-zero on Cancel, and `errexit` is silently disabled inside conditional contexts.
- **No `eval`, no `bash -c`/`sh -c` on operator-influenced strings, no command substitution built from input, no unquoted expansion in command position.**
- **No write command may appear in an executable position**, including the short aliases `dm mm mmr ef df ma da ca`.
- **Files under `lib/` are sourced, never executed:** mode 644, no shebang, first line `# shellcheck shell=bash`, and a reload guard.
- **Binary paths are never literals in module code.** Always `$ZRO_ZIMBRA_BIN`, `$ZRO_RUNUSER`, `$ZRO_TIMEOUT_BIN`, `$ZRO_ID_BIN`.
- **ShellCheck must be clean** across `zimbra-ro-tui.sh`, `lib/*.sh`, `tests/*.sh`, `tests/lib/*.sh`, `tests/mocks/*.sh`, `tests/mocks/bin/*`.
- **UI strings are Turkish. Code, comments, commit messages and documentation are English.**
- **LF line endings.** Enforced by `.gitattributes`, already committed.
- **Development happens on Windows; run everything under WSL**, not Git Bash: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`.
- **Executable bit:** Windows checkouts do not carry it. After creating any file under `tests/mocks/bin/`, `tests/run.sh` or `zimbra-ro-tui.sh`, run `git update-index --chmod=+x <path>` before committing.

## File Structure

| File | Responsibility |
|---|---|
| `zimbra-ro-tui.sh` | Entry point. Startup checks, main menu loop, wiring. |
| `lib/core.sh` | Exit codes, logging, temp files and traps, `zro_first_existing`. Depends on nothing. |
| `lib/validate.sh` | Pure input validators. Depends on `core.sh` for exit codes only. |
| `lib/capability.sh` | Binary availability and cached Zimbra version. |
| `lib/exec.sh` | **The gate.** Allowlist, identity mode, argv construction, timeout, status normalisation. |
| `lib/ui.sh` | whiptail and stub backends behind one interface. |
| `lib/account.sh` | M1 operations and their output parsing. |
| `tests/run.sh` | Test runner. |
| `tests/lib/assert.sh` | Assertion library and per-file reporting. |
| `tests/mocks/mock_common.sh` | Shared mock behaviour: argv recording, scripted responses. |
| `tests/mocks/bin/{zmprov,zmcontrol,runuser,timeout,id}` | Fake binaries. |
| `tests/fixtures/*` | Captured Zimbra output. |
| `tests/test_*.sh` | One file per module, plus two static-analysis suites. |
| `.shellcheckrc`, `.github/workflows/ci.yml` | Lint configuration and CI. |
| `docs/operations.md` | Operator guide and the read-only verification record. |

---

### Task 1: Test harness

**Files:**
- Create: `tests/lib/assert.sh`
- Create: `tests/run.sh`
- Test: `tests/test_harness.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `it <name>`; `assert_ok <cmd...>`; `assert_fail <cmd...>`; `assert_status <want> <cmd...>`; `assert_eq <got> <want>`; `assert_contains <haystack> <needle>`; `assert_not_contains <haystack> <needle>`; `assert_out_eq <want> <cmd...>`; `zro_t_report`. Counters `ZRO_T_OK`, `ZRO_T_FAIL`. Runner exports `ZRO_SRC` (repo root) and `ZRO_TEST_ROOT` to every test file.

- [ ] **Step 1: Write the failing test**

Create `tests/test_harness.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"

it "assert_eq passes on equal values"
assert_eq "abc" "abc"

it "assert_eq increments the failure counter on different values"
observed=$( ZRO_T_FAIL=0; assert_eq "abc" "xyz" 2>/dev/null; printf '%s' "$ZRO_T_FAIL" )
assert_eq "$observed" "1"

it "assert_status matches an exact exit status"
assert_status 3 bash -c 'exit 3'

it "assert_contains finds a substring"
assert_contains "hello world" "lo wo"

it "assert_out_eq compares stdout"
assert_out_eq "hi" printf 'hi'

zro_t_report
```

- [ ] **Step 2: Run it to verify it fails**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ZRO_TEST_ROOT=$PWD/tests bash tests/test_harness.sh'`
Expected: FAIL — `tests/lib/assert.sh: No such file or directory`.

- [ ] **Step 3: Write the assertion library**

Create `tests/lib/assert.sh`:

```bash
# shellcheck shell=bash
# Assertion library. Sourced by every tests/test_*.sh file.
[ -n "${ZRO_LIB_ASSERT_LOADED:-}" ] && return 0
ZRO_LIB_ASSERT_LOADED=1

ZRO_T_OK=0
ZRO_T_FAIL=0
ZRO_T_CURRENT="(unnamed)"

it() { ZRO_T_CURRENT=$1; }

zro_t_pass() { ZRO_T_OK=$((ZRO_T_OK + 1)); }

zro_t_fail() {
  ZRO_T_FAIL=$((ZRO_T_FAIL + 1))
  printf '  FAIL: %s\n        %s\n' "$ZRO_T_CURRENT" "$1" >&2
}

assert_ok() {
  if "$@" >/dev/null 2>&1; then
    zro_t_pass
  else
    zro_t_fail "expected success, got status $? from: $*"
  fi
}

assert_fail() {
  if "$@" >/dev/null 2>&1; then
    zro_t_fail "expected failure, got success from: $*"
  else
    zro_t_pass
  fi
}

assert_status() {
  local want=$1 got=0
  shift
  "$@" >/dev/null 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then
    zro_t_pass
  else
    zro_t_fail "expected status $want, got $got from: $*"
  fi
}

assert_eq() {
  if [ "$1" = "$2" ]; then
    zro_t_pass
  else
    zro_t_fail "expected [$2], got [$1]"
  fi
}

assert_contains() {
  case $1 in
    *"$2"*) zro_t_pass ;;
    *)      zro_t_fail "expected to contain [$2], got [$1]" ;;
  esac
}

assert_not_contains() {
  case $1 in
    *"$2"*) zro_t_fail "expected NOT to contain [$2], got [$1]" ;;
    *)      zro_t_pass ;;
  esac
}

assert_out_eq() {
  local want=$1 got
  shift
  got=$("$@" 2>/dev/null)
  assert_eq "$got" "$want"
}

zro_t_report() {
  printf '__ZRO_RESULT__ %d %d\n' "$ZRO_T_OK" "$ZRO_T_FAIL"
  [ "$ZRO_T_FAIL" -eq 0 ]
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ZRO_TEST_ROOT=$PWD/tests bash tests/test_harness.sh'`
Expected: `__ZRO_RESULT__ 5 0`, exit status 0.

- [ ] **Step 5: Write the runner**

Create `tests/run.sh`:

```bash
#!/usr/bin/env bash
# Dependency-free test runner. Runs every tests/test_*.sh in its own process.
set -uo pipefail

ZRO_TEST_ROOT=$(cd -- "$(dirname -- "$0")" && pwd)
ZRO_SRC=$(cd -- "$ZRO_TEST_ROOT/.." && pwd)
export ZRO_TEST_ROOT ZRO_SRC

# Windows checkouts do not carry the executable bit; restore it for the mocks.
if [ -d "$ZRO_TEST_ROOT/mocks/bin" ]; then
  chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* 2>/dev/null || true
fi

total_ok=0
total_fail=0
files=0

for f in "$ZRO_TEST_ROOT"/test_*.sh; do
  [ -e "$f" ] || continue
  files=$((files + 1))
  name=$(basename -- "$f")
  output=$(bash "$f" 2>&1)
  result=$(printf '%s\n' "$output" | grep '^__ZRO_RESULT__' | tail -n 1)
  if [ -z "$result" ]; then
    printf '%-28s CRASHED\n' "$name"
    printf '%s\n' "$output" | sed 's/^/    /'
    total_fail=$((total_fail + 1))
    continue
  fi
  ok=$(printf '%s' "$result" | awk '{print $2}')
  fail=$(printf '%s' "$result" | awk '{print $3}')
  total_ok=$((total_ok + ok))
  total_fail=$((total_fail + fail))
  if [ "$fail" -eq 0 ]; then
    printf '%-28s %3d ok\n' "$name" "$ok"
  else
    printf '%-28s %3d ok  %3d FAIL\n' "$name" "$ok" "$fail"
    printf '%s\n' "$output" | grep -v '^__ZRO_RESULT__'
  fi
done

printf -- '----\n%d files, %d ok, %d failed\n' "$files" "$total_ok" "$total_fail"
[ "$total_fail" -eq 0 ]
```

- [ ] **Step 6: Run the runner to verify it reports the harness test**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_harness.sh    5 ok` then `1 files, 5 ok, 0 failed`, exit status 0.

- [ ] **Step 7: Commit**

```bash
git update-index --chmod=+x tests/run.sh
git add tests/run.sh tests/lib/assert.sh tests/test_harness.sh
git commit -m "test: add dependency-free test runner and assertion library"
```

---

### Task 2: `lib/core.sh` — exit codes, logging, temp files

**Files:**
- Create: `lib/core.sh`
- Test: `tests/test_core.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: constants `ZRO_E_OK=0 ZRO_E_INPUT=10 ZRO_E_NO_ACCOUNT=11 ZRO_E_NO_MAILBOX=12 ZRO_E_NO_FOLDER=13 ZRO_E_NO_RESULT=14 ZRO_E_PERM=20 ZRO_E_UNAVAILABLE=21 ZRO_E_TIMEOUT=22 ZRO_E_NO_LOG=23 ZRO_E_PARTIAL=30 ZRO_E_CANCEL=40 ZRO_E_DENIED=90 ZRO_E_BADUSER=91 ZRO_E_NOCAP=92`; `zro_log <level> <message>`; `zro_first_existing <path...>`; `zro_tmpfile`; `zro_cleanup`; `zro_human_bytes <n>`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_core.sh`:

```bash
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_core.sh CRASHED` — `lib/core.sh: No such file or directory`.

- [ ] **Step 3: Write `lib/core.sh`**

```bash
# shellcheck shell=bash
# Exit codes, logging, temporary files. Depends on nothing.
[ -n "${ZRO_LIB_CORE_LOADED:-}" ] && return 0
ZRO_LIB_CORE_LOADED=1

# Success
ZRO_E_OK=0
# Input and lookup
ZRO_E_INPUT=10
ZRO_E_NO_ACCOUNT=11
ZRO_E_NO_MAILBOX=12
ZRO_E_NO_FOLDER=13
ZRO_E_NO_RESULT=14
# Environment
ZRO_E_PERM=20
ZRO_E_UNAVAILABLE=21
ZRO_E_TIMEOUT=22
ZRO_E_NO_LOG=23
# Bulk
ZRO_E_PARTIAL=30
# Navigation. Never becomes a process exit status.
ZRO_E_CANCEL=40
# Safety. Any of these is a defect, not operator error.
ZRO_E_DENIED=90
ZRO_E_BADUSER=91
ZRO_E_NOCAP=92

# Activity logging is off unless the administrator sets ZRO_LOG_FILE.
ZRO_LOG_FILE="${ZRO_LOG_FILE:-}"

zro_log() {
  local level=$1
  shift
  local line
  line="$(date '+%Y-%m-%dT%H:%M:%S%z') [$level] $*"
  printf '%s\n' "$line" >&2
  if [ -n "$ZRO_LOG_FILE" ]; then
    printf '%s\n' "$line" >>"$ZRO_LOG_FILE" 2>/dev/null || true
  fi
}

# Prints the first argument that is an executable file. Used to resolve system
# binaries explicitly instead of trusting PATH.
zro_first_existing() {
  local p
  for p in "$@"; do
    if [ -x "$p" ]; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

ZRO_TMPFILES=""

zro_tmpfile() {
  local f
  f=$(umask 077; mktemp "${TMPDIR:-/tmp}/zro.XXXXXXXX") || return 1
  ZRO_TMPFILES="$ZRO_TMPFILES $f"
  printf '%s' "$f"
}

zro_cleanup() {
  local f
  for f in $ZRO_TMPFILES; do
    [ -e "$f" ] && rm -f -- "$f"
  done
  ZRO_TMPFILES=""
}

zro_human_bytes() {
  local n=$1
  case $n in
    ''|*[!0-9]*) return "$ZRO_E_INPUT" ;;
  esac
  if [ "$n" -lt 1024 ]; then
    printf '%s B' "$n"
    return 0
  fi
  local units="KB MB GB TB PB" unit value=$n scaled
  for unit in $units; do
    scaled=$(( value * 10 / 1024 ))
    value=$(( value / 1024 ))
    if [ "$value" -lt 1024 ]; then
      printf '%s.%s %s' "$value" "$(( scaled % 10 ))" "$unit"
      return 0
    fi
  done
  printf '%s.%s PB' "$value" "$(( scaled % 10 ))"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_core.sh` passes; total failures 0.

- [ ] **Step 5: Run ShellCheck**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && shellcheck lib/core.sh tests/test_core.sh tests/lib/assert.sh tests/run.sh'`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/core.sh tests/test_core.sh
git commit -m "feat: add core module with exit codes, logging and temp files"
```

---

### Task 3: `lib/validate.sh` — email and domain validators

**Files:**
- Create: `lib/validate.sh`
- Test: `tests/test_validate.sh`

**Interfaces:**
- Consumes: `lib/core.sh` (`ZRO_E_INPUT`).
- Produces: `zro_validate_domain <value>` → 0 or `ZRO_E_INPUT`, no output; `zro_validate_email <value>` → 0 or `ZRO_E_INPUT`, no output. `zro_validate_email` delegates the right-hand side to `zro_validate_domain`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_validate.sh`:

```bash
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
assert_status "$ZRO_E_INPUT" zro_validate_email '$(id)@b.com'
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
long_local=$(printf 'a%.0s' $(seq 1 65))
assert_status "$ZRO_E_INPUT" zro_validate_email "${long_local}@b.com"
long_label=$(printf 'a%.0s' $(seq 1 64))
assert_status "$ZRO_E_INPUT" zro_validate_email "a@${long_label}.com"

it "validates bare domains"
assert_ok zro_validate_domain 'example.com'
assert_ok zro_validate_domain 'mail.example.co.uk'
assert_status "$ZRO_E_INPUT" zro_validate_domain '@example.com'
assert_status "$ZRO_E_INPUT" zro_validate_domain 'example'
assert_status "$ZRO_E_INPUT" zro_validate_domain 'exa mple.com'
assert_status "$ZRO_E_INPUT" zro_validate_domain 'example.com; id'

zro_t_report
```

- [ ] **Step 2: Run it to verify it fails**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_validate.sh CRASHED` — `lib/validate.sh: No such file or directory`.

- [ ] **Step 3: Write `lib/validate.sh`**

```bash
# shellcheck shell=bash
# Input validators. Pure functions: a return status, never output.
[ -n "${ZRO_LIB_VALIDATE_LOADED:-}" ] && return 0
ZRO_LIB_VALIDATE_LOADED=1

# A DNS label: alphanumeric ends, hyphens allowed only in the middle.
ZRO_RE_LABEL='[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?'
# Local part: the conservative subset Zimbra accounts actually use.
ZRO_RE_LOCAL='[A-Za-z0-9._%+-]+'

zro_validate_domain() {
  local d=${1-}
  [ -n "$d" ] || return "$ZRO_E_INPUT"
  [ "${#d}" -le 253 ] || return "$ZRO_E_INPUT"

  # At least two labels and an alphabetic TLD of two or more characters.
  [[ $d =~ ^${ZRO_RE_LABEL}(\.${ZRO_RE_LABEL})*\.[A-Za-z]{2,}$ ]] || return "$ZRO_E_INPUT"

  # No individual label may exceed 63 characters.
  local label
  local IFS=.
  for label in $d; do
    [ "${#label}" -le 63 ] || return "$ZRO_E_INPUT"
  done
  return 0
}

zro_validate_email() {
  local e=${1-}
  [ -n "$e" ] || return "$ZRO_E_INPUT"
  [ "${#e}" -le 320 ] || return "$ZRO_E_INPUT"

  # Exactly one @, splitting into a local part and a domain.
  local local_part=${e%@*}
  local domain_part=${e##*@}
  [ "$local_part@$domain_part" = "$e" ] || return "$ZRO_E_INPUT"

  [ -n "$local_part" ] || return "$ZRO_E_INPUT"
  [ "${#local_part}" -le 64 ] || return "$ZRO_E_INPUT"
  [[ $local_part =~ ^${ZRO_RE_LOCAL}$ ]] || return "$ZRO_E_INPUT"

  # A value starting with '-' would be read as a flag by any CLI it reaches.
  case $e in -*) return "$ZRO_E_INPUT" ;; esac

  zro_validate_domain "$domain_part" || return "$ZRO_E_INPUT"
  return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: all `test_validate.sh` assertions pass.

If `a@b..com` passes, the empty-label case is leaking: `ZRO_RE_LABEL` requires at least one character, so confirm the regex was written without an extra `?` after the group.

- [ ] **Step 5: Run ShellCheck**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && shellcheck lib/validate.sh tests/test_validate.sh'`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/validate.sh tests/test_validate.sh
git commit -m "feat: add email and domain validators"
```

---

### Task 4: Mock binaries and fixtures

**Files:**
- Create: `tests/mocks/mock_common.sh`
- Create: `tests/mocks/bin/zmprov`, `tests/mocks/bin/zmcontrol`, `tests/mocks/bin/runuser`, `tests/mocks/bin/timeout`, `tests/mocks/bin/id`
- Create: `tests/fixtures/zmcontrol_v.txt`
- Test: `tests/test_mocks.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: mocks that append one TAB-separated line per invocation to `$ZRO_MOCK_LOG`, then reply according to environment variables. Response variables are named `ZRO_MOCK_<BIN>_<TOKEN>_OUT` (file to write to stdout), `_ERR` (file to write to stderr) and `_RC` (exit status), with every character outside `[A-Za-z0-9_]` in `<TOKEN>` replaced by `_` and the whole name upper-cased. `runuser` and `timeout` record, then `exec` the remainder so the chain continues. `ZRO_MOCK_TIMEOUT_FIRE=1` makes the `timeout` mock exit 124 instead. `ZRO_MOCK_ID_USER` sets what the `id` mock prints.

- [ ] **Step 1: Write the failing test**

Create `tests/test_mocks.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
MOCKBIN="$ZRO_TEST_ROOT/mocks/bin"
chmod +x "$MOCKBIN"/* 2>/dev/null || true

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG

it "records the exact argument vector it received"
: >"$ZRO_MOCK_LOG"
"$MOCKBIN/zmprov" ga 'user@example.com' zimbraMailQuota >/dev/null 2>&1
assert_eq "$(cat "$ZRO_MOCK_LOG")" "$(printf 'zmprov\tga\tuser@example.com\tzimbraMailQuota')"

it "records an argument containing spaces as one field"
: >"$ZRO_MOCK_LOG"
"$MOCKBIN/zmprov" ga 'subject with spaces' >/dev/null 2>&1
assert_eq "$(cat "$ZRO_MOCK_LOG")" "$(printf 'zmprov\tga\tsubject with spaces')"

it "writes the configured fixture to stdout"
fixture=$(mktemp); printf 'zimbraAccountStatus: active\n' >"$fixture"
ZRO_MOCK_ZMPROV_GA_OUT="$fixture" assert_out_eq "zimbraAccountStatus: active" "$MOCKBIN/zmprov" ga x
rm -f -- "$fixture"

it "exits with the configured status"
ZRO_MOCK_ZMPROV_GA_RC=1 assert_status 1 "$MOCKBIN/zmprov" ga x

it "runuser strips its own flags and execs the rest"
: >"$ZRO_MOCK_LOG"
"$MOCKBIN/runuser" -u zimbra -- "$MOCKBIN/zmprov" gmi 'a@b.com' >/dev/null 2>&1
assert_contains "$(cat "$ZRO_MOCK_LOG")" "runuser"
assert_contains "$(cat "$ZRO_MOCK_LOG")" "zmprov"

it "timeout strips -k and the duration, then execs"
: >"$ZRO_MOCK_LOG"
"$MOCKBIN/timeout" -k 5 60 "$MOCKBIN/zmprov" ga 'a@b.com' >/dev/null 2>&1
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'timeout\t-k\t5\t60')"
assert_contains "$(cat "$ZRO_MOCK_LOG")" "zmprov"

it "timeout can simulate expiry"
ZRO_MOCK_TIMEOUT_FIRE=1 assert_status 124 "$MOCKBIN/timeout" -k 5 60 "$MOCKBIN/zmprov" ga x

it "id reports the configured user"
ZRO_MOCK_ID_USER=root assert_out_eq "root" "$MOCKBIN/id" -un

rm -f -- "$ZRO_MOCK_LOG"
zro_t_report
```

- [ ] **Step 2: Run it to verify it fails**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_mocks.sh` fails — the mock binaries do not exist.

- [ ] **Step 3: Write `tests/mocks/mock_common.sh`**

```bash
# shellcheck shell=bash
# Shared behaviour for the fake Zimbra binaries.

# Appends one TAB-separated line: the binary name followed by each argument.
# Tests assert on this line, which is what proves no word splitting or
# unintended flag reached the real command.
zro_mock_record() {
  local name=$1
  shift
  local line=$name arg
  for arg in "$@"; do
    line="$line	$arg"
  done
  [ -n "${ZRO_MOCK_LOG:-}" ] && printf '%s\n' "$line" >>"$ZRO_MOCK_LOG"
  return 0
}

# Replies according to ZRO_MOCK_<BIN>_<TOKEN>_{OUT,ERR,RC}.
zro_mock_respond() {
  local name=$1 token=${2:-}
  local key="ZRO_MOCK_${name}_${token}"
  key=${key//[^A-Za-z0-9_]/_}
  key=$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')

  local out_var="${key}_OUT" err_var="${key}_ERR" rc_var="${key}_RC"
  local out=${!out_var:-} err=${!err_var:-} rc=${!rc_var:-0}

  [ -n "$out" ] && [ -f "$out" ] && cat -- "$out"
  [ -n "$err" ] && [ -f "$err" ] && cat -- "$err" >&2
  exit "$rc"
}
```

- [ ] **Step 4: Write the mock binaries**

`tests/mocks/bin/zmprov`:

```bash
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=../mock_common.sh
. "${ZRO_MOCK_LIB:?ZRO_MOCK_LIB is required}/mock_common.sh"
zro_mock_record zmprov "$@"
zro_mock_respond zmprov "${1:-}"
```

`tests/mocks/bin/zmcontrol` — identical but with `zmcontrol` in both calls.

`tests/mocks/bin/runuser`:

```bash
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=../mock_common.sh
. "${ZRO_MOCK_LIB:?ZRO_MOCK_LIB is required}/mock_common.sh"
zro_mock_record runuser "$@"
while [ $# -gt 0 ]; do
  case $1 in
    -u) shift 2 ;;
    --) shift; break ;;
    *)  break ;;
  esac
done
[ $# -gt 0 ] || exit 0
exec "$@"
```

`tests/mocks/bin/timeout`:

```bash
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=../mock_common.sh
. "${ZRO_MOCK_LIB:?ZRO_MOCK_LIB is required}/mock_common.sh"
zro_mock_record timeout "$@"
while [ $# -gt 0 ]; do
  case $1 in
    -k) shift 2 ;;
    -*) shift ;;
    *)  break ;;
  esac
done
# The first non-flag argument is the duration.
[ $# -gt 0 ] && shift
[ -n "${ZRO_MOCK_TIMEOUT_FIRE:-}" ] && exit 124
[ $# -gt 0 ] || exit 0
exec "$@"
```

`tests/mocks/bin/id`:

```bash
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=../mock_common.sh
. "${ZRO_MOCK_LIB:?ZRO_MOCK_LIB is required}/mock_common.sh"
zro_mock_record id "$@"
printf '%s\n' "${ZRO_MOCK_ID_USER:-nobody}"
```

- [ ] **Step 5: Add the version fixture**

`tests/fixtures/zmcontrol_v.txt`:

```
Release 10.0.8.GA.4518.UBUNTU20.64 UBUNTU20_64 FOSS edition, Patch 10.0.8_P1.
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_mocks.sh` passes.

Every later test file configures a mock with a one-shot assignment in front of a
function call — `ZRO_MOCK_ZMPROV_GA_RC=1 assert_status 1 ...`. Bash places such
assignments in the called command's environment and restores them afterwards, so
they reach the mock process and do not leak into the next assertion. If a test
ever behaves as though the variable did not arrive, replace that one line with an
explicit `export VAR=…` before the call and `unset VAR` after it; do not scatter
exports pre-emptively, because a leaked mock setting makes a later test pass for
the wrong reason.

- [ ] **Step 7: Run ShellCheck**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && shellcheck tests/mocks/mock_common.sh tests/mocks/bin/* tests/test_mocks.sh'`
Expected: no output.

- [ ] **Step 8: Commit**

```bash
git update-index --chmod=+x tests/mocks/bin/zmprov tests/mocks/bin/zmcontrol \
  tests/mocks/bin/runuser tests/mocks/bin/timeout tests/mocks/bin/id
git add tests/mocks tests/fixtures tests/test_mocks.sh
git commit -m "test: add argv-recording mocks for the Zimbra and system binaries"
```

---

### Task 5: `lib/exec.sh` — the allowlist

**Files:**
- Create: `lib/exec.sh`
- Test: `tests/test_exec_allowlist.sh`

**Interfaces:**
- Consumes: `lib/core.sh`.
- Produces: `ZRO_ALLOW` (a newline-separated list of `binary:token` entries); `zro_allowed <binary> <token>` → 0 when listed, 1 otherwise; `zro_allow_entries` → prints one entry per line, used by the static scanner in Task 14.

- [ ] **Step 1: Write the failing test**

Create `tests/test_exec_allowlist.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"

it "allows every M1 read operation in both forms"
assert_ok zro_allowed zmprov ga
assert_ok zro_allowed zmprov getAccount
assert_ok zro_allowed zmprov gmi
assert_ok zro_allowed zmprov getMailboxInfo
assert_ok zro_allowed zmprov gam
assert_ok zro_allowed zmprov getAccountMembership
assert_ok zro_allowed zmprov gc
assert_ok zro_allowed zmprov getCos
assert_ok zro_allowed zmcontrol -v

it "denies every write verb"
for sub in ca ma da dm mm mmr ef df createAccount modifyAccount deleteAccount \
           deleteMessage moveMessage markMessageRead emptyFolder addMessage; do
  assert_fail zro_allowed zmprov "$sub"
  assert_fail zro_allowed zmmailbox "$sub"
done

it "denies a binary that is not on the list at all"
assert_fail zro_allowed zmmailbox search
assert_fail zro_allowed bash -c
assert_fail zro_allowed sh -c
assert_fail zro_allowed rm -rf

it "does not match on a prefix or a substring"
assert_fail zro_allowed zmprov g
assert_fail zro_allowed zmprov gam2
assert_fail zro_allowed zmprov 'ga extra'
assert_fail zro_allowed zmpro ga
assert_fail zro_allowed zmprovX ga

it "rejects empty arguments"
assert_fail zro_allowed "" ga
assert_fail zro_allowed zmprov ""

it "the allowlist itself contains no write verb"
entries=$(zro_allow_entries)
for verb in create modify delete remove move mark flag tag empty import post recover sync; do
  assert_not_contains "$entries" "$verb"
done

zro_t_report
```

- [ ] **Step 2: Run it to verify it fails**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_exec_allowlist.sh CRASHED` — `lib/exec.sh: No such file or directory`.

- [ ] **Step 3: Write the allowlist half of `lib/exec.sh`**

```bash
# shellcheck shell=bash
# The exec gate. Every external command in this program passes through here.
[ -n "${ZRO_LIB_EXEC_LOADED:-}" ] && return 0
ZRO_LIB_EXEC_LOADED=1

# The complete set of commands this program may run, as exact two-token argv
# prefixes: "<binary>:<token>". The token is positional, not semantic — it is
# whatever follows the binary, whether a subcommand (zmprov ga) or a flag
# (zmcontrol -v). Both the long and short form of each subcommand is listed.
#
# Adding an entry here is the second of two deliberate edits required to give
# this program a new capability. Nothing outside this list can be executed.
ZRO_ALLOW='
zmprov:ga
zmprov:getAccount
zmprov:gmi
zmprov:getMailboxInfo
zmprov:gam
zmprov:getAccountMembership
zmprov:gc
zmprov:getCos
zmcontrol:-v
'

zro_allow_entries() {
  printf '%s' "$ZRO_ALLOW" | grep -v '^[[:space:]]*$'
}

zro_allowed() {
  local bin=${1-} token=${2-}
  [ -n "$bin" ] || return 1
  [ -n "$token" ] || return 1
  local entry
  while IFS= read -r entry; do
    [ "$entry" = "$bin:$token" ] && return 0
  done <<EOF
$(zro_allow_entries)
EOF
  return 1
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_exec_allowlist.sh` passes. The comparison is a full-string equality, so prefix and substring cases fail as required.

- [ ] **Step 5: Run ShellCheck**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && shellcheck lib/exec.sh tests/test_exec_allowlist.sh'`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/exec.sh tests/test_exec_allowlist.sh
git commit -m "feat: add the central command allowlist"
```

---

### Task 6: `lib/exec.sh` — identity mode

**Files:**
- Modify: `lib/exec.sh`
- Test: `tests/test_exec_identity.sh`

**Interfaces:**
- Consumes: `lib/core.sh`, the `id` mock from Task 4.
- Produces: `ZRO_ID_BIN`, `ZRO_RUNUSER`, `ZRO_TIMEOUT_BIN`, `ZRO_ZIMBRA_BIN`, `ZRO_TIMEOUT`; `zro_current_user` → prints the current user name via `$ZRO_ID_BIN -un`; `zro_identity_mode <user>` → prints `direct` for `zimbra`, `runuser` for `root`, returns `ZRO_E_BADUSER` for anything else.

Identity is decided by a pure function taking the user name as an argument, and the user name comes from a mockable binary path. There is deliberately **no environment variable that overrides the identity decision itself** — a safety check must not have an off switch.

- [ ] **Step 1: Write the failing test**

Create `tests/test_exec_identity.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* 2>/dev/null || true

# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"

it "runs directly as zimbra"
assert_out_eq "direct" zro_identity_mode zimbra

it "wraps in runuser as root"
assert_out_eq "runuser" zro_identity_mode root

it "refuses every other user"
assert_status "$ZRO_E_BADUSER" zro_identity_mode nobody
assert_status "$ZRO_E_BADUSER" zro_identity_mode postfix
assert_status "$ZRO_E_BADUSER" zro_identity_mode ''
assert_status "$ZRO_E_BADUSER" zro_identity_mode 'zimbra x'
assert_status "$ZRO_E_BADUSER" zro_identity_mode 'ZIMBRA'
assert_status "$ZRO_E_BADUSER" zro_identity_mode 'zimbra2'

it "reads the current user from the resolved id binary"
ZRO_MOCK_ID_USER=root assert_out_eq "root" zro_current_user
ZRO_MOCK_ID_USER=zimbra assert_out_eq "zimbra" zro_current_user

it "resolves production defaults when no override is set"
( unset ZRO_ID_BIN
  unset ZRO_LIB_EXEC_LOADED
  # shellcheck source=../lib/exec.sh
  . "$ZRO_SRC/lib/exec.sh"
  case $ZRO_ID_BIN in
    /usr/bin/id|/bin/id) exit 0 ;;
    *) exit 1 ;;
  esac )
assert_status 0 true

zro_t_report
```

- [ ] **Step 2: Run it to verify it fails**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_exec_identity.sh` fails — `zro_identity_mode: command not found`.

- [ ] **Step 3: Add identity handling to `lib/exec.sh`**

Insert after the allowlist block, before the closing of the file:

```bash
# Binary locations. Production defaults, overridable so the suite can point at
# mocks. Never write one of these paths as a literal in module code.
ZRO_ZIMBRA_BIN="${ZRO_ZIMBRA_BIN:-/opt/zimbra/bin}"
ZRO_RUNUSER="${ZRO_RUNUSER:-$(zro_first_existing /sbin/runuser /usr/sbin/runuser /bin/runuser || printf '')}"
ZRO_TIMEOUT_BIN="${ZRO_TIMEOUT_BIN:-$(zro_first_existing /usr/bin/timeout /bin/timeout || printf '')}"
ZRO_ID_BIN="${ZRO_ID_BIN:-$(zro_first_existing /usr/bin/id /bin/id || printf '')}"
ZRO_TIMEOUT="${ZRO_TIMEOUT:-60}"

zro_current_user() {
  [ -n "$ZRO_ID_BIN" ] || return "$ZRO_E_UNAVAILABLE"
  "$ZRO_ID_BIN" -un
}

# Pure: the identity decision is a function of the user name alone, and has no
# environment override. Mocking happens one level down, at $ZRO_ID_BIN.
zro_identity_mode() {
  case ${1-} in
    zimbra) printf 'direct' ;;
    root)   printf 'runuser' ;;
    *)      return "$ZRO_E_BADUSER" ;;
  esac
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_exec_identity.sh` passes.

- [ ] **Step 5: Run ShellCheck**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && shellcheck lib/exec.sh tests/test_exec_identity.sh'`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/exec.sh tests/test_exec_identity.sh
git commit -m "feat: add identity mode selection with no override switch"
```

---

### Task 7: `lib/exec.sh` — `zro_exec`

**Files:**
- Modify: `lib/exec.sh`
- Test: `tests/test_exec.sh`

**Interfaces:**
- Consumes: `lib/core.sh`, `lib/capability.sh` is **not** required — availability is a filesystem check implemented here as `zro_bin_available` and re-exported for Task 8 to build on.
- Produces: `zro_bin_available <binary>` → 0 when `$ZRO_ZIMBRA_BIN/<binary>` is an executable file; `zro_exec <binary> <token> [args...]` → runs the command and returns its status, with `124` normalised to `ZRO_E_TIMEOUT`, `ZRO_E_DENIED` when not allowlisted, `ZRO_E_NOCAP` when the binary is missing, `ZRO_E_BADUSER` when the OS user is unsupported.

Order inside the gate is fixed: allowlist, availability, identity, argv, run.

- [ ] **Step 1: Write the failing test**

Create `tests/test_exec.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
export ZRO_TIMEOUT=60
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* 2>/dev/null || true

# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG

it "denies a command outside the allowlist and never executes it"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" zro_exec zmprov ma 'a@b.com'
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "denies a binary that is not on the list at all"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra assert_status "$ZRO_E_DENIED" zro_exec zmmailbox search 'x'
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "reports a missing binary as a capability failure"
: >"$ZRO_MOCK_LOG"
ZRO_ZIMBRA_BIN=/nonexistent ZRO_MOCK_ID_USER=zimbra \
  assert_status "$ZRO_E_NOCAP" zro_exec zmprov ga 'a@b.com'

it "refuses to run as an unsupported operating-system user"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=nobody assert_status "$ZRO_E_BADUSER" zro_exec zmprov ga 'a@b.com'
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "as zimbra, wraps in timeout but not in runuser"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra zro_exec zmprov ga 'a@b.com' >/dev/null 2>&1
log=$(cat "$ZRO_MOCK_LOG")
assert_not_contains "$log" "runuser"
assert_contains "$log" "$(printf 'timeout\t-k\t5\t60')"
assert_contains "$log" "$(printf 'zmprov\tga\ta@b.com')"

it "as root, places timeout inside the runuser wrapper"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=root zro_exec zmprov ga 'a@b.com' >/dev/null 2>&1
first=$(head -n 1 "$ZRO_MOCK_LOG")
assert_contains "$first" "$(printf 'runuser\t-u\tzimbra\t--')"
assert_contains "$first" "timeout"
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'zmprov\tga\ta@b.com')"

it "passes an argument containing spaces as a single field"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra zro_exec zmprov ga 'a b@c.com' >/dev/null 2>&1
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'zmprov\tga\ta b@c.com')"

it "passes shell metacharacters through as literal data"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=zimbra zro_exec zmprov ga 'x; touch /tmp/zro_pwned' >/dev/null 2>&1
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'zmprov\tga\tx; touch /tmp/zro_pwned')"
assert_fail test -e /tmp/zro_pwned

it "normalises a timeout to the documented exit code"
ZRO_MOCK_ID_USER=zimbra ZRO_MOCK_TIMEOUT_FIRE=1 \
  assert_status "$ZRO_E_TIMEOUT" zro_exec zmprov ga 'a@b.com'

it "passes through the command's own failure status"
ZRO_MOCK_ID_USER=zimbra ZRO_MOCK_ZMPROV_GA_RC=2 \
  assert_status 2 zro_exec zmprov ga 'a@b.com'

it "returns the command's stdout unchanged"
fixture=$(mktemp); printf 'zimbraAccountStatus: active\n' >"$fixture"
ZRO_MOCK_ID_USER=zimbra ZRO_MOCK_ZMPROV_GA_OUT="$fixture" \
  assert_out_eq "zimbraAccountStatus: active" zro_exec zmprov ga 'a@b.com'
rm -f -- "$fixture"

it "zro_bin_available reflects the filesystem"
assert_ok zro_bin_available zmprov
assert_fail zro_bin_available zmmailbox
assert_fail zro_bin_available 'zmprov; rm -rf /'

rm -f -- "$ZRO_MOCK_LOG"
zro_t_report
```

- [ ] **Step 2: Run it to verify it fails**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_exec.sh` fails — `zro_exec: command not found`.

- [ ] **Step 3: Add `zro_exec` to `lib/exec.sh`**

Append:

```bash
zro_bin_available() {
  local bin=${1-}
  [ -n "$bin" ] || return 1
  [ -x "$ZRO_ZIMBRA_BIN/$bin" ]
}

# The only path from this program to an external command.
#
#   $1  binary name, resolved under $ZRO_ZIMBRA_BIN
#   $2  the token that follows it (subcommand or flag)
#   $@  already-validated arguments, passed as separate argv elements
#
# Nothing here builds a string. There is no eval, no `sh -c`, and no path a
# caller can take to run something the allowlist does not name.
zro_exec() {
  local bin=${1-} token=${2-}
  [ $# -ge 2 ] || return "$ZRO_E_DENIED"
  shift 2

  if ! zro_allowed "$bin" "$token"; then
    zro_log error "denied by allowlist: $bin $token"
    return "$ZRO_E_DENIED"
  fi

  if ! zro_bin_available "$bin"; then
    zro_log error "not available on this host: $ZRO_ZIMBRA_BIN/$bin"
    return "$ZRO_E_NOCAP"
  fi

  local mode
  mode=$(zro_identity_mode "$(zro_current_user)") || return "$ZRO_E_BADUSER"

  [ -n "$ZRO_TIMEOUT_BIN" ] || return "$ZRO_E_UNAVAILABLE"

  local -a argv
  argv=( "$ZRO_TIMEOUT_BIN" -k 5 "$ZRO_TIMEOUT" "$ZRO_ZIMBRA_BIN/$bin" "$token" "$@" )

  if [ "$mode" = runuser ]; then
    [ -n "$ZRO_RUNUSER" ] || return "$ZRO_E_UNAVAILABLE"
    # timeout goes INSIDE the wrapper: killing runuser from outside would
    # leave the Zimbra JVM running.
    argv=( "$ZRO_RUNUSER" -u zimbra -- "${argv[@]}" )
  fi

  local rc=0
  "${argv[@]}" || rc=$?
  [ "$rc" -eq 124 ] && rc=$ZRO_E_TIMEOUT
  return "$rc"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_exec.sh` passes, all twelve groups.

- [ ] **Step 5: Run ShellCheck**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && shellcheck lib/exec.sh tests/test_exec.sh'`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/exec.sh tests/test_exec.sh
git commit -m "feat: add the exec gate with allowlist, identity and timeout"
```

---

### Task 8: `lib/capability.sh`

**Files:**
- Create: `lib/capability.sh`
- Test: `tests/test_capability.sh`

**Interfaces:**
- Consumes: `lib/core.sh`, `lib/exec.sh` (`zro_exec`, `zro_bin_available`).
- Produces: `zro_cap_version` → prints the cached `zmcontrol -v` line, or the value of `ZRO_CAP_FORCE` when set; `zro_cap_reset` → clears the cache; `zro_cap_op_available <binary> <token>` → 0 when the pair is both allowlisted and present on this host.

The probe cannot recurse: availability is a filesystem test, and only the version lookup goes through `zro_exec`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_capability.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* 2>/dev/null || true

# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"
# shellcheck source=../lib/capability.sh
. "$ZRO_SRC/lib/capability.sh"

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG
export ZRO_MOCK_ID_USER=zimbra
export ZRO_MOCK_ZMCONTROL__V_OUT="$ZRO_TEST_ROOT/fixtures/zmcontrol_v.txt"

it "reads the version through the exec gate"
zro_cap_reset
assert_contains "$(zro_cap_version)" "Release 10.0.8"

it "caches the version, running zmcontrol only once"
zro_cap_reset
: >"$ZRO_MOCK_LOG"
zro_cap_version >/dev/null
zro_cap_version >/dev/null
zro_cap_version >/dev/null
assert_eq "$(grep -c '^zmcontrol' "$ZRO_MOCK_LOG")" "1"

it "ZRO_CAP_FORCE replaces the probe entirely"
zro_cap_reset
: >"$ZRO_MOCK_LOG"
ZRO_CAP_FORCE="Release 8.8.15" assert_out_eq "Release 8.8.15" zro_cap_version
assert_eq "$(grep -c '^zmcontrol' "$ZRO_MOCK_LOG")" "0"

it "an operation is available only when allowlisted and present"
assert_ok zro_cap_op_available zmprov ga
assert_fail zro_cap_op_available zmprov ma
assert_fail zro_cap_op_available zmmailbox search

it "an allowlisted operation whose binary is missing is unavailable"
ZRO_ZIMBRA_BIN=/nonexistent assert_fail zro_cap_op_available zmprov ga

rm -f -- "$ZRO_MOCK_LOG"
zro_t_report
```

- [ ] **Step 2: Run it to verify it fails**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_capability.sh CRASHED` — `lib/capability.sh: No such file or directory`.

- [ ] **Step 3: Write `lib/capability.sh`**

```bash
# shellcheck shell=bash
# Runtime facts about this host. The Zimbra version is not pinned anywhere in
# this program; it is observed once per session and cached.
[ -n "${ZRO_LIB_CAPABILITY_LOADED:-}" ] && return 0
ZRO_LIB_CAPABILITY_LOADED=1

ZRO_CAP_VERSION_CACHE=""

zro_cap_reset() {
  ZRO_CAP_VERSION_CACHE=""
}

zro_cap_version() {
  if [ -n "${ZRO_CAP_FORCE:-}" ]; then
    printf '%s' "$ZRO_CAP_FORCE"
    return 0
  fi
  if [ -z "$ZRO_CAP_VERSION_CACHE" ]; then
    ZRO_CAP_VERSION_CACHE=$(zro_exec zmcontrol -v 2>/dev/null | head -n 1)
  fi
  printf '%s' "$ZRO_CAP_VERSION_CACHE"
}

# An operation is offered only when the allowlist names it AND the binary is
# actually installed here. Menus grey out what this rejects instead of letting
# the operator select something that will fail.
zro_cap_op_available() {
  local bin=${1-} token=${2-}
  zro_allowed "$bin" "$token" || return 1
  zro_bin_available "$bin" || return 1
  return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_capability.sh` passes.

- [ ] **Step 5: Run ShellCheck**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && shellcheck lib/capability.sh tests/test_capability.sh'`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/capability.sh tests/test_capability.sh
git commit -m "feat: add runtime capability probe with session caching"
```

---

### Task 9: `lib/ui.sh` — stub backend

**Files:**
- Create: `lib/ui.sh`
- Test: `tests/test_ui.sh`

**Interfaces:**
- Consumes: `lib/core.sh` (`ZRO_E_CANCEL`).
- Produces: `zro_ui_menu <title> <text> <tag> <label> [<tag> <label>...]` → prints the chosen tag, returns `ZRO_E_CANCEL` on cancel; `zro_ui_input <title> <text> [default]` → prints the entered value, returns `ZRO_E_CANCEL` on cancel; `zro_ui_msgbox <title> <text>`; `zro_ui_textbox <title> <file>`; `zro_ui_yesno <title> <text>` → 0 for yes, 1 for no.
- Stub contract: with `ZRO_UI_BACKEND=stub`, each prompting call consumes the next line of `$ZRO_UI_QUEUE`; the literal line `__CANCEL__` returns `ZRO_E_CANCEL`; an exhausted queue also returns `ZRO_E_CANCEL`. Every display call appends to `$ZRO_UI_OUT`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_ui.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/ui.sh
. "$ZRO_SRC/lib/ui.sh"

export ZRO_UI_BACKEND=stub
ZRO_UI_QUEUE=$(mktemp); export ZRO_UI_QUEUE
ZRO_UI_OUT=$(mktemp);   export ZRO_UI_OUT

queue() { printf '%s\n' "$@" >"$ZRO_UI_QUEUE"; zro_ui_reset; }

it "returns the tag the operator selected"
queue "2"
assert_out_eq "2" zro_ui_menu "Ana Menu" "Secim" 1 "Hesap" 2 "Kota"

it "consumes one queue line per prompt, in order"
queue "1" "ahmet@example.com"
assert_out_eq "1" zro_ui_menu "Ana Menu" "Secim" 1 "Hesap"
assert_out_eq "ahmet@example.com" zro_ui_input "Hesap" "Adres"

it "reports cancel distinctly from an error"
queue "__CANCEL__"
assert_status "$ZRO_E_CANCEL" zro_ui_menu "Ana Menu" "Secim" 1 "Hesap"

it "reports cancel on an input prompt"
queue "__CANCEL__"
assert_status "$ZRO_E_CANCEL" zro_ui_input "Hesap" "Adres"

it "treats an exhausted queue as cancel rather than hanging"
queue
assert_status "$ZRO_E_CANCEL" zro_ui_menu "Ana Menu" "Secim" 1 "Hesap"

it "captures displayed messages"
queue
: >"$ZRO_UI_OUT"
zro_ui_msgbox "Hata" "Hesap bulunamadi"
assert_contains "$(cat "$ZRO_UI_OUT")" "Hesap bulunamadi"

it "captures displayed files"
queue
: >"$ZRO_UI_OUT"
body=$(mktemp); printf 'zimbraAccountStatus: active\n' >"$body"
zro_ui_textbox "Ozet" "$body"
assert_contains "$(cat "$ZRO_UI_OUT")" "zimbraAccountStatus: active"
rm -f -- "$body"

it "answers yes/no from the queue"
queue "yes"
assert_status 0 zro_ui_yesno "Onay" "Devam?"
queue "no"
assert_status 1 zro_ui_yesno "Onay" "Devam?"

it "never writes prompt chrome to stdout"
queue "1"
assert_out_eq "1" zro_ui_menu "Ana Menu" "Bu metin stdout'a gitmemeli" 1 "Hesap"

rm -f -- "$ZRO_UI_QUEUE" "$ZRO_UI_OUT"
zro_t_report
```

- [ ] **Step 2: Run it to verify it fails**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_ui.sh CRASHED` — `lib/ui.sh: No such file or directory`.

- [ ] **Step 3: Write `lib/ui.sh` with the stub backend only**

```bash
# shellcheck shell=bash
# The only path from this program to the screen. Two backends: whiptail for
# real use, stub for the test suite, behind one interface.
[ -n "${ZRO_LIB_UI_LOADED:-}" ] && return 0
ZRO_LIB_UI_LOADED=1

ZRO_UI_BACKEND="${ZRO_UI_BACKEND:-whiptail}"
ZRO_UI_QUEUE="${ZRO_UI_QUEUE:-}"
ZRO_UI_OUT="${ZRO_UI_OUT:-}"
ZRO_UI_QUEUE_POS=0

zro_ui_reset() {
  ZRO_UI_QUEUE_POS=0
}

# Pops the next scripted answer. An exhausted queue reads as cancel, so a
# mis-scripted test fails fast instead of blocking.
zro_ui_stub_next() {
  [ -n "$ZRO_UI_QUEUE" ] || return "$ZRO_E_CANCEL"
  ZRO_UI_QUEUE_POS=$((ZRO_UI_QUEUE_POS + 1))
  local line
  line=$(sed -n "${ZRO_UI_QUEUE_POS}p" "$ZRO_UI_QUEUE")
  [ -n "$line" ] || return "$ZRO_E_CANCEL"
  [ "$line" = "__CANCEL__" ] && return "$ZRO_E_CANCEL"
  printf '%s' "$line"
}

zro_ui_stub_show() {
  [ -n "$ZRO_UI_OUT" ] || return 0
  printf '%s\n' "$*" >>"$ZRO_UI_OUT"
}

zro_ui_menu() {
  local title=$1 text=$2
  shift 2
  if [ "$ZRO_UI_BACKEND" = stub ]; then
    zro_ui_stub_show "MENU $title: $text"
    zro_ui_stub_next
    return $?
  fi
  zro_ui_whiptail_menu "$title" "$text" "$@"
}

zro_ui_input() {
  local title=$1 text=$2 default=${3-}
  if [ "$ZRO_UI_BACKEND" = stub ]; then
    zro_ui_stub_show "INPUT $title: $text"
    zro_ui_stub_next
    return $?
  fi
  zro_ui_whiptail_input "$title" "$text" "$default"
}

zro_ui_msgbox() {
  local title=$1 text=$2
  if [ "$ZRO_UI_BACKEND" = stub ]; then
    zro_ui_stub_show "MSG $title: $text"
    return 0
  fi
  zro_ui_whiptail_msgbox "$title" "$text"
}

zro_ui_textbox() {
  local title=$1 file=$2
  if [ "$ZRO_UI_BACKEND" = stub ]; then
    zro_ui_stub_show "TEXT $title:"
    [ -n "$ZRO_UI_OUT" ] && cat -- "$file" >>"$ZRO_UI_OUT"
    return 0
  fi
  zro_ui_whiptail_textbox "$title" "$file"
}

zro_ui_yesno() {
  local title=$1 text=$2
  if [ "$ZRO_UI_BACKEND" = stub ]; then
    zro_ui_stub_show "YESNO $title: $text"
    local answer
    answer=$(zro_ui_stub_next) || return 1
    [ "$answer" = "yes" ]
    return $?
  fi
  zro_ui_whiptail_yesno "$title" "$text"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_ui.sh` passes. ShellCheck will report the `zro_ui_whiptail_*` calls as undefined until Task 10; that is expected and is not a ShellCheck error.

- [ ] **Step 5: Commit**

```bash
git add lib/ui.sh tests/test_ui.sh
git commit -m "feat: add UI seam with a scriptable stub backend"
```

---

### Task 10: `lib/ui.sh` — whiptail backend

**Files:**
- Modify: `lib/ui.sh`
- Test: `tests/test_ui_whiptail.sh`

**Interfaces:**
- Consumes: `lib/core.sh`.
- Produces: `zro_ui_whiptail_menu`, `zro_ui_whiptail_input`, `zro_ui_whiptail_msgbox`, `zro_ui_whiptail_textbox`, `zro_ui_whiptail_yesno`, `zro_ui_locale_ok`. Adds `ZRO_WHIPTAIL_BIN`.

whiptail writes its result to stderr and its chrome to the terminal, so results are captured with `3>&1 1>&2 2>&3`. The Turkish menu labels need a UTF-8 locale; `zro_ui_locale_ok` reports whether the current locale can render them, and the startup checks in Task 13 warn when it cannot.

- [ ] **Step 1: Write the failing test**

Create `tests/test_ui_whiptail.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/ui.sh
. "$ZRO_SRC/lib/ui.sh"

it "accepts a UTF-8 locale"
assert_ok zro_ui_locale_ok "tr_TR.UTF-8"
assert_ok zro_ui_locale_ok "en_US.utf8"
assert_ok zro_ui_locale_ok "C.UTF-8"

it "rejects a locale that cannot render Turkish labels"
assert_fail zro_ui_locale_ok "C"
assert_fail zro_ui_locale_ok "POSIX"
assert_fail zro_ui_locale_ok "en_US.ISO-8859-1"
assert_fail zro_ui_locale_ok ""

it "builds the whiptail menu argument vector without string assembly"
ZRO_WHIPTAIL_BIN=/nonexistent/whiptail
argv=$(zro_ui_whiptail_argv menu "Ana Menu" "Secim" 1 "Hesap ve kota" 2 "Cikis")
assert_contains "$argv" "--menu"
assert_contains "$argv" "Ana Menu"
assert_contains "$argv" "Hesap ve kota"
assert_contains "$argv" "--notags"

it "keeps a label containing spaces as one argument"
argv=$(zro_ui_whiptail_argv menu "T" "S" 1 "Hesap ve kota kontrolleri")
assert_contains "$argv" "$(printf '\tHesap ve kota kontrolleri')"

zro_t_report
```

- [ ] **Step 2: Run it to verify it fails**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_ui_whiptail.sh` fails — `zro_ui_locale_ok: command not found`.

- [ ] **Step 3: Add the whiptail backend to `lib/ui.sh`**

Append:

```bash
ZRO_WHIPTAIL_BIN="${ZRO_WHIPTAIL_BIN:-$(zro_first_existing /usr/bin/whiptail /bin/whiptail || printf '')}"
ZRO_UI_HEIGHT="${ZRO_UI_HEIGHT:-20}"
ZRO_UI_WIDTH="${ZRO_UI_WIDTH:-78}"
ZRO_UI_LISTHEIGHT="${ZRO_UI_LISTHEIGHT:-10}"
ZRO_UI_BACKTITLE="Zimbra salt-okunur yonetim araci"

# The menu labels are Turkish. Without a UTF-8 locale whiptail miscounts
# character widths and the boxes break, so this is checked at startup.
zro_ui_locale_ok() {
  case ${1-} in
    *.UTF-8|*.utf8|*.UTF8|*.utf-8) return 0 ;;
    *) return 1 ;;
  esac
}

# Emitted as a TAB-joined line purely so tests can assert on the vector.
zro_ui_whiptail_argv() {
  local kind=$1 title=$2 text=$3
  shift 3
  local -a argv
  argv=( "$ZRO_WHIPTAIL_BIN" --backtitle "$ZRO_UI_BACKTITLE" --title "$title" )
  case $kind in
    menu)    argv+=( --notags --menu "$text" "$ZRO_UI_HEIGHT" "$ZRO_UI_WIDTH" "$ZRO_UI_LISTHEIGHT" "$@" ) ;;
    input)   argv+=( --inputbox "$text" "$ZRO_UI_HEIGHT" "$ZRO_UI_WIDTH" "$@" ) ;;
    msgbox)  argv+=( --msgbox "$text" "$ZRO_UI_HEIGHT" "$ZRO_UI_WIDTH" ) ;;
    textbox) argv+=( --scrolltext --textbox "$text" "$ZRO_UI_HEIGHT" "$ZRO_UI_WIDTH" ) ;;
    yesno)   argv+=( --yesno "$text" "$ZRO_UI_HEIGHT" "$ZRO_UI_WIDTH" ) ;;
  esac
  local a out=""
  for a in "${argv[@]}"; do
    out="$out	$a"
  done
  printf '%s' "${out#	}"
}

zro_ui_whiptail_run() {
  local kind=$1 title=$2 text=$3
  shift 3
  local -a argv
  argv=( "$ZRO_WHIPTAIL_BIN" --backtitle "$ZRO_UI_BACKTITLE" --title "$title" )
  case $kind in
    menu)    argv+=( --notags --menu "$text" "$ZRO_UI_HEIGHT" "$ZRO_UI_WIDTH" "$ZRO_UI_LISTHEIGHT" "$@" ) ;;
    input)   argv+=( --inputbox "$text" "$ZRO_UI_HEIGHT" "$ZRO_UI_WIDTH" "$@" ) ;;
    msgbox)  argv+=( --msgbox "$text" "$ZRO_UI_HEIGHT" "$ZRO_UI_WIDTH" ) ;;
    textbox) argv+=( --scrolltext --textbox "$text" "$ZRO_UI_HEIGHT" "$ZRO_UI_WIDTH" ) ;;
    yesno)   argv+=( --yesno "$text" "$ZRO_UI_HEIGHT" "$ZRO_UI_WIDTH" ) ;;
  esac
  # whiptail writes the result to stderr and its chrome to the terminal.
  "${argv[@]}" 3>&1 1>&2 2>&3
}

zro_ui_whiptail_menu() {
  local title=$1 text=$2
  shift 2
  local out rc=0
  out=$(zro_ui_whiptail_run menu "$title" "$text" "$@") || rc=$?
  [ "$rc" -ne 0 ] && return "$ZRO_E_CANCEL"
  printf '%s' "$out"
}

zro_ui_whiptail_input() {
  local title=$1 text=$2 default=${3-}
  local out rc=0
  out=$(zro_ui_whiptail_run input "$title" "$text" "$default") || rc=$?
  [ "$rc" -ne 0 ] && return "$ZRO_E_CANCEL"
  printf '%s' "$out"
}

zro_ui_whiptail_msgbox() {
  zro_ui_whiptail_run msgbox "$1" "$2" >/dev/null 2>&1
  return 0
}

zro_ui_whiptail_textbox() {
  zro_ui_whiptail_run textbox "$1" "$2" >/dev/null 2>&1
  return 0
}

zro_ui_whiptail_yesno() {
  zro_ui_whiptail_run yesno "$1" "$2" >/dev/null 2>&1
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_ui_whiptail.sh` passes.

- [ ] **Step 5: Run ShellCheck**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && shellcheck lib/ui.sh tests/test_ui.sh tests/test_ui_whiptail.sh'`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add lib/ui.sh tests/test_ui_whiptail.sh
git commit -m "feat: add whiptail UI backend with a locale check"
```

---

### Task 11: `lib/account.sh` — attribute parsing and account summary

**Files:**
- Create: `lib/account.sh`
- Create: `tests/fixtures/zmprov_ga_active.txt`, `tests/fixtures/zmprov_ga_locked.txt`, `tests/fixtures/zmprov_ga_no_such_account.err`
- Test: `tests/test_account.sh`

**Interfaces:**
- Consumes: `lib/core.sh`, `lib/validate.sh`, `lib/exec.sh`.
- Produces: `zro_attr_get <text> <name>` → prints the first value of an `attr: value` line, empty when absent; `zro_attr_all <text> <name>` → prints every value, one per line; `zro_zimbra_time <generalized-time>` → prints `YYYY-MM-DD HH:MM:SS`, returns `ZRO_E_INPUT` when malformed; `zro_account_fetch <account>` → prints the raw `zmprov ga` output for the M1 attribute set, returns `ZRO_E_NO_ACCOUNT` when the account does not exist; `zro_account_summary <account>` → prints the rendered summary block.

Only the attributes M1 displays are requested, in one call. Requesting the full attribute set would return hundreds of lines per account and cost the same JVM start.

- [ ] **Step 1: Write the fixtures**

`tests/fixtures/zmprov_ga_active.txt`:

```
# name ahmet.yilmaz@example.com
displayName: Ahmet Yilmaz
mail: ahmet.yilmaz@example.com
zimbraAccountStatus: active
zimbraCOSId: e00428a1-0c00-11d9-836a-000d93afea2a
zimbraLastLogonTimestamp: 20260715103012Z
zimbraMailAlias: a.yilmaz@example.com
zimbraMailAlias: ayilmaz@example.com
zimbraMailHost: mail01.example.com
zimbraMailQuota: 5368709120
```

`tests/fixtures/zmprov_ga_locked.txt`:

```
# name kilitli@example.com
displayName: Kilitli Kullanici
mail: kilitli@example.com
zimbraAccountStatus: locked
zimbraMailHost: mail01.example.com
zimbraMailQuota: 0
```

`tests/fixtures/zmprov_ga_no_such_account.err`:

```
ERROR: account.NO_SUCH_ACCOUNT (no such account: yok@example.com)
```

- [ ] **Step 2: Write the failing test**

Create `tests/test_account.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/validate.sh
. "$ZRO_SRC/lib/validate.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
export ZRO_MOCK_ID_USER=zimbra
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* 2>/dev/null || true

# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"
# shellcheck source=../lib/account.sh
. "$ZRO_SRC/lib/account.sh"

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG
FIX="$ZRO_TEST_ROOT/fixtures"
ACTIVE=$(cat "$FIX/zmprov_ga_active.txt")

it "extracts a single attribute value"
assert_out_eq "active" zro_attr_get "$ACTIVE" zimbraAccountStatus
assert_out_eq "Ahmet Yilmaz" zro_attr_get "$ACTIVE" displayName
assert_out_eq "mail01.example.com" zro_attr_get "$ACTIVE" zimbraMailHost

it "returns empty for an absent attribute"
assert_out_eq "" zro_attr_get "$ACTIVE" zimbraNoSuchAttribute

it "does not match an attribute whose name is a prefix of another"
assert_out_eq "" zro_attr_get "$ACTIVE" zimbraMail

it "extracts every value of a multi-valued attribute"
aliases=$(zro_attr_all "$ACTIVE" zimbraMailAlias)
assert_contains "$aliases" "a.yilmaz@example.com"
assert_contains "$aliases" "ayilmaz@example.com"
assert_eq "$(printf '%s\n' "$aliases" | wc -l | tr -d ' ')" "2"

it "converts Zimbra generalized time"
assert_out_eq "2026-07-15 10:30:12" zro_zimbra_time "20260715103012Z"

it "rejects malformed generalized time"
assert_status "$ZRO_E_INPUT" zro_zimbra_time "2026-07-15"
assert_status "$ZRO_E_INPUT" zro_zimbra_time ""
assert_status "$ZRO_E_INPUT" zro_zimbra_time "2026071510301Z"

it "rejects an invalid account before running anything"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_INPUT" zro_account_fetch 'a@b.com; id'
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

it "requests only the attributes M1 displays, in one call"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
  zro_account_fetch 'ahmet.yilmaz@example.com' >/dev/null
assert_eq "$(grep -c '^zmprov' "$ZRO_MOCK_LOG")" "1"
line=$(grep '^zmprov' "$ZRO_MOCK_LOG")
assert_contains "$line" "zimbraAccountStatus"
assert_contains "$line" "zimbraMailQuota"
assert_contains "$line" "zimbraLastLogonTimestamp"
assert_not_contains "$line" "-l"

it "maps a missing account to the documented exit code"
ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_ga_no_such_account.err" \
ZRO_MOCK_ZMPROV_GA_RC=1 \
  assert_status "$ZRO_E_NO_ACCOUNT" zro_account_fetch 'yok@example.com'

it "renders a summary with the operator-facing fields"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
      ZRO_CAP_FORCE=x zro_account_summary 'ahmet.yilmaz@example.com')
assert_contains "$out" "Ahmet Yilmaz"
assert_contains "$out" "active"
assert_contains "$out" "mail01.example.com"
assert_contains "$out" "2026-07-15 10:30:12"

it "labels last logon as approximate"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
      ZRO_CAP_FORCE=x zro_account_summary 'ahmet.yilmaz@example.com')
assert_contains "$out" "yaklasik"

it "handles an account with no last logon and no COS"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_locked.txt" \
      ZRO_CAP_FORCE=x zro_account_summary 'kilitli@example.com')
assert_contains "$out" "locked"
assert_contains "$out" "-"

rm -f -- "$ZRO_MOCK_LOG"
zro_t_report
```

- [ ] **Step 3: Run it to verify it fails**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_account.sh CRASHED` — `lib/account.sh: No such file or directory`.

- [ ] **Step 4: Write `lib/account.sh`**

```bash
# shellcheck shell=bash
# M1 operations: account, quota, COS, mailbox host, membership.
[ -n "${ZRO_LIB_ACCOUNT_LOADED:-}" ] && return 0
ZRO_LIB_ACCOUNT_LOADED=1

# Only what the M1 screens display. Asking for everything costs the same JVM
# start but returns several hundred lines per account.
ZRO_ACCOUNT_ATTRS='displayName mail zimbraAccountStatus zimbraCOSId zimbraLastLogonTimestamp zimbraMailAlias zimbraMailHost zimbraMailQuota'

zro_attr_get() {
  local text=$1 name=$2
  printf '%s\n' "$text" | awk -v key="$name" '
    index($0, key ": ") == 1 { print substr($0, length(key) + 3); exit }
  '
}

zro_attr_all() {
  local text=$1 name=$2
  printf '%s\n' "$text" | awk -v key="$name" '
    index($0, key ": ") == 1 { print substr($0, length(key) + 3) }
  '
}

# Zimbra stores timestamps as LDAP generalized time: 20260715103012Z
zro_zimbra_time() {
  local t=${1-}
  [[ $t =~ ^[0-9]{14}Z?$ ]] || return "$ZRO_E_INPUT"
  printf '%s-%s-%s %s:%s:%s' \
    "${t:0:4}" "${t:4:2}" "${t:6:2}" "${t:8:2}" "${t:10:2}" "${t:12:2}"
}

zro_account_fetch() {
  local acct=${1-}
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"

  local err out rc=0
  err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"
  # shellcheck disable=SC2086
  # ZRO_ACCOUNT_ATTRS is a deliberate word-split list of fixed attribute names.
  out=$(zro_exec zmprov ga "$acct" $ZRO_ACCOUNT_ATTRS 2>"$err") || rc=$?

  if [ "$rc" -ne 0 ]; then
    if grep -q 'NO_SUCH_ACCOUNT' "$err" 2>/dev/null; then
      rm -f -- "$err"
      return "$ZRO_E_NO_ACCOUNT"
    fi
    rm -f -- "$err"
    return "$rc"
  fi
  rm -f -- "$err"
  printf '%s' "$out"
}

zro_account_summary() {
  local acct=$1 raw rc=0
  raw=$(zro_account_fetch "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  local status name host quota cosid logon logon_h quota_h
  status=$(zro_attr_get "$raw" zimbraAccountStatus)
  name=$(zro_attr_get "$raw" displayName)
  host=$(zro_attr_get "$raw" zimbraMailHost)
  quota=$(zro_attr_get "$raw" zimbraMailQuota)
  cosid=$(zro_attr_get "$raw" zimbraCOSId)
  logon=$(zro_attr_get "$raw" zimbraLastLogonTimestamp)

  logon_h=$(zro_zimbra_time "$logon" 2>/dev/null) || logon_h="-"
  if [ "$quota" = "0" ]; then
    quota_h="sinirsiz"
  else
    quota_h=$(zro_human_bytes "$quota" 2>/dev/null) || quota_h="-"
  fi
  [ -n "$name" ]  || name="-"
  [ -n "$host" ]  || host="-"
  [ -n "$cosid" ] || cosid="-"

  printf 'Hesap        : %s\n' "$acct"
  printf 'Ad           : %s\n' "$name"
  printf 'Durum        : %s\n' "$status"
  printf 'Mailbox host : %s\n' "$host"
  printf 'Kota limiti  : %s\n' "$quota_h"
  printf 'COS ID       : %s\n' "$cosid"
  printf 'Son giris    : %s  (yaklasik; Zimbra bu alani gunde bir kez yeniler)\n' "$logon_h"

  local aliases
  aliases=$(zro_attr_all "$raw" zimbraMailAlias)
  if [ -n "$aliases" ]; then
    printf 'Aliaslar     :\n'
    printf '%s\n' "$aliases" | sed 's/^/               /'
  fi
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_account.sh` passes.

- [ ] **Step 6: Run ShellCheck**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && shellcheck lib/account.sh tests/test_account.sh'`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add lib/account.sh tests/fixtures tests/test_account.sh
git commit -m "feat: add account attribute parsing and summary view"
```

---

### Task 12: `lib/account.sh` — quota, membership, COS

**Files:**
- Modify: `lib/account.sh`
- Create: `tests/fixtures/zmprov_gmi_ok.txt`, `tests/fixtures/zmprov_gmi_no_mailbox.err`, `tests/fixtures/zmprov_gam_ok.txt`, `tests/fixtures/zmprov_gc_ok.txt`
- Test: `tests/test_account_quota.sh`

**Interfaces:**
- Consumes: everything from Task 11.
- Produces: `zro_account_mailbox_info <account>` → prints raw `zmprov gmi` output, `ZRO_E_NO_MAILBOX` when absent; `zro_account_quota <account>` → prints the rendered quota block; `zro_account_membership <account>` → prints one distribution list per line, `ZRO_E_NO_RESULT` when there are none; `zro_account_cos_name <cos-id>` → prints the COS name, `-` when unresolvable.

`zmprov gqu` is deliberately not used: it takes a **server** and returns every account on it. Per-account usage comes from `gmi`.

- [ ] **Step 1: Write the fixtures**

`tests/fixtures/zmprov_gmi_ok.txt`:

```
mailboxId: 214, used: 1073741824
```

`tests/fixtures/zmprov_gmi_full.txt` — usage exactly at the limit, so the
percentage arithmetic is exercised at its boundary:

```
mailboxId: 215, used: 5368709120
```

`tests/fixtures/zmprov_gmi_no_mailbox.err`:

```
ERROR: account.NO_SUCH_ACCOUNT (no such account: yok@example.com)
```

`tests/fixtures/zmprov_gam_ok.txt`:

```
bilgi-islem@example.com
tum-personel@example.com
```

`tests/fixtures/zmprov_gc_ok.txt`:

```
# name default
cn: default
zimbraMailQuota: 5368709120
```

- [ ] **Step 2: Write the failing test**

Create `tests/test_account_quota.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/validate.sh
. "$ZRO_SRC/lib/validate.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
export ZRO_MOCK_ID_USER=zimbra
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* 2>/dev/null || true

# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"
# shellcheck source=../lib/account.sh
. "$ZRO_SRC/lib/account.sh"

ZRO_MOCK_LOG=$(mktemp); export ZRO_MOCK_LOG
FIX="$ZRO_TEST_ROOT/fixtures"

it "never calls the server-wide quota command"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
ZRO_MOCK_ZMPROV_GMI_OUT="$FIX/zmprov_gmi_ok.txt" \
  zro_account_quota 'ahmet.yilmaz@example.com' >/dev/null
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "gqu"
assert_not_contains "$(cat "$ZRO_MOCK_LOG")" "getQuotaUsage"

it "reads per-account usage from gmi"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ZMPROV_GMI_OUT="$FIX/zmprov_gmi_ok.txt" \
  assert_contains "$(zro_account_mailbox_info 'a@b.com')" "mailboxId: 214"
assert_contains "$(cat "$ZRO_MOCK_LOG")" "$(printf 'zmprov\tgmi\ta@b.com')"

it "renders quota with limit, usage and percentage"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
      ZRO_MOCK_ZMPROV_GMI_OUT="$FIX/zmprov_gmi_ok.txt" \
      zro_account_quota 'ahmet.yilmaz@example.com')
assert_contains "$out" "214"
assert_contains "$out" "1.0 GB"
assert_contains "$out" "5.0 GB"
assert_contains "$out" "20%"

it "reports an account that is exactly at its quota"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
      ZRO_MOCK_ZMPROV_GMI_OUT="$FIX/zmprov_gmi_full.txt" \
      zro_account_quota 'ahmet.yilmaz@example.com')
assert_contains "$out" "100%"

it "reports unlimited quota without dividing by zero"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_locked.txt" \
      ZRO_MOCK_ZMPROV_GMI_OUT="$FIX/zmprov_gmi_ok.txt" \
      zro_account_quota 'kilitli@example.com')
assert_contains "$out" "sinirsiz"
assert_not_contains "$out" "%"

it "maps a missing mailbox to the documented exit code"
ZRO_MOCK_ZMPROV_GMI_ERR="$FIX/zmprov_gmi_no_mailbox.err" \
ZRO_MOCK_ZMPROV_GMI_RC=1 \
  assert_status "$ZRO_E_NO_MAILBOX" zro_account_mailbox_info 'yok@example.com'

it "lists distribution-list membership"
out=$(ZRO_MOCK_ZMPROV_GAM_OUT="$FIX/zmprov_gam_ok.txt" \
      zro_account_membership 'ahmet.yilmaz@example.com')
assert_contains "$out" "bilgi-islem@example.com"
assert_contains "$out" "tum-personel@example.com"

it "reports no membership distinctly from an error"
empty=$(mktemp); : >"$empty"
ZRO_MOCK_ZMPROV_GAM_OUT="$empty" \
  assert_status "$ZRO_E_NO_RESULT" zro_account_membership 'yalniz@example.com'
rm -f -- "$empty"

it "resolves a COS id to its name"
ZRO_MOCK_ZMPROV_GC_OUT="$FIX/zmprov_gc_ok.txt" \
  assert_out_eq "default" zro_account_cos_name 'e00428a1-0c00-11d9-836a-000d93afea2a'

it "returns a dash for an unresolvable COS id"
assert_out_eq "-" zro_account_cos_name ""
assert_out_eq "-" zro_account_cos_name 'not a uuid; id'

it "the summary shows the COS name, not the raw id"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" \
      ZRO_MOCK_ZMPROV_GC_OUT="$FIX/zmprov_gc_ok.txt" \
      zro_account_summary 'ahmet.yilmaz@example.com')
assert_contains "$out" "default"
assert_not_contains "$out" "e00428a1-0c00-11d9"

it "the summary survives an account with no COS set"
out=$(ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_locked.txt" \
      zro_account_summary 'kilitli@example.com')
assert_contains "$out" "locked"

it "validates the account before any of these calls"
: >"$ZRO_MOCK_LOG"
assert_status "$ZRO_E_INPUT" zro_account_mailbox_info 'a@b.com; id'
assert_status "$ZRO_E_INPUT" zro_account_membership 'a@b.com; id'
assert_eq "$(cat "$ZRO_MOCK_LOG")" ""

rm -f -- "$ZRO_MOCK_LOG"
zro_t_report
```

- [ ] **Step 3: Run it to verify it fails**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_account_quota.sh` fails — `zro_account_quota: command not found`.

- [ ] **Step 4: Append to `lib/account.sh`**

```bash
zro_account_mailbox_info() {
  local acct=${1-}
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"

  local err out rc=0
  err=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"
  out=$(zro_exec zmprov gmi "$acct" 2>"$err") || rc=$?

  if [ "$rc" -ne 0 ]; then
    if grep -qE 'NO_SUCH_ACCOUNT|NO_SUCH_MAILBOX' "$err" 2>/dev/null; then
      rm -f -- "$err"
      return "$ZRO_E_NO_MAILBOX"
    fi
    rm -f -- "$err"
    return "$rc"
  fi
  rm -f -- "$err"
  printf '%s' "$out"
}

# zmprov gmi prints: "mailboxId: 214, used: 1073741824"
zro_account_quota() {
  local acct=$1 raw info rc=0
  raw=$(zro_account_fetch "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  info=$(zro_account_mailbox_info "$acct") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"

  local limit used mbox limit_h used_h
  limit=$(zro_attr_get "$raw" zimbraMailQuota)
  mbox=$(printf '%s' "$info" | sed -n 's/.*mailboxId: *\([0-9]*\).*/\1/p')
  used=$(printf '%s' "$info" | sed -n 's/.*used: *\([0-9]*\).*/\1/p')
  [ -n "$used" ] || used=0
  [ -n "$limit" ] || limit=0

  used_h=$(zro_human_bytes "$used" 2>/dev/null) || used_h="-"

  printf 'Hesap        : %s\n' "$acct"
  printf 'Mailbox ID   : %s\n' "${mbox:--}"
  printf 'Kullanilan   : %s\n' "$used_h"
  if [ "$limit" = "0" ]; then
    printf 'Kota limiti  : sinirsiz\n'
  else
    limit_h=$(zro_human_bytes "$limit" 2>/dev/null) || limit_h="-"
    printf 'Kota limiti  : %s\n' "$limit_h"
    printf 'Doluluk      : %s%%\n' "$(( used * 100 / limit ))"
  fi
}

zro_account_membership() {
  local acct=${1-}
  zro_validate_email "$acct" || return "$ZRO_E_INPUT"

  local out rc=0
  out=$(zro_exec zmprov gam "$acct" 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  out=$(printf '%s' "$out" | grep -v '^[[:space:]]*$')
  [ -n "$out" ] || return "$ZRO_E_NO_RESULT"
  printf '%s\n' "$out"
}

# zimbraCOSId is a UUID; the readable name needs a second lookup. This is the
# only place M1 spends a second JVM start, and only when a COS is set.
zro_account_cos_name() {
  local cosid=${1-}
  if [ -z "$cosid" ]; then
    printf '%s' "-"
    return 0
  fi
  case $cosid in
    *[!A-Za-z0-9-]*) printf '%s' "-"; return 0 ;;
  esac
  local out rc=0
  out=$(zro_exec zmprov gc "$cosid" cn 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s' "-"
    return 0
  fi
  local name
  name=$(zro_attr_get "$out" cn)
  printf '%s' "${name:--}"
}
```

- [ ] **Step 5: Wire the COS name into the summary**

Task 11 printed the raw `zimbraCOSId` because nothing could resolve it yet. In
`zro_account_summary`, replace this line:

```bash
  printf 'COS ID       : %s\n' "$cosid"
```

with:

```bash
  printf 'COS          : %s\n' "$(zro_account_cos_name "$cosid")"
```

and delete the now-unused `[ -n "$cosid" ] || cosid="-"` line — `zro_account_cos_name`
already returns `-` for an empty or malformed id. Bash resolves function calls at
runtime, so `zro_account_summary` may call a function defined further down the file.

- [ ] **Step 6: Run tests to verify they pass**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_account_quota.sh` passes. `1073741824 * 100 / 5368709120 = 20`, matching the `20%` assertion, and the full fixture gives exactly `100%`.

`test_account.sh` from Task 11 must still pass: with no `ZRO_MOCK_ZMPROV_GC_OUT`
set, the COS lookup returns empty output and the summary prints `-`.

- [ ] **Step 7: Run ShellCheck**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && shellcheck lib/account.sh tests/test_account_quota.sh'`
Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add lib/account.sh tests/fixtures tests/test_account_quota.sh
git commit -m "feat: add per-account quota, membership and COS lookup"
```

---

### Task 13: `zimbra-ro-tui.sh` — startup checks and menu loop

**Files:**
- Create: `zimbra-ro-tui.sh`
- Test: `tests/test_startup.sh`

**Interfaces:**
- Consumes: every module.
- Produces: `zro_startup_check` → returns 0 when the host can run the tool, `ZRO_E_BADUSER` for an unsupported user, `ZRO_E_UNAVAILABLE` when a required binary is missing; `zro_menu_account` → the M1 menu loop; `zro_menu_main` → the top-level loop.

Startup runs the smoke check described in the spec: `zmcontrol -v` through the full identity wrapper. A host that cannot answer it fails immediately with one clear message, instead of failing later from inside a menu.

- [ ] **Step 1: Write the failing test**

Create `tests/test_startup.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"

export ZRO_MOCK_LIB="$ZRO_TEST_ROOT/mocks"
export ZRO_ZIMBRA_BIN="$ZRO_TEST_ROOT/mocks/bin"
export ZRO_ID_BIN="$ZRO_TEST_ROOT/mocks/bin/id"
export ZRO_RUNUSER="$ZRO_TEST_ROOT/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$ZRO_TEST_ROOT/mocks/bin/timeout"
export ZRO_UI_BACKEND=stub
export ZRO_SOURCED_ONLY=1
chmod +x "$ZRO_TEST_ROOT"/mocks/bin/* 2>/dev/null || true

# shellcheck source=../zimbra-ro-tui.sh
. "$ZRO_SRC/zimbra-ro-tui.sh"

ZRO_MOCK_LOG=$(mktemp);  export ZRO_MOCK_LOG
ZRO_UI_QUEUE=$(mktemp);  export ZRO_UI_QUEUE
ZRO_UI_OUT=$(mktemp);    export ZRO_UI_OUT
FIX="$ZRO_TEST_ROOT/fixtures"
export ZRO_MOCK_ZMCONTROL__V_OUT="$FIX/zmcontrol_v.txt"

queue() { printf '%s\n' "$@" >"$ZRO_UI_QUEUE"; zro_ui_reset; }

it "starts as zimbra"
ZRO_MOCK_ID_USER=zimbra assert_ok zro_startup_check

it "starts as root"
ZRO_MOCK_ID_USER=root assert_ok zro_startup_check

it "refuses any other user"
ZRO_MOCK_ID_USER=nobody assert_status "$ZRO_E_BADUSER" zro_startup_check
ZRO_MOCK_ID_USER=postfix assert_status "$ZRO_E_BADUSER" zro_startup_check

it "fails when the Zimbra binaries are absent"
ZRO_MOCK_ID_USER=zimbra ZRO_ZIMBRA_BIN=/nonexistent \
  assert_status "$ZRO_E_UNAVAILABLE" zro_startup_check

it "runs the smoke check through the full wrapper when root"
: >"$ZRO_MOCK_LOG"
ZRO_MOCK_ID_USER=root zro_startup_check >/dev/null 2>&1
assert_contains "$(cat "$ZRO_MOCK_LOG")" "runuser"
assert_contains "$(cat "$ZRO_MOCK_LOG")" "zmcontrol"

it "cancelling the account prompt returns to the menu instead of exiting"
export ZRO_MOCK_ID_USER=zimbra
queue "1" "__CANCEL__" "__CANCEL__"
assert_ok zro_menu_account

it "an invalid address is reported and the menu continues"
queue "1" 'a@b.com; id' "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"; : >"$ZRO_MOCK_LOG"
zro_menu_account
assert_contains "$(cat "$ZRO_UI_OUT")" "Gecersiz"
assert_eq "$(grep -c '^zmprov' "$ZRO_MOCK_LOG" || true)" "0"

it "a valid address reaches the summary view"
queue "1" "ahmet.yilmaz@example.com" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMPROV_GA_OUT="$FIX/zmprov_ga_active.txt" zro_menu_account
assert_contains "$(cat "$ZRO_UI_OUT")" "Ahmet Yilmaz"

it "a missing account is reported without leaving the menu"
queue "1" "yok@example.com" "__CANCEL__" "__CANCEL__"
: >"$ZRO_UI_OUT"
ZRO_MOCK_ZMPROV_GA_ERR="$FIX/zmprov_ga_no_such_account.err" \
ZRO_MOCK_ZMPROV_GA_RC=1 zro_menu_account
assert_contains "$(cat "$ZRO_UI_OUT")" "bulunamadi"

it "cancelling the main menu exits the loop cleanly"
queue "__CANCEL__"
assert_ok zro_menu_main

rm -f -- "$ZRO_MOCK_LOG" "$ZRO_UI_QUEUE" "$ZRO_UI_OUT"
zro_t_report
```

- [ ] **Step 2: Run it to verify it fails**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_startup.sh CRASHED` — `zimbra-ro-tui.sh: No such file or directory`.

- [ ] **Step 3: Write `zimbra-ro-tui.sh`**

```bash
#!/usr/bin/env bash
# Zimbra salt-okunur yonetim araci.
# No errexit: whiptail returns non-zero on Cancel, and errexit is silently
# disabled inside conditional contexts.
set -uo pipefail

ZRO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib/core.sh
. "$ZRO_ROOT/lib/core.sh"
# shellcheck source=lib/validate.sh
. "$ZRO_ROOT/lib/validate.sh"
# shellcheck source=lib/exec.sh
. "$ZRO_ROOT/lib/exec.sh"
# shellcheck source=lib/capability.sh
. "$ZRO_ROOT/lib/capability.sh"
# shellcheck source=lib/ui.sh
. "$ZRO_ROOT/lib/ui.sh"
# shellcheck source=lib/account.sh
. "$ZRO_ROOT/lib/account.sh"

trap zro_cleanup EXIT INT TERM

zro_startup_check() {
  if [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
     { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
    zro_log error "Bash 4.2 veya uzeri gerekiyor (bulunan: ${BASH_VERSION})"
    return "$ZRO_E_UNAVAILABLE"
  fi

  local user
  user=$(zro_current_user) || return "$ZRO_E_UNAVAILABLE"
  zro_identity_mode "$user" >/dev/null || {
    zro_log error "Bu arac yalnizca 'zimbra' veya 'root' ile calisir (bulunan: $user)"
    return "$ZRO_E_BADUSER"
  }

  local missing=""
  [ -n "$ZRO_TIMEOUT_BIN" ] || missing="$missing timeout"
  [ -n "$ZRO_ID_BIN" ] || missing="$missing id"
  if [ "$(zro_identity_mode "$user")" = runuser ] && [ -z "$ZRO_RUNUSER" ]; then
    missing="$missing runuser"
  fi
  if [ -n "$missing" ]; then
    zro_log error "Gerekli sistem komutlari bulunamadi:$missing"
    return "$ZRO_E_UNAVAILABLE"
  fi

  zro_bin_available zmcontrol || {
    zro_log error "Zimbra kurulumu bulunamadi: $ZRO_ZIMBRA_BIN"
    return "$ZRO_E_UNAVAILABLE"
  }

  # Smoke check: prove the full wrapper works before showing any menu.
  zro_cap_reset
  local version
  version=$(zro_cap_version)
  if [ -z "$version" ]; then
    zro_log error "Zimbra servisine erisilemedi ($ZRO_ZIMBRA_BIN/zmcontrol -v)"
    return "$ZRO_E_UNAVAILABLE"
  fi

  zro_ui_locale_ok "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" ||
    zro_log warn "UTF-8 olmayan locale: Turkce menu metinleri bozuk gorunebilir"

  return 0
}

zro_show_text() {
  local title=$1 body=$2 f
  f=$(zro_tmpfile) || return "$ZRO_E_UNAVAILABLE"
  printf '%s\n' "$body" >"$f"
  zro_ui_textbox "$title" "$f"
  rm -f -- "$f"
}

zro_prompt_account() {
  local acct rc=0
  acct=$(zro_ui_input "Hesap" "Hesap adresi:") || rc=$?
  [ "$rc" -eq 0 ] || return "$ZRO_E_CANCEL"
  if ! zro_validate_email "$acct"; then
    zro_ui_msgbox "Gecersiz girdi" "Gecersiz hesap adresi."
    return "$ZRO_E_INPUT"
  fi
  printf '%s' "$acct"
}

zro_report_error() {
  case $1 in
    "$ZRO_E_NO_ACCOUNT") zro_ui_msgbox "Bulunamadi" "Hesap bulunamadi." ;;
    "$ZRO_E_NO_MAILBOX") zro_ui_msgbox "Bulunamadi" "Mailbox bulunamadi." ;;
    "$ZRO_E_NO_RESULT")  zro_ui_msgbox "Sonuc yok" "Kayit bulunamadi." ;;
    "$ZRO_E_TIMEOUT")    zro_ui_msgbox "Zaman asimi" "Komut zaman asimina ugradi." ;;
    "$ZRO_E_DENIED")     zro_ui_msgbox "Reddedildi" "Bu islem izin listesinde degil." ;;
    "$ZRO_E_NOCAP")      zro_ui_msgbox "Kullanilamaz" "Bu islem bu sunucuda mevcut degil." ;;
    *)                   zro_ui_msgbox "Hata" "Islem basarisiz (kod $1)." ;;
  esac
}

zro_menu_account() {
  local choice acct out rc
  while :; do
    rc=0
    choice=$(zro_ui_menu "Hesap ve kota" "Islem secin:" \
      1 "Hesap ozeti" \
      2 "Kota kullanimi" \
      3 "Dagitim listesi uyelikleri") || rc=$?
    [ "$rc" -eq 0 ] || return 0

    rc=0
    acct=$(zro_prompt_account) || rc=$?
    [ "$rc" -eq 0 ] || continue

    rc=0
    case $choice in
      1) out=$(zro_account_summary "$acct") || rc=$? ;;
      2) out=$(zro_account_quota "$acct") || rc=$? ;;
      3) out=$(zro_account_membership "$acct") || rc=$? ;;
      *) continue ;;
    esac

    if [ "$rc" -ne 0 ]; then
      zro_report_error "$rc"
      continue
    fi
    zro_show_text "Sonuc" "$out"
  done
}

zro_menu_main() {
  local choice rc
  while :; do
    rc=0
    choice=$(zro_ui_menu "Ana menu" "Zimbra: $(zro_cap_version)" \
      1 "Hesap ve kota kontrolleri" \
      9 "Cikis") || rc=$?
    [ "$rc" -eq 0 ] || return 0
    case $choice in
      1) zro_menu_account ;;
      9) return 0 ;;
    esac
  done
}

zro_main() {
  zro_startup_check || return $?
  zro_menu_main
}

# Sourced by the test suite; executed in production.
if [ -z "${ZRO_SOURCED_ONLY:-}" ]; then
  zro_main
  exit $?
fi
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_startup.sh` passes.

- [ ] **Step 5: Run ShellCheck**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && shellcheck zimbra-ro-tui.sh tests/test_startup.sh'`
Expected: no output.

- [ ] **Step 6: Commit**

```bash
git update-index --chmod=+x zimbra-ro-tui.sh
git add zimbra-ro-tui.sh tests/test_startup.sh
git commit -m "feat: add entry point with startup checks and the account menu"
```

---

### Task 14: Static read-only scanner

**Files:**
- Create: `tests/test_readonly_scan.sh`

**Interfaces:**
- Consumes: `lib/exec.sh` (`zro_allow_entries`), the source tree.
- Produces: nothing importable. This is the suite that makes the allowlist a checked invariant instead of a convention.

The fourth check is the important one: it extracts every literal `zro_exec <bin> <token>` call site in the tree and fails when any of them is absent from the allowlist. A new call cannot be merged without the matching, reviewable allowlist entry.

- [ ] **Step 1: Write the test**

Create `tests/test_readonly_scan.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"
# shellcheck source=../lib/core.sh
. "$ZRO_SRC/lib/core.sh"
# shellcheck source=../lib/exec.sh
. "$ZRO_SRC/lib/exec.sh"

SOURCES=$(printf '%s\n' "$ZRO_SRC/zimbra-ro-tui.sh" "$ZRO_SRC"/lib/*.sh)

# Strip full-line comments so documentation may name what code may not do.
zro_scan_code() {
  local f
  for f in $SOURCES; do
    sed 's/[[:space:]]*#.*$//' "$f"
  done
}

it "contains no write subcommand in an executable position"
code=$(zro_scan_code)
for verb in createAccount modifyAccount deleteAccount renameAccount \
            deleteMessage deleteConversation deleteFolder emptyFolder \
            moveMessage markMessageRead markMessageSpam addMessage \
            postRestURL recoverItem createFolder modifyFolder; do
  assert_not_contains "$code" "$verb"
done

it "contains no short write alias in an executable position"
for alias in ' dm ' ' mm ' ' mmr ' ' ef ' ' df ' ' ma ' ' da ' ' ca '; do
  assert_not_contains "$code" "zro_exec zmprov$alias"
  assert_not_contains "$code" "zro_exec zmmailbox$alias"
done

it "contains no eval or shell-string execution"
assert_not_contains "$code" "eval "
assert_not_contains "$code" "bash -c"
assert_not_contains "$code" "sh -c"
assert_not_contains "$code" '`'

it "every zro_exec call site is covered by the allowlist"
allow=$(zro_allow_entries)
calls=$(zro_scan_code | grep -oE 'zro_exec[[:space:]]+[A-Za-z0-9_-]+[[:space:]]+[^[:space:]"]+' | sort -u)
uncovered=""
while IFS= read -r call; do
  [ -n "$call" ] || continue
  bin=$(printf '%s' "$call" | awk '{print $2}')
  token=$(printf '%s' "$call" | awk '{print $3}')
  case $token in
    '"'*|'$'*) continue ;;   # only literal call sites are decidable here
  esac
  printf '%s\n' "$allow" | grep -qx "$bin:$token" || uncovered="$uncovered $bin:$token"
done <<EOF
$calls
EOF
assert_eq "$uncovered" ""

it "found the call sites it claims to check"
assert_contains "$calls" "zro_exec zmprov ga"
assert_contains "$calls" "zro_exec zmcontrol -v"

it "the allowlist itself names no write verb"
for verb in create modify delete remove move mark flag tag empty import post recover sync; do
  assert_not_contains "$allow" "$verb"
done

it "no module hard-codes an absolute Zimbra path"
assert_not_contains "$code" "/opt/zimbra/bin/"
assert_not_contains "$code" "/opt/zimbra/libexec/"

it "no module calls a Zimbra binary outside the gate"
for f in $SOURCES; do
  body=$(sed 's/[[:space:]]*#.*$//' "$f" | grep -v 'zro_exec' | grep -v 'ZRO_ALLOW' || true)
  assert_not_contains "$body" 'zmprov '
  assert_not_contains "$body" 'zmmailbox '
done

zro_t_report
```

- [ ] **Step 2: Run it — it must pass against the code written so far**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_readonly_scan.sh` passes. If it does not, the failure is in `lib/`, not in the scanner — fix the module.

- [ ] **Step 3: Prove the scanner actually catches a violation**

Temporarily add `zro_exec zmprov ma "$acct"` to a function in `lib/account.sh`, then run the suite.
Expected: `test_readonly_scan.sh` fails on both the write-alias check and the call-site coverage check.
**Remove the line afterwards** and re-run to confirm the suite is green again.

- [ ] **Step 4: Run ShellCheck**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && shellcheck tests/test_readonly_scan.sh'`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add tests/test_readonly_scan.sh
git commit -m "test: make the allowlist a statically checked invariant"
```

---

### Task 15: Compatibility check, ShellCheck config and CI

**Files:**
- Create: `tests/test_bash_compat.sh`
- Create: `.shellcheckrc`
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: the source tree.
- Produces: nothing importable.

- [ ] **Step 1: Write the compatibility test**

Create `tests/test_bash_compat.sh`:

```bash
#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=lib/assert.sh
. "$ZRO_TEST_ROOT/lib/assert.sh"

FILES=$(printf '%s\n' "$ZRO_SRC/zimbra-ro-tui.sh" "$ZRO_SRC"/lib/*.sh \
        "$ZRO_SRC"/tests/*.sh "$ZRO_SRC"/tests/lib/*.sh)

code=""
for f in $FILES; do
  code="$code$(sed 's/[[:space:]]*#.*$//' "$f")
"
done

it "uses no bash 4.3 nameref"
assert_not_contains "$code" "local -n"
assert_not_contains "$code" "declare -n"

it "uses no bash 4.4 parameter transformations"
assert_not_contains "$code" '@Q'
assert_not_contains "$code" '@A'
assert_not_contains "$code" '@E'

it "uses no bash 4.3 wait -n"
assert_not_contains "$code" "wait -n"

it "uses no bash 5 EPOCHSECONDS"
assert_not_contains "$code" "EPOCHSECONDS"
assert_not_contains "$code" "EPOCHREALTIME"

it "every executable script disables errexit and enables nounset"
for f in "$ZRO_SRC/zimbra-ro-tui.sh" "$ZRO_SRC/tests/run.sh"; do
  head=$(head -n 10 "$f")
  assert_contains "$head" "set -uo pipefail"
  assert_not_contains "$head" "set -e"
  assert_not_contains "$head" "errexit"
done

it "every library declares its shell and guards against reloading"
for f in "$ZRO_SRC"/lib/*.sh; do
  head=$(head -n 5 "$f")
  assert_contains "$head" "shellcheck shell=bash"
  assert_contains "$head" "_LOADED"
done

zro_t_report
```

- [ ] **Step 2: Run it to verify it passes**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh'`
Expected: `test_bash_compat.sh` passes against the code written so far.

- [ ] **Step 3: Write `.shellcheckrc`**

```
# Follow `source` directives relative to each script's own directory.
source-path=SCRIPTDIR
external-sources=true

# Optional checks worth having in a program that builds command lines.
enable=quote-safe-variables
enable=check-set-e-suppressed
enable=deprecate-which
enable=avoid-nullary-conditions
```

- [ ] **Step 4: Run ShellCheck across the whole tree**

Run:

```bash
wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && shellcheck zimbra-ro-tui.sh lib/*.sh tests/*.sh tests/lib/*.sh tests/mocks/*.sh tests/mocks/bin/*'
```

Expected: no output. Fix anything reported before continuing — this is the point at which the ShellCheck-clean requirement is actually established.

- [ ] **Step 5: Write the CI workflow**

`.github/workflows/ci.yml`:

```yaml
name: ci

on:
  push:
    branches: ["**"]
  pull_request:

jobs:
  shellcheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install ShellCheck
        run: sudo apt-get update && sudo apt-get install -y shellcheck
      - name: Version
        run: shellcheck --version
      - name: Lint
        run: |
          shellcheck zimbra-ro-tui.sh lib/*.sh tests/*.sh tests/lib/*.sh \
                     tests/mocks/*.sh tests/mocks/bin/*

  tests:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Bash version
        run: bash --version
      - name: Run the suite
        run: ./tests/run.sh

  line-endings:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Reject CRLF in shell scripts
        run: |
          if grep -rlI $'\r' --include='*.sh' . ; then
            echo "CRLF line endings found; see .gitattributes" >&2
            exit 1
          fi
```

- [ ] **Step 6: Commit**

```bash
git add tests/test_bash_compat.sh .shellcheckrc .github/workflows/ci.yml
git commit -m "ci: add ShellCheck, the test suite and a CRLF guard"
```

---

### Task 16: Operator documentation

**Files:**
- Create: `docs/operations.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing importable.

- [ ] **Step 1: Write `docs/operations.md`**

Six sections, in this order.

**1. Installation.** Clone the repo anywhere readable by the `zimbra` user.
The only requirement beyond a Zimbra host is `whiptail` — package `newt` on the
RHEL family, `whiptail` on Debian and Ubuntu. Nothing else is installed, and the
test suite has no dependencies either.

**2. Running.** `./zimbra-ro-tui.sh` as `zimbra`, or as `root` (commands are then
wrapped in `runuser -u zimbra --`). Any other user is refused. List each startup
failure and its meaning: unsupported user, Bash older than 4.2, missing `timeout`
/ `id` / `runuser`, missing Zimbra installation, `zmcontrol -v` unreachable,
non-UTF-8 locale (a warning, not a failure).

**3. What M1 shows.** Account summary (name, status, mailbox host, quota limit,
COS, last logon, aliases), quota usage (mailbox id, used, limit, percentage) and
distribution-list membership. State plainly that **last logon is approximate**:
Zimbra refreshes `zimbraLastLogonTimestamp` at most once per
`zimbraLastLogonTimestampFrequency`, which defaults to one day.

**4. Exit codes.** Copy the table from §6.1 of the design spec verbatim, and add:
`90` means the tool tried to run something its own allowlist forbids — that is a
defect to report, not an operator mistake.

**5. Read-only verification record.** Paste this table and leave the result cells
empty until each has been settled on a disposable test account:

```markdown
| Question | Milestone | How it was tested | Result | Date |
|---|---|---|---|---|
| Does `zmmailbox -z -m <account>` create a mailbox for an account that has never logged in? | Blocks M2 | | | |
| Does `zmmailbox gm <id>` clear the unread flag on an unread message? | Blocks M2 | | | |
| Does `zmprov gmi` on an account with no mailbox return an error, or provision one? | M1 | | | |
```

**6. Production acceptance.** The sequence, numbered:

1. Copy the repo to the server and run `./tests/run.sh` there — it must be green
   with nothing installed.
2. Read `lib/exec.sh` and confirm every allowlist entry is a read operation.
3. Pick one disposable test account. Record its mailbox state before:
   `zmprov gmi <acct>` and, for a known folder, the message and unread counts.
4. Run every M1 screen against that account.
5. Record the same values after and confirm they are identical.
6. Fill in the row of the table in section 5 that M1 can answer.
7. Only then use the tool against real accounts.

- [ ] **Step 2: Update `README.md`**

Change the status block from "Milestone M1 … is being built" to a line stating M1 is complete and listing what it covers, and link `docs/operations.md`.

- [ ] **Step 3: Run the whole suite one final time**

Run: `wsl -- bash -lc 'cd /mnt/c/zimbra-readonly-tui && ./tests/run.sh && shellcheck zimbra-ro-tui.sh lib/*.sh tests/*.sh tests/lib/*.sh tests/mocks/*.sh tests/mocks/bin/*'`
Expected: every file green, ShellCheck silent.

- [ ] **Step 4: Commit**

```bash
git add docs/operations.md README.md
git commit -m "docs: add the operator guide and read-only verification record"
```

---

## Done When

1. `./tests/run.sh` is green on WSL and in CI.
2. ShellCheck is silent across the tree, tests and mocks included.
3. `test_readonly_scan.sh` passes, and was observed to fail when a write command was temporarily introduced (Task 14, Step 3).
4. Every acceptance criterion in §9 of the design spec has a passing test.
5. `docs/operations.md` carries the verification table with its three questions still open — they are answered on a real server, not in this plan.
