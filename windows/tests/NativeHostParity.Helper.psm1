# Phase 5 B1: parity harness for the native messaging host.
#
# Builds a fixture native-host root (staged support files + state + whitelist +
# config + overlay), runs a framed request sequence against the PowerShell
# reference host and (when csc.exe is available) against the compiled C# host,
# and compares the parsed responses semantically.
#
# Every request/response goes through the real 4-byte little-endian framing so
# the persistent port, id echo, malformed JSON and oversized frames are covered
# by construction.

function Get-NativeHostParityStagedFiles {
    # returns repo-relative source paths for every staged support file.
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    $scriptFiles = @(
        'windows\scripts\OpenPath-NativeHost.ps1',
        'windows\scripts\OpenPath-NativeHost.cmd',
        'windows\native-host\OpenPathNativeHost.cs'
    )
    $internalFiles = @(
        'CapabilityStorage.ps1',
        'Common.Redaction.ps1',
        'Common.Whitelist.Sections.ps1',
        'Common.Domains.Catalog.ps1',
        'RuntimeDependency.Protocol.ps1',
        'RuntimeDependency.Policy.ps1',
        'RuntimeDependency.Queue.ps1',
        'RuntimeDependency.Overlay.ps1',
        'CaptivePortal.RecoveryTransition.ps1',
        'CaptivePortal.StateFiles.ps1',
        'NativeHost.CaptivePortalRecoveryQueue.ps1',
        'TaskRunner.ps1',
        'NativeHost.State.ps1',
        'NativeHost.Protocol.ps1',
        'NativeHost.Actions.ps1',
        'NativeHost.Actions.Bootstrap.ps1',
        'NativeHost.Actions.Shared.ps1',
        'NativeHost.Actions.RuntimeDependency.ps1',
        'NativeHost.Actions.CaptivePortal.ps1',
        'NativeHost.Actions.MessageDispatch.ps1'
    )
    $paths = @()
    foreach ($relative in $scriptFiles) { $paths += (Join-Path $RepoRoot $relative) }
    foreach ($name in $internalFiles) { $paths += (Join-Path $RepoRoot ('windows\lib\internal\' + $name)) }
    $paths += (Join-Path $RepoRoot 'windows\lib\RequestSetup.State.psm1')
    return $paths
}

function New-NativeHostParityFixture {
    <#
    .SYNOPSIS
        Creates one fixture root with the staged host and deterministic state.
    .DESCRIPTION
        The whole windows/lib tree is staged so the reference host can lazily
        import CaptivePortal.psm1 + Common.psm1 exactly like a production
        install (configured captive-portal domains and protected hosts come from
        the same config the compiled host reads directly).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $native = Join-Path $Root 'browser-extension\firefox\native'
    New-Item -ItemType Directory -Path $native -Force | Out-Null
    foreach ($source in @(Get-NativeHostParityStagedFiles -RepoRoot $RepoRoot)) {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "native-host-parity-source-missing:$source" }
        Copy-Item -LiteralPath $source -Destination (Join-Path $native (Split-Path -Leaf $source)) -Force
    }
    # Production-layout lib tree for the lazy CaptivePortal/Common import.
    $libSource = Join-Path $RepoRoot 'windows\lib'
    $libTarget = Join-Path $Root 'lib'
    Copy-Item -LiteralPath $libSource -Destination $libTarget -Recurse -Force
    $data = Join-Path $Root 'data'
    New-Item -ItemType Directory -Path $data -Force | Out-Null

    $state = [ordered]@{
        machineName             = 'parity-machine'
        whitelistUrl            = 'https://api.parity.invalid/w/tok12345678/whitelist.txt'
        apiUrl                  = 'https://api.parity.invalid'
        requestApiUrl           = 'https://api.parity.invalid'
        classroom               = 'parity-class'
        classroomId             = 'parity-class-id'
        version                 = '9.9.9'
        syncedAt                = '2026-01-01T00:00:00.0000000Z'
        captivePortalDomains    = @('portal.parity.invalid')
        runtimeDependencyDomains = @('exactdep.parity.invalid')
    }
    [IO.File]::WriteAllText((Join-Path $native 'native-state.json'), ($state | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))

    $whitelist = @(
        '## WHITELIST',
        'anchor1.parity.invalid',
        'depwhitelisted.parity.invalid',
        '## BLOCKED-SUBDOMAINS',
        'blocked9.parity.invalid',
        '## BLOCKED-PATHS',
        'anchor1.parity.invalid/blocked',
        '## ALLOWED-PATHS',
        'anchor1.parity.invalid/allowed'
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $native 'whitelist.txt'), $whitelist + "`r`n", [Text.UTF8Encoding]::new($false))

    $config = [ordered]@{
        apiUrl                                     = 'https://api.parity.invalid'
        requestApiUrl                              = 'https://api.parity.invalid'
        whitelistUrl                               = 'https://api.parity.invalid/w/tok12345678/whitelist.txt'
        # The reference reads configured captive-portal domains through the
        # lazily imported CaptivePortal/Common modules; whether that import
        # succeeds is environment-dependent. An empty list keeps both hosts
        # deterministic (the marker drives the recent-success case instead).
        captivePortalDomains                       = @()
        runtimeDependencyPersistentTransportDisabled = $false
        extensionDiagnosticsDisabled               = $false
    }
    [IO.File]::WriteAllText((Join-Path $data 'config.json'), ($config | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))

    $overlay = [ordered]@{
        version           = 1
        generation        = 2
        appliedGeneration = 2
        entries           = @(
            [ordered]@{ dependencyHost = 'overlaydep.parity.invalid'; anchorHost = 'anchor1.parity.invalid'; requestType = 'script'; generation = 1; expiresAt = '2099-01-01T00:00:00.0000000Z' },
            [ordered]@{ dependencyHost = 'pendingdep.parity.invalid'; anchorHost = 'anchor1.parity.invalid'; requestType = 'script'; generation = 3; expiresAt = '2099-01-01T00:00:00.0000000Z' }
        )
    }
    [IO.File]::WriteAllText((Join-Path $data 'runtime-dependency-overlay.json'), ($overlay | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))

    # Ten minutes in the future: outside the freshness window (-30s tolerance),
    # so both hosts deterministically take the non-fresh trigger path.
    $workerState = [ordered]@{ heartbeatEpochMs = [DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeMilliseconds() }
    [IO.File]::WriteAllText((Join-Path $data 'runtime-dependency-worker-state.json'), ($workerState | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))

    foreach ($directory in @('runtime-dependency-queue', 'captive-portal-recovery-queue', 'captive-portal-recovery-result', 'captive-portal-recovery-progress')) {
        New-Item -ItemType Directory -Path (Join-Path $data $directory) -Force | Out-Null
    }

    # Recent active marker: drives the marker signal in check and the
    # RecentSuccess recovery path. Written last so it is inside the 30s window.
    $marker = [ordered]@{
        active         = $true
        mode           = 'limited'
        limitedModeReady = $true
        allowedHosts   = @('portal.parity.invalid')
        expiresAt      = '2099-01-01T00:00:00.0000000Z'
        state          = 'Portal'
    }
    [IO.File]::WriteAllText((Join-Path $data 'captive-portal-active.json'), ($marker | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))

    return [pscustomobject]@{ Root = $Root; Native = $native; Data = $data }
}

function New-NativeHostParitySequence {
    <#
    .SYNOPSIS
        Deterministic request sequence covering every action and error shape.
    #>
    [CmdletBinding()]
    param()

    $cases = @(
        @{ name = 'ping'; message = @{ action = 'ping' } },
        @{ name = 'ping-id-number'; message = @{ action = 'ping'; id = 42 } },
        @{ name = 'ping-id-string'; message = @{ action = 'ping'; id = 'client-7' } },
        @{ name = 'get-hostname'; message = @{ action = 'get-hostname' } },
        @{ name = 'get-machine-token'; message = @{ action = 'get-machine-token' } },
        @{ name = 'get-config'; message = @{ action = 'get-config' } },
        @{ name = 'get-blocked-paths'; message = @{ action = 'get-blocked-paths' } },
        @{ name = 'get-allowed-paths'; message = @{ action = 'get-allowed-paths' } },
        @{ name = 'get-blocked-subdomains'; message = @{ action = 'get-blocked-subdomains' } },
        @{ name = 'get-policy-version'; message = @{ action = 'get-policy-version' } },
        @{ name = 'check'; message = @{ action = 'check'; domains = @('anchor1.parity.invalid', 'depwhitelisted.parity.invalid', 'blocked9.parity.invalid', 'exactdep.parity.invalid', 'portal.parity.invalid', 'unlisted1.parity.invalid') } },
        @{ name = 'update-whitelist-noop'; message = @{ action = 'update-whitelist'; domains = @('depwhitelisted.parity.invalid') } },
        @{ name = 'dependency-invalid-payload'; message = @{ action = 'allow-local-runtime-dependency'; anchorHost = 'anchor1.parity.invalid' } },
        @{ name = 'dependency-same-host'; message = @{ action = 'allow-local-runtime-dependency'; anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'anchor1.parity.invalid'; requestType = 'script' } },
        @{ name = 'dependency-anchor-not-whitelisted'; message = @{ action = 'allow-local-runtime-dependency'; anchorHost = 'unlisted1.parity.invalid'; dependencyHost = 'dep2.parity.invalid'; requestType = 'script' } },
        @{ name = 'dependency-protected'; message = @{ action = 'allow-local-runtime-dependency'; anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'login.microsoftonline.com'; requestType = 'script' } },
        @{ name = 'dependency-blocked'; message = @{ action = 'allow-local-runtime-dependency'; anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'blocked9.parity.invalid'; requestType = 'script' } },
        @{ name = 'dependency-already-whitelisted'; message = @{ action = 'allow-local-runtime-dependency'; anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'depwhitelisted.parity.invalid'; requestType = 'script' } },
        @{ name = 'dependency-overlay-ready'; message = @{ action = 'allow-local-runtime-dependency'; anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'overlaydep.parity.invalid'; requestType = 'script' } },
        @{ name = 'dependency-overlay-pending'; message = @{ action = 'allow-local-runtime-dependency'; anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'pendingdep.parity.invalid'; requestType = 'script' } },
        @{ name = 'dependency-sensitive-field'; message = @{ action = 'allow-local-runtime-dependency'; anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'dep3.parity.invalid'; requestType = 'script'; url = 'https://example.invalid/' } },
        @{ name = 'dependency-main-frame'; message = @{ action = 'allow-local-runtime-dependency'; anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'dep4.parity.invalid'; requestType = 'main_frame' } },
        @{ name = 'dependency-invalid-mode'; message = @{ action = 'allow-local-runtime-dependency'; anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'dep5.parity.invalid'; requestType = 'script'; mode = 'weird' } },
        @{ name = 'dependency-enqueue-ready'; message = @{ action = 'allow-local-runtime-dependency'; anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'overlaydep.parity.invalid'; requestType = 'script'; mode = 'enqueue' } },
        @{ name = 'dependency-enqueue-pending'; message = @{ action = 'allow-local-runtime-dependency'; anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'newdep1.parity.invalid'; requestType = 'script'; mode = 'enqueue' } },
        @{ name = 'dependency-batch-enqueue'; message = @{ action = 'allow-local-runtime-dependency-batch'; mode = 'enqueue'; entries = @(
                    @{ anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'anchor1.parity.invalid'; requestType = 'script' },
                    @{ anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'depwhitelisted.parity.invalid'; requestType = 'script' },
                    @{ anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'blocked9.parity.invalid'; requestType = 'script' },
                    @{ anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'newdep2.parity.invalid'; requestType = 'script' }
                ) } },
        @{ name = 'dependency-batch-empty'; message = @{ action = 'allow-local-runtime-dependency-batch'; entries = @() } },
        @{ name = 'check-local-single-ready'; message = @{ action = 'check-local-runtime-dependency'; anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'overlaydep.parity.invalid' } },
        @{ name = 'check-local-single-pending'; message = @{ action = 'check-local-runtime-dependency'; anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'pendingdep.parity.invalid' } },
        @{ name = 'check-local-batch'; message = @{ action = 'check-local-runtime-dependency'; entries = @(
                    @{ anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'overlaydep.parity.invalid' },
                    @{ anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'pendingdep.parity.invalid' },
                    @{ anchorHost = 'bad host'; dependencyHost = 'x' }
                ) } },
        @{ name = 'report-extension-diagnostics'; message = @{ action = 'report-extension-diagnostics'; events = @(
                    @{ ts = 1791000000000; kind = 'transport'; tabId = 7; type = 'script'; anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'overlaydep.parity.invalid'; outcome = 'released'; ms = 12.3456; committed = $true },
                    @{ ts = 1791000000001; kind = 'reload-decision'; reason = 'reloaded'; url = 'https://example.invalid/private' },
                    @{ ts = 1791000000002; kind = 'unknown-field'; secretField = 'should-drop' },
                    @{ ts = 1791000000003; kind = ('k' * 200) }
                ) } },
        @{ name = 'unknown-action'; message = @{ action = 'not-a-real-action' } },
        @{ name = 'recover-invalid-host'; message = @{ action = 'recover-captive-portal-navigation'; operation = 'open' } },
        @{ name = 'recover-recent-success'; message = @{ action = 'recover-captive-portal-navigation'; operation = 'open'; triggerHost = 'portal.parity.invalid' } }
    )
    return $cases
}

function Get-NativeHostParityMaskedKeys {
    # Response keys whose values legitimately differ between the two hosts or
    # between runs (timings, generated ids, live task scheduler state).
    return @(
        'requestPath', 'queueWriteMs', 'updateTriggerMs', 'updateWaitMs', 'updateElapsedMs',
        'elapsedMs', 'taskState', 'taskLastResult', 'taskLastResultHex', 'taskLastRunTime',
        'taskNextRunTime', 'taskNumberOfMissedRuns', 'taskDiagnosticsError',
        'queuePath', 'resultPath', 'progressPath', 'pendingRequestIds',
        # The two fixture roots are separate directories, so file mtimes differ
        # by construction; presence still must match. expiresAt is opaque to the
        # extension and the PowerShell host stringifies it with the machine
        # culture (DateTime), while the compiled host keeps the ISO-8601 value.
        'mtime', 'expiresAt'
    )
}

function Start-NativeHostParityProcess {
    <#
    .SYNOPSIS
        Starts a host process with framed stdin/stdout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FilePath
    if ($startInfo.PSObject.Properties['ArgumentList']) {
        # .NET Core / PowerShell 7.
        foreach ($argument in $Arguments) { [void]$startInfo.ArgumentList.Add($argument) }
    }
    else {
        # Windows PowerShell 5.1 (.NET Framework): no ArgumentList property.
        # Quote only arguments containing whitespace; fixture paths with spaces
        # are the only reason this needs care.
        $startInfo.Arguments = (@($Arguments | ForEach-Object {
                    $text = [string]$_
                    if ($text -match '\s') { '"' + ($text -replace '"', '\"') + '"' } else { $text }
                }) -join ' ')
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    return [System.Diagnostics.Process]::Start($startInfo)
}

function Write-NativeHostParityFrame {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$Json
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
    $Process.StandardInput.BaseStream.Write([System.BitConverter]::GetBytes([int]$bytes.Length), 0, 4)
    $Process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $Process.StandardInput.BaseStream.Flush()
}

function Read-NativeHostParityFrame {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [int]$TimeoutSeconds = 30
    )
    $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))
    $lengthBuffer = New-Object byte[] 4
    $read = 0
    while ($read -lt 4 -and (Get-Date) -lt $deadline) {
        $remaining = [Math]::Max(1, [int](($deadline - (Get-Date)).TotalMilliseconds))
        $task = $Process.StandardOutput.BaseStream.ReadAsync($lengthBuffer, $read, 4 - $read)
        if ($task.Wait($remaining) -and $task.Result -gt 0) { $read += $task.Result }
        elseif ((Get-Date) -ge $deadline) { break }
    }
    if ($read -lt 4) { return $null }
    $length = [System.BitConverter]::ToInt32($lengthBuffer, 0)
    if ($length -le 0 -or $length -gt 4MB) { return $null }
    $payload = New-Object byte[] $length
    $offset = 0
    while ($offset -lt $length -and (Get-Date) -lt $deadline) {
        $remaining = [Math]::Max(1, [int](($deadline - (Get-Date)).TotalMilliseconds))
        $task = $Process.StandardOutput.BaseStream.ReadAsync($payload, $offset, $length - $offset)
        if ($task.Wait($remaining) -and $task.Result -gt 0) { $offset += $task.Result }
        elseif ((Get-Date) -ge $deadline) { break }
    }
    if ($offset -lt $length) { return $null }
    return ([System.Text.Encoding]::UTF8.GetString($payload) | ConvertFrom-Json)
}

