<#
.SYNOPSIS
    Creates Active Directory OUs and user accounts in bulk from a CSV file.

.DESCRIPTION
    PowerShell script for onboarding-style provisioning. Reads one row per user from
    a CSV file, creates any missing OUs (parents first), then creates each
    account with New-ADUser. The script is idempotent: existing OUs and
    existing accounts are skipped, so re-running the same CSV is safe.

    Supports -WhatIf / -Confirm through ShouldProcess - always do a
    -WhatIf dry run before touching a real domain.

.PARAMETER CsvPath
    Path to the input CSV. Required columns:
    FirstName, LastName, SamAccountName, UserPrincipalName, OU, Department, Title.
    Optional column: Manager (sAMAccountName of the manager).

.PARAMETER DomainSuffix
    UPN suffix that every UserPrincipalName must end with
    (default 'contoso.example'). Used to validate input and to derive the
    default base DN when -BaseDN is not given.

.PARAMETER BaseDN
    Distinguished name of the domain root, e.g. 'DC=contoso,DC=example'.
    Derived from -DomainSuffix when omitted.

.PARAMETER InitialPassword
    Temporary password (SecureString) assigned to every new account.
    Accounts are created with ChangePasswordAtLogon enabled.

.PARAMETER LogPath
    Folder where the per-run result CSV and error log are written.
    Defaults to ..\logs relative to this script.

.EXAMPLE
    .\New-ADUsersFromCsv.ps1 -CsvPath ..\templates\users.csv.example -WhatIf

    Dry run: shows every OU and account that WOULD be created, changes nothing.

.EXAMPLE
    $pw = Read-Host 'Temp password' -AsSecureString
    .\New-ADUsersFromCsv.ps1 -CsvPath .\new-hires.csv -InitialPassword $pw

    Real run against the target domain.

.NOTES
    TEST ENVIRONMENT ONLY. Requires the ActiveDirectory RSAT module and an account with
    delegated rights to create OUs/users under the target OUs.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$DomainSuffix = 'contoso.example',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$BaseDN,

    [Parameter(Mandatory = $true)]
    [securestring]$InitialPassword,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LogPath = (Join-Path -Path $PSScriptRoot -ChildPath '..\logs')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-DemoOrganizationalUnitPath {
    <#
    .SYNOPSIS
        Creates an OU and any missing parents, leaf-first safe.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DistinguishedName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$DomainBaseDN
    )

    # Already there (or not an OU path at all) -> nothing to do.
    $existing = Get-ADOrganizationalUnit -Identity $DistinguishedName -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Write-Verbose "OU already exists: $DistinguishedName"
        return
    }

    if ($DistinguishedName -eq $DomainBaseDN) {
        return # Reached the domain root; parents above this are out of scope.
    }

    # Ensure the parent exists before creating the child.
    $parentDN = $DistinguishedName -replace '^OU=[^,]+,', ''
    if ($parentDN -ne $DomainBaseDN) {
        New-DemoOrganizationalUnitPath -DistinguishedName $parentDN -DomainBaseDN $DomainBaseDN
    }

    if ($DistinguishedName -match '^OU=([^,]+),') {
        $ouName = $Matches[1]
        if ($PSCmdlet.ShouldProcess($DistinguishedName, 'Create organizational unit')) {
            New-ADOrganizationalUnit -Name $ouName -Path $parentDN -ProtectedFromAccidentalDeletion $true
            Write-Verbose "Created OU: $DistinguishedName"
        }
    }
    else {
        throw "OU value is not a valid OU distinguished name: $DistinguishedName"
    }
}

try {
    Import-Module -Name ActiveDirectory -ErrorAction Stop
}
catch {
    throw 'The ActiveDirectory module is required. Install RSAT AD DS tools first. See docs/runbook.md.'
}

if ([string]::IsNullOrWhiteSpace($BaseDN)) {
    $BaseDN = (($DomainSuffix -split '\.') | ForEach-Object { "DC=$_" }) -join ','
    Write-Verbose "Derived BaseDN: $BaseDN"
}

