# Runbook — Running the AD Automation Lab Scripts

## Prerequisites

| Requirement | Notes |
|---|---|
| Lab domain controller | Windows Server with AD DS installed and promoted (e.g. `contoso.example`) |
| Management workstation | Windows 10/11 domain-joined, or the DC itself for the lab |
| RSAT: AD DS tools | Provides the `ActiveDirectory` PowerShell module |
| RSAT: Group Policy Management Tools | Provides the `GroupPolicy` module (needed by `Get-GPOInventory.ps1`) |
| PowerShell | 5.1 (built into Windows) or PowerShell 7 on Windows |
| Delegated service account | See below — do **not** run these as Domain Admin |

Install RSAT on Windows 11 (elevated PowerShell):

```powershell
Get-WindowsCapability -Online -Name 'Rsat.ActiveDirectory*' |
    Add-WindowsCapability -Online

Get-WindowsCapability -Online -Name 'Rsat.GroupPolicy*' |
    Add-WindowsCapability -Online
```

Verify the modules are present:

```powershell
Get-Module -ListAvailable ActiveDirectory, GroupPolicy
```

## The delegated account

Create a normal user (e.g. `svc-ad-automation`) and delegate only what the
scripts need, only where they need it:

1. In **Active Directory Users and Computers**, right-click the target
   parent OU (e.g. `OU=Users`) → **Delegate Control**.
2. Add the service account; grant **Create, delete, and manage user
   accounts** scoped to that OU.
3. For group sync, grant **Modify the membership of a group** on the
   specific groups in scope.
4. For the two audit scripts (`Get-*`), no delegation is needed — ordinary
   read access is enough.

Log on (or use `Enter-PSSession`) as that account to run the write scripts.

## Always test with -WhatIf first

This is step one, not a suggestion. Both write scripts implement
`ShouldProcess`, so a dry run shows exactly what would happen.

```powershell
# 1. Dry run: creates nothing, reports WouldCreate per row
$pw = Read-Host 'Temporary password for new accounts' -AsSecureString
.\scripts\New-ADUsersFromCsv.ps1 `
    -CsvPath .\templates\users.csv.example `
    -InitialPassword $pw -WhatIf

# 2. Read logs\new-users-<timestamp>.csv — every row should say WouldCreate

# 3. Real run (same command, without -WhatIf)
.\scripts\New-ADUsersFromCsv.ps1 `
    -CsvPath .\templates\users.csv.example `
    -InitialPassword $pw

# 4. Re-run the same command — existing accounts must report Skipped
#    (this is the idempotency check)
```

Group membership follows the same pattern:

```powershell
.\scripts\Sync-ADGroupMembership.ps1 -CsvPath .\templates\groups.csv.example -WhatIf
.\scripts\Sync-ADGroupMembership.ps1 -CsvPath .\templates\groups.csv.example
# Add -RemoveExtra only after you have read the drift report from a prior run
```

## Running the read-only audits

```powershell
.\scripts\Get-StaleADAccounts.ps1 -DaysInactive 90
.\scripts\Get-GPOInventory.ps1
# Reports land in .\reports\ with a timestamp in the file name
```

## Input files

- `templates\users.csv.example` — columns: `FirstName, LastName,
  SamAccountName, UserPrincipalName, OU, Department, Title, Manager`.
  Copy it, rename to `*.csv`, and replace with your lab data. Real CSVs are
  git-ignored (see `.gitignore`); only `.example` templates are committed.
- `templates\groups.csv.example` — columns: `GroupName, SamAccountName`,
  one row per desired membership.

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| "The ActiveDirectory module is required" | RSAT AD DS tools not installed — see Prerequisites |
| Rows fail with "Invalid sAMAccountName" | Over 20 chars or characters outside `a-z 0-9 . _ -` |
| Rows fail the UPN check | UPN does not end with `-DomainSuffix` (default `contoso.example`) |
| "Insufficient access rights" | The delegated account lacks rights on that OU — re-check Delegation of Control |
| Everything reports `Skipped` | Working as designed: the accounts already exist (idempotency) |
