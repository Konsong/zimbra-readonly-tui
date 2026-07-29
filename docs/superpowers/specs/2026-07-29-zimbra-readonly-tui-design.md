# Zimbra Read-Only Administration TUI — Design

- **Date:** 2026-07-29
- **Status:** Approved
- **Supersedes:** [`2026-07-28-zimbra-readonly-tui-design.md`](./2026-07-28-zimbra-readonly-tui-design.md)
- **Target environment:** production Zimbra server, version detected at runtime
- **Interface:** Bash + whiptail

The 2026-07-28 draft established the objective, the non-goals and the read-only
posture. Those still hold and are not restated here. This document revises the
draft where it was wrong, fills the gaps that made it untestable, and cuts the
first release down to a slice that can be proven on a real server quickly.

---

## 1. Corrections to the 2026-07-28 draft

| # | Draft said | Correction |
|---|---|---|
| 1 | `zmprov getQuotaUsage` for one account | `gqu` takes a **server**, not an account, and dumps every account on it. Per-account: `zmprov gmi <account>` (mailbox id + used bytes) and `zmprov ga <account> zimbraMailQuota` (limit). |
| 2 | "Last logon timestamp" shown as fact | `zimbraLastLogonTimestamp` is throttled by `zimbraLastLogonTimestampFrequency` (default 1 day). It must be labelled as approximate in the UI. |
| 3 | Read-only defined by command name | Read-only must be defined by **effect**. `zmmailbox -z -m <account>` can materialise a mailbox that never existed, and `zmmailbox gm` may clear the unread flag — both pass a name-based allowlist. See §8. |
| 4 | `journalctl` in the approved list | The `zimbra` user is not in `systemd-journal`. Journal views are offered only when `EUID = 0`; otherwise the menu entry is unavailable, not a runtime permission error. |
| 5 | Injection treated as a shell problem | Shell safety does not protect the **Zimbra query language**. A `"` or `\` inside a subject changes query semantics without ever reaching a shell. A separate escape layer is required (§5.4). |
| 6 | `cmd=(/opt/zimbra/bin/zmmailbox …)` | Hard-coded absolute paths make the tool unmockable. Binary roots come from overridable variables with production defaults (§4.2). |
| 7 | Menus call whiptail directly | Navigation cannot be tested that way. All UI goes through `lib/ui.sh`, which has a stub backend (§4.2). |
| 8 | `set -o errexit` "used carefully" | Dropped. whiptail returns non-zero on Cancel/ESC, which kills the TUI under `errexit`; `errexit` is also silently disabled inside conditional contexts. `set -uo pipefail` plus explicit checks instead (§6.2). |
| 9 | Timeout unspecified | `timeout` must run **inside** the identity wrapper, otherwise killing `runuser` leaves the JVM alive (§5.5). |
| 10 | No performance model | Every `zmprov`/`zmmailbox` invocation starts a JVM (≈1–3 s). Bulk work needs `zmprov -l` for pure-LDAP attributes and single-process batching (§9, M6). |
| 11 | Single `lib/common.sh` | Splits into `core` / `exec` / `validate` / `capability` / `ui`. A shared grab-bag cannot be loaded selectively, and every test would drag in the whole program. |

---

## 2. Delivery milestones

The draft's v1 was eight menu groups and roughly forty operations. That defers
the only question that actually carries risk — *does the read-only claim hold
against a real server?* — to the very end. The work is sliced vertically
instead: M1 delivers the entire safety spine plus one real menu.

| Milestone | Contents |
|---|---|
| **M1** | Safety spine + account/quota menu. Exec gate, identity wrapper, validation, UI seam, capability probe, mock harness, static read-only scanner, ShellCheck + CI, `.gitattributes`. Menu: account existence/status, COS, mailbox host, mailbox id, quota, last logon, distribution-list membership. |
| M2 | Message search + message detail. Zimbra query builder and query escaping. |
| M3 | Mailbox and folder views. |
| M4 | Filters, forwarding, aliases, identities, signatures. |
| M5 | Delivery tracing and bounded log inspection. |
| M6 | Bulk queries, TSV/CSV metadata export, `zmprov -l` and batching. |
| M7 | System and service status. |
| M8 | Advanced read-only views (message body, blob path), explicitly labelled. |

**M1 uses `zmprov` and `zmcontrol` only.** `zmmailbox` does not appear in the M1
allowlist, so the two effect-level risks in §8 are structurally absent from the
first release rather than merely avoided by discipline.

---

## 3. Runtime version strategy

The target Zimbra version is not pinned. At startup the tool records
`zmcontrol -v` and probes for the binaries it needs. An operation whose
binary or subcommand is unavailable is shown as unavailable in the menu
rather than failing when selected. Capability results are cached for the
session; `ZRO_CAP_FORCE` overrides the probe in tests.

---

## 4. Architecture

### 4.1 Layout

```
zimbra-readonly-tui/
├── zimbra-ro-tui.sh        entry point: startup checks, main menu loop
├── lib/
│   ├── core.sh             exit codes, logging, mktemp + traps, helpers
│   ├── exec.sh             the exec gate: allowlist, identity, timeout
│   ├── validate.sh         input validators (pure functions, no dependencies)
│   ├── capability.sh       version record + capability probe
│   ├── ui.sh               whiptail | stub backend
│   └── account.sh          M1 menu: account, quota, COS, host, membership
├── tests/
│   ├── run.sh              runner
│   ├── lib/assert.sh       assertion library
│   ├── mocks/bin/          fake zmprov / zmcontrol / runuser
│   ├── fixtures/           captured real Zimbra output
│   └── test_*.sh
├── docs/operations.md
├── .gitattributes  .shellcheckrc  .github/workflows/ci.yml  README.md
```

Files under `lib/` are sourced, never executed. Each carries a reload guard and
a `# shellcheck shell=bash` directive. `validate.sh` depends on nothing, which
makes it the cheapest layer to test.

