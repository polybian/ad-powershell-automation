# AD PowerShell Automation Implementation — Bulk Users, Group Sync & AD Audits

An implementation (fictional `contoso.example` domain, no real users or data) for
the on-prem Active Directory work that shows up in mid-level IT roles:
bulk-provision OUs and users from a CSV instead of clicking through ADUC,
keep group membership in a declared desired state, and audit the domain for
stale accounts and undocumented GPOs — all with dry-run support and a
written audit trail.

**What this demonstrates:** PowerShell + ActiveDirectory module automation,
idempotent provisioning (safe re-runs), desired-state group reconciliation
with drift reporting, input validation before writes, read-only AD hygiene
audits (stale accounts, GPO inventory with links), least-privilege
delegation, and SecureString-only credential handling.

```
  desired state (CSV)                 scripts                        directory

  templates/users.csv   ───►  New-ADUsersFromCsv.ps1   ───►  ┌──────────────────┐
   FirstName, LastName,        validate UPN / SAM / OU       │  TARGET DOMAIN   │
   UPN, OU, Dept, Title        create OUs (parents first)    │ contoso.example  │
                               skip accounts that exist      │                  │
                                                             │  OU=Users        │
  templates/groups.csv  ───►  Sync-ADGroupMembership.ps1 ──► │  ├─ OU=Sales     │
   GroupName,                  add missing members           │  ├─ OU=Support   │
   SamAccountName              report drift (extras)         │  └─ OU=Finance   │
                               remove only with -RemoveExtra │  users + GG-*    │
                                                             │  groups          │
  AD (actual state)     ───►  Get-StaleADAccounts.ps1  ───►  └──────────────────┘
                               disabled / never logged on            │
                               / expired passwords                   ▼
  AD (actual state)     ───►  Get-GPOInventory.ps1     ───►  logs/ + reports/
                               GPOs, links, enabled state     (timestamped CSVs)

  AD (actual state)     ───►  Get-ADHealthReport.ps1   ───►  console summary +
   (v2, read-only)             DCs / replication / FSMO        reports/*.html
                               stale PCs / lockouts /          (self-contained)
                               expiring passwords
```

## Repo layout

| Path | Purpose |
|---|---|
| `scripts/New-ADUsersFromCsv.ps1` | Bulk-creates OUs + users from CSV; validates input, skips existing accounts, logs errors per row |
| `scripts/Sync-ADGroupMembership.ps1` | Reconciles group membership to a desired-state CSV; adds missing, reports drift, removes only with `-RemoveExtra`; optional `-DriftReportPath` writes an HTML drift report (v2) |
| `scripts/Get-StaleADAccounts.ps1` | Read-only audit: disabled / never-logged-on / inactive / password-expired accounts → CSV |
| `scripts/Get-GPOInventory.ps1` | Read-only audit: every GPO with its links and enabled state → CSV |
| `scripts/Get-ADHealthReport.ps1` | (v2) Read-only AD health snapshot: DC reachability, replication, FSMO, stale computers, lockouts, expiring passwords → console + self-contained HTML |
| `templates/users.csv.example` | Example user input (fictional `contoso.example` data) |
| `templates/groups.csv.example` | Example desired group membership |
| `docs/architecture.md` | Design decisions: idempotency, OU design, naming, why the AD module over raw LDAP |
| `docs/runbook.md` | Prerequisites (RSAT, delegated account) and the -WhatIf-first workflow |

## Quick start

```powershell
# Prerequisites: RSAT AD DS + Group Policy tools, a target DC, delegated account
# (full details in docs/runbook.md)

# 1. ALWAYS dry-run first — creates nothing, reports WouldCreate per row
$pw = Read-Host 'Temporary password for new accounts' -AsSecureString
.\scripts\New-ADUsersFromCsv.ps1 -CsvPath .\templates\users.csv.example `
    -InitialPassword $pw -WhatIf

