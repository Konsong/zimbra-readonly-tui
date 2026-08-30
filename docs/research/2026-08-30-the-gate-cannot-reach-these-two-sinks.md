# The gate cannot reach these two sinks — what #77 and #78 were really about

- **Date:** 2026-08-30
- **Scope:** one question, asked of the tree at `a2ab0dc`: **can `zro_exec` return
  `ZRO_E_UNAVAILABLE` to `zro_queue_fetch` or `zro_svc_fetch`?** Three ADR paragraphs and two open
  issues say the answer decides what those modules' fall-through sink MEANS. The answer is no, in
  production, by four separate mechanisms — so the decision those paragraphs deferred was never in
  the way.
- **Method:** driven, not read. Both fetch functions were called through their own interface against
  the mock tree under WSL, with the environment shaped to force each path; the low-priority
  membership was asked of the tree's own predicate rather than read off the list. The static reads
  are named as static where they appear. §5 and §6 are findings this question turned up on the way
  and are not part of its answer.
- **Reproduce:** §7 holds the script verbatim.
- **Feeds:** [ADR-0016](../adr/0016-unavailable-names-a-service-that-did-not-answer.md). The
  reachability analysis in §1 is also the shared premise of the tickets that ADR opens.

## 1. The five sites, and why none of them arrives

`zro_exec` and its two identity helpers return `ZRO_E_UNAVAILABLE` at five places. For a call
coming from `zro_queue_fetch` or `zro_svc_fetch`, every one of them is closed:

| Site | What it means | Why it cannot arrive |
| --- | --- | --- |
| `zro_current_user` — no `ZRO_ID_BIN` | the `id` binary is missing | **Two mechanisms.** `zro_startup_check` lists `id` among the binaries it refuses to start without; and the gate calls it inside a command substitution, where its status is discarded — an empty name reaches `zro_identity_mode`, which answers `ZRO_E_BADUSER`, not this code |
| `zro_user_groups` — no `ZRO_ID_BIN` | the same binary | **The gate never calls it.** Its only caller is the capability module |
| `zro_exec` — no `ZRO_TIMEOUT_BIN` | the clock every command runs under is missing | `zro_startup_check` refuses to start |
| `zro_exec` — no `ZRO_NICE_BIN` or `ZRO_IONICE_BIN` | this host cannot run a scan at reduced priority | **Reached only for a low-priority binary.** `ZRO_LOW_PRIORITY` holds `grep` and `gzip`; neither `postqueue` nor `zmcontrol` is in it |
| `zro_exec` — no `ZRO_RUNUSER` | the privilege wrapper is missing, in runuser mode | `zro_startup_check` refuses to start |

Three of the five are shut by the startup preflight, which reads the same variables and refuses the
session with one message naming everything that is missing. The fourth is shut by a list. The fifth
was never open.

**The preflight is why this is a claim about production and not about the suite.** The test runner
sources the entry point with `ZRO_SOURCED_ONLY` set and never calls the preflight, so a case that
empties `ZRO_TIMEOUT_BIN` really does drive a gate `ZRO_E_UNAVAILABLE` into these two modules. That
path exists in the harness and nowhere else, and the run in §3 records it as such.

## 2. Measured: the low-priority membership, and a fetch that survives without `nice`

```
postqueue  low-priority? NO
zmcontrol  low-priority? NO
grep       low-priority? YES

--- with ZRO_NICE_BIN and ZRO_IONICE_BIN both empty ---
zro_queue_fetch rc=0  output lines=10
zro_svc_fetch   rc=0  output lines=11
```

Both reads complete normally on a host with no `nice` and no `ionice`, because neither binary asks
for the wrapper. The one gate site that is reachable at run time is reachable only from the log
search and the compressed-blob read.

## 3. Measured: what the two sinks actually do

Driven twice — once with the command exiting non-zero, once with the gate refusing:

```
UNAVAILABLE=21 DENIED=90 NOCAP=92 TIMEOUT=22 PERM=20

A. the command really ran and failed (mock exits 1)
   zro_queue_fetch  rc=21   warn| mail queue unreadable (no message on stderr)
   zro_svc_fetch    rc=21   warn| service status unreadable (no message on stderr)

B. the gate refused with its own UNAVAILABLE (ZRO_TIMEOUT_BIN emptied; harness-only, see §1)
   zro_queue_fetch  rc=21   warn| mail queue unreadable (no message on stderr)
   zro_svc_fetch    rc=21   warn| service status unreadable (no message on stderr)

C. a gate code that is passed through (allowlist emptied)
   zro_queue_fetch  rc=90   (nothing on stderr)
   zro_svc_fetch    rc=90   (nothing on stderr)
```

A and B are indistinguishable — same code, same sentence. That is the observation the issues are
built on, and §1 is why it does not matter: B cannot happen where an operator is.

## 4. What is left is a defect, and it is not about the gate

`ZRO_E_UNAVAILABLE` is answered by one screen, and that screen opens:

> *zmprov varsayilan olarak mailboxd servisine SOAP ile baglanir. En sik iki sebep: mailbox servisi
> durmus (kontrol: zmcontrol status), admin sertifikasi gecersiz (kontrol: zmcertmgr
> viewdeployedcrt)*

`postqueue` speaks no SOAP and never reaches mailboxd. `zmcontrol status` does not either — and the
screen tells an operator whose `zmcontrol status` just failed to go and run `zmcontrol status`.
Both screens reach it by falling through their own `case` to the shared reporter.

This is the defect ADR-0010 exists to prevent, and ADR-0012 refused this exact constant for this
exact reason when it was proposed for the delivery tracer: *"this would reproduce the exact defect
ADR-0010 was written about — naming a service the command never talks to."* The two modules the
same ADR left open were already doing it.

**It is untested.** `tests/test_service_queue_screen.sh` has twenty-four cases across these two
screens and covers the timeout, the missing tool and the host's own refusal. None of them reaches
the sink. The one code both modules fall back to is the one code neither screen's suite asks about,
which is how the wrong screen survived.

## 5. Aside: the gate's own log line never reaches the log

Both fetch functions capture the gate's error stream — the `zro_exec` call redirects file
descriptor 2 to a scratch file — and `zro_log` writes to stderr. So when the gate logs a refusal in
its own words, that sentence lands in the scratch file, becomes the kept message, and goes to the
error store. It does not reach the terminal, and it reaches `ZRO_LOG_FILE` only because `zro_log`
writes there separately — and that file is off unless an administrator sets it. Run C above shows
the effect: an allowlist denial, which the gate logs at `error`, printed nothing at all.

This is a property of every module that redirects the gate's stderr to a file, not of these two. It
is recorded here because both issues describe the sink as replacing *"a refusal the gate had
already explained in its own words"*, and the words were never where that sentence assumes.

## 6. Aside: `ZRO_E_BADUSER` has no screen anywhere

Found while measuring which codes have their own arm in the shared reporter. `ZRO_E_BADUSER` — 91,
in the band this program defines as its own defects — has no arm in `zro_report_error` and no
call-site handler in any module. It reaches an operator as *"Islem basarisiz (kod 91)"*.

Like three of the five sites in §1, it is unreachable in production: `zro_startup_check` refuses any
user that is neither `zimbra` nor `root`, and the gate's identity question cannot change answer
mid-session. Recorded because the pin ADR-0016 asks for will fail on it.

## 7. The script

Run under WSL from a clone. It sources the tree the way the suite does and drives the two functions
through their own interface.