### 4.2 The three seams

Testability rests entirely on these. All three use production defaults, so
behaviour on the server is identical to a run with no overrides set.

| Seam | Responsibility | Test override |
|---|---|---|
| `zro_exec` | the only path to an external program | `ZRO_ZIMBRA_BIN` → `tests/mocks/bin` |
| `zro_ui_*` | the only path to the screen | `ZRO_UI_BACKEND=stub` — answers read from a queue, output captured to a file |
| `zro_cap_*` | version and capability facts | `ZRO_CAP_FORCE` pins results, probe does not run |

```bash
ZRO_ZIMBRA_BIN="${ZRO_ZIMBRA_BIN:-/opt/zimbra/bin}"
ZRO_LIBEXEC="${ZRO_LIBEXEC:-/opt/zimbra/libexec}"
ZRO_RUNUSER="${ZRO_RUNUSER:-/sbin/runuser}"
ZRO_TIMEOUT_BIN="${ZRO_TIMEOUT_BIN:-/usr/bin/timeout}"
ZRO_TIMEOUT="${ZRO_TIMEOUT:-60}"
```

### 4.3 Data flow

```
menu selection (fixed id — never operator text)
      │
      ▼
ui.sh          collect input (whiptail or stub)
      │
      ▼
validate.sh    REJECT ◄── malformed
      │  clean value
      ▼
account.sh     zro_exec zmprov ga "$acct" zimbraMailQuota
      │
      ▼
exec.sh   [1] allowlist   is zmprov:ga listed?      no → REJECT (90)
          [2] capability  is it available here?     no → REJECT (92)
          [3] identity    zimbra → direct | root → runuser -u zimbra --
          [4] timeout     inside the identity wrapper
          [5] argv[]      array only, no string assembly
      │
      ▼
parse (fixture-driven)  →  ui.sh: display
```

Two independent gates, both mandatory: an unvalidated value cannot reach
`zro_exec`, and a command absent from the allowlist cannot leave it.

---

## 5. Security model

### 5.1 The exec gate

Module functions build argv naturally, which keeps call sites readable, but
every execution passes one door that checks the `(binary, subcommand)` pair
against a central list:

```bash
zro_exec() {
  local bin=$1 sub=$2; shift 2
  zro_allowed "$bin" "$sub" || return "$ZRO_E_DENIED"    # 90
  ...
}
```

Adding an operation therefore requires two deliberate edits — the calling
function and an allowlist entry. In a read-only tool that friction is the
point: a command that is not listed does not run even if it is called.

### 5.2 M1 allowlist

```
zmprov:ga      getAccount
zmprov:gmi     getMailboxInfo
zmprov:gam     getAccountMembership
zmprov:gc      getCos
zmcontrol:-v   version
```

Both the long and short forms of each subcommand are listed; nothing else is.

### 5.3 Input validation (M1)

M1 accepts exactly one operator-supplied value, an account address.

- **email** — `^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$`, length ≤ 320.
- **domain** — leading `@` stripped, LDH labels, length ≤ 253.

Validators for dates, limits, item ids and folder paths ship with the milestone
that uses them. Adding them now would mean shipping untested-in-context code.

### 5.4 Zimbra query escaping (debt owed to M2)

Query values are wrapped and escaped for the query language, independently of
shell safety:

```bash
zro_query_quote() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}
```

Control characters and newlines are rejected before this point. This is listed
as an M2 acceptance criterion so the gap identified in the draft cannot be lost.

### 5.5 Identity and timeout

```
zimbra → run directly
root   → runuser -u zimbra -- …
other  → refuse (91)
```

`runuser -u` does not open a login shell, so `PATH`, `ZIMBRA_HOME` and
`JAVA_HOME` are absent — every binary is referenced by absolute path. `timeout`
runs **inside** the wrapper:

```bash
runuser -u zimbra -- timeout -k 5 60 /opt/zimbra/bin/zmprov ga …
```

Placing `timeout` outside would kill `runuser` and leave the JVM running. A
startup smoke check runs `zmcontrol -v` through the full wrapper; if that fails
the tool exits with a clear message rather than surfacing the fault later from
inside a menu.

### 5.6 Prohibited construction

