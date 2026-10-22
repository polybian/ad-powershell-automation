<#
.SYNOPSIS
    Read-only Active Directory health snapshot with console summary and HTML report.

.DESCRIPTION
    PowerShell script for AD health checks. Collects, without modifying anything:
      - every domain controller and whether it answers a ping,
      - replication partner status from the AD module's own replication
        cmdlets - this script never shells out to repadmin.exe,
      - the five FSMO role holders,
      - stale computer accounts (machine password older than
        -StaleComputerDays),
      - locked-out user accounts,
      - user accounts whose password already expired or expires within
        -PasswordExpiryDays.

    Prints a console summary and writes a self-contained HTML report
    (inline CSS, no external assets) to -ReportPath.

.PARAMETER StaleComputerDays
    Age in days of the computer account password past which a computer is
    considered stale (default 90).

.PARAMETER PasswordExpiryDays
    Look-ahead window in days for passwords about to expire (default 14).

.PARAMETER ReportPath
    Folder for the HTML health report. Defaults to ..\reports.

.EXAMPLE
    .\Get-ADHealthReport.ps1

    Console summary plus reports\ad-health-<timestamp>.html.

.NOTES
    TEST ENVIRONMENT ONLY. Read-only; requires the ActiveDirectory RSAT module and read
    access to the directory (an ordinary domain user is enough).
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$StaleComputerDays = 90,

    [Parameter()]
    [ValidateRange(1, 365)]
    [int]$PasswordExpiryDays = 14,

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

function Get-DemoHtmlTable {
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

function Convert-DemoDateToDisplayString {
    <#
    .SYNOPSIS
        Formats a nullable date for the report, showing (never) when unset.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [System.Nullable[datetime]]$Value
    )

    if ($null -eq $Value) {
        return '(never)'
    }
    return $Value.ToString('u')
}

# ---- Domain and forest context ----
$domain = Get-ADDomain -ErrorAction Stop
$forest = Get-ADForest -ErrorAction Stop

# ---- 1. Domain controllers: inventory plus reachability ----
$domainControllers = @(Get-ADDomainController -Filter * -ErrorAction Stop)
$dcRows = [System.Collections.Generic.List[object]]::new()
$unreachableDcs = [System.Collections.Generic.List[string]]::new()
foreach ($dc in $domainControllers) {
    $reachable = $false
    try {
        $reachable = Test-Connection -ComputerName $dc.HostName -Count 1 -Quiet -ErrorAction Stop
    }
    catch {
        Write-Verbose "Ping failed for '$($dc.HostName)': $($_.Exception.Message)"
    }
    $reachability = 'Unreachable'
    if ($reachable) {
        $reachability = 'Reachable'
    }
    else {
        $unreachableDcs.Add($dc.HostName)
    }
    $dcRows.Add(@(
            $dc.HostName,
            $dc.IPv4Address,
            $dc.Site,
            $dc.OperatingSystem,
            $reachability
        ))
}

# ---- 2. Replication: partner metadata from the AD module itself ----
# Deliberate design choice: replication state is read through
# Get-ADReplicationPartnerMetadata, which returns structured partner
# metadata straight from the directory. This script never invokes
# repadmin.exe and never parses command-line text output.
$replRows = [System.Collections.Generic.List[object]]::new()
$replProblems = [System.Collections.Generic.List[string]]::new()
foreach ($dc in $domainControllers) {
    $partners = @()
    try {
        $partners = @(Get-ADReplicationPartnerMetadata -Target $dc.HostName -Partition '*' -ErrorAction Stop)
    }
    catch {
        $replProblems.Add("$($dc.HostName): replication metadata unreadable ($($_.Exception.Message))")
        Write-Warning "Could not read replication metadata for '$($dc.HostName)'."
        continue
    }
    foreach ($partner in $partners) {
        $linkStatus = 'OK'
        if ($partner.LastReplicationResult -ne 0 -or $partner.ConsecutiveReplicationFailures -gt 0) {
            $linkStatus = 'FAIL'
            $replProblems.Add(
                "$($dc.HostName) <- $($partner.Partner): result $($partner.LastReplicationResult), " +
                "$($partner.ConsecutiveReplicationFailures) consecutive failures"
            )
        }
        $partnerName = $partner.Partner -replace '^CN=([^,]+),.*$', '$1'
        $replRows.Add(@(
                $dc.HostName,
                $partner.Partition,
                $partnerName,
                (Convert-DemoDateToDisplayString -Value $partner.LastReplicationSuccess),
                $partner.LastReplicationResult,
                $partner.ConsecutiveReplicationFailures,
                $linkStatus
            ))
    }
}

