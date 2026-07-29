# Zimbra Read-Only Administration TUI — Design Specification

Date: 2026-07-28
Status: Approved design, pending user review
Target environment: Production Zimbra server
Primary interface: Bash + whiptail

## 1. Objective

Create a terminal user interface for Zimbra system administrators that performs common mailbox, account, message, delivery, log, filter, forwarding, alias, and service-health checks without changing Zimbra data or configuration.

The tool must support execution by either `root` or `zimbra`:

- When executed as `zimbra`, approved commands run directly.
- When executed as `root`, approved commands run through `runuser -u zimbra --`.
- Any other user is rejected.

## 2. Non-Goals

The first version will not:

- Create, modify, move, mark, flag, tag, delete, restore, import, send, inject, or recover messages.
- Create, modify, rename, lock, unlock, delete, or change passwords for accounts.
- Add, remove, or modify aliases, forwarding rules, filters, grants, identities, signatures, folders, or distribution-list memberships.
- Execute arbitrary Zimbra commands or arbitrary shell expressions entered by the operator.
- Use `eval`, dynamic function dispatch from user input, or shell command strings.
- Automatically export message bodies or attachments.

## 3. Architecture

The implementation will be modular:

```text
zimbra-readonly-tui/
├── zimbra-ro-tui.sh
├── lib/
│   ├── common.sh
│   ├── account.sh
│   ├── mailbox.sh
│   ├── message.sh
│   ├── delivery.sh
│   ├── settings.sh
│   ├── bulk.sh
│   └── system.sh
├── tests/
│   ├── test_validation.sh
│   ├── test_command_building.sh
│   └── fixtures/
├── docs/
│   └── operations.md
└── README.md
```

### 3.1 Responsibilities

- `zimbra-ro-tui.sh`: startup checks, main menu, navigation, exit handling.
- `lib/common.sh`: execution wrapper, input validation, temporary files, output display, command preview, logging controls.
- `lib/account.sh`: account existence, status, COS, mailbox host, mailbox ID, quota, last logon, memberships.
- `lib/mailbox.sh`: mailbox size, folders, folder details, unread counts, grants.
- `lib/message.sh`: safe search builders, message metadata, folder lookup, flags, headers, attachments metadata.
- `lib/delivery.sh`: `zmmsgtrace`, bounded `grep`/`zgrep` log inspection, delivery result interpretation.
- `lib/settings.sh`: filters, forwarding, aliases, identities, signatures.
- `lib/bulk.sh`: list-file and comma-separated input workflows, per-user error isolation, TSV/CSV metadata output.
- `lib/system.sh`: Zimbra version, hostname, service status, mailbox server checks.

Each module exposes named read-only functions. Menus call only these functions.

## 4. Main Menu

```text
1. Hesap ve kota kontrolleri
2. Mailbox ve klasör kontrolleri
3. Mesaj arama
4. Mesaj detayları
5. Teslimat ve log takibi
6. Filtre, yönlendirme ve alias kontrolleri
7. Toplu kullanıcı sorguları
8. Sistem ve servis durumu
9. Çıkış
```

## 5. Supported Read-Only Operations

### 5.1 Account and quota

Approved command families:

- `zmprov getAccount`
- `zmprov getMailboxInfo`
- `zmprov getQuotaUsage`
- `zmprov getAccountMembership`
- `zmprov getCos`

Displayed fields include:

- Account existence and status
- Display name and addresses
- Mailbox host and mailbox ID
- Mailbox quota and used space
- Last logon timestamp
- COS name and selected COS metadata
- Distribution-list memberships

### 5.2 Mailbox and folders

Approved command families:

- `zmmailbox getMailboxSize`
- `zmmailbox getAllFolders`
- `zmmailbox getFolder`
- `zmmailbox getFolderGrant`

Displayed information includes:

- Total mailbox size
- Folder IDs and paths
- Message and unread counts
- Folder view types
- Existing share grants

### 5.3 Message search

Approved command family:

- `zmmailbox search -t message`

The TUI builds search queries from separately validated fields. Initial search modes:

- Sender address
- Sender domain
- Recipient address
- Subject
- Message-ID
- Date or date range
- Attachment filename
- Attachment type
- Read/unread status
- Specific folder
- Whole mailbox using `is:anywhere`
- Combined criteria

The first version will not provide an unrestricted raw query textbox.

Limits:

- Result limit: 1–1000
- Default result limit: 200
- Search timeout: configurable, default 60 seconds
- Long or broad searches show a confirmation screen

