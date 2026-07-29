# zimbra-readonly-tui

A terminal UI for Zimbra administrators that runs **read-only** checks against a
production mail server — accounts, quotas, mailboxes, messages, delivery traces,
filters and service health — without changing any Zimbra data or configuration.

Bash + whiptail. No runtime dependencies beyond what a Zimbra host already has.

> **Status: M1 complete, pending verification on a real server.** The safety
> spine and the account/quota menu are built and tested: account summary, quota
> usage and distribution-list membership. Before using it against real accounts,
> work through the acceptance steps in the [operator guide](docs/operations.md) —
> three questions about Zimbra's own side effects are still open and are recorded
> there. Message search arrives in M2; see the
> [design spec](docs/superpowers/specs/2026-07-29-zimbra-readonly-tui-design.md).

## Why "read-only" is a structural claim, not a promise

Any tool that runs `zmprov` and `zmmailbox` on a live server is one typo away
from a write. This one is built so a write cannot be expressed:

- **One exec gate.** Every external command passes through a single function
  that checks the `(binary, subcommand)` pair against a central allowlist.
  A command that is not listed does not run, even if some function calls it.
  A mode flag such as `zmprov -l` is only ever approved together with the
  subcommand it precedes — listing the flag alone would admit everything behind
  it.
- **A checked invariant, not a convention.** The test suite statically extracts
  every call site in the tree and fails if any of them resolves to something the
  allowlist does not cover.
- **No string assembly.** Commands are built as Bash arrays. No `eval`, no
  `bash -c`, no command substitution from operator input.
- **Menu selections are fixed identifiers.** Operator text never becomes a
  command name.
- **Effect, not just name.** Some read-sounding Zimbra commands have write side
  effects. Those are tracked and verified rather than assumed — see §8 of the
  design spec.

## Running as root or zimbra

```
zimbra → commands run directly
root   → commands run through: runuser -u zimbra -- timeout -k 5 60 <binary> …
other  → refused at startup
```

`timeout` sits inside the identity wrapper deliberately: outside it, killing
`runuser` would leave the Zimbra JVM running.

## Requirements

- Bash ≥ 4.2 (CentOS 7 / Zimbra 8.8 are still in the field)
- `whiptail` (`newt` on RHEL family, `whiptail` on Debian/Ubuntu)
- A Zimbra installation; version is detected at runtime, not pinned

## Tests

The suite has **no dependencies** — that is deliberate, so it can run on the
Zimbra host itself during production acceptance:

```bash
./tests/run.sh
```

External Zimbra binaries are replaced by mocks that record the exact argument
vector they received, so tests assert on what would have been executed, not
merely on printed output. Nothing in the suite contacts a real server.

The suite also enforces the Bash 4.2 floor by scanning for constructs that only
exist in later versions — development happens on 5.x, where they would pass
silently and fail only on an older Zimbra host.

## Documentation

- [Operator guide](docs/operations.md) — installation, failure messages, exit codes, and the production acceptance procedure
- [Design spec](docs/superpowers/specs/2026-07-29-zimbra-readonly-tui-design.md) — architecture, security model, milestones
- [Implementation plan](docs/superpowers/plans/2026-07-29-m1-safety-spine-account.md) — the M1 task breakdown
- [Original design draft](docs/superpowers/specs/2026-07-28-zimbra-readonly-tui-design.md) — superseded, kept for history
