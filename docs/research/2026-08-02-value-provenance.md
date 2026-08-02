# Where a value came from, as TEST-C really answers it

Captured 2026-08-02 on TEST-C (`posta.sirket.lcl`, Zimbra 9.0.0 GA FOSS on Ubuntu 20.04) for
[#31](https://github.com/Konsong/zimbra-readonly-tui/issues/31). Everything below is observed output. Names
and addresses are anonymised in the committed fixtures; shapes, field names and punctuation are verbatim.

Both forms were run back to back, as the zimbra user, over the sixteen attributes the account card asks for.
Both are `zmprov ga`: they return an account entry and change nothing.

## 1. The entry-only form drops exactly the inherited attributes

`zimscope-fixture-populated-20260731@sirket.lcl`, the account whose quota was set on it during the
[account card capture](./2026-08-02-account-card-attributes.md):

| Attribute | `ga` | `ga -e` |
|---|---|---|
| `displayName` | present | **present** |
| `zimbraAccountStatus: active` | present | **present** |
| `zimbraCOSId` | present | **absent** |
| `zimbraFeatureTwoFactorAuthAvailable: FALSE` | present | **absent** |
| `zimbraIsDelegatedAdminAccount: TRUE` | present | **present** |
| `zimbraMailAlias` (×2) | present | **present** |
| `zimbraMailDeliveryAddress` | present | **present** |
| `zimbraMailForwardingAddress` (×2) | present | **present** |
| `zimbraMailHost` | present | **present** |
| `zimbraMailQuota: 5368709120` | present | **present** |
| `zimbraPasswordModifiedTime` | present | **present** |
| `zimbraPrefMailForwardingAddress` | present | **present** |

Two attributes and no others fall away, and they are the two nobody set on this account. This is the
discriminator working: the quota was set here, so `-e` keeps it.

## 2. And on an account that inherits its quota, the quota falls away too

`zimscope-fixture-ldaponly-20260731@sirket.lcl`, which nobody has given a limit:

```
$ zmprov ga <acct> …                    $ zmprov ga -e <acct> …
# name …                                # name …
displayName: …                          displayName: …
zimbraAccountStatus: active             zimbraAccountStatus: active
zimbraCOSId: e00428a1-…                 zimbraMailDeliveryAddress: …
zimbraFeatureTwoFactorAuthAvailable: FALSE   zimbraMailHost: posta.sirket.lcl
zimbraMailDeliveryAddress: …            zimbraPasswordModifiedTime: 20260730212940.596Z
zimbraMailHost: posta.sirket.lcl
zimbraMailQuota: 0
zimbraPasswordModifiedTime: 20260730212940.596Z
```

**The same attribute, both ways, on one server.** `zimbraMailQuota` is set on the entry of one account and
inherited by the other, and only the entry-only form can tell them apart — the expanding read answers with a
figure in both cases and says nothing about which.

The class of service confirms where the inherited one comes from:

```
$ zmprov gc default cn zimbraMailQuota
# name default
cn: default
zimbraMailQuota: 0
```

So `zimbraMailQuota: 0` reaches the second account by expansion, which is also why an **absent** quota and a
quota of **zero** must render differently: zero means unlimited.

## 3. Three states, not two

An attribute missing from the entry-only read is either inherited or set nowhere at all. On the populated
account, four of the sixteen are in **neither** form — `zimbraIsAdminAccount`, `zimbraLastLogonTimestamp`,
`zimbraPasswordLockoutLockedTime`, `zimbraTwoFactorAuthEnabled`. Reporting those as inherited would send an
operator to read a class of service that has nothing to say about them either. So the screen answers with
three words and the third one is `tanimsiz`.

## 4. A pair has to be captured as a pair

The account card's fixture for this same account carries a `zimbraLastLogonTimestamp` line that the account
does not answer with today. That is right for the card — the timestamp path needs a sample carrying
fractional seconds — and **wrong for provenance**: paired against a fresh entry-only read it would report an
attribute nothing inherits as inherited.

Two halves taken at different moments differ wherever the account changed in between, and every one of those
differences reads as inheritance. So the provenance fixtures are a matched pair captured back to back
(`zmprov_ga_quota_set.txt` / `zmprov_ga_e_quota_set.txt`), and the card's fixtures were left alone.

The bare account needed only its entry-only half. Its expanding half is the card's own
`zmprov_ga_bare.txt`, and that reuse is not an exemption from the rule above: **§2 is the re-capture** — the
left-hand column there is today's `zmprov ga` for that account, and it is `zmprov_ga_bare.txt` line for line,
`zimbraPasswordModifiedTime: 20260730212940.596Z` included. The pair is matched because it was checked, not
because one half looked close enough.

## 5. What was NOT measured, and what follows from it

**`zmprov -l ga -e` was not run.** The three modes measured for this question are `ga`, `-l ga`
([existence gate §4](./2026-08-02-existence-gate-settled.md)) and `ga -e`. The fourth combination is an
assumption, and this tool does not add an allowlist entry on a family resemblance.

The consequence is deliberate rather than discovered. `zro_prov_read` retries every read against LDAP when
mailboxd is unreachable, so without a guard the provenance read would be retried into a form the gate refuses
— and an allowlist denial is logged as a **defect**, during an ordinary outage. The retry therefore asks the
gate first (`zro_ldap_form_allowed`), and a read with no approved LDAP form reports the outage that stopped
it. **Provenance is answerable through mailboxd only**, until someone measures the fourth combination.

## What was left on TEST-C

Nothing. Both commands are reads; no account was modified for this capture.
