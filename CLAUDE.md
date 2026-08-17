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
shellcheck zimbra-ro-tui.sh lib/*.sh tests/*.sh tests/lib/*.sh
./tests/run.sh
```

## Agent skills

### Issue tracker

Issues live as GitHub issues in `Konsong/zimbra-readonly-tui`, managed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each label string equal to its name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context — `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
