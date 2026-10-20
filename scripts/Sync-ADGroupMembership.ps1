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

.PARAMETER DriftReportPath
    Optional folder for an HTML drift report. When drift is found (members
    added, removed, or reported as extras), a self-contained
    group-sync-drift-<timestamp>.html file is written there with
    Added / Removed-or-drift / No-change tables. When nothing drifted,
    no HTML file is written.

.PARAMETER RemoveExtra
    Also remove members that are in the group but not in the CSV.
    Without this switch, extras are only reported as drift.

.EXAMPLE
    .\Sync-ADGroupMembership.ps1 -CsvPath ..\templates\groups.csv.example -WhatIf

    Shows what would change without changing anything.

.EXAMPLE
    .\Sync-ADGroupMembership.ps1 -CsvPath .\desired-membership.csv -RemoveExtra

    Adds missing members AND removes extras.

.EXAMPLE
    .\Sync-ADGroupMembership.ps1 -CsvPath .\desired-membership.csv -DriftReportPath .\reports

    Same reconciliation, plus a self-contained HTML drift report in
    .\reports when drift is found.

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
    [ValidateNotNullOrEmpty()]
    [string]$DriftReportPath,

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

function Get-LabHtmlTable {
    <#
    .SYNOPSIS
        Renders one HTML table from header names plus row value arrays.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [string[]]$Headers,

        [Parameter()]
        [object[]]$Rows
    )

    $sb = [System.Text.StringBuilder]::new()
    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $encodedTitle = [System.Net.WebUtility]::HtmlEncode($Title)
        $null = $sb.AppendLine("    <h2>$encodedTitle</h2>")
    }
    $null = $sb.AppendLine('    <table>')
    $null = $sb.AppendLine('      <tr>')
    foreach ($header in $Headers) {
        $encodedHeader = [System.Net.WebUtility]::HtmlEncode($header)
        $null = $sb.AppendLine("        <th>$encodedHeader</th>")
    }
    $null = $sb.AppendLine('      </tr>')
    if ($null -ne $Rows) {
        foreach ($row in $Rows) {
            $null = $sb.AppendLine('      <tr>')
            foreach ($cell in $row) {
                $encodedCell = [System.Net.WebUtility]::HtmlEncode([string]$cell)
                $null = $sb.AppendLine("        <td>$encodedCell</td>")
            }
            $null = $sb.AppendLine('      </tr>')
        }
    }
    $null = $sb.AppendLine('    </table>')
    return $sb.ToString()
}

function Get-LabDriftHtml {
    <#
    .SYNOPSIS
        Builds the self-contained HTML drift report for a group sync run.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[pscustomobject]]$SyncReport,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$CsvPath,

        [Parameter()]
        [switch]$RemoveExtra
    )

    $addedRows = [System.Collections.Generic.List[object]]::new()
    $removedRows = [System.Collections.Generic.List[object]]::new()
    $unchangedRows = [System.Collections.Generic.List[object]]::new()
    $issueRows = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in $SyncReport) {
        $row = @($entry.GroupName, $entry.SamAccountName, $entry.Action, $entry.Detail)
        if ($entry.Action -in @('Added', 'WouldAdd')) {
            $addedRows.Add($row)
        }
        elseif ($entry.Action -in @('Removed', 'WouldRemove', 'Drift')) {
            $removedRows.Add($row)
        }
        elseif ($entry.Action -eq 'AlreadyMember') {
            $unchangedRows.Add($row)
        }
        else {
            $issueRows.Add($row)
        }
    }

    $mode = 'report-only (extras kept)'
    if ($RemoveExtra) {
        $mode = 'enforced (-RemoveExtra passed)'
    }
    $generatedAt = Get-Date -Format 'u'
    $encodedCsv = [System.Net.WebUtility]::HtmlEncode($CsvPath)
    $tableHeaders = @('Group', 'Account', 'Action', 'Detail')

    $css = @'