$requiredColumns = @('FirstName', 'LastName', 'SamAccountName', 'UserPrincipalName', 'OU', 'Department', 'Title')
$rows = Import-Csv -Path $CsvPath
if ($rows.Count -eq 0) {
    throw "CSV has no data rows: $CsvPath"
}
$csvColumns = $rows[0].PSObject.Properties.Name
foreach ($column in $requiredColumns) {
    if ($csvColumns -notcontains $column) {
        throw "CSV is missing required column: $column"
    }
}

$null = New-Item -Path $LogPath -ItemType Directory -Force
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$resultCsv = Join-Path -Path $LogPath -ChildPath "new-users-$stamp.csv"
$errorLog = Join-Path -Path $LogPath -ChildPath "new-users-$stamp.errors.log"

$results = [System.Collections.Generic.List[pscustomobject]]::new()
$created = 0
$skipped = 0
$failed = 0

foreach ($row in $rows) {
    $sam = $row.SamAccountName.Trim()
    $upn = $row.UserPrincipalName.Trim()
    $ouDN = $row.OU.Trim()
    $status = ''
    $detail = ''

    try {
        # ---- Input validation (fail fast, before touching AD) ----
        if ([string]::IsNullOrWhiteSpace($sam) -or $sam -notmatch '^[a-zA-Z0-9._-]{1,20}$') {
            throw "Invalid sAMAccountName: '$sam'"
        }
        if ([string]::IsNullOrWhiteSpace($upn) -or -not $upn.EndsWith("@$DomainSuffix", [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "UserPrincipalName '$upn' must end with '@$DomainSuffix'"
        }
        if ($ouDN -notlike "*, $BaseDN" -and $ouDN -ne $BaseDN -and -not $ouDN.EndsWith(",$BaseDN")) {
            throw "OU '$ouDN' is outside the target base DN '$BaseDN'"
        }

        # ---- Idempotency: skip accounts that already exist ----
        $alreadyThere = Get-ADUser -Identity $sam -ErrorAction SilentlyContinue
        if ($null -ne $alreadyThere) {
            $status = 'Skipped'
            $detail = 'Account already exists'
            $skipped++
            Write-Verbose "Skipping existing account: $sam"
            continue
        }

        # ---- Create the OU chain (parents first), then the user ----
        New-DemoOrganizationalUnitPath -DistinguishedName $ouDN -DomainBaseDN $BaseDN

        $newUserParams = @{
            Name              = "$($row.FirstName.Trim()) $($row.LastName.Trim())"
            GivenName         = $row.FirstName.Trim()
            Surname           = $row.LastName.Trim()
            SamAccountName    = $sam
            UserPrincipalName = $upn
            Path              = $ouDN
            Department        = $row.Department.Trim()
            Title             = $row.Title.Trim()
            Enabled           = $true
            AccountPassword   = $InitialPassword
            ChangePasswordAtLogon = $true
        }
        if ($csvColumns -contains 'Manager' -and -not [string]::IsNullOrWhiteSpace($row.Manager)) {
            $newUserParams['Manager'] = $row.Manager.Trim()
        }

        if ($PSCmdlet.ShouldProcess($sam, "Create AD user in $ouDN")) {
            New-ADUser @newUserParams
            $status = 'Created'
            $detail = "Created in $ouDN"
            $created++
            Write-Verbose "Created account: $sam"
        }
        else {
            $status = 'WouldCreate'
            $detail = 'WhatIf: no changes made'
        }
    }
    catch {
        $status = 'Failed'
        $detail = $_.Exception.Message
        $failed++
        $logLine = "$(Get-Date -Format 'o') [$sam] $detail"
        Add-Content -Path $errorLog -Value $logLine
        Write-Warning "Row failed for '$sam': $detail"
    }
    finally {
        $results.Add([pscustomobject]@{
                SamAccountName    = $sam
                UserPrincipalName = $upn
                OU                = $ouDN
                Status            = $status
                Detail            = $detail
                Timestamp         = (Get-Date -Format 'o')
            })
    }
}

$results | Export-Csv -Path $resultCsv -NoTypeInformation -Encoding UTF8

Write-Output "Done. Created=$created Skipped(existing)=$skipped Failed=$failed"
Write-Output "Per-user results: $resultCsv"
if ($failed -gt 0) {
    Write-Warning "Errors logged to: $errorLog"
}
