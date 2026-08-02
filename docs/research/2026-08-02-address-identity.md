# What an address turns out to be, as TEST-C really answers it

Captured 2026-08-02 on TEST-C (`posta.sirket.lcl`, Zimbra 9.0.0 GA FOSS on Ubuntu 20.04) for
[#27](https://github.com/Konsong/zimbra-readonly-tui/issues/27). Everything below is observed output, not
inference. Names and addresses are anonymised in the committed fixtures; shapes, error strings and exit
statuses are verbatim.

## 1. The premise, confirmed word for word

`zmprov ga` on a distribution list and `zmprov ga` on an address that exists nowhere produce **the same
sentence** and the same exit status:

```
$ zmprov ga zimscope-liste-20260802@sirket.lcl          # a real distribution list
ERROR: account.NO_SUCH_ACCOUNT (no such account: zimscope-liste-20260802@sirket.lcl)   # rc=2

$ zmprov ga zimscope-yok-20260802@sirket.lcl            # nothing, anywhere
ERROR: account.NO_SUCH_ACCOUNT (no such account: zimscope-yok-20260802@sirket.lcl)     # rc=2
```

An address in a domain that does not exist answers the same way — `account.NO_SUCH_ACCOUNT`, not a
domain-specific error — so there is no fourth case hiding behind a different string.

## 2. `zmprov ga` already resolves an alias, and says which account answered

```
$ zmprov ga zimscope-alias-a@sirket.lcl displayName zimbraMailDeliveryAddress
# name zimscope-fixture-populated-20260731@sirket.lcl
displayName: ZimScope temporary populated fixture 2026-07-31
zimbraMailDeliveryAddress: zimscope-fixture-populated-20260731@sirket.lcl
```

The header line names the entry that answered, not the name that was asked for. **That is the alias
detection**, and it costs nothing: the read that identifies the address is the same read that resolves it.

`zmprov gam` was run through the alias as well and returned the account's own memberships, so no screen has to
rewrite an alias before querying.

## 3. A calendar resource IS an account, and `zmprov gcr` is not needed to find one

There were no calendar resources on TEST-C, so one was created for this capture.

```
$ zmprov ga zimscope-kaynak-20260802@sirket.lcl displayName zimbraAccountCalendarUserType
# name zimscope-kaynak-20260802@sirket.lcl
displayName: ZimScope toplanti odasi
zimbraAccountCalendarUserType: RESOURCE
```

`ga` answers for it, its objectClass carries `zimbraCalendarResource` alongside `zimbraAccount`, and
`zimbraAccountCalendarUserType: RESOURCE` is what an ordinary account does not have. So the resource case is
**one attribute on a read that was happening anyway** rather than a third invocation, and `zmprov gcr` never
enters the allowlist.

The reverse does not hold: `zmprov gcr` on an ordinary account fails with
`account.NO_SUCH_CALENDAR_RESOURCE`. Only `ga` is general.

## 4. `zmprov gdl` is what tells a list apart from nothing

```
$ zmprov gdl zimscope-liste-20260802@sirket.lcl
# distributionList zimscope-liste-20260802@sirket.lcl memberCount=1
mail: zimscope-liste-20260802@sirket.lcl
objectClass: zimbraDistributionList
...
zimbraMailStatus: enabled

members
zimscope-fixture-populated-20260731@sirket.lcl
```

Its header carries the entry name in the same third position `# name` does, so one parser reads both.

On anything that is not a list — an account, a resource, an address that is nowhere — it fails with a
**different error string** from `ga`'s:

```
ERROR: account.NO_SUCH_DISTRIBUTION_LIST (no such distribution list: ...)   # rc=2
```

That string was not in `zro_prov_fail_code`'s pattern and had to be added; without it a missing list would
have fallen through to the raw exit status and been read as a question that could not be asked.

**Requesting attributes does not bound the output.** `zmprov gdl <list> zimbraMailStatus` still prints the
whole `members` block. Nothing bounds it, so the identity resolver reads only the header and leaves the
members to the screen that displays them. The output is proportional to the list, never to the server, which
is cost class 1 by the definition in `CONTEXT.md`.

## 5. Both reads answer in LDAP mode, header and all

```
$ zmprov -l ga zimscope-alias-a@sirket.lcl ...     -> # name zimscope-fixture-populated-...
$ zmprov -l gdl zimscope-liste-20260802@sirket.lcl -> # distributionList zimscope-liste-... memberCount=1
```

So a degraded read still identifies an address, and the one thing the resolver parses is the one thing both
modes print.

## 6. zmprov answers in the case the directory holds, not the case it was asked in

```
$ zmprov ga ZimScope-Alias-A@Sirket.LCL displayName zimbraMailDeliveryAddress
# name zimscope-fixture-populated-20260731@sirket.lcl
```

Comparing the requested address to the header literally would report **every operator who capitalised an
address** as having typed an alias. The comparison is case-folded.

## 7. A third failure shape, so that failure is never read as absence

Captured by asking zmprov to authenticate with a password that is not the admin's:

```
ERROR: account.AUTH_FAILED (authentication failed for [admin@sirket.lcl])
```

It maps to the permission code, not to a missing address. Together with the two connection failures already on
file it gives three distinct causes, none of which may ever reach the operator as *"this address does not
exist"*.

## What this settles about cost

| Outcome | Reads | Why |
|---|---|---|
| account | 1 | `ga` answered |
| alias | 1 | `ga` answered, and its header named a different entry |
| resource | 1 | `ga` answered, with `zimbraAccountCalendarUserType: RESOURCE` |
| list | 2 | `ga` said no such account, `gdl` answered |
| absent | 2 | both said no |

Nothing searches, and no read's work grows with the number of accounts on the server.

## What was left behind on TEST-C

The calendar resource **`zimscope-kaynak-20260802@sirket.lcl`** ("ZimScope toplanti odasi",
`zimbraCalResType: Location`) was created for §3 and is still there; it is the only resource on the server and
the only object this capture added. The fixture account and distribution list from the
[account card capture](./2026-08-02-account-card-attributes.md) were read but not modified. Nothing else on
the server was changed.
