# Architecture review — where this tree is shallow, and what it has already cost

- **Date:** 2026-08-18
- **Scope:** the whole tree at `c275695`, surveyed for **deepening opportunities** — places where a module's
  interface is nearly as complex as its implementation, or where one rule is re-derived at N call sites. Seven
  candidates, ranked. The vocabulary is `/codebase-design`'s: module, interface, depth, seam, adapter,
  leverage, locality.
- **Method:** unlike every other note in this directory, **nothing here was measured on a server**. This is a
  static read of the tree — four sub-agents walking the screen layer, the exec gate, the domain modules and
  the test suite, each finding cross-checked afterwards by `grep`. Every claim below is marked
  **VERIFIED** (re-run directly against the tree) or **REPORTED** (a sub-agent's count, not independently
  re-run). Nothing here is a fact about Zimbra; it is a fact about this repository.
- **Companion:** [`2026-08-18-architecture-review.html`](2026-08-18-architecture-review.html) — the same
  seven candidates with before/after diagrams. It needs a network connection to render (Tailwind and Mermaid
  come from CDNs), which is why the findings are also written out here in full.

## 0. Where the change keeps landing

Churn over the last 60 commits — the survey was pointed here first, because deepening pays off where the next
change is going to land anyway. **VERIFIED.**

| file | commits | size |
|---|---|---|
| `CONTEXT.md` | 23 | 43 KB |
| `zimbra-ro-tui.sh` | 22 | 3,345 lines |
| `docs/operations.md` | 20 | — |
| `lib/exec.sh` | 16 | 959 lines |
| `tests/test_readonly_scan.sh` | 15 | 51 KB |
| `tests/test_main_menu.sh` | 11 | 40 KB |
| `tests/test_exec_allowlist.sh` | 10 | 41 KB |
| `lib/account.sh` | 10 | 963 lines |

15,054 lines of program against 17,023 of tests. The screen file and the exec gate are the two hot spots, and
their two giant tests account for 36 commits between them.

## 1. The gate's own codes are re-decided in every module — AND IT HAS ALREADY COST US A SCREEN

The single most important finding, because it is not a tidiness argument: it is visible to an operator today.

`zro_exec` returns codes that are **the gate's**, not the binary's — `90` denied, `91` bad user, `92` no
capability, `21` unavailable, `22` timeout. Which of those a module must pass through untouched is written out
six times, in **three different memberships**. **VERIFIED:**

| site | codes passed through |
|---|---|
| `lib/logview.sh:196` | DENIED BADUSER NOCAP TIMEOUT UNAVAILABLE |
| `lib/message.sh:536` | DENIED BADUSER NOCAP TIMEOUT UNAVAILABLE **+ INPUT** |
| `lib/queue.sh:254` | DENIED BADUSER NOCAP TIMEOUT *(no UNAVAILABLE)* |
| `lib/service.sh:150` | DENIED BADUSER NOCAP TIMEOUT *(no UNAVAILABLE)* |
| `lib/message.sh:332` | **none** |

**The live defect.** `zro_msg_fail_code` (`lib/message.sh:332-374`) has no `ZRO_E_DENIED` arm. It checks the
timeout, matches three text patterns, then falls through to `printf '%s' "$ZRO_E_UNAVAILABLE"`. So an
allowlist denial on `zmmetadump` — exit `90`, which `lib/core.sh:46` defines as *a defect in this program* and
which is always logged — reaches the operator through `zimbra-ro-tui.sh:401-407` as:

> zmprov varsayilan olarak mailboxd servisine SOAP ile baglanir. En sik iki sebep: mailbox servisi durmus…

That sentence names a service `zmmetadump` never talks to. The log line is still written
(`lib/exec.sh:890`), so the defect is recorded — the screen just names the wrong thing. Thirty lines further
down **in the same file**, `zro_msg_head_fetch` (`:536`) passes `90` through correctly.

**The three settlers are byte-identical apart from the classifier they name. VERIFIED** —
`lib/store.sh:268`, `lib/search.sh:737`, `lib/message.sh:379`:

```bash
zro_<X>_settle() {
  local errfile=${1-} rc=${2-0} msg mapped
  if [ "$rc" -eq 0 ]; then
    rm -f -- "$errfile"; zro_clear_error; printf '0'; return 0
  fi
  msg=$(head -c 500 -- "$errfile" 2>/dev/null)
  mapped=$(zro_<X>_fail_code "$errfile" "$rc")     # <-- the only difference
  [ -n "$msg" ] && zro_set_error "$msg"
  rm -f -- "$errfile"
  printf '%s' "$mapped"
}
```

And the 500-byte bound is a literal in **12 places. VERIFIED:** `account.sh:323`, `delivery.sh:333`,
`delivery.sh:399`, `logsearch.sh:607`, `logsearch.sh:668`, `logview.sh:190`, `message.sh:387`,
`message.sh:521`, `queue.sh:238`, `search.sh:745`, `service.sh:144`, `store.sh:276`. `zro_set_error`
(`lib/core.sh:118`) — the function that would own it — does not bound at all.