### 5.4 Message details

Approved command families:

- `zmmailbox getMessage`
- `zmmailbox search`
- `zmmetadump`

Displayed metadata includes:

- Message ID
- Conversation ID
- Folder
- From, To, Cc
- Subject and date
- Flags
- Size
- Attachment metadata
- Message-ID header
- Blob path, only under the advanced menu

Message body display is optional and separated from the default metadata view. No message body is automatically written to disk.

### 5.5 Delivery and logs

Approved command families:

- `/opt/zimbra/libexec/zmmsgtrace`
- `grep`
- `zgrep`
- `journalctl --no-pager`, only for approved service-health views

Supported searches:

- Sender and recipient
- Recipient and sender domain
- Message-ID
- Date range
- Rejected, deferred, bounced, or locally delivered status
- Audit and mailbox logs by account

Production constraints:

- Date range requested before broad log scans.
- File paths are fixed in code; operators cannot choose arbitrary files.
- Pattern values are passed as arguments, not interpolated into executable strings.
- Output is capped or paged.

### 5.6 Filters, forwarding, and aliases

Approved command families:

- `zmmailbox getFilterRules`
- `zmmailbox getOutgoingFilterRules`
- `zmmailbox getIdentities`
- `zmmailbox getSignatures`
- `zmprov getAccount`
- `zmprov getAccountMembership`

Displayed values include:

- Incoming and outgoing filters
- User forwarding attributes
- Local delivery status
- Mail aliases
- Identities and signatures
- Distribution-list memberships

### 5.7 Bulk operations

Input forms:

- A single account
- A line-delimited text file
- A comma-separated list

Supported bulk checks:

- Account status
- Quota
- Sender or sender-domain presence
- Subject presence
- Message-ID presence
- Filter, forwarding, and alias summary

Bulk behavior:

- Failure for one account does not terminate the complete run.
- Per-account status is recorded.
- Optional output is metadata-only TSV or CSV.
- Output files are created with restrictive permissions.

### 5.8 System and service status

Approved commands:

- `zmcontrol -v`
- `zmcontrol status`
- `zmhostname`
- selected `zmprov getServer` reads if needed

No service start, stop, restart, enable, disable, or configuration change is exposed.

## 6. Security Model

### 6.1 Explicit allowlist

Only hard-coded wrapper functions may execute external programs. No menu selection is converted into a command name or shell expression.

Approved binaries and subcommands are enumerated in code. Any operation absent from the allowlist is unavailable.

### 6.2 Prohibited operations

The source tree must not contain executable paths to the following Zimbra write operations:

- create
- modify
- delete
- remove
- move
- mark
- flag
- tag
- empty
- import
- post
- recover
- sync

Documentation may name prohibited operations, but executable command construction must not include them.

Known prohibited Zimbra examples include:

- `deleteMessage`
- `deleteConversation`
- `deleteFolder`
- `emptyFolder`
- `moveMessage`
- `markMessageRead`
- `markMessageSpam`
- `modifyAccount`
- `deleteAccount`
- `createAccount`
- `addMessage`
- `postRestURL`
- `recoverItem`

Short aliases such as `dm`, `mm`, `mmr`, `ef`, `df`, `ma`, `da`, and `ca` are not used.

### 6.3 Safe command construction

Commands are constructed as Bash arrays:

```bash
cmd=(/opt/zimbra/bin/zmmailbox -z -m "$account" search -t message -l "$limit" "$query")
"${cmd[@]}"
```

The implementation must not use:

- `eval`
- `bash -c` with user-controlled strings
- `sh -c` with user-controlled strings
- command substitution constructed from user input
- unquoted expansion of input values

### 6.4 Execution identity

A single execution wrapper enforces identity:

```text
zimbra -> execute approved command directly
root   -> execute approved command using runuser -u zimbra --
other  -> refuse execution
```

### 6.5 Input validation

Validation rules:

- Account/email: restricted email-address character set; no whitespace or shell metacharacters.
- Domain: letters, digits, dots, and hyphens; normalized by removing a leading `@`.
- Message ID: positive integer.
- Limit: integer between 1 and 1000.
- Date: strict `MM/DD/YYYY`; calendar validity checked.
- Message-ID header: bounded length and safe printable characters.
- Folder: selected from returned folder list or validated as a bounded path; not interpreted by the shell.
- List files: regular files only, bounded size and line count, no symlink following unless explicitly accepted by the implementation.

### 6.6 Temporary files

