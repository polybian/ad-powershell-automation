<#
.SYNOPSIS
    Reports stale Active Directory accounts (read-only audit).

.DESCRIPTION
    PowerShell script for account hygiene reviews. Queries every user in scope and
    flags accounts that are disabled, have never logged on, have not logged
    on within -DaysInactive days, or have an expired password. This script
    never modifies anything - its only output is a CSV report an admin can
    review before taking action.

.PARAMETER DaysInactive
    Logon staleness threshold in days (default 90).

.PARAMETER SearchBase
    Optional DN to scope the query, e.g. 'OU=Users,DC=contoso,DC=example'.
    Defaults to the whole domain.

.PARAMETER ReportPath
    Folder for the CSV report. Defaults to ..\reports.

.EXAMPLE
    .\Get-StaleADAccounts.ps1 -DaysInactive 90

    Reports accounts with no logon in 90+ days (plus disabled / expired).

.EXAMPLE
    .\Get-StaleADAccounts.ps1 -SearchBase 'OU=Contractors,DC=contoso,DC=example' -DaysInactive 30

.NOTES
    TEST ENVIRONMENT ONLY. Read-only; requires only read access to user objects plus
    the ActiveDirectory RSAT module.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$DaysInactive = 90,

    [Parameter()]
    [string]$SearchBase,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ReportPath = (Join-Path -Path $PSScriptRoot -ChildPath '..\reports')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Import-Module -Name ActiveDirectory -ErrorAction Stop
}
catch {
    throw 'The ActiveDirectory module is required. Install RSAT AD DS tools first. See docs/runbook.md.'
}

$cutoff = (Get-Date).AddDays(-$DaysInactive)
$properties = @('LastLogonDate', 'PasswordLastSet', 'PasswordExpired', 'Enabled', 'whenCreated', 'Description')

$queryParams = @{
    Filter     = '*'
    Properties = $properties
}
if (-not [string]::IsNullOrWhiteSpace($SearchBase)) {
    $queryParams['SearchBase'] = $SearchBase
}

$allUsers = Get-ADUser @queryParams -ErrorAction Stop
Write-Verbose "Scanned $($allUsers.Count) user accounts"

$findings = [System.Collections.Generic.List[pscustomobject]]::new()
foreach ($user in $allUsers) {
    $reasons = [System.Collections.Generic.List[string]]::new()

    if (-not $user.Enabled) {
        $reasons.Add('Disabled')
    }
    if ($null -eq $user.LastLogonDate) {
        $reasons.Add('NeverLoggedOn')
    }
    elseif ($user.LastLogonDate -lt $cutoff) {
        $reasons.Add("NoLogonSinceThreshold($DaysInactive days)")
    }
    if ($user.PasswordExpired) {
        $reasons.Add('PasswordExpired')
    }

    if ($reasons.Count -gt 0) {
        $findings.Add([pscustomobject]@{
                SamAccountName    = $user.SamAccountName
                UserPrincipalName = $user.UserPrincipalName
                DisplayName       = $user.Name
                Enabled           = $user.Enabled
                LastLogonDate     = $user.LastLogonDate
                PasswordLastSet   = $user.PasswordLastSet
                PasswordExpired   = $user.PasswordExpired
                Created           = $user.whenCreated
                DistinguishedName = $user.DistinguishedName
                StaleReasons      = ($reasons -join '; ')
            })
    }
}

$null = New-Item -Path $ReportPath -ItemType Directory -Force
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportCsv = Join-Path -Path $ReportPath -ChildPath "stale-accounts-$stamp.csv"
$findings | Sort-Object SamAccountName | Export-Csv -Path $reportCsv -NoTypeInformation -Encoding UTF8

Write-Output "Scanned $($allUsers.Count) accounts; flagged $($findings.Count) as stale/disabled/expired."
Write-Output "Report: $reportCsv"
