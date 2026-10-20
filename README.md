# AD PowerShell Automation Lab — Bulk Users, Group Sync & AD Audits

A lab build (fictional `contoso.example` domain, no real users or data) for
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
   FirstName, LastName,        validate UPN / SAM / OU       │  LAB DOMAIN      │
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
```

## Repo layout

| Path | Purpose |
|---|---|
| `scripts/New-ADUsersFromCsv.ps1` | Bulk-creates OUs + users from CSV; validates input, skips existing accounts, logs errors per row |
| `scripts/Sync-ADGroupMembership.ps1` | Reconciles group membership to a desired-state CSV; adds missing, reports drift, removes only with `-RemoveExtra` |
| `scripts/Get-StaleADAccounts.ps1` | Read-only audit: disabled / never-logged-on / inactive / password-expired accounts → CSV |
| `scripts/Get-GPOInventory.ps1` | Read-only audit: every GPO with its links and enabled state → CSV |
| `templates/users.csv.example` | Example user input (fictional `contoso.example` data) |
| `templates/groups.csv.example` | Example desired group membership |
| `docs/architecture.md` | Design decisions: idempotency, OU design, naming, why the AD module over raw LDAP |
| `docs/runbook.md` | Prerequisites (RSAT, delegated account) and the -WhatIf-first workflow |
| `docs/interview-answers.md` | "How did you build this?" — talking points for interviews |

## Quick start

```powershell
# Prerequisites: RSAT AD DS + Group Policy tools, lab DC, delegated account
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

## Validation

Validated in this (Linux) sandbox with PowerShell 7.4.6:

- All four scripts parse with zero errors via the PowerShell engine's own
  parser (`[System.Management.Automation.Language.Parser]::ParseFile`).
- PSScriptAnalyzer 1.25.0: **0 findings** on all four scripts. (First pass
  flagged `PSUseBOMForUnicodeEncodedFile` on two files for non-ASCII em
  dashes in comments; fixed at the source by replacing them with ASCII,
  then re-run clean.)
- Both CSV templates load cleanly with `Import-Csv` (5 user rows, 5 group
  rows, columns as documented).
- The two read-only scripts were executed in the sandbox and correctly
  stop at their module check with a clear "install RSAT" error — the
  `ActiveDirectory` and `GroupPolicy` modules do not exist on Linux, which
  is expected.

Not validated here, by design:

- No script has run against a real domain controller in this environment,
  so `New-ADUser`, OU creation, group changes, and GPO link parsing have
  **not** been executed end-to-end. Before any real use, run each write
  script with `-WhatIf` against a throwaway lab DC (e.g. a Windows Server
  eval VM promoted to `contoso.example`) and verify the reports, per
  `docs/runbook.md`.