function Invoke-NativeHostParitySession {
    <#
    .SYNOPSIS
        Runs the full sequence against one host and returns parsed responses.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][object[]]$Cases,
        [int]$PerMessageTimeoutSeconds = 30,
        # Case name -> file path: touched right before that case so time-window
        # checks (recent portal success) are deterministic in both sessions.
        [hashtable]$TouchFilesByCase = @{},
        # Case name -> scriptblock run right before that case (e.g. refresh the
        # worker heartbeat so the 10 s freshness window covers the request).
        [hashtable]$BeforeCaseScripts = @{}
    )
    $process = Start-NativeHostParityProcess -FilePath $FilePath -Arguments $Arguments
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $responses = @()
    try {
        foreach ($case in $Cases) {
            if ($BeforeCaseScripts.ContainsKey($case.name)) {
                & $BeforeCaseScripts[$case.name]
            }
            if ($TouchFilesByCase.ContainsKey($case.name)) {
                $touchPath = [string]$TouchFilesByCase[$case.name]
                if (Test-Path -LiteralPath $touchPath) {
                    $touchItem = Get-Item -LiteralPath $touchPath
                    $contents = [IO.File]::ReadAllBytes($touchPath)
                    [IO.File]::WriteAllBytes($touchPath, $contents)
                }
            }
            $json = if ($case.ContainsKey('raw')) { [string]$case.raw } else { ($case.message | ConvertTo-Json -Depth 10 -Compress) }
            Write-NativeHostParityFrame -Process $process -Json $json
            $response = Read-NativeHostParityFrame -Process $process -TimeoutSeconds $PerMessageTimeoutSeconds
            $responses += [pscustomobject]@{ name = $case.name; response = $response }
        }
    }
    finally {
        try { $process.StandardInput.Close() } catch { }
        if (-not $process.WaitForExit(10000)) {
            try { $process.Kill($true) } catch { try { $process.Kill() } catch { } }
        }
        $process.Dispose()
    }
    return $responses
}

