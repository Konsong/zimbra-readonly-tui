# Mail settings — the two child-entry reads, and what a multi-line attribute really looks like

- **Date:** 2026-08-03
- **Scope:** the reads behind the mail settings and filter rules screens, for issue #28.
- **Method:** every command below was run on **TEST-C** (`posta.sirket.lcl`, Zimbra 9.0.0 GA FOSS,
  Ubuntu 20.04). A fixture account — `zimscope-ayar-20260803@sirket.lcl`, created for this work and
  **never logged into**, so it has no mailbox — was given two filter rule sets, two signatures, one
  send-as identity, two aliases, both kinds of forwarding and a disabled local delivery. Output is
  committed under `tests/fixtures/` with the names and addresses changed and nothing else.

## 1. The subcommand is `gid`, not `gia`

`zmprov help account` names them:

```
getIdentities(gid)  {name@domain|id} [arg1 [arg...]]
getSignatures(gsig) {name@domain|id} [arg1 [arg...]]
```

`zmprov gia <account>` is not a command: it prints the usage banner and exits 1. Written down because
the abbreviation is guessable and wrong, and a guess would have reached the allowlist as an entry for
an operation that cannot run.

## 2. Both reads take an attribute list

`gsig` and `gid` accept attribute arguments exactly as `ga` does, in SOAP and in LDAP mode. Unfiltered,
`gid` returns twelve attributes per identity — forward-reply prefixes, sent-folder names, a signature id;
the send-as identity screen asks for five, and paragraph-mode record splitting is safe there because
every one of those five holds a single line.

**The signature read is deliberately not reduced to the name.** An operator reaches this screen to
explain what a user's outgoing mail *looks* like, and a list of names does not answer that. So the read
asks for `zimbraPrefMailSignature`, `zimbraPrefMailSignatureHTML` and `zimbraSignatureName`, and the
value that comes back is multi-line:

```
# name Kurumsal
zimbraPrefMailSignature: --
Ahmet Yilmaz
Bilgi Islem

Tel: 0212 000 00 00
zimbraSignatureName: Kurumsal

# name Kisa
zimbraPrefMailSignatureHTML: <p>ZimScope Ayar</p>
zimbraSignatureName: Kisa
```

**The name is what makes the records separable, and that is why it is requested.** zmprov answers in
alphabetical order, so `zimbraSignatureName` sorts after both bodies and every record therefore *ends*
with a single-line attribute. A multi-line body standing last would run into the blank line and the
`# name` header that follow it — and both of those occur inside the body above.

**The HTML body is measured, not shown.** A Zimbra HTML signature routinely carries an embedded image as
a data URI; printing the markup into a whiptail box is not showing an operator a footer. The screen names
it, gives its length in characters, and says the content is not displayed.

## 3. Neither read opens a mailbox — MEASURED, on an account that has none

`zmprov gis` was run against the fixture account immediately before and immediately after `ga`, `gsig`
and `gid`, and again after the tool's own screens were driven against it:

```
before  ERROR: service.FAILURE (system failure: mailbox not found for account 65ad4077-…)
after   ERROR: service.FAILURE (system failure: mailbox not found for account 65ad4077-…)
```

The same held for `zimscope-fixture-ldaponly-20260731@sirket.lcl`, the account the existence-gate work
uses. Both screens rendered **in full** for both accounts: every fact they show lives on the account
entry or on a child entry of it, so there is nothing for a mailbox to answer.

**Bounded claim.** This says these two reads do not provision a mailbox. It says nothing about the
write-named siblings one letter away — `csig`, `msig`, `dsig`, `cid`, `mid`, `did` — which are absent
from the allowlist and therefore refused.

`gsig` on an account with **no signatures** prints nothing and exits **0**. That is a result, not a
failure, and the screen renders it as `yok` rather than as the word this tool keeps for a question
nobody could ask. `gid` always answers with at least the `DEFAULT` identity Zimbra creates with the
account, carrying the account's own address.

`gsig` and `gid` on an address that is not an account — a distribution list, or nothing at all — fail
with `account.NO_SUCH_ACCOUNT`, exactly as `ga` does. So the screens are `account`-scoped and the menu
marks them for a list address like every other account screen.

## 4. A multi-line attribute prints its continuation lines RAW

This is the whole reason the ticket exists. `zmprov ga` on the account carrying a filter rule set:

```
zimbraMailOutgoingSieveScript: require ["fileinto", "copy"];

# Giden kopya
if anyof (header :contains ["to"] ["arsiv@ornek.com"])
{
    fileinto "Gonderilmis";
    stop;
}
zimbraMailSieveScript: require ["fileinto", "copy", "reject", "tag", "flag", "log"];

# Faturalar
…
zimbraPrefMailLocalDeliveryDisabled: TRUE
```

Nothing marks a continuation line as one. There is no leading space, no quoting, no LDIF-style fold.
**All three of the ways a reader might identify one by shape are wrong:**

- a continuation may be **blank** — which is also what separates one record from the next;
- a continuation may begin with **`#`** — every rule in a Zimbra filter is introduced by a comment,
  and `# name <x>` is also the record header;
- a continuation may look **exactly like an attribute line**. Measured, in the signature read the card
  really makes, committed as `tests/fixtures/zmprov_gsig_bodies.txt`:

```
zimbraPrefMailSignature: --
Ahmet Yilmaz
Bilgi Islem

Tel: 0212 000 00 00
zimbraSignatureName: Kurumsal
```

A reader that ended a value at the first `word: value` line cuts that signature off at the telephone
number.

**So what ends a value is declared rather than guessed.** `zro_attr_block` is given the attribute list
the read asked for — `zmprov` answers with those and no others — and a line begins a new attribute only
when it begins one of *those*. Every other line is a continuation.

The existing single-line reader is not merely short on this input, it is **wrong**: it answers
`require ["fileinto", …];` and stops, so the rule that files invoices is visible and the rule underneath
it that discards a sender is not. Absence would have been visible; truncation is not.

## 5. zmprov ends a record with a blank line

An attribute that stands last in the output has the record separator sitting where its own value would
continue — seen with `ga <account> zimbraMailOutgoingSieveScript zimbraMailSieveScript`, where the rule
set is last. In practice the read path strips trailing newlines before any parser sees them, so this
never reaches a screen; the reader drops trailing blank lines anyway rather than resting on that.
Interior blank lines are the operator's own and are preserved.

## 6. LDAP mode answers both reads

`zmprov -l gsig` and `zmprov -l gid` returned the same records SOAP returns for the attributes these
screens ask for. Both are therefore declared LDAP-capable, and the mail settings screen keeps working
during a `mailboxd` outage — unlike provenance, whose entry-only form has no measured LDAP spelling.

The LDAP answers carry a few attributes the SOAP ones omit (`objectClass`, `zimbraCreateTimestamp`),
which the attribute filter removes.

## 7. A flag in the data position is accepted by the tool and refused by the gate

`zmprov gsig <account> -e` does not fail: it prints the record headers and exits 0. That is exactly the
case the allowlist's data-position rule exists for — `zmprov:gsig:-e` is not on the list, so the gate
refuses it before the binary is reached, and no caller has to know what that tool's parser does with a
flag it was not expecting.