**Proposed deepening.** One `zro_settle "$errfile" "$rc" <mapper-name>` beside the gate, owning the
passthrough set, the 500-byte bound, `zro_set_error`/`zro_clear_error` and the tmpfile. Each module supplies
only the thing that is genuinely its own — the text→code mapper — travelling as a **name**, which is the
convention [ADR-0009](../adr/0009-what-is-not-a-declared-table.md) already settled for tables.

**Two questions the merge must answer first**, because the differences above may not all be accidents:

1. Are `queue`/`service` omitting `UNAVAILABLE` deliberately? If yes, a single passthrough set is the wrong
   shape and the mapper needs a say.
2. `zro_msg_fail_code:361-373` **deliberately** refuses the shared Zimbra-error reader, with a measured
   reason: the dump takes no SOAP path, and its failure text is a `DbPool` exception carrying a JDBC URL.
   That refusal has to survive whatever replaces it.

## 2. The declared cost class is checked but never spoken

Every operation declares a cost class (`ZRO_MENU_OPS`, `zimbra-ro-tui.sh:2959`) and every class declares a
unit (`ZRO_COST_CLASSES`, `:2906`). **`zro_menu_cost` has zero callers in the program. VERIFIED** — every hit
outside its own definition is under `tests/`. `zro_cost_unit` is called exactly once, by `zro_menu_cost`
itself (`:3006`), purely to refuse class 4.

What the operator actually reads before spending is hand-written **five ways**:

| mechanism | screens | site |
|---|---|---|
| `zro_account_cost_note` — a case list | 3 + default | `:424-441` |
| `zro_mailbox_cost_note` — a second case list | 8 + defect default | `:630-676` |
| inline literal in the notice body | dl, domain, trace, logview, identity | `:1412`, `:1466`, `:1641`, `:1832`, `:3177` |
| a `ZRO_TXT_*` constant | queue, service | `:2374`, `:2527` |
| a `zro_ui_yesno` confirmation | log search, bulk | `:2257`, `:2711` |

The two case lists **disagree about failure**: `zro_mailbox_cost_note`'s default arm logs a defect
(`:672-674`); `zro_account_cost_note`'s silently prints a generic sentence (`:438-440`). Add a `mailbox-*`
operation with no note and the tool shouts. Add an `account-*` one and nothing does.

Nothing fails if a screen's note says "two queries" while its declared class says otherwise.

## 3. A partial answer is a code plus a habit, not a value

**VERIFIED.** Three modules produce `ZRO_E_PARTIAL` and each builds its own banner —
`lib/delivery.sh:164`/`:442`, `lib/logsearch.sh:440`,`:461`/`:706`, `lib/bulk.sh:650`,`:663`/`:804`. Then three
screens each hand-write a title:

```
zimbra-ro-tui.sh:1689   zro_show_text "Teslim izi - EKSIK TARAMA" "$out"
zimbra-ro-tui.sh:2326   zro_show_text "Log arama - EKSIK TARAMA"  "$out"
zimbra-ro-tui.sh:2838   zro_show_text "$title - EKSIK SONUC"      "$out"
```

Two hard-code a title instead of reading the one `ZRO_MENU_OPS` already carries, and they use two different
suffix words. A fourth rendering exists at `zimbra-ro-tui.sh:388-393` — the shared reporter's arm for code 30,
which shows a `msgbox` and **is never handed `$out`**. A screen that returns 30 and forgets the `if` discards
both the answer and the banner the module worked to write.

**REPORTED:** the two log banners disagree about arithmetic. `delivery.sh:167` computes the selection as
`read_n + skipped_n`; `logsearch.sh:435-439` takes `selected_n` directly, because a cap leaves files that are
neither read nor skipped. The second is the corrected version of the first, and the first was never corrected.

## 4. The card vocabulary is not an account concept

**VERIFIED.** `zro_card_line`, `zro_card_head`, `zro_card_more`, `zro_card_list`, `ZRO_CARD_LABEL_W` and the
three absence words `ZRO_TXT_UNSET`/`UNKNOWN`/`NONE` are defined in `lib/account.sh:370-418` — a domain module
— and called **183 times from 11 other modules**. That is why `lib/account.sh` must be sourced tenth in
`zimbra-ro-tui.sh:30`, ahead of `mailset`, `bulk`, `mailbox`, `store`, `search`, `message`, `identity`,
`directory`, `queue` and `service`. The load order encodes a dependency on a domain module for rendering.

Reaching across already felt wrong to somebody once: `lib/queue.sh:348` forked the unreadable-size fallback,
printing the raw number where `lib/store.sh:371` prints `bilinmiyor`. Same value, two answers for the same
absence — which is exactly the distinction `CONTEXT.md` §Asking about an address exists to protect.

The move to `lib/card.sh` is a pure relocation: no call site changes.