```bash
#!/usr/bin/env bash
set -uo pipefail
SRC=/mnt/c/zimbra-readonly-tui; T="$SRC/tests"
export ZRO_MOCK_LIB="$T/mocks" ZRO_ZIMBRA_BIN="$T/mocks/bin" ZRO_ZIMBRA_LIBEXEC="$T/mocks/libexec"
export ZRO_POSTFIX_SBIN="$T/mocks/sbin" ZRO_SYSTEM_BIN="$T/mocks/system"
export ZRO_ID_BIN="$T/mocks/bin/id" ZRO_RUNUSER="$T/mocks/bin/runuser"
export ZRO_TIMEOUT_BIN="$T/mocks/bin/timeout"
export ZRO_NICE_BIN="$T/mocks/bin/nice" ZRO_IONICE_BIN="$T/mocks/bin/ionice"
export ZRO_MOCK_ID_USER=zimbra
TREE=$(mktemp -d); mkdir -p "$TREE/var/log" "$TREE/zimbra/log" "$TREE/store"
export ZRO_SYSLOG_FILE="$TREE/var/log/zimbra.log" ZRO_LOG_DIR="$TREE/zimbra/log"
export ZRO_STORE_ROOT="$TREE/store"
ZRO_MBOX_PROOF_FILE=$(mktemp); export ZRO_MBOX_PROOF_FILE
chmod +x "$T"/mocks/bin/* "$T"/mocks/libexec/* "$T"/mocks/system/* "$T"/mocks/sbin/* 2>/dev/null || true
. "$SRC/lib/core.sh"; . "$SRC/lib/table.sh"; . "$SRC/lib/validate.sh"
. "$SRC/lib/exec.sh"; . "$SRC/lib/settle.sh"; . "$SRC/lib/capability.sh"
. "$SRC/lib/queue.sh"; . "$SRC/lib/service.sh"

run() {
  local label=$1; shift
  local errf; errf=$(mktemp); local rc=0
  "$@" >/dev/null 2>"$errf" || rc=$?
  printf '%-46s rc=%s\n' "$label" "$rc"
  sed 's/^/      log| /' "$errf"
  rm -f "$errf"
}

for b in postqueue zmcontrol grep; do
  printf '%-10s low-priority? ' "$b"
  if zro_runs_low_priority "$b"; then echo YES; else echo NO; fi
done

export ZRO_MOCK_POSTQUEUE__P_OUT="$T/fixtures/postqueue_p_deferred.txt"
export ZRO_MOCK_ZMCONTROL_STATUS_OUT="$T/fixtures/zmcontrol_status_ok.txt"
( export ZRO_NICE_BIN= ZRO_IONICE_BIN=; run "no nice/ionice: queue"   zro_queue_fetch )
( export ZRO_NICE_BIN= ZRO_IONICE_BIN=; run "no nice/ionice: service" zro_svc_fetch )

( export ZRO_MOCK_POSTQUEUE__P_RC=1;     run "A queue: command exits 1"   zro_queue_fetch )
( export ZRO_MOCK_ZMCONTROL_STATUS_RC=1; run "A service: command exits 1" zro_svc_fetch )
( export ZRO_TIMEOUT_BIN=; run "B queue: gate UNAVAILABLE"   zro_queue_fetch )
( export ZRO_TIMEOUT_BIN=; run "B service: gate UNAVAILABLE" zro_svc_fetch )
( export ZRO_ALLOW=; run "C queue: allowlist denial"   zro_queue_fetch )
( export ZRO_ALLOW=; run "C service: allowlist denial" zro_svc_fetch )
```

## 8. What this corrects

Three places in the tree give a reason that rests on the path §1 closes. Each is corrected where it
stands rather than only here:

- **ADR-0010**, *"The modules that keep their own lists are not an oversight"* — *"a gate refusal
  that falls into the sink leaves as the same number it arrived as"*. True of the number, and the
  refusal cannot arrive. The paragraph's **second** reason for excluding these two from the settler
  — the inline shape and the capability side effect — does not depend on this and stands.
- **ADR-0012**, *"What was considered and rejected"* — converting these two was deferred as *"a
  decision about what the sink means"*. It is a substitution, as `lib/logview.sh` was.
- **`lib/exec.sh`**, the comment above `zro_exec_own_code` — says three hand-written lists still
  stand and names `lib/logview.sh` as one of them. ADR-0012 converted it; two stand, not three. It
  repeats the sink-decision reason as well.
