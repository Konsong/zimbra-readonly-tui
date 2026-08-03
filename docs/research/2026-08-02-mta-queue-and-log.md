# The mail transfer agent, the queue tool and a populated mail log

Captured on **TEST-C** (`posta.sirket.lcl`, Zimbra 9.0.0 GA FOSS on Ubuntu 20.04) on **2026-08-02**, for
issue #24. Everything below is verbatim output with names and addresses replaced; the fixtures under
`tests/fixtures/` are the same output with the same substitutions.

The lab state this needed did not exist and was created for it, which the ticket anticipated: the box carried
the directory and store packages but no mail transfer agent, so there was no queue tool and no mail traffic
at all. What was installed and what was left behind is at the end.

**Substitutions applied throughout.** The repository is public and this is a private network, so every
address that identifies the lab was replaced, consistently, in both this file and the fixtures:

| Observed | Written as |
|---|---|
| `posta.sirket.lcl` / `192.168.1.12` | `mail01.example.com` / `192.0.2.12` |
| `scapad.sirket.lcl` / `192.168.1.5` (the site's DNS and directory server) | `dc01.example.com` / `192.0.2.5` |
| `deneme-mbx@sirket.lcl` (sender) | `ahmet.yilmaz@example.com` |
| `zimbra.auth.test@sirket.lcl` (recipient) | `ayse.demir@example.com` |
| `yokboyle-kullanici@sirket.lcl` (an address nobody has) | `olmayan-kullanici@example.com` |

Queue identifiers, process ids, timings and byte counts are **not** substituted — they are what the tool has
to parse, and inventing them would defeat the point of capturing at all. The syslog host field is left as
`posta`, because a log line's shape includes it.

## 1. What was installed

Only `zimbra-mta` was added. `logger`, `dnscache`, `snmp`, `apache`, `spell`, `memcached`, `proxy`, `drive`,
`imapd` and `chat` were declined; `core`, `ldap` and `store` were reinstalled at the same version, which is
what the installer does when it adds a package to an existing deployment.

```
zimbra-mta              9.0.0.GA.4200046.UBUNTU20.64
zimbra-postfix          3.6.14-1zimbra8.7b4.20.04
zimbra-mta-components   1.0.23-1zimbra8.8b1.20.04
zimbra-amavisd          2.13.0-1zimbra8.7b2.20.04
zimbra-clamav           1.0.1-1zimbra8.8b4.20.04
zimbra-opendkim         2.10.3-1zimbra8.7b6.20.04
```

The package came from the installer tarball already on disk
(`/opt/zimbra-install/zcs-9.0.0_GA_4200046.UBUNTU20_64.20250725085925`), not from `repo.zimbra.com`. That
matters: the repository serves the newest patch level, and a mail transfer agent newer than the installed
store would not have matched. The repository was still reachable and supplied the dependency packages.

## 2. The queue tool, and the three facts a capability probe needs

```
mail_version            = 3.6.14
authorized_mailq_users  = static:anyone
queue_directory         = /opt/zimbra/data/postfix/spool
command_directory       = /opt/zimbra/common/sbin
```

```
-rwxr-sr-x 1 root postdrop 327744 Jan 26  2024 /opt/zimbra/common/sbin/postqueue
```

**`authorized_mailq_users = static:anyone` is the permissive default**, and it is the setting the probe in
issue #33 exists to read. Postfix consults it inside `postqueue` itself: where a site has narrowed it, the
tool is present, executable, and answers with a refusal rather than a queue. Run as `zimbra` on this host it
exits **0**.

`postqueue` is **setgid `postdrop`**, not setuid root. It reads the queue through the `postdrop` group, which
is why it answers for an unprivileged user at all — and why its absence from that group would be a different
failure from its absence from the disk.

## 3. Both queue listing forms

The installed version offers both, so both are captured.

**Traditional** — `postqueue -p`, with two deferred messages
(`tests/fixtures/postqueue_p_deferred.txt`):

```
-Queue ID-  --Size-- ----Arrival Time---- -Sender/Recipient-------
C800B104BA4     848 Sun Aug  2 16:49:03  ahmet.yilmaz@example.com
(Host or domain name not found. Name service error for name=nosuchdomain.invalid type=MX: Host not found, try again)
                                         kullanici@nosuchdomain.invalid

C5233104BA7     846 Sun Aug  2 16:49:03  ahmet.yilmaz@example.com
            (connect to dc01.example.com[192.0.2.5]:25: Connection refused)
                                         kuyruk-test@dc01.example.com

-- 1 Kbytes in 2 Requests.
```

**Three things a parser has to survive here.** The reason line sits *between* the sender and the recipient,
not after the entry. Its indentation is **not stable** — the first entry's reason starts at column 1 because
the text is long enough to wrap the field, the second is indented twelve spaces. And entries are separated by
a blank line, with a summary line at the end that is not an entry.

**Structured** — `postqueue -j`, one JSON object per line, no enclosing array
(`tests/fixtures/postqueue_j_deferred.txt`):

```
{"queue_name": "deferred", "queue_id": "C800B104BA4", "arrival_time": 1785678543, "message_size": 848, "forced_expire": false, "sender": "ahmet.yilmaz@example.com", "recipients": [{"address": "kullanici@nosuchdomain.invalid", "delay_reason": "Host or domain name not found. Name service error for name=nosuchdomain.invalid type=MX: Host not found, try again"}]}
```

The structured form carries the same facts without the indentation problem, and `arrival_time` as an epoch
rather than a formatted date. **It is the better form to read** — but the traditional form is what an
operator recognises, and the tool has no JSON parser and may not grow one for this.

**Empty queue** (`tests/fixtures/postqueue_p_empty.txt`) is a single line and **not** an error — exit status
is still 0:

```
Mail queue is empty
```

## 4. The four delivery outcomes

All four were produced over real SMTP against this box. **Postfix's configuration was not touched**; each
outcome comes from the deployment as the installer left it.

Two of them landed the opposite way round from the obvious guess, which is exactly why this project captures
rather than writes from memory:

| Intended | What actually happened |
|---|---|
| An address nobody has → *reject* | **Accepted, then bounced.** `permit_mynetworks` is evaluated before `reject_unlisted_recipient`, so a local client is permitted before any rejection rule runs. The failure surfaces at the error transport instead. |
| A domain that does not exist → *bounce* | **Deferred.** Postfix reads an MX lookup failure as temporary (`4.4.3 … try again`) and keeps retrying. |

`smtpd_recipient_restrictions` as installed:

```
reject_non_fqdn_recipient, permit_sasl_authenticated, permit_mynetworks, reject_unlisted_recipient,
reject_invalid_helo_hostname, reject_non_fqdn_sender, permit
```

### delivered

Two queue ids per message, because everything passes through amavis and comes back: the first hop is
`smtp` to `127.0.0.1:10026`, the second is `lmtp` to the mailbox server on `:7025`.

```
Aug  2 16:49:03 posta postfix/smtp[288931]: 90693104B8D: to=<ayse.demir@example.com>, relay=127.0.0.1[127.0.0.1]:10026, delay=0.15, delays=0.02/0.01/0/0.12, dsn=2.0.0, status=sent (250 2.0.0 from MTA(smtp:[127.0.0.1]:10025): 250 2.0.0 Ok: queued as B0CC6104BA2)
Aug  2 16:49:04 posta postfix/lmtp[288967]: B0CC6104BA2: to=<ayse.demir@example.com>, relay=mail01.example.com[192.0.2.12]:7025, delay=0.63, delays=0/0.02/0.08/0.53, dsn=2.1.5, status=sent (250 2.1.5 Delivery OK)
```

**A trace that stops at the first `status=sent` has not proved delivery.** The first one only says amavis
accepted it. The `lmtp` line with `dsn=2.1.5` is the one that means a mailbox received it, and it carries the
*second* queue id — so following one message end to end means following the `queued as` handover.

### bounced

```
Aug  2 16:49:03 posta postfix/error[288975]: B8E90104BA5: to=<olmayan-kullanici@example.com>, relay=none, delay=0.05, delays=0.02/0.02/0/0.01, dsn=5.0.0, status=bounced (example.com)
Aug  2 16:49:03 posta postfix/bounce[288977]: B8E90104BA5: sender non-delivery notification: C2131104BA8
```

The reason text is **just the domain** — `(example.com)` — which says nothing an operator can act on. The
useful detail is in the notification message, not in this line. A screen that prints the reason verbatim will
print a bare domain name and must not present that as an explanation.

### deferred

Two different causes, and the tool should not flatten them:

```
Aug  2 16:49:03 posta postfix/smtp[288983]: C800B104BA4: to=<kullanici@nosuchdomain.invalid>, relay=none, delay=0.06, delays=0.01/0.04/0/0, dsn=4.4.3, status=deferred (Host or domain name not found. Name service error for name=nosuchdomain.invalid type=MX: Host not found, try again)
Aug  2 16:49:03 posta postfix/smtp[288981]: C5233104BA7: to=<kuyruk-test@dc01.example.com>, relay=none, delay=0.1, delays=0.02/0.03/0.05/0, dsn=4.4.1, status=deferred (connect to dc01.example.com[192.0.2.5]:25: Connection refused)
```

### rejected

**No local client can produce one.** `permit_mynetworks` covers `127.0.0.0/8` and the site's own `/24`, so
the rejection rules are never reached from inside. These two were observed from a client address outside
`mynetworks` — `10.99.99.99`, added to loopback for the length of the capture and removed afterwards. That
is the production condition, not a relaxed one: a rejected message is by definition one a foreign server
offered.

```
Aug  2 16:51:15 posta postfix/smtpd[288566]: NOQUEUE: reject: RCPT from unknown[10.99.99.99]: 550 5.1.1 <olmayan-kullanici@example.com>: Recipient address rejected: example.com; from=<ahmet.yilmaz@example.com> to=<olmayan-kullanici@example.com> proto=ESMTP helo=<foreign.example.net>
Aug  2 16:51:15 posta postfix/smtpd[288566]: NOQUEUE: reject: RCPT from unknown[10.99.99.99]: 554 5.7.1 <someone@example.org>: Relay access denied; from=<ahmet.yilmaz@example.com> to=<someone@example.org> proto=ESMTP helo=<foreign.example.net>
```

**A rejection has no queue id.** The literal `NOQUEUE` sits where every other line carries one, so a search
keyed on queue id will never find a rejected message — and a rejected message is exactly the one an operator
is looking for when they say "it never arrived". Both lines carry `from=` and `to=`, so the address search
finds them; the message-id search cannot, because the message was refused before `DATA`.

## 5. The mail log

```
-rw-r--r-- 1 syslog adm 732586 Aug  2 16:53 /var/log/zimbra.log
8268 lines, 732586 bytes
```

**It is owned `syslog:adm`, not `zimbra`.** This is the ownership `docs/operations.md` already documents as
the cause of exit code 23 — created by rsyslog rather than by Zimbra. Here it happens to be mode 644, so
`zimbra` can read it and the tool works; the hazard is one `chmod` away, and it arrived that way on a fresh
install without anybody configuring it.

At 8268 lines against a bounded read of 500, **a bounded read and a full scan see different things** — the
delivery outcomes above are in the first fifth of the file and a tail of 500 lines does not reach them. That
is the condition the log search in issue #32 needs, and it is why the tool reads whole files rather than
tails when it is searching rather than viewing.

`tests/fixtures/zimbra_log_outcomes.txt` carries the outcome lines above as a fixture. The **full** log is
not committed — 716 KB of mostly startup noise — and stays on the lab server.

## 6. What was left behind on TEST-C

- **`zimbra-mta` is installed and running**, along with amavis and clamav. `zmcontrol status` shows `mta`
  and `amavis` alongside the services that were already there. Port 25 listens.
- **The `stats` service is running again.** It was stopped before the install and the installer restarted it.
- **Two messages are still in the deferred queue** and will retry until they expire. One of them retries
  against the site's directory server on port 25, which refuses; that is a connection attempt every
  retry interval until Postfix gives up. Delete them with `postsuper -d ALL` when the queue is no longer
  needed for capture.
- Four test messages were delivered to `zimbra.auth.test@sirket.lcl`, plus two non-delivery notifications to
  `deneme-mbx@sirket.lcl`.
- The temporary `10.99.99.99` address on loopback **was removed**.
- The installer's license agreement was accepted. The "notify Zimbra of your installation" step, which
  transmits the admin address, was **declined**.

## 7. Still open after the first pass

Everything the ticket asked for was observed except these, which are recorded rather than guessed. **Three
of the four were settled in the second pass below**; the rows are left as they were written, with what
answered them.

| Question | Why it was still open | Answered |
|---|---|---|
| `postqueue` behaviour when `authorized_mailq_users` is **narrowed** | The default is `static:anyone` and it was not changed. What the refusal looks like — exit status and message — is unobserved, and the capability probe in #33 needs it. Producing it means editing a Postfix parameter, which no capture so far has needed. | §9.3 — and the obvious way to narrow it does not narrow it at all |
| The queue tool's behaviour on an **active** or **hold** queue | Both captures are of the `deferred` queue. `queue_name` is a field in the structured form, so the other values exist; none was observed. | §9.2 for `hold`. `active` remains unobserved |
| A queue large enough to need bounding | Two entries. The screen is specified to summarise by status first, and two entries cannot show that a large queue is unreadable without it. | Still open. Three entries is what the second pass produced |
| Whether a **rejected** message can be produced without a client outside `mynetworks` | Not on this configuration. Any site whose `mynetworks` covers its own hosts has the same property, so the tool should not expect to reproduce a rejection locally. | Still open, and expected to stay so |

## 8. Second pass: the service status, for issue #33

Captured on **TEST-C** on **2026-08-02**, late evening, with the same substitutions as everywhere above.
`zmcontrol status` had never been captured at all — it was described in the CLI reference from source, and
the screen that renders it needed the real shape.

**Everything running** (`tests/fixtures/zmcontrol_status_ok.txt`), exit **0**:

```
Host mail01.example.com
	amavis                  Running
	ldap                    Running
	mailbox                 Running
	mta                     Running
	service webapp          Running
	stats                   Running
	zimbra webapp           Running
	zimbraAdmin webapp      Running
	zimlet webapp           Running
	zmconfigd               Running
```

**Three things a parser has to survive here.** The host stands in column 1 and every service hangs under it
behind a **tab**. Four of the ten service names **contain a space** — `service webapp`, `zimbra webapp`,
`zimbraAdmin webapp`, `zimlet webapp` — so a reader that split on whitespace and took the second field as
the state would report four services in a state that does not exist. And the name is padded to a fixed
width, which is presentation and not data: the state is the **last** word on the line.

**With one service stopped** (`tests/fixtures/zmcontrol_status_stopped.txt`): `stats` was stopped with
`zmstatctl stop` and started again straight afterwards, which is the only way a stopped line could be
observed on a box where everything runs.

```
	stats                   Stopped
```

**The exit status is 0 either way.** A stopped service is not an error to this command, so nothing about
whether the server is healthy can be read from the status code — only from the lines.

**A service line is an aggregate, and `stats` is what showed it.** Hours after the capture the same host
reported `stats Stopped` again without anybody stopping it. `zmstatctl status` listed ten of its collectors
running and one — `zmstat-ldap` — with a pid file pointing at a process that was gone, and exited 1. So
`Stopped` on this screen means *this service is not fully up*, not *nothing of it is running*, and the
screen is right to show the word the command chose rather than a healthier reading of it. `zmstatctl start`
brought it back.

## 9. Second pass: the queue, on a queue that had something in it

The two deferred messages from the first pass had expired by the time this was captured: `postqueue -p`
answered `Mail queue is empty` and `postqueue -j` printed **nothing at all**, both on exit 0. Three fresh
messages were injected with `sendmail` — two to a domain that does not resolve, one to a host that refuses
port 25 — and the captures below are of that queue.

### 9.1 What an empty queue is

`Mail queue is empty` on stdout, exit **0**, for `-p`; **no output at all** for `-j`. An empty queue is not
an error and must not be rendered as one.

### 9.2 Two statuses in one listing

`tests/fixtures/postqueue_p_deferred_hold.txt` — two deferred and one placed on hold with
`postsuper -h <id>`:

```
-Queue ID-  --Size-- ----Arrival Time---- -Sender/Recipient-------
21E9B104C1C     316 Sun Aug  2 23:26:43  ahmet.yilmaz@example.com
(Host or domain name not found. Name service error for name=nosuchdomain.invalid type=MX: Host not found, try again)
                                         kullanici@nosuchdomain.invalid

26D3F102FBF!     316 Sun Aug  2 23:26:43  ahmet.yilmaz@example.com
            (connect to dc01.example.com[192.0.2.5]:25: Connection refused)
                                         kuyruk-test@dc01.example.com

-- 0 Kbytes in 3 Requests.
```

**The hold marker is a `!` appended directly to the queue id**, with no space — so the id is one word and
the marker is the last character of it, exactly as the manual page describes. The structured form of the
same queue confirms it reads `"queue_name": "hold"` where the traditional form marks `!`, and `"deferred"`
where it marks nothing. **`active` was still not observed**: an entry is active only while it is being
delivered, which on a box with nothing to deliver to is a window too small to catch.

The unstable indentation of the reason line reproduced exactly as in the first pass — column 1 for the long
one, twelve spaces for the short one — in the same listing, which is what the parser is held to.

### 9.3 The access-control setting, and the way it is not narrowed

**`authorized_mailq_users = static:root` does not narrow anything.** Set that way, `postqueue -p` as
`zimbra` still answered, exit 0. A `static:` map returns its value for **every** lookup, so `static:root`
permits everyone exactly as `static:anyone` does — the word after the colon is the value, not the
permitted user. This is the trap the first pass would have walked into, and it is why the refusal is worth
capturing rather than reasoning about.

**A plain name list narrows it.** With `authorized_mailq_users = root`, as `zimbra`:

```
postqueue: fatal: User zimbra(997) is not allowed to view the mail queue
```

on **stderr**, exit **69** (`EX_NOPERM`). The empty value — `authorized_mailq_users =` — refuses everybody
with the same message and the same status. `-j` prints nothing on stdout and exits 69 too. As `root` with
the same setting the listing works, exit 0, which is the point: the refusal is about the account every
command in this tool runs as, and reading the queue as `root` would be escalating around a setting somebody
chose.

The setting was restored to `static:anyone` and the listing as `zimbra` confirmed working before the capture
ended.

## 10. What the second pass left behind on TEST-C

- **The queue is empty again.** The three injected messages were released from hold and deleted with
  `postsuper -d ALL`; `postqueue -p` answers `Mail queue is empty`.
- **`authorized_mailq_users` is back to `static:anyone`**, restored from a copy of `main.cf` taken before
  the edit, and the copy was removed.
- **`stats` is running.** It was stopped for one capture and started again — and found stopped once more a
  few hours later, of its own accord, with `zmstat-ldap`'s pid file stale. Started again; see §8.
- Nothing else was changed. No message was sent to a real recipient: every injected message was addressed to
  a domain that does not resolve or to a host that refuses port 25.

## 11. The tool itself, run against this server

The modules were copied to `/tmp/zro` on the lab server and driven as `zimbra` — the real binaries, the real
directory, no mocks — because a fixture proves a parser and only the server proves the path. Removed
afterwards.

| Condition | What the tool did |
|---|---|
| Ordinary host | Service card rendered all ten services with `stats` correctly shown as stopped; queue summary counted the two injected messages as waiting, and the detail rendered both with their reasons |
| `authorized_mailq_users = root` | `zro_queue_fetch` returned **20** (`ZRO_E_PERM`), the capability answered **`denied`**, and the message the tool quotes is Postfix's own |
| `ZRO_POSTFIX_SBIN` pointed at a directory with no queue tool | `zro_queue_fetch` returned **92** (`ZRO_E_NOCAP`) and the capability answered **`nobin`** — a different answer with a different repair, which is what the ticket asked for |

The queue was emptied and the Postfix setting restored at the end of the run.
