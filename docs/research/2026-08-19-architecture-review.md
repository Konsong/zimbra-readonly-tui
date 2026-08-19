# Architecture review — what the settler migration left, and what four fresh walks found

- **Date:** 2026-08-19
- **Scope:** the whole tree at `406c9a9`, surveyed for **deepening opportunities** — places where a module's
  interface is nearly as complex as its implementation, or where one rule is re-derived at N call sites.
  Thirteen candidates in four groups, ranked. The vocabulary is `/codebase-design`'s: module, interface,
  depth, seam, adapter, leverage, locality.
- **Method:** as with [the previous survey](2026-08-18-architecture-review.md), **nothing here was measured on
  a server**. This is a static read of the tree — four sub-agents walking the screen layer, the safety spine,
  the domain modules and the test suite. Unlike that one, **every number the previous survey reported was
  re-run rather than inherited**, and the headline claims were then verified a third time by hand — then a
  fourth time, adversarially, by an agent briefed to refute rather than confirm. **That pass changed this
  document**: one claim of its own was withdrawn and eight numbers were corrected before it was committed.
  Of the previous survey, one claim did not survive and one was overstated; both are marked in place in that
  file and set out in §Corrections below. Nothing here is a fact about Zimbra; it is a fact about this
  repository.
- **Companion:** [`2026-08-19-architecture-review.html`](2026-08-19-architecture-review.html) — the same
  thirteen with before/after diagrams. It needs a network connection to render (Tailwind and Mermaid come
  from CDNs), which is why the findings are written out here in full.