function Compare-NativeHostParityValue {
    <#
    .SYNOPSIS
        Returns '' when the two values are equivalent, or a human description.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Reference,
        [AllowNull()][object]$Candidate,
        [string]$Path = '$',
        [string[]]$MaskedKeys = @(),
        # List-shaped response keys where Windows PowerShell 5.1 references
        # serialize an empty collection as '' while the compiled host uses [].
        # The comparator only equates the two when BOTH sides are empty.
        [string[]]$ListFields = @(),
        [string]$KeyName = ''
    )

    if ($KeyName -and $MaskedKeys -contains $KeyName) {
        # Presence must match; the value is allowed to differ.
        return ''
    }
    if ($KeyName -and $ListFields -contains $KeyName) {
        # Windows PowerShell 5.1 renders an empty collection as '' or {} in
        # different code paths; the compiled host always uses []. Only when BOTH
        # sides are empty is the difference structural, not behavioural.
        $referenceListEmpty = ($null -eq $Reference) -or
            ($Reference -is [string] -and [string]$Reference -eq '') -or
            (($Reference -is [System.Collections.IDictionary]) -and $Reference.Count -eq 0) -or
            (($Reference -is [System.Management.Automation.PSCustomObject]) -and @($Reference.PSObject.Properties).Count -eq 0) -or
            (($Reference -is [System.Collections.IEnumerable]) -and -not ($Reference -is [string]) -and @($Reference).Count -eq 0)
        $candidateListEmpty = ($null -eq $Candidate) -or
            ($Candidate -is [string] -and [string]$Candidate -eq '') -or
            (($Candidate -is [System.Collections.IDictionary]) -and $Candidate.Count -eq 0) -or
            (($Candidate -is [System.Management.Automation.PSCustomObject]) -and @($Candidate.PSObject.Properties).Count -eq 0) -or
            (($Candidate -is [System.Collections.IEnumerable]) -and -not ($Candidate -is [string]) -and @($Candidate).Count -eq 0)
        if ($referenceListEmpty -and $candidateListEmpty) { return '' }
    }
    if ($KeyName -eq 'resolved_ip') {
        # DNS answers may differ between the two host runs; require presence.
        return ''
    }
    if ($KeyName -eq 'source') {
        # Path responses echo the fixture path (different roots); constant
        # source values ('firefox-webrequest-local') still must match.
        $referenceText = [string]$Reference
        $candidateText = [string]$Candidate
        $looksLikePath = { param($text) $text -match '^[A-Za-z]:[\\/]' -or $text -match '^/' }
        if ((& $looksLikePath $referenceText) -and (& $looksLikePath $candidateText)) { return '' }
    }
    $referenceNull = $null -eq $Reference
    $candidateNull = $null -eq $Candidate
    if ($referenceNull -and $candidateNull) { return '' }

    # Normalize PowerShell array-unrolling artifacts (documented comparator
    # rule): a single-element array and its element are the same value, and an
    # empty array equals null. Multi-element arrays still compare element-wise.
    $referenceArray = -not $referenceNull -and $Reference -is [System.Collections.IEnumerable] -and -not ($Reference -is [string])
    $candidateArray = -not $candidateNull -and $Candidate -is [System.Collections.IEnumerable] -and -not ($Candidate -is [string])
    if ($referenceArray -and -not $candidateArray -and @($Reference).Count -eq 1) {
        $Reference = @($Reference)[0]
        $referenceArray = $false
        $referenceNull = $null -eq $Reference
    }
    if ($candidateArray -and -not $referenceArray -and @($Candidate).Count -eq 1) {
        $Candidate = @($Candidate)[0]
        $candidateArray = $false
        $candidateNull = $null -eq $Candidate
    }
    $referenceEmpty = $referenceNull -or ($referenceArray -and @($Reference).Count -eq 0)
    $candidateEmpty = $candidateNull -or ($candidateArray -and @($Candidate).Count -eq 0)
    if ($referenceEmpty -and $candidateEmpty) { return '' }
    if ($referenceEmpty -or $candidateEmpty) { return "$Path reference=$Reference candidate=$Candidate" }

    $referenceObject = $Reference -is [System.Management.Automation.PSCustomObject] -or $Reference -is [System.Collections.IDictionary]
    $candidateObject = $Candidate -is [System.Management.Automation.PSCustomObject] -or $Candidate -is [System.Collections.IDictionary]
    if ($referenceObject -and $candidateObject) {
        $referenceKeys = @($Reference.PSObject.Properties | ForEach-Object { $_.Name })
        $candidateKeys = @($Candidate.PSObject.Properties | ForEach-Object { $_.Name })
        $missing = @($referenceKeys | Where-Object { $candidateKeys -notcontains $_ })
        $extra = @($candidateKeys | Where-Object { $referenceKeys -notcontains $_ })
        if ($missing.Count -gt 0 -or $extra.Count -gt 0) {
            # Compact diff: the full key lists exceed the Pester message budget.
            return "$Path key-diff reference-only=[$(($missing | Sort-Object) -join ',')] candidate-only=[$(($extra | Sort-Object) -join ',')]"
        }
        foreach ($key in $referenceKeys) {
            $child = Compare-NativeHostParityValue -Reference $Reference.$key -Candidate $Candidate.$key -Path "$Path.$key" -MaskedKeys $MaskedKeys -ListFields $ListFields -KeyName $key
            if ($child) { return $child }
        }
        return ''
    }
    if ($referenceArray -and $candidateArray) {
        $referenceItems = @($Reference)
        $candidateItems = @($Candidate)
        if ($referenceItems.Count -ne $candidateItems.Count) {
            return "$Path count reference=$($referenceItems.Count) candidate=$($candidateItems.Count)"
        }
        for ($index = 0; $index -lt $referenceItems.Count; $index++) {
            $child = Compare-NativeHostParityValue -Reference $referenceItems[$index] -Candidate $candidateItems[$index] -Path "$Path[$index]" -MaskedKeys $MaskedKeys -ListFields $ListFields
            if ($child) { return $child }
        }
        return ''
    }
    if ($Reference -is [bool] -or $Candidate -is [bool]) {
        if ([bool]$Reference -ne [bool]$Candidate) { return "$Path reference=$Reference candidate=$Candidate" }
        return ''
    }
    $referenceNumber = $Reference -is [int] -or $Reference -is [long] -or $Reference -is [double] -or $Reference -is [decimal]
    $candidateNumber = $Candidate -is [int] -or $Candidate -is [long] -or $Candidate -is [double] -or $Candidate -is [decimal]
    if ($referenceNumber -and $candidateNumber) {
        if ([double]$Reference -ne [double]$Candidate) { return "$Path reference=$Reference candidate=$Candidate" }
        return ''
    }
    if ([string]$Reference -ne [string]$Candidate) {
        return "$Path reference='$Reference' candidate='$Candidate'"
    }
    return ''
}

