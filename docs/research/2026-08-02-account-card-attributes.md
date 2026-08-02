# The account card's attributes, as TEST-C really answers them

Captured 2026-08-02 on TEST-C (`posta.sirket.lcl`, Zimbra 9.0.0 GA FOSS on Ubuntu 20.04) for
[#26](https://github.com/Konsong/zimbra-readonly-tui/issues/26). Everything below is observed output, not
inference. Names and addresses are anonymised in the committed fixtures; shapes, field names and punctuation
are verbatim.

## 1. Every attribute the card names exists

`zmprov desc -a <name>` resolved all sixteen, plus the three that were considered and dropped:

`zimbraMailDeliveryAddress`, `zimbraPasswordModifiedTime`, `zimbraPasswordLockoutLockedTime`,
`zimbraPasswordLockoutFailureTime`, `zimbraTwoFactorAuthEnabled`, `zimbraFeatureTwoFactorAuthAvailable`,
`zimbraFeatureTwoFactorAuthRequired`, `zimbraTwoFactorAuthLastReset`, `zimbraIsAdminAccount`,
`zimbraIsDelegatedAdminAccount`, `zimbraIsDomainAdminAccount`, `zimbraMailForwardingAddress`,
`zimbraPrefMailForwardingAddress`, `zimbraPrefMailLocalDeliveryDisabled`, `zimbraMailAlias`,
`zimbraMailQuota`, `zimbraCOSId`, `zimbraLastLogonTimestamp`.

## 2. The filter is not only about cost

An unfiltered `zmprov ga` on one ordinary account returned **hundreds of lines** — every class-of-service
preference, mobile policy, sieve setting and zimlet the account inherits. The dozen facts an operator came for
are somewhere inside it. Asking for a named attribute list is what makes the output readable at all; that it
also costs one JVM start instead of several is the second reason, not the first.

## 3. Absence is the ordinary case

Asked for sixteen attributes, an account that nobody has logged into, forwarded from, aliased or made an
administrator answers with **nine**:

```
# name zimscope-fixture-ldaponly-20260731@sirket.lcl
displayName: ZimScope temporary LDAP-only fixture 2026-07-31
zimbraAccountStatus: active
zimbraCOSId: e00428a1-0c00-11d9-836a-000d93afea2a
zimbraFeatureTwoFactorAuthAvailable: FALSE
zimbraMailDeliveryAddress: zimscope-fixture-ldaponly-20260731@sirket.lcl
zimbraMailHost: posta.sirket.lcl
zimbraMailQuota: 0
zimbraPasswordModifiedTime: 20260730212940.596Z
```

No placeholder line, no empty value — the attribute is simply not there. **`zimbraLastLogonTimestamp` is
absent on eight of the ten accounts on this server**, which is why rendering absence as a default would have
reported most of a directory as dormant.

## 4. A prefix collision that a naive parser would fall into

The unfiltered dump carries all three of these:

```
zimbraMailForwardingAddress: denetim@example.net
zimbraMailForwardingAddressMaxLength: 4096
zimbraMailForwardingAddressMaxNumAddrs: 100
```

The existing reader matches the attribute name **with its separator attached** (`key ": "` at position 1), so
the two limit attributes cannot be read as forwarding addresses. That was already true; it is now asserted,
because the card's whole claim about forwarding rests on it.

## 5. `zimbraMailForwardingAddress` comes back in insertion order

Every other attribute in `zmprov ga` output is sorted. The multi-valued forwarding attribute is not:

```
zimbraMailForwardingAddress: denetim@example.net
zimbraMailForwardingAddress: arsiv@example.net
```

`denetim` was set first and `arsiv` appended. Nothing in the card depends on the order, but a test that
assumed alphabetical would be asserting something the server does not promise.

## 6. Two-factor authentication could not be captured in its enabled state

Both writes were refused, in sequence:

```
$ zmprov ma <account> zimbraTwoFactorAuthEnabled TRUE
ERROR: service.FAILURE (system failure: cannot enable two-factor auth because it is not available
on this account)

$ zmprov ma <account> zimbraFeatureTwoFactorAuthAvailable TRUE
ERROR: service.FAILURE (system failure: cannot make two-factor auth available because the extension
is not deployed on this server)
```

The `twofactorauth` extension **is** present under `/opt/zimbra/lib/ext` but is not loaded, so the server
refuses either way. What that leaves is a real observation rather than a gap: on such a server
`zimbraTwoFactorAuthEnabled` is **absent on every account** while `zimbraFeatureTwoFactorAuthAvailable` is
present and `FALSE`.

Two consequences for the card. It must tell "this user has not set it up" from "nobody on this server can",
because an operator diagnosing a login failure needs the difference. And **the enabled rendering has no
fixture** — it is asserted against the rendering function directly, and no `ga` fixture in this repository
claims Zimbra wrote a line it has never written.

## 7. Lockout is two signals, and they can disagree

Setting the status and the timestamp together produced exactly what was expected:

```
zimbraAccountStatus: lockout
zimbraPasswordLockoutLockedTime: 20260801091500.000Z
```

Note the fraction: `.000Z`, three digits, like `zimbraPasswordModifiedTime` and `zimbraLastLogonTimestamp`.
The two signals answer different halves of one question — the status says whether the account is locked out
now, the stamp says when a lockout last began — so a stamp left behind by a lockout that has since expired
must not be reported as a locked account.

## 8. The class of service on this server carries no quota

```
# name default
cn: default
zimbraMailQuota: 0
```

So the COS fallback path could be verified for **shape** but not for a non-zero inherited value; the 10 GB COS
fixture keeps the captured shape with a substituted figure, and says so here rather than pretending otherwise.
This also confirms that `zimbraMailQuota: 0` reaches an account by expansion — which is why an *absent* quota
and a quota of zero must render differently.

## 9. `zmprov gam` on an account in no list prints nothing and exits 0

The same "no results is not a failure" shape `gsig` already has. An empty membership and a membership lookup
that failed are different answers, and only one of them means the account belongs to nothing.

## What was left behind on TEST-C

The fixture account `zimscope-fixture-populated-20260731@sirket.lcl` keeps the attributes set for this
capture — a 5 GB quota, one user-set and two administrator-set forwards, delegated admin, and the aliases
`zimscope-alias-a@` and `zimscope-alias-b@` — and belongs to the new list
`zimscope-liste-20260802@sirket.lcl`. Its status was set to `lockout` for the capture and **restored to
`active`** afterwards, confirmed by re-reading it. Nothing was changed on any other account.