body { font-family: "Segoe UI", Arial, sans-serif; margin: 2em; color: #1a1a1a; }
.banner { background: #fff3cd; border: 1px solid #e0c36a; padding: 0.75em 1em; margin-bottom: 1.5em; }
h1 { margin-bottom: 0.2em; }
h2 { margin-top: 1.5em; border-bottom: 2px solid #2b579a; padding-bottom: 0.2em; }
table { border-collapse: collapse; margin: 0.5em 0 1em 0; min-width: 60%; }
th, td { border: 1px solid #999; padding: 0.4em 0.8em; text-align: left; font-size: 0.9em; }
th { background: #2b579a; color: #ffffff; }
tr:nth-child(even) td { background: #f2f5fa; }
.meta { color: #555; font-size: 0.9em; }
'@

    $body = [System.Text.StringBuilder]::new()
    $null = $body.AppendLine('  <div class="banner"><strong>LAB REPORT</strong> - generated from fictional lab data; contains no production information.</div>')
    $null = $body.AppendLine('  <h1>Group Sync Drift Report</h1>')
    $null = $body.AppendLine("  <p class=`"meta`">Source CSV: $encodedCsv | Generated: $generatedAt | Mode: $mode</p>")
    $null = $body.Append((Get-LabHtmlTable -Title "Added members ($($addedRows.Count))" -Headers $tableHeaders -Rows $addedRows.ToArray()))
    $null = $body.Append((Get-LabHtmlTable -Title "Removed or drifted members ($($removedRows.Count))" -Headers $tableHeaders -Rows $removedRows.ToArray()))
    $null = $body.Append((Get-LabHtmlTable -Title "No change ($($unchangedRows.Count))" -Headers $tableHeaders -Rows $unchangedRows.ToArray()))
    if ($issueRows.Count -gt 0) {
        $null = $body.Append((Get-LabHtmlTable -Title "Errors / missing groups ($($issueRows.Count))" -Headers $tableHeaders -Rows $issueRows.ToArray()))
    }

    $doc = [System.Text.StringBuilder]::new()
    $null = $doc.AppendLine('<!DOCTYPE html>')
    $null = $doc.AppendLine('<html lang="en">')
    $null = $doc.AppendLine('<head>')
    $null = $doc.AppendLine('  <meta charset="utf-8">')
    $null = $doc.AppendLine('  <title>Group Sync Drift Report (Lab)</title>')
    $null = $doc.AppendLine('  <style>')
    $null = $doc.AppendLine($css)
    $null = $doc.AppendLine('  </style>')
    $null = $doc.AppendLine('</head>')
    $null = $doc.AppendLine('<body>')
    $null = $doc.Append($body.ToString())
    $null = $doc.AppendLine('</body>')
    $null = $doc.AppendLine('</html>')
    return $doc.ToString()
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

# ---- Optional HTML drift report (written only when something drifted) ----
$driftActionNames = @('Added', 'WouldAdd', 'Removed', 'WouldRemove', 'Drift')
$issueActionNames = @('Error', 'GroupNotFound')
$driftFound = @($report | Where-Object { $driftActionNames -contains $_.Action }).Count -gt 0
$issuesFound = @($report | Where-Object { $issueActionNames -contains $_.Action }).Count -gt 0

if (-not [string]::IsNullOrWhiteSpace($DriftReportPath) -and ($driftFound -or $issuesFound)) {
    $null = New-Item -Path $DriftReportPath -ItemType Directory -Force
    $driftHtmlPath = Join-Path -Path $DriftReportPath -ChildPath "group-sync-drift-$stamp.html"
    $driftHtml = Get-LabDriftHtml -SyncReport $report -CsvPath $CsvPath -RemoveExtra:$RemoveExtra
    # Out-File (unlike .NET WriteAllText) honors -WhatIf, so a dry run
    # reports instead of writing; utf8NoBOM needs PS 6+, hence the fallback.
    $fileEncoding = 'UTF8'
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $fileEncoding = 'utf8NoBOM'
    }
    $driftHtml | Out-File -FilePath $driftHtmlPath -Encoding $fileEncoding -Force
    Write-Output "Drift HTML report: $driftHtmlPath"
}
elseif (-not [string]::IsNullOrWhiteSpace($DriftReportPath)) {
    Write-Verbose 'No drift found; skipping the HTML drift report.'
}
