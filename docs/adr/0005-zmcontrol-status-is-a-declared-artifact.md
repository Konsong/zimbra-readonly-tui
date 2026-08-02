# `zmcontrol status` is admitted as a declared artifact

- **Status:** accepted
- **Date:** 2026-08-03
- **Resolves:** the third condition the glossary's [declared artifact](../../CONTEXT.md) entry requires
- **Evidence:** [`docs/research/2026-07-29-zimbra-cli-read-only-reference.md`](../research/2026-07-29-zimbra-cli-read-only-reference.md) §B.12, and the status captured on the lab server in [`docs/research/2026-08-02-mta-queue-and-log.md`](../research/2026-08-02-mta-queue-and-log.md) §9
- **Affects:** the service status screen, and every borderline command judged after it

The tool's guarantee is that running it leaves no change to Zimbra-managed domain state, and that the
guarantee is about **effect, never about a command's name**. `zmcontrol status` is the first command this
project has admitted whose effect includes a **write**, so the reasoning is recorded rather than left in a
comment.

Read from source rather than assumed, it does three things to disk: it creates the localconfig temp
directory when it is missing, it leaves temp files in it, and it **rewrites `/opt/zimbra/log/.zmcontrol.cache`
on every successful directory lookup**. It starts and stops nothing.

## The decision

**It is admitted, as a declared artifact, under three conditions that hold together.**

1. **It changes no domain state.** No account, mailbox, folder, message, flag, filter, configuration or
   service is different afterwards. Service state is domain state in this project's vocabulary — which is
   exactly why the rest of that binary is refused — and this subcommand does not touch it.
2. **The screen that runs it says what it writes.** Not the manual, not a comment: the box the answer
   arrives in. An operator who can see which file was rewritten can go and look at it, which is the
   difference between trusting the read-only claim precisely and trusting it vaguely. `tests/test_service.sh`
   and `tests/test_service_queue_screen.sh` fail the build if that disclosure leaves the screen.
3. **This ADR records the judgement.**

Remove any one of the three and the operation comes out of the allowlist with it. Three conditions rather
than one, because the alternative is a guarantee that widens one convenient command at a time.

**The rest of that binary stays refused.** `start`, `stop`, `restart`, `shutdown` and `maintenance` are
absent from the allowlist, named in the tests, and refused at the gate. This is the one binary in the tool
whose family changes service state, and the entry for `status` is not approval of the binary.

**Its wall-clock bound is not optional.** The command wraps each service it asks in an alarm and wraps the
**directory lookup it makes first in nothing**, so a hung LDAP master leaves it waiting with nothing of its
own to interrupt it. The gate's timeout is therefore the only thing that ends it, and the screen reports the
expiry as itself — naming the directory as the place to look — rather than as a server that answered
nothing. That is a screen, not a log line: a tool that appears to hang is a tool an operator kills.

## What was rejected

**Reading `.zmcontrol.cache` and the pid files directly**, which the research file records as the strictly
read-only alternative. It would satisfy the letter of the guarantee and answer a worse question: the cache is
what `zmcontrol` last wrote rather than what is running now, and reading pid files means this tool carrying
its own model of Zimbra's service layout and being wrong about it one release later. A stale answer about
whether the mailbox service is up is worse than a disclosed cache write.

**Admitting it quietly**, on the grounds that a cache file is obviously harmless. That is the reasoning this
project exists to refuse: `zmprov gmi` is also obviously harmless, and it provisions mailboxes.

## Consequences

The glossary now has a word for this class of command, so the next borderline one is **measured against
three conditions rather than argued about**. Anything that fails one of them is refused; anything that
passes all three arrives with its own ADR, its own screen text, and a test holding the screen to it.

The read-only guarantee gains a precise edge instead of a vague one. "This tool writes nothing at all" was
never true of any tool that runs a JVM — the audit log alone falsifies it — and a claim that is nearly true
is one an operator eventually catches out. "This tool changes no domain state, and here is the one thing it
writes and where" survives being checked.
