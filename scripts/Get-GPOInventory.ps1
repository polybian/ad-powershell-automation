<#
.SYNOPSIS
    Exports a GPO inventory with links and enabled state (read-only audit).

.DESCRIPTION
    PowerShell script for GPO documentation / change review. Enumerates every GPO
    in the domain, resolves where each one is linked (domain, site, or OU),
    and whether each link is enabled or enforced, then writes one row per
    GPO-link to a CSV. Unlinked GPOs get a single row with empty link
    columns. This script never modifies anything.

.PARAMETER ReportPath
    Folder for the CSV report. Defaults to ..\reports.

.EXAMPLE
    .\Get-GPOInventory.ps1

    Writes reports\gpo-inventory-<timestamp>.csv.

.NOTES
    TEST ENVIRONMENT ONLY. Read-only; requires the GroupPolicy module
    (RSAT "Group Policy Management Tools") and read access to GPOs.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ReportPath = (Join-Path -Path $PSScriptRoot -ChildPath '..\reports')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Import-Module -Name GroupPolicy -ErrorAction Stop
}
catch {
    throw 'The GroupPolicy module is required. Install RSAT Group Policy Management Tools first. See docs/runbook.md.'
}

$gpos = Get-GPO -All -ErrorAction Stop
Write-Verbose "Found $($gpos.Count) GPOs"

$inventory = [System.Collections.Generic.List[pscustomobject]]::new()
foreach ($gpo in $gpos) {
    $wmiFilterName = ''
    if ($null -ne $gpo.WmiFilter) {
        $wmiFilterName = $gpo.WmiFilter.Name
    }

    $links = @()
    try {
        [xml]$reportXml = Get-GPOReport -Guid $gpo.Id -ReportType Xml -ErrorAction Stop
        $links = @($reportXml.GPO.LinksTo)
    }
    catch {
        Write-Warning "Could not read links for '$($gpo.DisplayName)': $($_.Exception.Message)"
    }

    if ($links.Count -eq 0) {
        $inventory.Add([pscustomobject]@{
                DisplayName  = $gpo.DisplayName
                Id           = $gpo.Id
                GpoStatus    = $gpo.GpoStatus
                Owner        = $gpo.Owner
                CreatedTime  = $gpo.CreationTime
                ModifiedTime = $gpo.ModificationTime
                WmiFilter    = $wmiFilterName
                LinkTarget   = ''
                LinkEnabled  = ''
                LinkEnforced = ''
            })
        continue
    }

    foreach ($link in $links) {
        $inventory.Add([pscustomobject]@{
                DisplayName  = $gpo.DisplayName
                Id           = $gpo.Id
                GpoStatus    = $gpo.GpoStatus
                Owner        = $gpo.Owner
                CreatedTime  = $gpo.CreationTime
                ModifiedTime = $gpo.ModificationTime
                WmiFilter    = $wmiFilterName
                LinkTarget   = $link.SOMPath
                LinkEnabled  = $link.Enabled
                LinkEnforced = $link.NoOverride
            })
    }
}

$null = New-Item -Path $ReportPath -ItemType Directory -Force
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportCsv = Join-Path -Path $ReportPath -ChildPath "gpo-inventory-$stamp.csv"
$inventory | Sort-Object DisplayName, LinkTarget | Export-Csv -Path $reportCsv -NoTypeInformation -Encoding UTF8

Write-Output "Inventoried $($gpos.Count) GPOs ($($inventory.Count) rows)."
Write-Output "Report: $reportCsv"