- Created only using `mktemp` or `mktemp -d`.
- Default permissions governed by `umask 077`.
- Removed through traps on `EXIT`, `INT`, and `TERM`.
- Message bodies and attachments are not placed in temporary files by default.

### 6.7 Output handling

Default output is terminal-only.

Optional export:

- Metadata only
- TSV or CSV
- Created with mode `0600`
- Destination defaults to a safe administrator-selected directory
- Existing files are not overwritten without explicit confirmation

### 6.8 Auditability

Optional local activity logging may record:

- Timestamp
- Operator account
- Selected read-only function
- Target Zimbra account
- Success or failure
- Duration

It will not record message bodies, attachment contents, or passwords. Activity logging is disabled by default unless the administrator enables it.

## 7. User Interface Behavior

- `whiptail --menu` for navigation.
- `whiptail --inputbox` for validated scalar input.
- `whiptail --checklist` for combined search criteria.
- `whiptail --yesno` for broad searches, exports, and long-running checks.
- Command preview may be enabled, but secrets and unsafe shell representations are not displayed.
- Results are shown through a pager or temporary text box without changing mailbox state.
- Cancel returns to the previous menu instead of terminating unexpectedly.

## 8. Error Handling

The UI distinguishes:

- Invalid input
- Account not found
- Mailbox not found
- No search result
- Folder not found
- Permission failure
- Zimbra service unavailable
- Command timeout
- Log file unavailable
- Partial bulk-run failure

`set -o errexit`, `set -o nounset`, and `set -o pipefail` are used carefully. Expected command failures are captured explicitly so one failed query does not terminate the complete TUI session or bulk run.

## 9. Production Performance Controls

- Default message limit: 200
- Maximum message limit: 1000
- Default command timeout: 60 seconds
- Broad message searches require confirmation
- Log scans require or strongly prompt for date bounds
- Bulk runs display account count before execution
- Bulk runs process sequentially in version 1 to avoid mailbox-server load spikes
- Result display is capped and paged
- No recursive filesystem scans

## 10. Testing Strategy

### 10.1 Static checks

- `bash -n` for all scripts
- `shellcheck` where available
- Search implementation files for prohibited subcommands
- Search implementation files for `eval`, unsafe `bash -c`, and unquoted execution patterns

### 10.2 Unit tests

Tests cover:

- Email, domain, Message ID, date, limit, folder, and file validation
- Query construction for each search mode
- Root versus zimbra execution wrapper selection
- Correct rejection of unauthorized operating-system users
- Safe handling of spaces, quotes, semicolons, command substitutions, and newline injection attempts
- Temporary file cleanup

External Zimbra commands are replaced by fixtures or stubs during tests.

### 10.3 Integration tests

In a non-production Zimbra environment or with mocked binaries:

- Account lookup
- Folder listing
- Whole-mailbox sender-domain search using `is:anywhere`
- Message folder lookup
- Filter and forwarding display
- Delivery trace parsing
- Bulk list processing

### 10.4 Production acceptance

Before production use:

1. Review every external command in the allowlist.
2. Run static prohibited-command scan.
3. Run tests with mocked Zimbra binaries.
4. Execute against a designated test mailbox.
5. Verify before/after mailbox counters and flags remain unchanged.
6. Enable production deployment only after system-team approval.

## 11. Initial Release Scope

Version 1 includes:

- Account and quota checks
- Folder and mailbox-size checks
- Sender, sender-domain, recipient, subject, Message-ID, date, attachment, and folder searches
- Message folder and header metadata
- Filters, forwarding, aliases, identities, and signatures
- `zmmsgtrace` delivery checks
- Bounded account-related log searches
- Single-account and list-file workflows
- Optional metadata-only TSV/CSV export
- System and service status views

Advanced body viewing and blob-path inspection are present only in an explicitly labeled advanced read-only menu and remain terminal-only by default.

## 12. Acceptance Criteria

The design is accepted when:

- All accessible workflows are read-only by construction.
- No arbitrary shell or Zimbra command can be entered through the TUI.
- The tool supports both `root` and `zimbra` execution safely.
- Searches work for one account and account lists.
- A sender-domain search can cover the complete mailbox with `is:anywhere`.
- Message results can be mapped to their folders without modifying flags.
- Delivery traces can be inspected with bounded log access.
- Static scans and automated tests reject prohibited command paths.
- Production acceptance confirms no mailbox counts, flags, folders, messages, filters, account attributes, or service states change.