# ---- 3. FSMO role holders ----
$fsmoRows = @(
    @('Schema master', $forest.SchemaMaster),
    @('Domain naming master', $forest.DomainNamingMaster),
    @('PDC emulator', $domain.PDCEmulator),
    @('RID master', $domain.RIDMaster),
    @('Infrastructure master', $domain.InfrastructureMaster)
)

# ---- 4. Stale computer accounts ----
# A computer whose machine password has not changed in -StaleComputerDays
# days has almost certainly not talked to the domain in that time.
$computers = @(Get-ADComputer -Filter * -Properties PasswordLastSet, Enabled, OperatingSystem, whenCreated -ErrorAction Stop)
$staleCutoff = (Get-Date).AddDays(-$StaleComputerDays)
$staleComputerRows = [System.Collections.Generic.List[object]]::new()
$staleComputerCount = 0
foreach ($computer in $computers) {
    if ($null -ne $computer.PasswordLastSet -and $computer.PasswordLastSet -ge $staleCutoff) {
        continue
    }
    $staleComputerCount++
    $staleComputerRows.Add(@(
            $computer.SamAccountName,
            $computer.OperatingSystem,
            $computer.Enabled,
            (Convert-DemoDateToDisplayString -Value $computer.PasswordLastSet),
            (Convert-DemoDateToDisplayString -Value $computer.whenCreated)
        ))
}

# ---- 5. Locked-out user accounts ----
$lockedOut = @(Search-ADAccount -LockedOut -UsersOnly -ErrorAction Stop)
$lockedRows = [System.Collections.Generic.List[object]]::new()
foreach ($account in $lockedOut) {
    $lockedRows.Add(@(
            $account.SamAccountName,
            $account.Name,
            $account.Enabled
        ))
}

