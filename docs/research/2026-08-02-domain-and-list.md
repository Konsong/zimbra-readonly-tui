# The domain read and the distribution list read

Captured on **TEST-C** (`posta.sirket.lcl`, Zimbra 9.0.0 GA FOSS on Ubuntu 20.04) on **2026-08-02**, for
issue #30. Everything below is verbatim output with names and addresses replaced; the fixtures under
`tests/fixtures/` are the same output with the same substitutions.

The lab state this needed did not exist and was created for it, which the ticket anticipated: a second
distribution list with no members, an owner grant, three send grants, a catch-all address and a default class
of service on the domain. All of it is left in place — see the notes at the end.

## 1. `zmprov gd` filters, and the unfiltered form must never reach a screen

`zmprov gd sirket.lcl` with no attribute list answered with **111 lines**: every GAL attribute mapping, every
web client preference — and this:

```
zimbraAuthLdapSearchBindDn: CN=svc_zimbra_ldap svc_zimbra_ldap,CN=Users,DC=sirket,DC=lcl
zimbraAuthLdapSearchBindPassword: <redacted; the real password was printed in the clear>
```

A screen is a thing an operator takes a screenshot of. **The domain card requests its six attributes
explicitly**, which the account card already did for cost reasons and which this makes a second, harder
reason for.

Filtered through the card's own attribute list, on a domain where neither the catch-all nor the default class
of service was set:

```
# name sirket.lcl
zimbraDomainStatus: active
zimbraDomainType: local
```

and with both set:

```
# name sirket.lcl
zimbraDomainDefaultCOSId: e00428a1-0c00-11d9-836a-000d93afea2a
zimbraDomainStatus: active
zimbraDomainType: local
zimbraMailCatchAllAddress: @sirket.lcl
```

- The header is `# name <domain>` — the same shape `zmprov ga` prints, so the identity module's header parser
  reads it unchanged.
- An unset attribute is **absent**, exactly as on an account.
- `zimbraMailCatchAllAddress` must match `^@[A-Za-z0-9-\.]+$`: a catch-all names a **domain**, not a mailbox.
  Setting `zimbraMailCatchAllForwardingAddress` to an account address was refused with
  `account.INVALID_ATTR_VALUE`.
- The default class of service is an **opaque id**. Naming it costs the `zmprov gc` read the account card
  already makes, which is what keeps the domain card at two invocations.

**`zmprov -l gd` answers**, byte for byte for these attributes, so `gd` joins the LDAP-capable set on evidence
rather than by analogy.

A domain the directory does not hold:

```
ERROR: account.NO_SUCH_DOMAIN (no such domain: yok-boyle-bir-alan.example)
[rc=2]
```

**The same error answers an address handed to `gd` in place of a domain**, which is why the domain screen
derives the domain from the selected address rather than passing the address through: without that, every
mistyped call would report a domain this server does not host.

## 2. What a distribution list read carries

```
# distributionList zimscope-liste-20260802@sirket.lcl memberCount=1
mail: zimscope-liste-20260802@sirket.lcl
objectClass: zimbraDistributionList
objectClass: zimbraMailRecipient
uid: zimscope-liste-20260802
zimbraACE: 60b41207-8f1d-470f-8128-d5717e8f29a0 usr sendToDistList
zimbraACE: 99999999-9999-9999-9999-999999999999 pub sendToDistList
zimbraACE: eee27787-0043-4d18-b07f-bbddcf628f5e grp sendToDistList
zimbraACE: 60b41207-8f1d-470f-8128-d5717e8f29a0 usr ownDistList
zimbraACE: eee27787-0043-4d18-b07f-bbddcf628f5e grp ownDistList
zimbraCreateTimestamp: 20260802010122.857Z
zimbraId: d3e4c5d5-8b1e-4f8a-aefc-be4a62672bab
zimbraMailAlias: zimscope-liste-20260802@sirket.lcl
zimbraMailForwardingAddress: zimscope-fixture-populated-20260731@sirket.lcl
zimbraMailHost: posta.sirket.lcl
zimbraMailStatus: enabled

members
zimscope-fixture-populated-20260731@sirket.lcl
```

- **Members are `zimbraMailForwardingAddress`.** The `members` block after the record is a rendering of the
  same values; the attribute is the field, in the `key: value` shape every other read here parses.
- **Owners and send permissions are `zimbraACE` on the same entry**, so one read answers all three questions
  the ticket asks for.
- An **empty list** answers `memberCount=0`, no `zimbraMailForwardingAddress` line at all, and a `members`
  block with nothing under it. Absence is an empty list, not a failure.
- Filtering the read to `zimbraACE zimbraMailForwardingAddress zimbraMailStatus` works and still prints the
  header and the `members` block.
- **`zmprov -l gdl` answers identically**, ACEs included.

### The right is `ownDistList`, not `ownerDistList`

```
zmprov grr dl <list> usr <account> ownerDistList
ERROR: account.NO_SUCH_RIGHT (no such right: invalid right ownerDistList)
```

Worth recording because the admin console calls the same thing "owner", and a card matching the wrong string
would report every list as having no owners while the directory said otherwise.

### A grantee is an id, and `zmprov gg` cannot be the way to name one

`zimbraACE` records the grantee as a `zimbraId`. `zmprov gg -t dl <list>` does list grants with names — and
**truncates them to 30 characters**:

```
grantee name
------------------------------
zimscope-fixture-populated-202
zimscope-liste-bos-20260802@si
```

A truncated address on the screen that answers "who may send to this list" is worse than none, so `gg` is not
in the allowlist and the card names grantees itself: **one read per distinct grantee**, dispatched by grantee
type. Both were measured to answer for an id:

```
zmprov ga 60b41207-8f1d-470f-8128-d5717e8f29a0 displayName
# name zimscope-fixture-populated-20260731@sirket.lcl

zmprov gdl eee27787-0043-4d18-b07f-bbddcf628f5e zimbraMailStatus
# distributionList zimscope-liste-bos-20260802@sirket.lcl memberCount=0
```

The header names the entry in both, so the name comes from the parser the identity module already has.

The public grantee is the fixed sentinel `99999999-9999-9999-9999-999999999999` and names no entry: the card
says what it means instead of looking it up.

## 3. What was not settled here

| Question | Why it is open |
|---|---|
| How a **denied** grant renders (`-sendToDistList`) | Not produced on TEST-C. The card keeps any access control entry it does not recognise, verbatim, under its own heading, rather than reading one as permission. |
| The `all`, `dom`, `gst` and `key` grantee types | No instance on the lab server. They render as the type plus the identifier — honest and unresolved — rather than as a translation nobody measured. |
| Whether an empty send permission really means "anyone may send" | Zimbra's documented rule, and not testable on TEST-C: the box has no `zimbra-mta`, so no message can be sent to a list at all. The card states the rule; the fields above it state only what the directory holds. |

## 4. Lab state left behind

On `sirket.lcl`, all of it deliberate and none of it reverted, so the fixtures can be re-captured:

- `zimscope-liste-bos-20260802@sirket.lcl` — a distribution list with **no members**.
- `zimscope-liste-20260802@sirket.lcl` — now carries `sendToDistList` for an account, for that empty list as a
  group, and for `pub`; and `ownDistList` for the account and the group.
- The domain carries `zimbraMailCatchAllAddress: @sirket.lcl` and
  `zimbraDomainDefaultCOSId` pointing at the `default` class of service.
