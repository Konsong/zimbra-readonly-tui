# zimbra-readonly-tui

A terminal UI for Zimbra administrators that runs **read-only** checks against a
production mail server — accounts, quotas, mailboxes, messages, delivery traces,
filters and service health — without changing any Zimbra data or configuration.

Bash + whiptail. No runtime dependencies beyond what a Zimbra host already has.

> **Status: M1 verified on a production server.** The safety spine and the
> account/quota menu are built, tested and exercised against a live Zimbra:
> running every screen left `mailboxId` and `quotaUsed` unchanged, and a message
> delivered afterwards was reflected immediately — so the readings are live and
> the tool changes nothing. It was also run against a server with `mailboxd`
> stopped, where it degraded to LDAP reads rather than failing.
>
> **The first mailbox screens are in.** Folders, one folder, one folder's
> sharing, the mailbox size and quota usage all read the mailbox itself — behind
> an existence gate that proves the mailbox is there using a command incapable of
> creating one, because `zmmailbox` provisions during session setup. Each of the
> four reads was measured on a lab server with the account's row in the `mailbox`
> table captured either side, against a control that moved it: see
> [the research note](docs/research/2026-08-02-folders-size-and-quota.md).
> **And the two screens about the server itself.** The mail queue is read with
> the listing form of `postqueue` and no other — the forms that flush, requeue or
> delete are refused, because each of them makes the transfer agent act — and it
> answers with counts by status before it answers with a bounded list. Service
> status is the one operation whose command **writes**: `zmcontrol status`
> rewrites a cache inside Zimbra's tree, changes no domain state, and is admitted
> only because the screen says what it writes and
> [ADR-0005](docs/adr/0005-zmcontrol-status-is-a-declared-artifact.md) records
> the judgement.
>
> **And what decides where an account's mail goes.** Filter rules, local
> delivery, aliases, send-as identities and signatures are read from the
> directory and open no mailbox, so they answer in full for an account that has
> never been used — measured on the lab server, where `zmprov gis` reported no
> mailbox for that account before the reads and again after them. The filter
> rules get a screen of their own because a rule set is one attribute holding a
> whole script: the single-line attribute reader truncates it to its first rule,
> which hides every rule underneath, so a sibling reader treats any line that
> does not begin a **declared** attribute as a continuation — a continuation may
> be blank, may begin with `#`, and may look exactly like an attribute line.
>
> **Finding a message, and then reading one.** The search builds its query out of
> criteria an operator picks — nothing typed becomes an operator, a field name or a
> boolean — and shows the finished query above the answer. Reading one message is
> the part that could not be done the obvious way: the single command that answers
> it, `zmmailbox gm`, **clears the unread flag on the message it reports**, so the
> record is read straight from the mailbox database with `zmmetadump` and the
> headers, addresses and attachment list from a bounded read of the file the
> message is stored in. The body is out of scope and is not read. That screen is
> the one mailbox screen with no existence gate in front of it, because it opens no
> mailbox session at all — and on the lab server the messages it displayed in full
> were still unread afterwards, with the account's `mailbox` row byte-identical:
> [the research note](docs/research/2026-08-17-message-detail.md),
> [ADR-0008](docs/adr/0008-message-detail-is-the-dump-and-a-bounded-blob-head.md).

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
