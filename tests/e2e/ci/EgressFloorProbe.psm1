Set-StrictMode -Version Latest

# Pure helpers for run-windows-egress-floor-probe.ps1 (Windows egress floor lab
# acceptance). No cmdlet side effects here, so they are unit-tested on any OS.

function ConvertTo-OpenPathEgressProbeObservation {
    <#
    .SYNOPSIS
        Classifies probe output as reachable, unreachable, or unknown.
    .DESCRIPTION
        Http probes print `http=<code>` (curl -w, or the python/MSBuild probes);
        000 means no connection. Ping probes are judged by `TTL=`, which Windows
        prints untranslated in every locale.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Http', 'Ping')][string]$Kind,
        [AllowNull()][AllowEmptyString()][string]$Output
    )

    $text = [string]$Output
    if ($Kind -eq 'Ping') {
        if ($text -match 'TTL=') { return 'reachable' }
        if ($text -match 'exit=\d+') { return 'unreachable' }
        return 'unknown'
    }

    $codes = @([regex]::Matches($text, 'http=(\d{3})') | ForEach-Object { $_.Groups[1].Value })
    if ($codes.Count -eq 0) { return 'unknown' }
    if ($codes[-1] -eq '000') { return 'unreachable' }
    return 'reachable'
}

function Get-OpenPathEgressProbeVerdict {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Blocked', 'Allowed')][string]$Expectation,
        [Parameter(Mandatory = $true)][ValidateSet('reachable', 'unreachable', 'unknown')][string]$Observation
    )

    if ($Observation -eq 'unknown') { return 'unknown' }
    $expected = if ($Expectation -eq 'Blocked') { 'unreachable' } else { 'reachable' }
    if ($Observation -eq $expected) { return 'pass' }
    return 'fail'
}

function Get-OpenPathEgressProbeMissingFixtureStatus {
    [CmdletBinding()]
    param([switch]$RequireFixtures)

    if ($RequireFixtures) { return 'fail' }
    return 'skip'
}

function Get-OpenPathEgressProbeOverallStatus {
    <# fail on any fail/unknown (or no probes); pass-pending-manual when manual rows remain. #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Probes = @())

    $statuses = @($Probes | ForEach-Object { [string]$_.status })
    if ($statuses.Count -eq 0) { return 'fail' }
    if (@($statuses | Where-Object { $_ -eq 'fail' -or $_ -eq 'unknown' }).Count -gt 0) { return 'fail' }
    if ($statuses -contains 'manual') { return 'pass-pending-manual' }
    return 'pass'
}

function New-OpenPathEgressProbeCmdArgument {
    <#
    .SYNOPSIS
        Argument string for `cmd.exe` that runs CommandLine, captures stdout and
        stderr to OutputPath, and appends `exit=<errorlevel>`.
    .DESCRIPTION
        `/s /c "..."` strips only the outer quotes, so quoted paths inside the
        command line survive.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )

    return "/s /c `"$CommandLine > `"$OutputPath`" 2>&1 & echo exit=%errorlevel% >> `"$OutputPath`"`""
}

function Protect-OpenPathEgressProbeText {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [AllowNull()][AllowEmptyCollection()][object[]]$Secrets = @()
    )

    $result = [string]$Text
    foreach ($secret in @($Secrets)) {
        if ([string]::IsNullOrEmpty([string]$secret)) { continue }
        $result = $result.Replace([string]$secret, '<redacted>')
    }
    return $result
}

function Add-OpenPathEgressProbeBatchLogonSid {
    <#
    .SYNOPSIS
        Adds `*<Sid>` to SeBatchLogonRight in `secedit /export` INF lines, so the
        lab student can run the scheduled-task probes. Idempotent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$Sid
    )

    $entry = "*$Sid"
    $result = [System.Collections.Generic.List[string]]::new()
    $found = $false
    foreach ($line in $Lines) {
        if ($line -match '^SeBatchLogonRight\s*=\s*(.*)$') {
            $found = $true
            $members = @($Matches[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($members -notcontains $entry) { $members += $entry }
            $result.Add("SeBatchLogonRight = $($members -join ',')")
            continue
        }
        $result.Add($line)
    }
    if (-not $found) {
        $index = $result.IndexOf('[Privilege Rights]')
        if ($index -lt 0) {
            $result.Add('[Privilege Rights]')
            $index = $result.Count - 1
        }
        $result.Insert($index + 1, "SeBatchLogonRight = $entry")
    }
    return , $result.ToArray()
}

function ConvertFrom-OpenPathEgressProbeAuditCsv {
    <#
        Numeric Setting Value of "Filtering Platform Connection" from `auditpol /backup`
        CSV: row picked by GUID, value read from the LAST field. Headers and names are
        localized (and a name may contain commas); `/get /r` has no numeric column.
    #>
    [CmdletBinding()]
    param([AllowNull()][string[]]$Lines)

    $guid = '{0CCE9226-69AE-11D9-BED3-505054503030}'
    foreach ($line in @($Lines | Select-Object -Skip 1)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $fields = @(([string]$line).Split(','))
        if (@($fields | Where-Object { $_.Trim() -eq $guid }).Count -eq 0) { continue }
        $value = 0
        if ($fields.Count -ge 7 -and [int]::TryParse($fields[-1].Trim(), [ref]$value)) { return $value }
    }
    return $null
}

Export-ModuleMember -Function @(
    'ConvertTo-OpenPathEgressProbeObservation',
    'Get-OpenPathEgressProbeVerdict',
    'Get-OpenPathEgressProbeMissingFixtureStatus',
    'Get-OpenPathEgressProbeOverallStatus',
    'New-OpenPathEgressProbeCmdArgument',
    'Protect-OpenPathEgressProbeText',
    'Add-OpenPathEgressProbeBatchLogonSid',
    'ConvertFrom-OpenPathEgressProbeAuditCsv'
)
