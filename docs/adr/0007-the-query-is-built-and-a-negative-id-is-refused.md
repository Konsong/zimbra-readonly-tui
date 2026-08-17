# The search query is built, never typed — and a conversation id that looks like a flag is refused

- **Status:** accepted
- **Date:** 2026-08-03
- **Extends:** [ADR-0001](./0001-mailbox-existence-gate.md) — two more operations behind the gate, reached
  through the one function that owns the gated binary
- **Evidence:** [`docs/research/2026-08-03-message-search-and-conversations.md`](../research/2026-08-03-message-search-and-conversations.md),
  captured on the lab server
- **Affects:** the message search and the conversation listing, the query-language quoting the design spec
  recorded as debt, and the item-id validator

Finding a message means sending Zimbra a query in a language of its own — with boolean operators, a field
separator, a wildcard and its own quoting. That is a third escaping layer beside the shell safety the exec
gate provides by passing argument arrays and the pattern escaping the delivery tracer needs, and it is the
one this ADR is mostly about.

## The decision

**The operator never types a query.** They pick a criterion from a declared list and give it at most one
value; the tool writes the term, joins the terms, and shows the finished query above the answer. Nothing an
operator types becomes an operator, a field name or a boolean — the same rule the canned log searches live
by, and it matters more here, because a query that means something other than it reads answers with a
plausible list rather than with an error.

**A value is quoted by Zimbra's rule and by no other.** Inside a `"…"` term a literal double quote is written
`\"`, and a backslash is an ordinary character everywhere else. The design draft doubled backslashes, which
would have searched `C:\\rapor` for an operator who typed `C:\rapor`: Zimbra's unescaper only ever collapses
that one two-character sequence. The rule here is Zimbra's own escaper's, and it was checked against a
message whose subject really carries quotes.

**A value that ends in a backslash is refused, because no escaping saves it.** It pairs with the closing
quote the tool adds, and the value then terminates its own quoting. Both outcomes were measured and neither
may be passed on: alone at the end of a query, the lexer backtracks, drops the backslash and answers about a
*different* value than the one typed — a silent false negative on a screen whose empty answer is read as
proof; with another quoted criterion behind it, the closing quote is swallowed, that criterion is eaten, and
the whole query fails to parse. Refusing is visible, and it is the only one of the three that is.

**Dates are sent as epoch milliseconds, and a day is a bounded pair rather than a `date:` term.** Zimbra
parses an absolute date with the request locale's short format and refuses ISO outright, so the same query
would mean different days on a Turkish and an American server; a count of milliseconds means one thing
everywhere, which is the reason the mailbox size is asked for as a raw byte count too. `date:` is documented
as equality over a whole day and is **not** used: given a numeric value it compares one instant, and a
single-day search built on it answered with nothing at all on a day holding eleven messages — measured after
a code review asked whether it ever had been. What is used instead is `after:<midnight> before:<next
midnight>`, and the boundary that makes that exact was measured in the same pass: `after:` compares the
instant as given, so a range keeps its own first day rather than silently dropping it.

**A conversation id beginning with a minus is refused without anything being run.** Zimbra names a
conversation holding one message with the **negation** of that message's id, and prints it in the table it
offers. The CLI would take it — commons-cli does not read `-263` as an option, measured — but this program
cannot: a token shaped like a flag standing in the data position is not data to the exec gate, it is looked
up in the allowlist under the subcommand that approved it, and no list can carry an entry per id. Weakening
that rule for one screen would weaken it for `zmprov -t`, which writes a file, so the refusal stands and the
screen answers it in its own words: the conversation holds one message, its id is the value without the sign,
and the operator already has that row on the screen in front of them.

**The result is bounded and the search is not.** The tool declares how many hits it will show; the server
still examines the whole mailbox and says through its own `more:` flag whether it had more to give, which the
screen passes on. That is the opposite trade from the log viewer's bounded read and it is a third thing again
from a match-bounded scan: nothing here went unread, so a capped answer is not a partial scan and is not
disclosed as one.

**The row is offered as the server printed it, and only the id is parsed.** The table's column widths are
computed per page — a page of ten hits prints every column one character further right than a page of nine,
captured both ways — so the fixed-offset reading that is correct for the folder listing is wrong here. Only
the region left of the sender is read field by field, and it holds nothing but digits, a dot and a
four-letter type; everything from the sender onwards is shown as it came, because those fields carry text in
the account holder's own language and a substring taken by character position means one thing under a UTF-8
locale and another under C. A misplaced cut in a display column is a garbled name; a misplaced cut in an id
is the wrong message.

## Consequences

**`gm` stays off the allowlist and message detail stays unbuilt.** The search answers what a mailbox holds
without opening anything: `ZSearchParams` never sets `markAsRead`, and the measurement agrees — the same
unread ids answered before and after roughly forty searches and five conversation listings, with the
account's `mailbox` row byte-identical. Message *detail* is the read that clears the flag it reports, and it
is still nowhere in this tool.

**Two criteria are offered that answered nothing here.** `envfrom:` and `envto:` parse, are refused by
nothing, and matched no message on the lab server — including messages whose envelope was exactly the address
searched for, delivered through that server's own MTA minutes earlier. They are offered because the ticket
asks for them and the language accepts them, and the screen says before the value is asked for that an empty
answer from those two may mean the field was never indexed rather than that no such message exists. The
alternative — leaving them out — would have been a screen that quietly cannot answer a question an operator
knows Zimbra has words for.

**One virtual conversation per single-message conversation cannot be listed**, which on a mailbox of mostly
unthreaded mail is most of them. The cost is nothing an operator loses: such a listing would print the row
they picked it from.