# 2. Real run, then re-run it — existing accounts must report "Skipped"
.\scripts\New-ADUsersFromCsv.ps1 -CsvPath .\templates\users.csv.example `
    -InitialPassword $pw

# 3. Group membership: dry run, then real run (drift is report-only by default)
.\scripts\Sync-ADGroupMembership.ps1 -CsvPath .\templates\groups.csv.example -WhatIf
.\scripts\Sync-ADGroupMembership.ps1 -CsvPath .\templates\groups.csv.example

# 4. Read-only audits (no credentials, no changes)
.\scripts\Get-StaleADAccounts.ps1 -DaysInactive 90
.\scripts\Get-GPOInventory.ps1

# 5. v2: read-only health snapshot (console summary + HTML report)
.\scripts\Get-ADHealthReport.ps1

# 6. v2: group sync + HTML drift report (written only when drift is found)
.\scripts\Sync-ADGroupMembership.ps1 -CsvPath .\templates\groups.csv.example `
    -DriftReportPath .\reports
```

## Security notes

- **Least privilege:** run the write scripts as a delegated service account
  that can create users / modify membership only under the target OUs —
  never Domain Admin (delegation steps are in `docs/runbook.md`).
- **`-WhatIf` first, always:** both write scripts implement `ShouldProcess`;
  the report shows `WouldCreate` / `WouldAdd` / `WouldRemove` rows before
  anything changes.
- **No plaintext credentials:** the initial password is a mandatory
  `SecureString` parameter entered at a prompt; it is never in a script, a
  CSV, or this repo. New accounts get `ChangePasswordAtLogon`.
- **Nothing real in the repo:** every name, UPN, and DN is fictional
  `contoso.example` data. Real CSV inputs and all generated logs/reports
  are git-ignored (see `.gitignore`).
- **Removal is opt-in:** group sync reports extra members as drift and only
  removes them when `-RemoveExtra` is passed explicitly.

## v2 — health snapshot and HTML drift reports

v2 builds on the v1 scripts without changing their safe-by-default
behavior (the v1 validation notes below still stand):

- **`scripts/Get-ADHealthReport.ps1` (new)** — a read-only AD health
  snapshot in one run:
  - every domain controller, plus whether it answers a ping,
  - replication partner status read through the AD module's own
    replication cmdlets (`Get-ADReplicationPartnerMetadata`) — the script
    never shells out to `repadmin.exe` or parses its text output,
  - the five FSMO role holders,
  - stale computer accounts (machine password older than
    `-StaleComputerDays`, default 90, or never set),
  - locked-out user accounts,
  - user passwords already expired or expiring within
    `-PasswordExpiryDays` (default 14).
  It prints a console summary and writes a self-contained HTML report
  (inline CSS, no external assets, HTML-escaped values) to
  `reports\ad-health-<timestamp>.html`.
- **`scripts/Sync-ADGroupMembership.ps1` (enhanced)** — new optional
  `-DriftReportPath` folder parameter. When drift is found, it writes
  `group-sync-drift-<timestamp>.html` with **Added** /
  **Removed-or-drifted** / **No-change** tables (plus an errors table when
  a group is missing or a member cannot be added). No drift → no HTML
  file. Writing goes through `Out-File`, so a `-WhatIf` dry run reports
  the write instead of performing it, exactly like the CSV report.
  `-RemoveExtra` stays strictly opt-in and `SupportsShouldProcess` is
  unchanged.

## Testing

Checked with PowerShell 7.4.6 and PSScriptAnalyzer 1.25.0:

- All five scripts parse with zero errors and have **0 PSScriptAnalyzer
  findings**, with no suppressions. Earlier findings were fixed in the code: a
  missing BOM caused by non-ASCII characters in comments, and `ShouldProcess`
  warnings on the HTML helper functions (renamed from `New-*` to `Get-*`).
- Both CSV templates load with `Import-Csv` (5 users, 5 groups).
- Without the `ActiveDirectory` and `GroupPolicy` modules, every script stops at
  its module check with a clear "install RSAT" message and changes nothing.
- The HTML reports were tested with mocked AD cmdlets and fake
  `contoso.example` data. The health report produces all seven sections; the
  group sync writes a drift report next to its CSV, skips it when there's no
  drift, and removes nothing unless you pass `-RemoveExtra`.
- That mock testing caught two real bugs: a `$null` `PasswordLastSet` failed to
  convert to `[datetime]` (fixed with a nullable parameter), and the drift
  report ignored `-WhatIf` because .NET `WriteAllText` doesn't honor it
  (switched to `Out-File`).
- Not run against a real domain controller yet. Before real use, run each write
  script with `-WhatIf` against a test DC (for example, a Windows Server
  evaluation VM promoted to `contoso.example`) and confirm the report fields,
  following `docs/runbook.md`.
