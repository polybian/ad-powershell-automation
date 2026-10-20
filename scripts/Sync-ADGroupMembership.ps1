<#
.SYNOPSIS
    Reconciles AD group membership against a desired-state CSV.

.DESCRIPTION
    Lab script for access-review style work. The CSV declares the desired
    state as one row per (GroupName, SamAccountName) pair. For every group
    the script compares desired vs actual membership and:
      - adds members that are missing (with -WhatIf support),
      - REPORTS extra members (drift) but never removes them unless
        -RemoveExtra is explicitly given.

    Safe by default: the destructive action (removal) is opt-in.

.PARAMETER CsvPath
    Path to the input CSV. Required columns: GroupName, SamAccountName.

.PARAMETER ReportPath
    Folder for the reconciliation report CSV. Defaults to ..\logs.

.PARAMETER RemoveExtra
    Also remove members that are in the group but not in the CSV.
    Without this switch, extras are only reported as drift.

.EXAMPLE
    .\Sync-ADGroupMembership.ps1 -CsvPath ..\templates\groups.csv.example -WhatIf

    Shows what would change without changing anything.

.EXAMPLE
    .\Sync-ADGroupMembership.ps1 -CsvPath .\desired-membership.csv -RemoveExtra

    Adds missing members AND removes extras.

.NOTES
    LAB ONLY. Requires the ActiveDirectory RSAT module and an account with
    delegated rights to modify group membership.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ReportPath = (Join-Path -Path $PSScriptRoot -ChildPath '..\logs'),

    [Parameter()]
    [switch]$RemoveExtra
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Import-Module -Name ActiveDirectory -ErrorAction Stop
}
catch {
    throw 'The ActiveDirectory module is required. Install RSAT AD DS tools first. See docs/runbook.md.'
}

$rows = Import-Csv -Path $CsvPath
if ($rows.Count -eq 0) {
    throw "CSV has no data rows: $CsvPath"
}
$csvColumns = $rows[0].PSObject.Properties.Name
foreach ($column in @('GroupName', 'SamAccountName')) {
    if ($csvColumns -notcontains $column) {
        throw "CSV is missing required column: $column"
    }
}

$null = New-Item -Path $ReportPath -ItemType Directory -Force
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportCsv = Join-Path -Path $ReportPath -ChildPath "group-sync-$stamp.csv"

$report = [System.Collections.Generic.List[pscustomobject]]::new()
$added = 0
$removed = 0
$drift = 0
$errors = 0

$groups = $rows | Select-Object -ExpandProperty GroupName -Unique
foreach ($groupName in $groups) {
    $groupName = $groupName.Trim()
    try {
        $group = Get-ADGroup -Identity $groupName -ErrorAction Stop
    }
    catch {
        $errors++
        Write-Warning "Group not found, skipping: $groupName"
        $report.Add([pscustomobject]@{
                GroupName      = $groupName
                SamAccountName = ''
                Action         = 'GroupNotFound'
                Detail         = $_.Exception.Message
                Timestamp      = (Get-Date -Format 'o')
            })
        continue
    }

    $desired = @(
        $rows | Where-Object { $_.GroupName.Trim() -eq $groupName } |
            Select-Object -ExpandProperty SamAccountName |
            ForEach-Object { $_.Trim() } |
            Sort-Object -Unique
    )
    $current = @(
        Get-ADGroupMember -Identity $group.DistinguishedName -ErrorAction Stop |
            Where-Object { $_.objectClass -eq 'user' } |
            ForEach-Object { (Get-ADUser -Identity $_.SamAccountName -ErrorAction Stop).SamAccountName } |
            Sort-Object -Unique
    )

    # ---- Add missing members ----
    $missing = $desired | Where-Object { $current -notcontains $_ }
    foreach ($sam in $missing) {
        try {
            $user = Get-ADUser -Identity $sam -ErrorAction Stop
            if ($PSCmdlet.ShouldProcess("$sam -> $groupName", 'Add group member')) {
                Add-ADGroupMember -Identity $group.DistinguishedName -Members $user.DistinguishedName
                $report.Add([pscustomobject]@{
                        GroupName      = $groupName
                        SamAccountName = $sam
                        Action         = 'Added'
                        Detail         = 'Missing member added'
                        Timestamp      = (Get-Date -Format 'o')
                    })
                $added++
            }
            else {
                $report.Add([pscustomobject]@{
                        GroupName      = $groupName
                        SamAccountName = $sam
                        Action         = 'WouldAdd'
                        Detail         = 'WhatIf: no changes made'
                        Timestamp      = (Get-Date -Format 'o')
                    })
            }
        }
        catch {
            $errors++
            Write-Warning "Could not add '$sam' to '$groupName': $($_.Exception.Message)"
            $report.Add([pscustomobject]@{
                    GroupName      = $groupName
                    SamAccountName = $sam
                    Action         = 'Error'
                    Detail         = $_.Exception.Message
                    Timestamp      = (Get-Date -Format 'o')
                })
        }
    }

    # ---- Report (or remove) extras ----
    $extras = $current | Where-Object { $desired -notcontains $_ }
    foreach ($sam in $extras) {
        $drift++
        if ($RemoveExtra) {
            if ($PSCmdlet.ShouldProcess("$sam -> $groupName", 'Remove group member')) {
                Remove-ADGroupMember -Identity $group.DistinguishedName -Members $sam -Confirm:$false
                $report.Add([pscustomobject]@{
                        GroupName      = $groupName
                        SamAccountName = $sam
                        Action         = 'Removed'
                        Detail         = 'Extra member removed (-RemoveExtra)'
                        Timestamp      = (Get-Date -Format 'o')
                    })
                $removed++
            }
            else {
                $report.Add([pscustomobject]@{
                        GroupName      = $groupName
                        SamAccountName = $sam
                        Action         = 'WouldRemove'
                        Detail         = 'WhatIf: no changes made'
                        Timestamp      = (Get-Date -Format 'o')
                    })
            }
        }
        else {
            Write-Verbose "Drift: '$sam' is in '$groupName' but not in the CSV"
            $report.Add([pscustomobject]@{
                    GroupName      = $groupName
                    SamAccountName = $sam
                    Action         = 'Drift'
                    Detail         = 'In group but not in CSV; use -RemoveExtra to remove'
                    Timestamp      = (Get-Date -Format 'o')
                })
        }
    }

    # ---- Already-correct members, for a complete audit trail ----
    $ok = $desired | Where-Object { $current -contains $_ }
    foreach ($sam in $ok) {
        $report.Add([pscustomobject]@{
                GroupName      = $groupName
                SamAccountName = $sam
                Action         = 'AlreadyMember'
                Detail         = 'No change needed'
                Timestamp      = (Get-Date -Format 'o')
            })
    }
}

$report | Export-Csv -Path $reportCsv -NoTypeInformation -Encoding UTF8

Write-Output "Done. Added=$added Removed=$removed DriftReported=$drift Errors=$errors"
Write-Output "Reconciliation report: $reportCsv"
