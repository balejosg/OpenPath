# Phase 3A.3 L2: first-visit warm-up verdicts.
#
# Two different things live in the warm-up:
#   * lane preconditions (the fixture served and the managed policy installed
#     the signed extension). A precondition failure is INFRA: without them the
#     measured visit says nothing about the product.
#   * the native host start, which is PRODUCT behaviour under test. It is
#     measured and reported (hostStarted, first `initialization completed`,
#     AppLocker 8004 events for the student) and never aborts the visit.
#
# The module is shared by the in-guest harness (staged next to it) and the
# controller so the contract tests can execute the verdicts without a VM.

function Get-FirstVisitWarmupField {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-FirstVisitPreconditionVerdict {
    <#
    .SYNOPSIS
    Lane preconditions for a measured first visit (INFRA when failed).
    .DESCRIPTION
      - the signed XPI was served on the managed path and fetched;
      - the add-on entry is registered and active after an orderly close;
      - the installed version matches the template's manifest version.
    #>
    [CmdletBinding()]
    param(
        [bool]$XpiFetched = $false,
        [AllowNull()][object]$ExtensionState = $null,
        [string]$ExpectedVersion = ''
    )
    $reasons = New-Object System.Collections.Generic.List[string]
    if (-not $XpiFetched) { $reasons.Add('xpi-not-fetched') }
    if ($ExtensionState -and [bool](Get-FirstVisitWarmupField -InputObject $ExtensionState -Name 'found')) {
        $active = [bool](Get-FirstVisitWarmupField -InputObject $ExtensionState -Name 'active')
        $userDisabled = [bool](Get-FirstVisitWarmupField -InputObject $ExtensionState -Name 'userDisabled')
        $appDisabled = [bool](Get-FirstVisitWarmupField -InputObject $ExtensionState -Name 'appDisabled')
        $version = [string](Get-FirstVisitWarmupField -InputObject $ExtensionState -Name 'version')
        if (-not ($active -and -not $userDisabled -and -not $appDisabled)) {
            $reasons.Add('extension-registered-inactive')
        }
        elseif ($ExpectedVersion -and $version -and ($version -ne $ExpectedVersion)) {
            $reasons.Add("extension-version-mismatch:$version-expected-$ExpectedVersion")
        }
    }
    elseif ($XpiFetched) {
        $reasons.Add('xpi-fetched-not-registered')
    }
    else {
        $reasons.Add('extension-not-registered')
    }
    return [ordered]@{
        status  = if ($reasons.Count -eq 0) { 'passed' } else { 'failed' }
        reasons = @($reasons.ToArray())
    }
}

function Select-FirstVisitAppControlEvidence {
    <#
    .SYNOPSIS
    AppLocker 8004 events that show the native host launcher being blocked.
    .DESCRIPTION
    The wrapper launches Windows PowerShell, so a deny for the restricted group
    shows up as an 8004 for powershell.exe/pwsh.exe. The event text is kept
    literally; the student filter is preferred but the blocked interpreter is
    the decisive fact. Event timestamps are used only when parseable (fail-open
    toward keeping evidence).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Events = $null,
        [string]$StudentUserName = 'alumno',
        [string]$WindowStart = ''
    )
    $window = $null
    if ($WindowStart) {
        try { $window = ([datetime]$WindowStart).ToUniversalTime() } catch { $window = $null }
    }
    # wevtutil /f:text emits one block per event: a Date line, then the
    # description with the prevented file. The date belongs to the block, not
    # to the line that names powershell.exe, so parse per block.
    $blocks = New-Object System.Collections.Generic.List[object]
    $current = $null
    foreach ($line in @(Get-FirstVisitWarmupField -InputObject $Events -Name 'events8004')) {
        $text = [string]$line
        if ($text -match '^\s*Event\[\d+\]:') {
            if ($current) { $blocks.Add($current.ToArray()) | Out-Null }
            $current = New-Object System.Collections.Generic.List[string]
        }
        if ($null -eq $current) { $current = New-Object System.Collections.Generic.List[string] }
        $current.Add($text) | Out-Null
    }
    if ($current) { $blocks.Add($current.ToArray()) | Out-Null }
    $evidence = New-Object System.Collections.Generic.List[object]
    foreach ($block in $blocks.ToArray()) {
        $blockText = (@($block) -join "`n")
        if ($blockText -notmatch '(?i)powershell\.exe|pwsh\.exe') { continue }
        if ($window) {
            $dateMatch = [regex]::Match($blockText, '(?im)^\s*(?:Date|Fecha)\s*:\s*(\S+)')
            if ($dateMatch.Success) {
                try {
                    $eventTime = ([datetime]$dateMatch.Groups[1].Value).ToUniversalTime()
                    # Keep only events from this run's warm-up window (with a
                    # small grace for log-flush jitter).
                    if ($eventTime -lt $window.AddMinutes(-10)) { continue }
                }
                catch { }
            }
        }
        $evidence.Add([ordered]@{
            student = [bool]($blockText -match [regex]::Escape($StudentUserName))
            line    = $blockText
        }) | Out-Null
    }
    return @($evidence.ToArray())
}