- **Already acted on:** **§1 shipped the same day**, as
  [PR #75](https://github.com/Konsong/zimbra-readonly-tui/pull/75) — the two mappers renamed, three static
  cases added, `CONTEXT.md` given the **outcome reader** term and ADR-0010 a correction section. The finding
  is left below as it was written, because the reasoning is what the other twelve are ranked against.

## 0. What has changed since 2026-08-18

The previous survey's **§1** — the gate's own codes re-decided in every module — **has landed**.
`lib/settle.sh` exists, `zro_exec_own_code` owns the predicate, `ZRO_ERROR_KEEP_BYTES` replaced the 500-byte
literal at all twelve sites, and [ADR-0010](../adr/0010-the-gate-owns-the-predicate-and-one-settler-asks-it.md)
and [ADR-0011](../adr/0011-the-four-lines-above-the-settler-stay-at-the-call-site.md) record what deliberately
did NOT move. This review does not re-propose it. It reports what the migration left, and what four fresh
walks found around it.

Churn over the last 60 commits — the survey was pointed here first. **VERIFIED.**

| file | commits | size |
|---|---|---|
| `CONTEXT.md` | 21 | 864 lines |
| `zimbra-ro-tui.sh` | 17 | 3,347 lines |
| `lib/exec.sh` | 17 | 1,001 lines |
| `docs/operations.md` | 16 | — |
| `tests/test_readonly_scan.sh` | 13 | — |
| `lib/message.sh` | 7 | 1,057 lines |
| `lib/account.sh` | 7 | 963 lines |

15,261 lines of program against 17,557 of tests. The screen file and the exec gate are still the two hot spots.

---

# A. Live consequences

Five findings where something is wrong today, not merely arranged awkwardly. Each is small.

## 1. The settler admits a failure reader it cannot call

**Files:** `lib/settle.sh:47`, `:131`, `lib/account.sh:234`, `lib/delivery.sh:47`

`zro_settle_reader_ok` asks whether a name is *shaped* like a failure reader and whether a function answers to
it. It does not ask whether that function can be **called** with the one argument the settler passes — and
bash cannot be asked how many arguments a function takes. **VERIFIED:** two of the five `*_fail_code`
functions take more than one.

| function | arguments | handed to the settler? |
|---|---|---|
| `zro_store_fail_code` | 1 | yes |
| `zro_search_fail_code` | 1 | yes |
| `zro_msg_fail_code` | 1 | yes |
| `zro_prov_fail_code` | **3** | **no** |
| `zro_trace_fail_code` | **2** | **no** |

Both match `ZRO_RE_FAIL_READER` and both are sourced by the entry point. Under `set -u` with no `errexit` the
reader's `local` assignment dies, `zro_settle` prints nothing, and the caller's `[ "$rc" -eq 0 ]` errors on an
empty string — the operator is handed a code this program does not define, by the module written to stop
exactly that, and **neither refusal is logged, because neither fires**.

ADR-0010 states the check is *"a defence against an edit"*. The two names an edit is most likely to reach for
are the two it does not cover.

**Deletion test:** the check cannot be deleted — it is the module's only test. It is one question short, not
surplus. **Strong.** *(Shipped as PR #75; the repair was a name rather than a third run-time question — see
that PR and ADR-0010's closing section.)*

## 2. The message-id rule has two implementations, and they disagree

**Files:** `lib/delivery.sh:139`, `zimbra-ro-tui.sh:942`, `lib/validate.sh:159`, `lib/search.sh:367`

`zro_trace_msgid_bare` strips **only a matching pair** of angle brackets, and says why at `:135`: *"never more
than one: that is unwrapping a delimiter the syntax defines, not repairing a value into something nobody
typed."* `lib/logsearch.sh:809` calls it rather than copying it, warning in place that a second implementation
*"is the kind of pair that drifts."*

**VERIFIED — it drifted.** The mailbox-search screen at `zimbra-ro-tui.sh:942` strips each end
independently. `lib/validate.sh:159` refuses anything still wearing a bracket, so for `<CAabc123@example.com`:

- delivery trace and log search **refuse** the input;
- mailbox search **accepts** it and searches for `CAabc123@example.com`.

`tests/test_delivery.sh:553-554` pins both half-bracket cases on the owner's side. Nothing pins the screen's
copy.

**Deletion test:** concentrates — the rule moves into the module that already owns it and already tests it.
Four lines deleted, one added. **Strong.**

## 3. The alias disclosure is applied by habit, and one screen forgets

**Files:** `zimbra-ro-tui.sh:520`, `:1158`, `lib/ui.sh:20`, `lib/search.sh:1074`

`zro_screen_alias_note` exists to prevent what its own comment describes: *"A card headed
`Hesap: ahmet.yilmaz@example.com` after an operator typed `a.yilmaz@example.com` is correct and still reads as
an answer about the wrong address."* Its sibling `zro_ui_title` applies the selected address at **the one path**
to the screen, and `lib/ui.sh:20` states the rule: *"a screen written next month cannot forget to do something
it never does."*

The alias note is applied by each screen, at **8 sites. VERIFIED:** `:501, :577, :608, :611, :782, :1078,
:1163, :1224`. And one forgets, four lines from a sibling that does not:

```
zimbra-ro-tui.sh:1158   zro_show_text "$title" "$(zro_search_conv_body "$acct" "$conv" '')"
zimbra-ro-tui.sh:1162   zro_show_text "$title" "$(zro_screen_alias_note "$(zro_search_conv_body ...))"
```

`lib/search.sh:1074` prints `zro_card_line 'Hesap' "$acct"`, so the `:1158` path — a conversation the server no
longer holds — shows the alias on the frame and the account in the body with nothing joining them. **Exactly one of
the 8 application sites is pinned by a test** (`tests/test_mailbox_screen.sh:256`, which asserts the note's
text on a screen that draws it); `tests/test_main_menu.sh:585` and `:591` exercise the function directly,
which is a different question — whether it renders, not whether a screen remembered to call it. The
neighbouring exemption at `:1144` is defensible: that body prints no `Hesap` line.

**Deletion test:** the function earns its keep — deleting it grows the identity check plus the wording at 8
sites. Its *application* is what is shallow. A straight move into `zro_show_text` is not available: that also
serves server-scoped screens where the note would be wrong. **Strong.**

## 4. The queue capability's cache can never fill

**Files:** `lib/capability.sh:398`, `:351`, `:39`, `:445`

`zro_cap_queue_available` is written `[ "$(zro_cap_queue_reason)" = ok ]`. The probe it reaches fills
`ZRO_CAP_QUEUE_BIN_CACHE` **inside the command substitution**, where the assignment dies.
`zro_cap_trace_available` is a bare `||` chain *specifically to avoid this*, and `zimbra-ro-tui.sh:3040` names
the hazard: *"an assignment made inside `$( )` dies with the subshell, which is the exact bug
`lib/capability.sh` records having already been fixed once."* The fix landed on the tracer and not on the queue.

**VERIFIED — every caller reaches the probe through a substitution:** `:2400` and `:2429` call
`$(zro_cap_queue_reason)` directly; `:2460`, `:2484` and `:3059` go through `zro_cap_queue_available`, which is
itself one. So the cache is empty on every program path and `zro_cap_reset` clears a variable that is always
empty.

**MEASURED under WSL:** 3 warn lines after 3 calls for the queue against 1 after 3 for the tracer; **5 warn
lines after 5 main-menu redraws**. On a host without `zimbra-mta` the tool re-probes and re-warns once per
return to the main menu, all session.

`zro_cap_search_available` uses the same shape and costs nothing — its reason function reads two variables and
runs no probe.

**Deletion test:** delete the cache and its reset line and *nothing changes* — it is already inert on every
path. That is the definition of a pass-through. **Strong**, and the cheapest change in this report.

## 5. The mock transcript is a declared table read by hand

**Files:** `tests/mocks/mock_common.sh:7`, `tests/test_main_menu.sh:798`, `tests/test_store.sh:572`,
`lib/exec.sh:433`

`zro_mock_record` declares one output format — one TAB-separated line, the binary then each argument. **35 test
files read it by hand. VERIFIED**, and the method matters because a bare count of the variable is misleading:
`$ZRO_MOCK_LOG` appears on 432 lines, of which **188 are reads rather than setup** —
`grep -h 'ZRO_MOCK_LOG' tests/*.sh | grep -vc 'export\|mktemp\|: >'`. This is the pattern CLAUDE.md forbids in
the program: *a declared table is read through `lib/table.sh`, never by hand.*

**The tab is re-derived at 13 sites in 9 files** as `$(printf '^zmprov\tga\t')`, and has drifted into an exact
form (trailing tab) and a prefix form (none). `lib/exec.sh:430-433` allowlists `zmprov:ga`, `zmprov:ga:-e`
**and** `zmprov:gam`, so the two prefix-form counts at `tests/test_main_menu.sh:798` and
`tests/test_store.sh:572` include a sibling subcommand. **Those two bounds hold by accident.**

This is the same prefix collision `tests/test_account.sh:32` exists to prove the program does **not** have. The
suite reintroduced it in its own reader.

**Deletion test:** the reader does not exist yet — that is the finding. The five filtering `ran()` variants are
its beginnings; the 14 identical `cat` copies are not. **Strong.**

---

# B. Concentration available

Nothing is broken here. These are places where one rule has more than one home.

## 6. Two windowed log-scan engines; the correction landed in one

**Files:** `lib/delivery.sh:230`, `lib/logsearch.sh:502`, `lib/inventory.sh`, `lib/window.sh`

`zro_trace_run` and `zro_logsearch_run` are the same engine — select files from the log inventory for a window,
run one command per file, accumulate skipped files, disclose a partial scan, report `ZRO_E_PARTIAL` — differing
only in the per-file command and the match cap.

**VERIFIED:** stripped of comments, `zro_trace_run` is 94 code lines and `zro_logsearch_run` is 121; **41 of
the 94 appear verbatim in the other**, including the whole skipped-file block (`delivery.sh:354-362` ≡
`logsearch.sh:633-640`), both `zro_win_human` guards, both `ZRO_E_NO_LOG` arms, the
`total == 0 && skipped_n == 0` arm, the kept-message line and the `----- $path -----` heading.

**VERIFIED — the reasoning lives on one side only, and the asymmetry is the finding rather than its size.**
Counting comment lines that name the other engine
(`grep -cE '^[[:space:]]*#.*(zro_trace|delivery trace|teslim iz)' lib/logsearch.sh` and its mirror):
`lib/logsearch.sh` names the delivery trace **8 times**, `lib/delivery.sh` names log search **0**. A looser
pattern raises the first number and never the second. The rules are documented once and implemented twice.

The partial-scan arithmetic differs — `delivery.sh:167` computes the selection as `read_n + skipped_n`,
`logsearch.sh:443` takes `selected_n` directly with its reason written at `:435`. **This is not a defect today:**
the tracer has no match cap, so every selected file is either read or skipped and the sum is correct. It stops
being correct the day a cap is added, and nothing holds the two equal.

**ADR-0011 bounds this and does not forbid it.** That ADR declines a helper owning a *mailbox read's
invocation*, because `tests/test_readonly_scan.sh` reads token positions off `zro_mbox_run` lines. The
equivalent cases here read call sites of `zro_trace_exec` and `zro_logsearch_grep`, so **the per-file
invocation must stay written out at each site**, as must the two caller-frame returns. Neither constraint
reaches the window validation, the selection, the skipped accumulation, the two exit arms or the banner.

**Deletion test:** neither function is a pass-through. The concentration is in the ~40 shared lines around the
invocation, which name no subcommand. **Strong** — the largest concentration available in the program.

## 7. The card vocabulary lives inside a domain module

**Files:** `lib/account.sh:371-418`, `:690`, `lib/queue.sh:348`, `lib/service.sh:197`

`zro_card_line`, `zro_card_head`, `zro_card_more`, `zro_card_list`, `ZRO_CARD_LABEL_W` and the three absence
words are defined in `lib/account.sh` — a domain module — and used **189 times across 11 other files.
VERIFIED** (was 183): store 44, message 38, mailset 31, directory 24, search 15, bulk 12, queue 11, service 5,
identity 4, mailbox 3, screen file 2. `zro_mode_banner` is a rendering primitive in the same file and belongs
in the same move; counted with it the figures are **195 across 12** (delivery joins). It is kept out of the
headline number so the two are not conflated.

**The previous survey's argument for moving them was wrong, and is corrected here.** It said the arrangement
*"forces the source order"*. It does not: bash resolves function names at call time, no domain module expands
the vocabulary at source time (checked on every top-level non-function line in all 13), and sourcing
`lib/service.sh` **before** `lib/account.sh` loads clean and renders a full card. The order at
`zimbra-ro-tui.sh:32` is a reading convention.

**The real cost is measurable elsewhere. VERIFIED:** `lib/service.sh` (222 lines) depends on exactly **one**
symbol outside core and exec — `zro_card_line`, five uses at `:203-207`. Of 52 test files, **16** source the
whole entry point, and `tests/test_service.sh` and `tests/test_queue.sh` are two of only **three** non-screen
module tests that do. They load 3,347 lines of screen file to reach a three-line `printf`. The third,
`tests/test_table.sh`, is not evidence for this and is named so it is not counted as though it were: it
sources the entry point for a reason of its own, written at `:227` — three of the eleven declared tables live
there.

**And the absence word has no owner. VERIFIED — one value, one absence, three answers:**

| site | answer |
|---|---|
| `lib/store.sh:390` | `$ZRO_TXT_UNKNOWN` (`bilinmiyor`) |
| `lib/queue.sh:348` | the raw number |
| `lib/service.sh:197` | `'(bilinmiyor)'`, a literal, not the constant |

`lib/message.sh:834` does the right thing and delegates to `zro_store_size_field`.

**Deletion test:** the card functions earn their keep — inlining `printf '%-21s: %s\n'` at 189 sites reopens the
label width everywhere. Their *home* is what is wrong; the move to `lib/card.sh` is a pure relocation with no
call site changes. **Strong.**

## 8. "A position in a list this program built", written three times

**Files:** `zimbra-ro-tui.sh:749`, `:1128`, `:1820`

The rule that keeps operator input from becoming a path exists as three byte-identical copies differing only by
the array name and one noun in the log line: a `case` refusing non-digits, an `if` refusing out-of-range, two
`zro_log error` lines, then `${arr[choice - 1]}`. **VERIFIED.**

**All three are documented, and that is what makes this a duplication rather than a gap. VERIFIED:** each
carries the headline — `:695` *"A POSITION IN THE LIST, NEVER A PATH, exactly as the log viewer does it"*,
`:1098` *"…NEVER AN ID FROM THE SCREEN, exactly as the folder menu…"*, `:1816` *"…This is the line that keeps
the viewer bounded to the inventory"* — and the first two cross-reference the others by name. So the rule is
not unwritten; it is written three times, by three authors who each knew about the other two and copied the
code anyway. **That is the argument for a reader, and against the easy version of it:** whoever writes the
fourth list screen will find the rule stated wherever they look, and will still write the fourth copy.

**VERIFIED — nothing is in the way.** No ADR mentions this, and `tests/test_readonly_scan.sh` does not read
these call sites. That is the difference from ADR-0011's declined helper, and it is what makes this one
available.

**Deletion test:** concentrates — three copies of one safety rule become one, and the three comments that
point at each other become the module's own. **Strong**, and the smallest blast radius in this report.

## 9. Two seams still decide the gate's codes for themselves

**SHIPPED as #81, #84 and #86, and recorded in
[ADR-0012](../adr/0012-no-reader-ends-with-the-status-it-was-handed.md).** Two things the walk below did not
reach. The `errno` collision is worse than the bare code it names: `zmmsgtrace` is Perl, so a failed trace
exits with `$!`, and `errno` 23 IS `ZRO_E_NO_LOG` — which the trace loop was also using as its
skip-this-file signal, so such a trace was disclosed as a file that could not be opened and answered as a
partial scan. A wrong ANSWER about delivery, not a wrong screen. And the leak was pinned by four assertions
rather than tolerated by none. The general rule this produced — *no mapping of a failed command ends by
returning the status it was handed* — is now static in `tests/test_settle.sh`.

**Files:** `lib/logview.sh:196`, `lib/delivery.sh:52`, `lib/exec.sh:995`, `lib/message.sh:517`

**VERIFIED — three hand-written memberships survive:** `logview.sh:196` (5 codes), `queue.sh:254` (4),
`service.sh:150` (4). `zro_exec_own_code` has 2 real call sites: `lib/settle.sh:101` and `lib/message.sh:517`.

`zro_msg_head_fetch` is the **worked precedent**: it made exactly this edit and kept its own sink, and its
comment records what the edit found — *the list it replaced carried `ZRO_E_INPUT`, a code `zro_exec` never
returns*. That is the drift ADR-0010 predicted, measured.

**VERIFIED — the fall-through survives at exactly two readers:** `lib/account.sh:246` and `lib/delivery.sh:52`.
The delivery path is traceable end to end: `zmmsgtrace` fails for any reason other than *unable to open file* →
`delivery.sh:52` returns the binary's status → `delivery.sh:326` returns it whole → `zimbra-ro-tui.sh:1693` →
the default arm at `:410`, `"Islem basarisiz (kod $1)"`. **That is verbatim the screen ADR-0010 was written to
abolish.**

**Read ADR-0010 first — it covers three of the five sites, correctly.**

- **Do not touch `queue` or `service`:** their fifth code *is* their sink, so converting them changes what the
  sink means.
- **Do not touch `lib/account.sh:246`:** the retry at `:333` reads the mapped value, so a constant there changes
  behaviour.
- Of logview the ADR says only *"its list is complete today; what it lacks is a reason to stay complete."* That
  reason has not arrived, and unlike queue and service its list buys nothing, because it sinks into
  `ZRO_E_NO_LOG`.
- Delivery was excluded from the *settler*, never from the fall-through rule.

**Deletion test:** delete `logview.sh:195-198` — nothing re-derives it; the behaviour is reproduced by one line
already written twice elsewhere. Pure copy. **Strong.**

---

# C. The test seam

*The interface is the test surface.* Here the seam is real and has two adapters — but only one side of it was
ever written down.

**VERIFIED:** `tests/lib/` is **153 lines** (`assert.sh` 99 + `cost.sh` 54) against **3,015 lines of preamble**
summed across 52 files. Median first assertion: **line 66.5**.

## 10. The screen stub has two adapters and no client library

**Files:** `lib/ui.sh:57`, `lib/selection.sh:79`, `tests/lib/`, 13 screen suites

Of 70 functions in `zimbra-ro-tui.sh`, tests can name **17**. Every screen is reached by scripting menu ids into
a queue file and running the whole `zro_menu_main` loop. The four helpers that make that possible **are** the
per-screen interface, and they are written out instead of declared. **VERIFIED:**

| helper | copies |
|---|---|
| `queue()` | 13, byte-identical |
| `transcript()` | 10, byte-identical |
| `entries()` | 8, byte-identical |
| `ran()` | 18 definitions, 5 spellings (14 identical) |
| `run()` | 8 definitions, 3 spellings |

`run()`'s three spellings differ **only in which module cache they reset** — 4 call `zro_mbox_forget`, 1 calls
`zro_cap_reset`, 3 call neither. That is a hand-maintained inventory of module state, kept in eight places by
whoever remembered.

The Turkish UI literal `'MENU Ana menu'` is hard-coded in **9 files**. And two production functions exist only
so tests can drive this: `zro_ui_reset` (`lib/ui.sh:57`) has **0 program call sites** and 15 test files;
`zro_sel_clear` (`lib/selection.sh:79`) has **0** and 12. **VERIFIED.**

**The gradient is the argument.** `tests/test_exec_allowlist.sh` gets **238 assertions off a 12-line preamble**
because `zro_allowed` takes values and returns a status; `tests/test_mailbox_screen.sh` gets 46 out of 84. The
four modules with every function named in a test — `selection`, `table`, `validate`, `window` — are exactly the
four whose tests need under 30 lines of setup. **Coverage in this tree is a function of setup cost, not of
intent.**

**Deletion test:** `transcript()` and the 14 identical `ran()` are **shallow** — inlining loses nothing.
`entries()` is **deep but misplaced**: it encodes a parse of the transcript format that would land at ~60 call
sites. `run()` is neither — it is an interface whose varying part nobody wrote down. **Strong**, and the largest
lever in the tree.

## 11. The existence gate is restated in eight files, in three conventions

**Files:** `tests/test_mailbox_gate.sh:56`, `test_search.sh:66`, `test_store.sh:69`, `test_mailbox_screen.sh:62`,
`test_search_screen.sh:59`, `test_store_screen.sh:63`, `test_main_menu.sh:377`, `test_gate_passthrough.sh:170`

The invariant the product exists to guarantee is set up **8 times in 3 incompatible conventions** (the previous
survey found 7 and 2):

1. a `"$@"`-prefixing wrapper — and the same bodies carry two different names, `answers_exists`/… against
   `proven`/…;
2. export/unset "server" helpers;
3. no helper at all — an inline env prefix on the assertion.

Within convention 2 it has drifted again: `tests/test_store_screen.sh:291` inlines the no-account case where its
sibling `tests/test_mailbox_screen.sh:73` defines a helper.

**Deletion test:** the helpers are **deep** — each names a captured server outcome and pins a fixture triple.
What is missing is the declaration underneath them. The two conventions are not interchangeable — one scopes to
a single command, the other mutates the process — so this is **one declaration with two adapters**, which is a
real seam by the two-adapter rule, not a hypothetical one. **Strong.**

---

# D. Carried over from 2026-08-18, re-verified

## 12. The declared cost class has no reader in the program

**Files:** `zimbra-ro-tui.sh:3005`, `:426`, `:632`, `tests/lib/cost.sh:33`

**VERIFIED — still true.** `zro_menu_cost` has **zero callers in the program**; every hit outside its
definition is under `tests/`. `zro_cost_unit` is called once, by `zro_menu_cost` itself, purely to refuse
class 4.

**Sharper than last time: the declaration is not dead, it is a test oracle only.** `tests/lib/cost.sh` is its
sole real reader, feeding **29 `assert_cost` calls across 11 test files**.

What the operator reads before spending is hand-derived **six** ways (was five): two `case` lists (`:426`,
`:632`), six inline literals, two `ZRO_TXT_*` constants, one inline `zro_ui_yesno`, and one builder function.
**The two case lists still disagree about failure. VERIFIED:** `zro_mailbox_cost_note`'s default arm logs a
defect and prints; `zro_account_cost_note`'s prints silently. Add a `mailbox-*` operation with no note and the
tool shouts; add an `account-*` one and nothing does.

Nothing links declaration to note: a screen's note can say "two queries" while its class says otherwise, and no
test can catch it because `assert_cost` reads the class and the note is prose.

**Deletion test:** delete `zro_menu_cost` and complexity *moves* to the suite — 29 assertions would restate
numbers, which `cost.sh`'s own header forbids. It earns its keep as a test seam and is shallow as a program
module. The friction is the missing edge. **Worth exploring.**

## 13. A partial scan is a code plus a habit, not a value

**Files:** `zimbra-ro-tui.sh:1691`, `:2328`, `:2840`, `:390`

**VERIFIED.** Three modules produce `ZRO_E_PARTIAL` and each builds its own banner (`lib/delivery.sh:164`/`:442`,
`lib/logsearch.sh:440`,`:461`/`:706`, `lib/bulk.sh:650`,`:663`/`:804`). Then three screens hand-write a title:

```
zimbra-ro-tui.sh:1691   zro_show_text "Teslim izi - EKSIK TARAMA" "$out"
zimbra-ro-tui.sh:2328   zro_show_text "Log arama - EKSIK TARAMA"  "$out"
zimbra-ro-tui.sh:2840   zro_show_text "$title - EKSIK SONUC"      "$out"
```

Two hard-code a title instead of reading the one `ZRO_MENU_OPS` already carries, and they use two different
suffix words.

**The live edge:** a fourth rendering exists at `:390` — the shared reporter's arm for code 30 — and it **is
never handed `$out`**, because `zro_report_error` takes only `$1`. A screen that returns 30 and forgets the `if`
discards both the answer and the banner the module worked to write.

**Deletion test:** the three banner builders individually earn their keep. What does not exist is the thing that
would concentrate: nothing owns *"a partial answer is shown, not reported, and its title says so."*
**Worth exploring.**

---

# Also found

Verified, cheap, and independent of everything above.

| what | where | note |
|---|---|---|
| 36 dead `chmod +x` lines in 8 spellings | `tests/*.sh` | `tests/run.sh:12` already chmods all four mock roots and CI only invokes the suite through it. **The experiment is already run:** 16 of the 52 files carry no chmod line, and of those exactly one — `tests/test_table.sh` — actually exports a mock root and drives the mocks. It is green. Pure subtraction. |
| `zro_menu_entry` is dead | `zimbra-ro-tui.sh:2989` | Its definition is still the only occurrence in the repository, and its comment still claims *"Every lookup below goes through this"*. Its three siblings call `lib/table.sh` directly. Two-line change. |
| the passthrough suite covers 3 of the gate's 5 codes | `tests/test_gate_passthrough.sh` | And the two it omits — `TIMEOUT`, `UNAVAILABLE` — are precisely the two the three surviving lists disagree about. A gate-produced `UNAVAILABLE` is asserted at no seam in the tree. `lib/exec.sh:987` and ADR-0010 both lean on this suite as what makes the exclusions safe. |
| the error store has no reset discipline | `lib/core.sh:137` | `zro_reset_mode` is called at 18 screen-entry sites; `zro_clear_error` at 10, every one on a success path. The rule *"detail only when a command ran"* is re-derived arm by arm and written out in one comment. Not live today — closed by a coincidence of three unrelated guards in three files. |
| the existence gate reads its evidence from a global | `lib/mailbox.sh:130` | `zro_mbox_verdict` tells *nomailbox* from *noaccount* by reading `zro_last_error`, because `zro_prov_read` has no channel for the oracle's stderr. Of that store's four callers it is the only one reading it as data. The verdict is therefore bounded by `ZRO_ERROR_KEEP_BYTES`, a number `lib/core.sh:129` says was *"chosen and never measured"*. Margin is comfortable (fixtures are 108 and 66 bytes); nothing names the dependency. |
| no record reader exists | `lib/mailset.sh:248`, `:308` | Two readers reimplement the `key: value` rule — once in awk with `RS=""`, once with attribute names as literal prefixes — because what they need is a **record** boundary. The *"a declared attribute ends a value"* rule has three implementations. Also: `zro_dl_card` parses the same `#` header line twice, two awk invocations over one `$raw` (`lib/directory.sh:419`, `:422`). |
| the mock's own interface never refuses | `tests/mocks/mock_common.sh:82` | 98 `ZRO_MOCK_*` names in use, **82 appearing nowhere under `tests/mocks/`**. Absence resolves to a default, so a misspelled key produces empty output and exit 0 — a case that passes while scripting nothing. `lib/table.sh` refuses an undeclared key on principle; its test double does not. |
| a capability answer arriving as a status is re-derived three ways | `zimbra-ro-tui.sh:1882`, `:2345`, `:2483` | Three code sets, two polarities, and one of the three ends at a bespoke inline msgbox rather than the module's own screen. The trace screen has no such check at all. |
| the CRLF gate does not cover the mocks | `.github/workflows/ci.yml:41` | The grep uses `--include='*.sh'` and 16 of the 17 mock files have no extension. The job's own comment says CRLF is *"checked rather than trusted to `.gitattributes`"* — for those 16 it is trusted after all. Clean today. |
| the runner has no floor on assertions | `tests/run.sh:38` | A file reporting `0 ok 0 fail` passes. With a median preamble of 66.5 lines and no `errexit` — correctly, per CLAUDE.md — that is the failure mode the runner cannot see. All 52 files are fine today; the gap is structural. |

---

# What is already deep, and was deliberately left alone

Re-verified at this commit, so a future survey does not "improve" it.

- **`lib/table.sh`** — 95 non-comment lines, 7 functions, 30 call sites. Thirteen tables are read through it:
  the **eleven declared** ones `tests/test_table.sh` holds it to, plus `ZRO_ALLOW` and `ZRO_LOW_PRIORITY`,
  which `lib/exec.sh:494` and `:680` pass to `zro_table_entries` while remaining outside the declared-table
  rules for the reason [ADR-0009](../adr/0009-what-is-not-a-declared-table.md) gives. ADR-0009's exclusions
  intact. Still the deepest module in the tree.
- **The allowlist half of `lib/exec.sh`** — 56 rows and 43 non-comment lines behind 2 predicates, yielding 238
  assertions off a 12-line preamble.
- **`zro_exec` itself** — not named by the previous survey. 57 non-comment lines behind a `(bin, token, args…)`
  interface carrying caller identity, the allowlist, root resolution, executability, `runuser` mode, the
  wall-clock timeout, reduced-priority wrapping and the 124→22 rewrite. Only 2 branches special-case the gated
  binary.
- **`lib/message.sh`** — 1,057 lines, 31 functions, **one** public function. The deepest domain module, and the
  model the others are measured against.
- **`lib/ui.sh`, `lib/window.sh`, `lib/selection.sh`** — one seam with two real adapters; a pure/thin split that
  takes the clock as an argument so `yesterday` is testable without a frozen clock; a module deliberately opaque
  about the identity record's shape.
- **The six column-table readers** — `store.sh:99`/`:130`, `search.sh:607`/`:630`, `queue.sh:120`,
  `service.sh:91`. One reader per output *shape*, and `lib/search.sh:624` still says why: *"two tables read by
  one function are two tables that agree by accident."*
- **`tests/lib/cost.sh`** — reads the class *and* its unit out of the program rather than restating a number.
  Still the model; see §12 for the caveat.
- **`tests/test_gate_passthrough.sh`** — new since the previous survey and worth naming: a *seam* test, one
  interface property across 10 call sites, with `:22-32` recording which two seams are excluded and why. Its 24
  assertions per 118 preamble lines look poor because 100 of those lines are the argument. That is the right
  trade.
- **The thin table accessors** in `lib/logsearch.sh:111-123`, `:775-785` and `lib/search.sh:98-118` — they look
  like pass-throughs and are not: deleting them moves the *declaration name* to the screen, and
  `lib/logsearch.sh:106` writes the reason down.

**Do not reopen:** ADR-0011's four lines at the seven mailbox reads; the `queue`/`service` sink question;
`zro_prov_read`'s settler exclusion — which has a **stronger** reason than ADR-0010 gives, a three-argument
reader contract; `zro_msg_head_fetch`; and the validators' repeated one-line refusals, which `lib/exec.sh:533`
documents as two refusals with two meanings.

---

# Corrections to the 2026-08-18 survey

Marked in place in that file as well, because that document will go on being read.

**1. WRONG — *"The load order encodes a dependency on a domain module for rendering."* (§4)** Bash resolves
function names at call time and no domain module expands the card vocabulary at source time. Proven rather
than reasoned about: sourcing `lib/service.sh` **before** `lib/account.sh` loads clean and `zro_svc_card`
renders a full card. §7 above is argued from the test coupling and the three-way absence fork instead. The
count that paragraph rests on holds, and so does the move it asks for.

**2. OVERSTATED — *"the first was never corrected"*, of the delivery partial-scan arithmetic. (§3)** The
banner really was never changed; what does not follow is that it is wrong. The tracer has no match cap, so
`read_n + skipped_n` equals `selected_n` and it is right today. The finding is that one rule has two
derivations and only one survives a cap being added — see §6.

**3. NOT AN ERROR, though an earlier draft of this file called it one — §7's coverage figures.** They hold.
The unit there is *% untested*, so *0% untested* means fully covered, which is what re-running finds, and
**188 of 461 was exact at that commit** (181 today; `zimbra-ro-tui.sh` unchanged at 76%). The disagreement is
about the CAUSE: that survey reads the gradient as tracking depth, §10 above reads it as tracking setup cost,
and the two are confounded in this tree — a module that takes values and returns values is also a module that
is cheap to stand up. Recorded as a disagreement rather than a correction, and recorded at all because the
misreading is easy to repeat: *0% untested* and *0% tested* are one character apart and mean opposite things.

---

# Recommended order

1. **§1** — shipped as PR #75 the day this was written. The only one with a defect the tree already asserted
   against itself.
2. **§4** and **§2** — a handful of lines each, both measured, and the correct version already exists elsewhere
   in the tree.
3. ~~**§9**~~ — shipped as #81, #84 and #86, with ADR-0012 and a static rule behind it. **§8** remains: a
   safety rule with a home available and no ADR or static scan in the way.
4. **§3** — a live disclosure gap, then the design question behind it.
5. **§10** — the largest lever. Coverage here is a function of setup cost, and this is the setup cost. **§6** is
   its counterpart in the program.
6. **§5**, **§11** — the suite's two remaining shared seams.
7. **§12**, **§13** — each removes one of the screen layer's per-id decisions.

The *Also found* table is independent of all of it and can be picked up whenever.