function Get-NativeHostParityCompiler {
    # returns the in-box csc.exe path on Windows, or '' anywhere else.
    if ($env:OS -ne 'Windows_NT' -and -not $IsWindows) { return '' }
    $windowsDirectory = if ($env:WINDIR) { $env:WINDIR } else { $env:SystemRoot }
    if (-not $windowsDirectory) { return '' }
    foreach ($candidate in @(
            (Join-Path $windowsDirectory 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
            (Join-Path $windowsDirectory 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
        )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return ''
}

function Get-NativeHostParityWindowsPowerShellPath {
    # returns Windows PowerShell 5.1 (the shell every agent scheduled task
    # uses), or '' anywhere else. The producers must run under 5.1: that is
    # what turns `Set-Content -Encoding UTF8` into UTF-8 with a BOM.
    if ($env:OS -ne 'Windows_NT' -and -not $IsWindows) { return '' }
    $windowsDirectory = if ($env:WINDIR) { $env:WINDIR } else { $env:SystemRoot }
    if (-not $windowsDirectory) { return '' }
    $candidate = Join-Path $windowsDirectory 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    return ''
}

function Set-NativeHostParityProducerFiles {
    <#
    .SYNOPSIS
        Generates the parity fixture files with the real agent producers under
        Windows PowerShell 5.1 and returns their metadata.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$AddBomVariants
    )
    $windowsPowerShell = Get-NativeHostParityWindowsPowerShellPath
    if (-not $windowsPowerShell) { throw 'native-host-parity-powershell51-unavailable' }
    $scriptPath = Join-Path $RepoRoot 'windows\tests\NativeHostParity.Producers.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "native-host-parity-producer-script-missing:$scriptPath" }
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-RepoRoot', $RepoRoot, '-Root', $Root)
    if ($AddBomVariants) { $arguments += '-AddBomVariants' }
    $output = (& $windowsPowerShell @arguments 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "native-host-parity-producers-failed: $output" }
    $jsonLine = @($output -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    if (-not $jsonLine) { throw "native-host-parity-producers-no-metadata: $output" }
    return ([string]$jsonLine | ConvertFrom-Json)
}

function Set-NativeHostParityWorkerState {
    <#
    .SYNOPSIS
        Refreshes the fixture worker heartbeat with the real writer under
        Windows PowerShell 5.1 (the freshness window is only 10 s).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $windowsPowerShell = Get-NativeHostParityWindowsPowerShellPath
    if (-not $windowsPowerShell) { throw 'native-host-parity-powershell51-unavailable' }
    $scriptPath = Join-Path $RepoRoot 'windows\tests\NativeHostParity.Producers.ps1'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath, '-RepoRoot', $RepoRoot, '-Root', $Root, '-WorkerOnly')
    $output = (& $windowsPowerShell @arguments 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "native-host-parity-worker-refresh-failed: $output" }
    return
}

function New-NativeHostParityWorkerStateHook {
    <#
    .SYNOPSIS
        Returns a BeforeCaseScripts closure that refreshes the worker state.
    .DESCRIPTION
        Phase 5.3 P1: do not capture `$script:` variables inside GetNewClosure;
        the closure lives in a dynamic module with its own script scope, so it
        only sees copies of local variables. The function parameters below are
        locals and therefore captured correctly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Root
    )
    return ({ Set-NativeHostParityWorkerState -RepoRoot $RepoRoot -Root $Root }).GetNewClosure()
}

function Get-NativeHostParityListFields {
    # Response keys whose empty value may serialize as '' on Windows
    # PowerShell 5.1 references and as []/null on the compiled host. The
    # comparator only equates the two when BOTH sides are empty (never a
    # populated list against '').
    return @(
        'bootstrapHosts', 'allowedHosts', 'redirectHosts', 'resourceHosts',
        'observedRuntimeHosts', 'pendingRuntimeHosts', 'portalRecoveryHosts',
        'configuredCaptivePortalDomains', 'effectiveExactHosts', 'hostPids',
        'results', 'entries', 'domains', 'requestTypes', 'ipAddresses'
    )
}

function New-NativeHostParityProducerSequence {
    <#
    .SYNOPSIS
        Focused request sequence for the producer-encoded fixture.
    .DESCRIPTION
        The base sequence assumes the hand-written fixture (future heartbeat,
        no BOM). This sequence exercises the files the real producers write:
        a ready + pending overlay, a fresh worker state, a queued request, a
        recent captive marker and the whitelist mirror, so the compiled host
        answers exactly like the reference on production encodings.
    #>
    [CmdletBinding()]
    param()
    return @(
        @{ name = 'probe-ping'; message = @{ action = 'ping' } },
        @{ name = 'probe-dependency-overlay-ready'; message = @{ action = 'allow-local-runtime-dependency'; anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'overlaydep.parity.invalid'; requestType = 'script' } },
        @{ name = 'probe-dependency-overlay-pending'; message = @{ action = 'allow-local-runtime-dependency'; anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'pendingdep.parity.invalid'; requestType = 'script' } },
        @{ name = 'probe-check-local-single-ready'; message = @{ action = 'check-local-runtime-dependency'; anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'overlaydep.parity.invalid' } },
        @{ name = 'probe-check-local-single-pending'; message = @{ action = 'check-local-runtime-dependency'; anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'pendingdep.parity.invalid' } },
        @{ name = 'probe-check-local-batch'; message = @{ action = 'check-local-runtime-dependency'; entries = @(
                    @{ anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'overlaydep.parity.invalid' },
                    @{ anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'pendingdep.parity.invalid' }
                ) } },
        @{ name = 'probe-dependency-enqueue-pending'; message = @{ action = 'allow-local-runtime-dependency'; anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'freshdep7.parity.invalid'; requestType = 'script'; mode = 'enqueue' } },
        @{ name = 'probe-dependency-queue-dedup'; message = @{ action = 'allow-local-runtime-dependency'; anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'queueddep.parity.invalid'; requestType = 'script'; mode = 'enqueue' } },
        @{ name = 'probe-dependency-fresh-worker-blocking'; message = @{ action = 'allow-local-runtime-dependency'; anchorHost = 'anchor1.parity.invalid'; dependencyHost = 'freshdep8.parity.invalid'; requestType = 'script' } },
        @{ name = 'probe-check'; message = @{ action = 'check'; domains = @('anchor1.parity.invalid', 'depwhitelisted.parity.invalid', 'blocked9.parity.invalid', 'portal.parity.invalid') } },
        @{ name = 'probe-recover-recent-success'; message = @{ action = 'recover-captive-portal-navigation'; operation = 'open'; triggerHost = 'portal.parity.invalid' } }
    )
}


function Build-NativeHostParityExecutable {
    # compiles the fixture source next to the fixture host; returns the exe path or ''.
    param(
        [Parameter(Mandatory = $true)][string]$NativeRoot,
        [Parameter(Mandatory = $true)][string]$CompilerPath
    )
    $source = Join-Path $NativeRoot 'OpenPathNativeHost.cs'
    $output = Join-Path $NativeRoot 'OpenPath-NativeHost.exe'
    $compileOutput = & $CompilerPath /nologo /target:exe /optimize+ /r:System.dll /out:$output $source 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) {
        Write-Host "parity compile failed: $compileOutput"
        return ''
    }
    return $output
}

function Get-NativeHostParityHostCommand {
    # resolves the interpreter used to run the PowerShell reference host.
    $current = Get-Process -Id $PID
    $path = $current.Path
    return [pscustomobject]@{ FilePath = $path; Arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File') }
}

Export-ModuleMember -Function @(
    'New-NativeHostParityFixture',
    'New-NativeHostParitySequence',
    'New-NativeHostParityProducerSequence',
    'Set-NativeHostParityProducerFiles',
    'Set-NativeHostParityWorkerState',
    'New-NativeHostParityWorkerStateHook',
    'Get-NativeHostParityListFields',
    'Get-NativeHostParityMaskedKeys',
    'Start-NativeHostParityProcess',
    'Write-NativeHostParityFrame',
    'Read-NativeHostParityFrame',
    'Invoke-NativeHostParitySession',
    'Compare-NativeHostParityValue',
    'Get-NativeHostParityCompiler',
    'Get-NativeHostParityWindowsPowerShellPath',
    'Build-NativeHostParityExecutable',
    'Get-NativeHostParityHostCommand',
    'Get-NativeHostParityStagedFiles'
)