function Get-FirstVisitHostSignalsVerdict {
    <#
    .SYNOPSIS
    Product verdict for the native host start (never a lane precondition).
    .DESCRIPTION
    Reasons (both PRODUCT):
      - native-host-blocked-by-appcontrol: the student's launcher interpreter
        was denied by AppLocker (8004 for powershell.exe/pwsh.exe);
      - native-host-not-started: the template ships the per-user native host
        log but no `initialization completed` line appeared.
    A build without the per-user log capability and without deny events yields
    no product reason (the signals are simply not observable).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Live = $null,
        [AllowNull()][object]$Events = $null,
        [AllowNull()][string]$Capabilities = '',
        [string]$StudentUserName = 'alumno',
        [string]$WindowStart = ''
    )
    $hostStarted = [bool](Get-FirstVisitWarmupField -InputObject $Live -Name 'hostStarted')
    $evidence = @(Select-FirstVisitAppControlEvidence -Events $Events -StudentUserName $StudentUserName -WindowStart $WindowStart)
    $blocked = ($evidence.Count -gt 0)
    $hostLogCapable = $false
    $backgroundStartCapable = $false
    $diagnosticBatchCapable = $false
    foreach ($capability in @(([string]$Capabilities) -split ',')) {
        switch ($capability.Trim()) {
            'native-host-log' { $hostLogCapable = $true }
            'background-start' { $backgroundStartCapable = $true }
            'diagnostic-batch' { $diagnosticBatchCapable = $true }
        }
    }
    $productReasons = New-Object System.Collections.Generic.List[string]
    if (-not $hostStarted) {
        if ($blocked) { $productReasons.Add('native-host-blocked-by-appcontrol') }
        elseif ($hostLogCapable) { $productReasons.Add('native-host-not-started') }
    }
    $signals = [ordered]@{
        hostStarted          = $hostStarted
        hostPids             = @(Get-FirstVisitWarmupField -InputObject $Live -Name 'hostPids')
        firstInitLine        = [string](Get-FirstVisitWarmupField -InputObject $Live -Name 'firstInitLine')
        diagnosticLines      = [int](Get-FirstVisitWarmupField -InputObject $Live -Name 'diagnosticLines')
        backgroundStart      = [bool](Get-FirstVisitWarmupField -InputObject $Live -Name 'backgroundStart')
        diagnosticBatchFirst = [bool](Get-FirstVisitWarmupField -InputObject $Live -Name 'diagnosticBatchFirst')
        hostLogCapable       = $hostLogCapable
        backgroundStartCapable = $backgroundStartCapable
        diagnosticBatchCapable = $diagnosticBatchCapable
    }
    return [ordered]@{
        status               = if ($productReasons.Count -eq 0) { 'passed' } else { 'failed' }
        productReasons       = @($productReasons.ToArray())
        blockedByAppControl  = $blocked
        appControlEvidence   = $evidence
        signals              = $signals
    }
}

Export-ModuleMember -Function Get-FirstVisitPreconditionVerdict, Get-FirstVisitHostSignalsVerdict, Select-FirstVisitAppControlEvidence
