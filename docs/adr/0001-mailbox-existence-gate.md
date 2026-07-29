# Mailbox existence gate for `zmmailbox` operations

- **Status:** accepted
- **Date:** 2026-07-29
- **Resolves:** §2.1 of [`docs/superpowers/specs/2026-07-29-zimbra-readonly-tui-design.md`](../superpowers/specs/2026-07-29-zimbra-readonly-tui-design.md)
- **Affects:** M2, M3, M4, M8

`zmmailbox` creates a mailbox for an account that has none, during session setup
rather than inside any subcommand — confirmed by experiment on 2026-07-29
([observed](../research/2026-07-29-observed-on-our-servers.md) §6.2). Four
milestones depend on that binary. We decided that a `zmmailbox` session may be
opened **only after a command incapable of provisioning has proven the mailbox
already exists**, and that the guarantee admits no operator-confirmed exception.

## The decision

**The guarantee is absolute.** The tool never emits a command that changes
domain state, with or without consent. Read-only is defined in
[`CONTEXT.md`](../../CONTEXT.md) as *no change to Zimbra-managed domain state* —
log lines a server writes about being queried, and the tool's own scratch files,
are incidental artifacts and do not break it. That boundary was already implicit
in shipped M1, which writes an `audit.log` line on every `zmprov` call.

**The unit of decision is the subcommand, and §2.1 splits in two.** It conflated
two independent effect classes:

- **D1 — provisioning.** Whether a session may be opened at all. Answered here.
- **D2 — in-mailbox mutation.** Which subcommands are safe once inside a mailbox
  that certainly exists. Largely settled already by the summary table in
  [the CLI reference](../research/2026-07-29-zimbra-cli-read-only-reference.md):
  `search`, `gaf`, `gms`, `gfrl`/`gofrl` and `gc <conv-id>` are safe; `gm` clears
  UNREAD and `sf` fetches a remote feed, so both are refused; `gru` writes a
  local file with `-o`. Entries land in the allowlist with the milestone that
  uses them.

An existence gate does nothing about D2, and banning `gm` does nothing about D1.

**The oracle is layered.** `zimbraLastLogonTimestamp` being set proves a mailbox
exists — an account cannot log in without one — and the account screen already
reads it, so the common case costs no extra invocation. Where it is unset, the
gate falls back to `zmprov gis` (`GetIndexStats`), which passes
`DO_NOT_AUTOCREATE` and throws `mailbox not found` instead of provisioning. If
neither can answer, the gate refuses.

**Enforcement is structural, not disciplinary.** `zmmailbox`'s argv shape is
`zmmailbox -z -m <acct> <subcommand>`, which puts the subcommand out of reach of
the allowlist's two- and three-token prefix model; an entry like
`zmmailbox:-z:-m` would approve everything behind it, which is exactly what §9.3
refused to do for `zmprov:-l`. So a single function owns the whole fixed prefix:
callers pass an account, a subcommand and arguments, and never write `-z` or
`-m` themselves. That function runs the oracle and hands `zro_exec` a subcommand
in a position the allowlist can see. `zro_exec` refuses the `zmmailbox` binary
when `${FUNCNAME[1]}` is anything else, and the static scanner enforces that no
other call site names it.

**Refusal is an answer.** An account with no mailbox produces a plain result —
it has never logged in and never received mail — under the existing exit code
12, not an error dialog. Shipped M1 screens are unchanged.

**Verdicts cache one way.** A proof of existence is held for the session; a "no
mailbox" verdict is never cached, because the next delivered message falsifies
it and an operator who has just sent a test message must not be told a stale no.

**Coverage degrades before the guarantee does.** Where `gis` is unavailable —
absent on that build, the *reindex* right denied, or an unexpected error — the
gate runs one-sided, carries a sticky banner for the whole screen, and refuses
accounts it cannot clear. This mirrors the banner discipline §9.2 established
for degraded reads.

## Considered options

**Disclose and confirm — rejected.** Warning before a `zmmailbox` operation and
proceeding on an explicit yes keeps every feature, and it is honest. It was
rejected because it hands the operator a judgement they cannot make: whether the
mailbox exists is precisely what they came to find out. It would also weaken the
static guarantee in §7.4 from *no write verb may appear in the tree* to *a write
verb may appear if guarded*, which is not statically decidable.

**Do without `zmmailbox` — rejected.** Safe by construction, no oracle to
maintain, no race to document. Rejected on cost: there is no directory source
for messages or folders, so M2, M3 and M8 lose their only source outright. Much
of M4 survives without it — aliases, forwarding, signatures and identities are
all LDAP — but filter rules do not.

**Other oracles considered.** `zmprov gqu <server>` reports `quotaUsed: 0` for
an empty mailbox and for no mailbox alike, so it cannot serve as an oracle at
all. `zmmetadump -m <acct> -i 1` is the best-evidenced read-only command in the
whole survey — every statement a `SELECT`, the connection opened
`autoCommit(false)` and never committed — and it works with `mailboxd` stopped,
but it reads the **local** MySQL only. `zmmailbox` proxies to the account's home
host by itself, so on any host that is not the mailbox's home the oracle could
not answer for an account the operation could otherwise reach; and it cannot
distinguish "no mailbox" from "homed elsewhere" without a separate lookup. It
remains the right tool for M8's message-body problem, where locality is not a
constraint.

## Consequences

**`zmprov gis` is not in the allowlist yet, and M2 is blocked until it is.** The
gate now structurally depends on the claim that `gis` throws rather than
provisions — the same claim `gmi` failed. Present evidence is one row in a
summary table. Before it ships it must reach the depth of §A.3 and §A.5: the
call site cited, then an experiment on TEST-C against an account with no mailbox
(expect `mailbox not found`, no new `mailbox` row, no `Creating mailbox with id`
line) and against an account with an unindexed mailbox (snapshot the index
directory and database rows either side). The experiment must also settle
**whether `gis` proxies to the account's home host**; if it does not, the gate is
one-sided on every multi-server deployment, including ours.

**Ordering is unchanged.** M5 remains next: delivery tracing reads logs, opens no
mailbox, and answers the question operators ask most. The `gis` experiment is
hours of server work, not a milestone, and runs alongside — off the critical
path. M2 then ships as gate plus search, mirroring M1's shape of a shared safety
mechanism proven against one real screen.

**One race is documented rather than defended against.** A mailbox deleted by
another administrator between proof and use would be recreated by the next
`zmmailbox` call. Deletion is a deliberate administrative act and the window is
a single session; closing it would cost a probe before every operation.

**M8 still has no answer for message bodies.** `gm` is refused for clearing
UNREAD. The candidates are a `GetMsgRequest` issued without the `read` attribute,
the REST content servlet, or `zmmetadump`. That decision is M8-scoped and is not
made here.