## 5. An operation is declared once and re-matched five times

`ZRO_MENU_OPS` declares `id:scope:class:label`. Four more per-id decisions live in scattered `case` lists,
each with its own defect branch — **VERIFIED:** the dispatch (`:3300-3332`), the capability refusal
(`:3047-3079`), the unavailability screen (`:3104-3127`), and the cost note (`:424`/`:630`). On top of that the
account-scoped preamble is copied five times (`:451`, `:540`, `:700`, `:972`, `:1184`), differing by one word.

**`zro_menu_entry` (`:2987-2989`) is dead. VERIFIED** — its own definition is the only hit in the repository.
Its comment claims *"Every lookup below goes through this, so an id that is not in the list has exactly one
answer everywhere"*, and its three siblings — `zro_menu_ids`, `zro_menu_scope`, `zro_menu_cost` — all call
`lib/table.sh` directly instead. Deleting it is a two-line change independent of everything above.

## 6. One record reader instead of eight

**REPORTED.** `key: value` is one output shape with eight readers: `lib/account.sh:49`, `:58`, `:111`, `:173`
(three genuinely different questions — this split earns its keep), `lib/mailset.sh:252`, `:311`,
`lib/identity.sh:61`, `lib/directory.sh:191`, `:235`.

Two of them reimplement `zro_attr_get`'s rule — once in awk with `RS=""`, once in parameter expansion with the
attribute names hard-coded as literal prefixes — because what they actually need is a **record** boundary, and
the record reader does not exist. The "a declared attribute ends a value" rule has three implementations
(`account.sh:111`, `search.sh:161-167`, `mailset.sh:241-247`) whose comments each name the other two. And the
`# <kind> <address>` header line is parsed twice off the same text: `directory.sh:94` calls
`zro_identity_canonical`, then hands the same raw output to its own `#`-line parser at `:191`.

**Keep out:** `ZRO_SEARCH_PROMPTS`. [ADR-0009](../adr/0009-what-is-not-a-declared-table.md) explains why that
shape stays separate — folding it in buys a parameter meaning *which of two readers am I*.

## 7. The suite's preamble is an interface nobody wrote down

**VERIFIED:** `tests/lib/` is **153 lines** (`assert.sh` 99 + `cost.sh` 54). Against that, 36 test files export
`ZRO_MOCK_LIB`, 34 carry the same `chmod +x` line that `tests/run.sh:12-16` already runs, and
`queue() { printf '%s\n' "$@" >"$ZRO_UI_QUEUE"; zro_ui_reset; }` appears **13 times** character-for-character.

**REPORTED:** the 15-line environment block is byte-identical in 8 files and drifted cosmetically in 4 more;
`ran()` has 17 definitions in 5 spellings; the existence gate — this project's central invariant — is restated
in **7 files in two mutually incompatible calling conventions** (a `"$@"`-prefixing wrapper dialect and an
export/unset dialect). The median first-assertion line across 51 files is **69**.

**REPORTED, and the sharpest number in the survey:** 188 of 461 functions are never named in any test. The
four modules at **0% untested** are `selection`, `table`, `validate` and `window` — exactly the four that take
values and return values, touch no external command and open no screen. `zimbra-ro-tui.sh` sits at 76%
untested. The coverage gradient tracks depth precisely, which is candidates 1–5 restated as a measurement.

`tests/lib/cost.sh` is the counterexample and the model: `assert_cost` reads the operation's declared class
*and its unit* out of the program rather than restating a number, and its header says why —
*"A case that could only say '3' would be describing the implementation back to itself."*

## 8. What is already deep, and was deliberately left alone

Worth recording so a future survey does not "improve" it:

- **`lib/table.sh`** — eleven declarations, one reader, five rules that were each a defect somewhere first.
  The deepest module in the tree.
- **The allowlist half of `lib/exec.sh`** — `tests/test_exec_allowlist.sh` stands `zro_allowed` up in 5 lines
  of setup and gets 238 assertions out of it. **VERIFIED:** 56 allowlist rows, 14 public functions, 22
  production call sites of `zro_exec`, none of them in `zimbra-ro-tui.sh`.
- **`lib/ui.sh`** — one seam, two real adapters (whiptail and the stub). `zro_ui_title` applies the selected
  address at the one path to the screen, so a screen written next month cannot forget it.
- **`tests/lib/cost.sh`** — see §7.
- **The column-table readers** — `store.sh:99`/`:130`, `search.sh:607`/`:630`, `queue.sh:120`, `service.sh:91`.
  One reader per output *shape*, and both files say out loud why two tables read by one function are two
  tables that agree by accident.

## Recommended order

1. **§1** — the only one with a live consequence, and the cheapest deep module in the list.
2. **§4** — hours, pure move, and it clears the way for §2's cost note to live beside it.
3. **§2** and **§3** — each removes one of §5's five sites.
4. **§5** last, when its blast radius is smallest.

§6 and §7 are independent of the rest and can be picked up whenever.
