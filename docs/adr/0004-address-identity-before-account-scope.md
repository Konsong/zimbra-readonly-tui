# An address is identified before it is assumed to be an account

- **Status:** accepted
- **Date:** 2026-08-02
- **Evidence:** [2026-08-02 research](../research/2026-08-02-address-identity.md)
- **Affects:** M1, M6, and every account-scoped screen

`zmprov ga` answers a distribution list and an address that exists nowhere with the same sentence —
`ERROR: account.NO_SUCH_ACCOUNT (no such account: ...)`, exit 2, measured on TEST-C. Until now this tool
repeated that sentence to the operator. An operator who reads *"no such account"* about a list they can see in
the address book stops looking in the right place, which is the failure this decision exists to remove.

## The decision

**An address is resolved when it is selected, not when a screen fails.** Resolution runs once per address,
before any account-scoped screen, and the answer is carried with the selection for the rest of the session.
The alternative — each screen interpreting its own failure — would put the interpretation in seven places and
would only ever run after the operator had already spent the query.

**`zmprov ga` is the identity read, and it covers three of the five outcomes.** It resolves an alias to the
account behind it and returns a calendar resource as the account Zimbra stores it as. So an account, an alias
and a resource each cost **one** invocation; only a list and an absent address cost two. `zmprov gcr` is not
allowlisted, because there is no outcome it would decide that `ga` does not.

**The canonical name comes from zmprov's own header line, and from nowhere else.** `# name <address>` for an
account and `# distributionList <address> memberCount=N` for a list carry the entry that answered in the same
position, in both SOAP and LDAP mode. `zimbraMailDeliveryAddress` usually equals it; two sources that can
disagree is how a program reports an alias that is not one. Where there is no header there is no canonical
name and the address is called an account — claiming an alias needs evidence.

**The kind says what the entry is; whether it was reached by a second name is a separate fact.** A calendar
resource can carry an alias too, so deciding both from one cascade would drop whichever came second. The kind
is `resource`, and every screen that has to name both addresses asks `zro_identity_aliased` instead — one
case-folded comparison, in one place, rather than a literal `!=` per screen.

**Absence is a result and returns 0. A question that could not be asked returns why.** The list read runs
only when the account read said, in Zimbra's own words, that there is no such account; every other failure
travels out with its own code. This is the whole discipline: a resolver that answered *"does not exist"*
whenever it failed would put this tool's most misleading sentence behind a stopped service.

**An identity nobody could establish marks nothing.** A failed resolution leaves the address selected and the
identity unanswered, and no menu entry is marked from it. Marking one would report this program's ignorance as
a fact about the server.

**Menu scope is three-valued, not two.** `account` needs the address to be an account; `address` needs an
address of any kind; `server` needs none. Mail to a list appears in the transfer agent's log under the list's
own address, so a delivery trace answers there exactly as it does for a mailbox — and a single
address-or-not distinction would have taken away the one screen that still answers.

## What this does not decide

The distribution list screen itself — members, owners, who may send to it — is
[#30](https://github.com/Konsong/zimbra-readonly-tui/issues/30), which this ticket blocks. Until it lands, an
account operation chosen for a list address shows the identity screen: what the address is, that account
operations do not apply to it, and that tracing still does. What it never shows is *"no such account"*.