No `eval`, no `bash -c`/`sh -c` on operator-influenced strings, no command
substitution built from input, no unquoted expansion in command position. Menu
selections are fixed identifiers and are never converted into command names.

---

## 6. Error handling

### 6.1 Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 10 | invalid input |
| 11 | account not found |
| 12 | mailbox not found |
| 13 | folder not found |
| 14 | no results |
| 20 | permission denied |
| 21 | Zimbra service unreachable |
| 22 | command timed out (`timeout`'s 124 normalised here) |
| 23 | log unreadable |
| 30 | partial bulk failure |
| 90 | **allowlist denial** — always logged, treated as a defect |
| 91 | unsupported operating-system user |
| 92 | capability unavailable |

### 6.2 Shell options

`set -uo pipefail`, without `errexit`. Failures are handled where they occur.
Cancel and ESC are ordinary navigation: `zro_ui_menu` reports them distinctly
from an error so the caller returns to the previous screen instead of exiting.

### 6.3 Temporary files

`mktemp` only, under `umask 077`, removed by traps on `EXIT`, `INT` and `TERM`.
Message bodies and attachments are never written to temporary files by default.

---

## 7. Testing

### 7.1 Runner

A dependency-free Bash runner (`tests/run.sh`) with an assertion library
(`tests/lib/assert.sh`). The decisive advantage is that the suite runs on the
Zimbra server itself during production acceptance, where installing a test
framework is not acceptable. Test files are plain `.sh`, so ShellCheck lints
them too.

### 7.2 Mocks and fixtures

`tests/mocks/bin` holds fake `zmprov`, `zmcontrol` and `runuser`. Each records
the argv it received, so tests assert on the **exact argument vector** rather
than on stdout alone — that is what proves no string assembly or unintended
flag reached the real binary. Responses come from `tests/fixtures`, which holds
captured real output.

### 7.3 Test categories

| File | Covers |
|---|---|
| `test_validate.sh` | accept/reject tables, including metacharacter, whitespace, newline and length attacks |
| `test_exec.sh` | allowlist denial, argv construction, identity selection per user, timeout placement, exit-code normalisation |
| `test_capability.sh` | probe results, unavailable operations suppressed |
| `test_ui_flow.sh` | menu navigation, Cancel/ESC returns rather than exits |
| `test_account.sh` | M1 operations against fixtures, including "account not found" |
| `test_readonly_scan.sh` | static guarantees (below) |
| `test_bash_compat.sh` | no bash 4.3+/4.4+ constructs |

### 7.4 Static read-only guarantees

`test_readonly_scan.sh` enforces, without executing anything:

1. No prohibited subcommand appears in an executable position anywhere in `lib/`
   or the entry point.
2. No `eval`, `bash -c`, `sh -c` or backtick construction.
3. **Every `zro_exec` call site in the tree resolves to an allowlist entry.**
   Adding a call the list does not cover fails the suite before the code can run.
4. The allowlist itself contains no write verb.

Guarantee 3 is the strongest of the four: it makes the allowlist a checked
invariant rather than a convention.

### 7.5 Compatibility floor

Bash 4.2 (CentOS 7 / Zimbra 8.8 remain common). No namerefs, no `${var@Q}`,
no `wait -n`. `test_bash_compat.sh` enforces this; a startup check reports a
too-old interpreter clearly.

### 7.6 Continuous integration

GitHub Actions on `ubuntu-latest`: ShellCheck over every `.sh` file including
tests, then `tests/run.sh`, then the static scanner. A red scanner blocks merge.

---

## 8. Read-only verification before production

Two behaviours are believed but not proven, and both are properties of
`zmmailbox`, which M1 does not use. They must be settled on a disposable test
account before M2 ships:

1. **Does `zmmailbox -z -m <account>` create a mailbox for an account that has
   never logged in?** If so, every `zmmailbox` path needs an existence
   pre-check, and the pre-check itself must not create one.
2. **Does `zmmailbox gm <id>` clear the unread flag?** If so, message detail
   must be sourced from `search` and `zmmetadump`, and body viewing must be
   gated behind explicit confirmation.

One M1-scoped item also needs confirming: whether `zmprov gmi` on an account
with no mailbox returns an error or provisions one.

The procedure for all three: record counters and flags before, run the
operation, compare after. Results are recorded in `docs/operations.md`.

---

## 9. M1 acceptance criteria

1. Running as any user other than `zimbra` or `root` refuses to start (91).
2. As `root`, every command observably runs through `runuser -u zimbra --`.
3. A `zro_exec` call for a command outside the allowlist returns 90 and logs,
   even when the calling function exists.
4. No operator-supplied text reaches a command except as a validated,
   individually quoted array element.
5. Cancel and ESC return to the previous menu from every M1 screen; the TUI
   never exits on a cancelled prompt.
6. The account menu produces correct output against fixtures for: existing
   account, non-existent account, account without a mailbox, account at quota.
7. ShellCheck is clean across the tree, including tests.
8. `test_readonly_scan.sh` passes, including the call-site/allowlist cross-check.
9. The suite runs on a stock Zimbra host with nothing installed beyond the repo.