# ---- 6. Passwords expired or expiring soon ----
# msDS-UserPasswordExpiryTimeComputed is 0 or the int64 max value when the
# password never expires; both are skipped so only real deadlines count.
$neverExpiresSentinel = 9223372036854775807
$expiryDeadline = (Get-Date).AddDays($PasswordExpiryDays)
$expiringRows = [System.Collections.Generic.List[object]]::new()
$expiringUsers = @(Get-ADUser -Filter 'Enabled -eq $true' -Properties 'msDS-UserPasswordExpiryTimeComputed', 'PasswordNeverExpires', 'PasswordExpired' -ErrorAction Stop)
foreach ($user in $expiringUsers) {
    if ($user.PasswordNeverExpires) {
        continue
    }
    $expiryFileTime = [long]$user.'msDS-UserPasswordExpiryTimeComputed'
    if ($expiryFileTime -eq 0 -or $expiryFileTime -eq $neverExpiresSentinel) {
        continue
    }
    $expiryDate = [datetime]::FromFileTime($expiryFileTime)
    $expiryStatus = 'Expiring'
    if ($user.PasswordExpired) {
        $expiryStatus = 'Expired'
    }
    elseif ($expiryDate -gt $expiryDeadline) {
        continue
    }
    $expiringRows.Add(@(
            $user.SamAccountName,
            $user.Name,
            $expiryDate.ToString('u'),
            $expiryStatus
        ))
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$generatedAt = Get-Date -Format 'u'

# ---- Console summary ----
Write-Output 'AD health summary (read-only)'
Write-Output "Domain: $($domain.DNSRoot)   Generated: $generatedAt"
Write-Output "Domain controllers: $($domainControllers.Count) ($($unreachableDcs.Count) unreachable)"
Write-Output "Replication partner links checked: $($replRows.Count) ($($replProblems.Count) with problems)"
Write-Output "Stale computer accounts (password older than $StaleComputerDays days): $staleComputerCount"
Write-Output "Locked-out user accounts: $($lockedOut.Count)"
Write-Output "Passwords expired or expiring within $PasswordExpiryDays days: $($expiringRows.Count)"
foreach ($dcName in $unreachableDcs) {
    Write-Warning "Unreachable domain controller: $dcName"
}
foreach ($problem in $replProblems) {
    Write-Warning "Replication problem: $problem"
}

# ---- HTML report (self-contained: inline CSS, no external assets) ----
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

$summaryRows = @(
    @('Domain controllers', "$($domainControllers.Count) total, $($unreachableDcs.Count) unreachable"),
    @('Replication', "$($replRows.Count) partner links checked, $($replProblems.Count) with problems"),
    @('FSMO roles', '5 roles, holders listed below'),
    @('Stale computer accounts', "$staleComputerCount with machine password older than $StaleComputerDays days"),
    @('Locked-out user accounts', "$($lockedOut.Count)"),
    @('Passwords expiring soon', "$($expiringRows.Count) expired or expiring within $PasswordExpiryDays days")
)

$encodedDomain = [System.Net.WebUtility]::HtmlEncode($domain.DNSRoot)
$body = [System.Text.StringBuilder]::new()
$null = $body.AppendLine('  <div class="banner"><strong>TEST REPORT</strong> - generated from fictional data; contains no production information.</div>')
$null = $body.AppendLine('  <h1>Active Directory Health Report</h1>')
$null = $body.AppendLine("  <p class=`"meta`">Domain: $encodedDomain | Generated: $generatedAt | Stale computer threshold: $StaleComputerDays days | Password expiry window: $PasswordExpiryDays days</p>")
$null = $body.Append((Get-DemoHtmlTable -Title 'Summary' -Headers @('Check', 'Result') -Rows $summaryRows))
$null = $body.Append((Get-DemoHtmlTable -Title 'Domain controllers' -Headers @('Host name', 'IPv4', 'Site', 'Operating system', 'Reachability') -Rows $dcRows.ToArray()))
$null = $body.Append((Get-DemoHtmlTable -Title 'Replication partner links' -Headers @('Target DC', 'Partition', 'Partner', 'Last success (UTC)', 'Last result', 'Consecutive failures', 'Status') -Rows $replRows.ToArray()))
$null = $body.Append((Get-DemoHtmlTable -Title 'FSMO role holders' -Headers @('Role', 'Holder') -Rows $fsmoRows))
$null = $body.Append((Get-DemoHtmlTable -Title "Stale computer accounts ($staleComputerCount)" -Headers @('Account', 'Operating system', 'Enabled', 'Password last set (UTC)', 'Created (UTC)') -Rows $staleComputerRows.ToArray()))
$null = $body.Append((Get-DemoHtmlTable -Title "Locked-out user accounts ($($lockedOut.Count))" -Headers @('sAMAccountName', 'Name', 'Enabled') -Rows $lockedRows.ToArray()))
$null = $body.Append((Get-DemoHtmlTable -Title "Passwords expired or expiring within $PasswordExpiryDays days ($($expiringRows.Count))" -Headers @('sAMAccountName', 'Name', 'Expires (UTC)', 'Status') -Rows $expiringRows.ToArray()))

$doc = [System.Text.StringBuilder]::new()
$null = $doc.AppendLine('<!DOCTYPE html>')
$null = $doc.AppendLine('<html lang="en">')
$null = $doc.AppendLine('<head>')
$null = $doc.AppendLine('  <meta charset="utf-8">')
$null = $doc.AppendLine('  <title>AD Health Report</title>')
$null = $doc.AppendLine('  <style>')
$null = $doc.AppendLine($css)
$null = $doc.AppendLine('  </style>')
$null = $doc.AppendLine('</head>')
$null = $doc.AppendLine('<body>')
$null = $doc.Append($body.ToString())
$null = $doc.AppendLine('</body>')
$null = $doc.AppendLine('</html>')

$null = New-Item -Path $ReportPath -ItemType Directory -Force
$htmlPath = Join-Path -Path $ReportPath -ChildPath "ad-health-$stamp.html"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($htmlPath, $doc.ToString(), $utf8NoBom)

Write-Output "HTML report: $htmlPath"
