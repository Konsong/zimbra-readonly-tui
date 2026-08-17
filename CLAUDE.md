# zimbra-readonly-tui

A Bash + whiptail TUI that runs read-only checks against a production Zimbra
server. The read-only guarantee is the product; treat it as the first constraint
on every change.

## Non-negotiables

- **Never add a write command.** Not `create`, `modify`, `delete`, `remove`,
  `move`, `mark`, `flag`, `tag`, `empty`, `import`, `post`, `recover`, `sync`,
  nor their short aliases (`dm`, `mm`, `mmr`, `ef`, `df`, `ma`, `da`, `ca`).
- **Everything external goes through `zro_exec`.** Never call a Zimbra binary
  directly from a module. Adding an operation means editing both the calling
  function and the allowlist in `lib/exec.sh` — that friction is intentional.
- **Judge commands by effect, not name.** Some read-sounding Zimbra commands
  write (see §8 of the design spec). An unverified assumption is not a green light.
- **No `eval`, no `bash -c`/`sh -c`, no command substitution from input.**
  Commands are Bash arrays. Operator text never becomes a command name.
- **Binary paths come from `ZRO_*` variables**, never hard-coded — that is what
  makes the tool mockable.

## Conventions

- `set -uo pipefail`. **No `errexit`** — whiptail returns non-zero on Cancel and
  would kill the TUI; `errexit` is also silently disabled in conditional contexts.
- **Bash 4.2 floor.** No namerefs, no `${var@Q}`, no `wait -n`.
  `tests/test_bash_compat.sh` enforces this.
- `lib/*.sh` are sourced, not executed: reload guard plus `# shellcheck shell=bash`,
  mode 644, no shebang.
- Exit codes are defined in `lib/core.sh`. `90` (allowlist denial) is a defect,
  not a user error — always logged.
- **A declared table is read through `lib/table.sh`, never by hand.** A table is
  `<key>:<field>[:<field>…]` rows in a `ZRO_` variable, and it travels to the
  reader as a **name**, not as its text — that is what lets a refusal say which
  declaration to edit. Absence is a refusal, never a default: an undeclared key,
  a missing field and an empty root all fail rather than resolve. Add the table
  to the list in `tests/test_table.sh` and give it a `# shellcheck disable=SC2034`
  with the reason on it. Two lists are deliberately NOT read this way — `ZRO_ALLOW`
  and `ZRO_LOW_PRIORITY` answer their own membership question; see
  [ADR-0009](docs/adr/0009-what-is-not-a-declared-table.md) before folding them in.
- Documentation and code in English; whiptail UI strings in Turkish.
- LF line endings, enforced by `.gitattributes`. This repo is developed on
  Windows where `core.autocrlf=true`; CRLF in a `.sh` file breaks the shebang
  on the server. Fixtures are exempt (`-text`): they are captured byte for byte,
  and a stored message blob really is CRLF.
- **No lone `"` inside a single-quoted string in the program's own files.** The
  static scanner tracks quote state across the whole tree as one stream, so one
  unbalanced quote makes it read every file after it inside out — strings as code,
  code as strings. Write the character as `$'\x22'` (see `ZRO_MSG_DQUOTE`). The
  failure reads "the scan's own view of the tree closes every quote it opens".
- **A screen test that answers the window menu reads the real clock**, so stamp
  its fixture tree RELATIVE to now (`NOW`/`TODAY` offsets, as
  `tests/test_delivery_screen.sh` does), never with calendar dates. Only the pure
  cases get a fixed tree, and only because they pass fixed bounds to match it. An
  absolute stamp in a screen test is a suite that goes red on a date nobody chose.

## Verification

ShellCheck must be clean across the tree, tests included. Run both before
claiming anything works — this project is developed on Windows, so run them
under WSL (`wsl -- bash -lc './tests/run.sh'`), not Git Bash:

```bash
shellcheck zimbra-ro-tui.sh lib/*.sh tests/*.sh tests/lib/*.sh \
           tests/mocks/*.sh tests/mocks/bin/* tests/mocks/libexec/* \
           tests/mocks/system/* tests/mocks/sbin/*
./tests/run.sh
```

**The mocks are in that list because CI lints them.** This command used to stop at
`tests/lib`, so a mock could fail the build after a green local run —
`.github/workflows/ci.yml` is what this has to match, and it is the file to check
if the two ever drift again.

**A green suite here is not a green suite everywhere.** The runner's `gzip` reports
a closed pipe differently from WSL's, which is how a compressed-blob read passed on
two machines and failed on CI. When a case turns on how an external command
*reports* something, script the other host's behaviour into the mock rather than
trusting the local one — `ZRO_MOCK_GZIP_PIPE_RC` in `tests/mocks/system/gzip` is
the worked example.

## Agent skills

### Issue tracker

Issues live as GitHub issues in `Konsong/zimbra-readonly-tui`, managed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each label string equal to its name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
