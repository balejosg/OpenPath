# OpenPath compiled Firefox native host: build, health check and manifest.
#
# Phase 5: the classroom AppLocker boundary denies powershell.exe to the
# restricted student, so the native messaging host must be a compiled binary
# under the allowed OpenPath runtime root. The C# source ships as a payload and
# is compiled on the target machine with the in-box .NET Framework compiler;
# the previous cmd/PowerShell host stays registered as the fallback until a
# compiled executable passes a framed ping health check.

function Get-OpenPathNativeHostExecutableName {
    # returns the compiled host executable file name
    return 'OpenPath-NativeHost.exe'
}

function Get-OpenPathNativeHostSourceName {
    return 'OpenPathNativeHost.cs'
}

function Get-OpenPathNativeHostBuildManifestName {
    return 'OpenPath-NativeHost.manifest.json'
}

function Get-OpenPathNativeHostBuildDiagnosticsName {
    return 'OpenPath-NativeHost.build.json'
}

function Get-OpenPathNativeHostCompilerPath {
    <#
    .SYNOPSIS
        Resolves the in-box .NET Framework C# compiler for the running process
        architecture, falling back to the other view.
    #>
    [CmdletBinding()]
    param([string]$WindowsDirectory = $env:WINDIR)

    if ([string]::IsNullOrWhiteSpace($WindowsDirectory)) { $WindowsDirectory = "$env:SystemRoot" }
    if ([string]::IsNullOrWhiteSpace($WindowsDirectory)) { return '' }
    $candidates = if ([IntPtr]::Size -eq 8) {
        @(
            (Join-Path $WindowsDirectory 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
            (Join-Path $WindowsDirectory 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
        )
    }
    else {
        @(
            (Join-Path $WindowsDirectory 'Microsoft.NET\Framework\v4.0.30319\csc.exe'),
            (Join-Path $WindowsDirectory 'Microsoft.NET\Framework64\v4.0.30319\csc.exe')
        )
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return ''
}

function Get-OpenPathNativeHostInstalledSourcePath {
    <#
    .SYNOPSIS
        Locates the installed C# source: the install-tree native-host directory
        first, then the staged copy next to the native host artifacts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OpenPathRoot,
        [Parameter(Mandatory = $true)][string]$NativeRoot
    )

    foreach ($candidate in @(
            (Join-Path $OpenPathRoot ('native-host\' + (Get-OpenPathNativeHostSourceName))),
            (Join-Path $NativeRoot (Get-OpenPathNativeHostSourceName))
        )) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return ''
}

function Get-OpenPathSmartAppControlState {
    <#
    .SYNOPSIS
        Reads the Smart App Control / WDAC state that can block an unsigned
        locally compiled executable.
    .DESCRIPTION
        SAC state comes from
        HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy\VerifiedAndReputablePolicyState
        (0 = off, 1 = enforcement, 2 = evaluation). WDAC activity is approximated
        by the number of active code-integrity policies. Read-only and
        best-effort: unknown states never throw.
    #>
    [CmdletBinding()]
    param()

    $state = [ordered]@{
        State                        = 'unknown'
        VerifiedAndReputableState    = $null
        ActiveIntegrityPolicyCount   = 0
        BlockingUnsignedBinaries     = $false
    }
    if ([System.Environment]::OSVersion.Platform -ne 'Win32NT') { return [pscustomobject]$state }
    try {
        $policyPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
        $policy = Get-ItemProperty -Path $policyPath -ErrorAction SilentlyContinue
        if ($policy -and $null -ne $policy.PSObject.Properties['VerifiedAndReputablePolicyState']) {
            $value = [int]$policy.VerifiedAndReputablePolicyState
            $state.VerifiedAndReputableState = $value
            switch ($value) {
                0 { $state.State = 'off' }
                1 { $state.State = 'enforcement' }
                2 { $state.State = 'evaluation' }
                default { $state.State = 'unknown' }
            }
        }
        else {
            $state.State = 'not-configured'
        }
        $activePolicies = @(Get-ChildItem -LiteralPath "$env:WINDIR\System32\CodeIntegrity\CiPolicies\Active" -Filter '*.cip' -File -ErrorAction SilentlyContinue)
        $state.ActiveIntegrityPolicyCount = $activePolicies.Count
        $state.BlockingUnsignedBinaries = ($state.State -eq 'enforcement') -or ($state.ActiveIntegrityPolicyCount -gt 0 -and $state.State -ne 'off')
    }
    catch { }
    return [pscustomobject]$state
}

function Get-OpenPathNativeHostSignaturePin {
    <#
    .SYNOPSIS
        Publisher pin for the prebuilt Authenticode-signed native host.
    .DESCRIPTION
        Phase 8: constants only. Empty until Phase 8.1 activates the SignPath
        Foundation signing channel; an empty pin fails closed, so a prebuilt
        executable is never trusted before the publisher identity is known.
        Subject/Issuer are the certificate values the submission must present.
        Description is the authenticated SpcSpOpusInfo program description when
        the pin declares one (SignPath Foundation signs many projects, so the
        subject alone does not identify OpenPath).
    #>
    [CmdletBinding()]
    param()

    return [ordered]@{
        Subject     = ''
        Issuer      = ''
        Description = ''
    }
}

function Get-OpenPathNativeHostSignatureProjection {
    <#
    .SYNOPSIS
        Normalizes Get-AuthenticodeSignature for the native host verification.
    .DESCRIPTION
        Read-only. The Description comes from the signature object when the
        platform exposes it; an empty value means the pin cannot rely on it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ExecutablePath)

    $signature = Get-AuthenticodeSignature -LiteralPath $ExecutablePath -ErrorAction Stop
    $subject = ''
    $issuer = ''
    $thumbprint = ''
    if ($signature.SignerCertificate) {
        $subject = [string]$signature.SignerCertificate.Subject
        $issuer = [string]$signature.SignerCertificate.Issuer
        $thumbprint = [string]$signature.SignerCertificate.Thumbprint
    }
    $description = ''
    if ($signature.PSObject.Properties['Description']) { $description = [string]$signature.Description }
    return [ordered]@{
        Status        = [string]$signature.Status
        StatusMessage = [string]$signature.StatusMessage
        Subject       = $subject
        Issuer        = $issuer
        Thumbprint    = $thumbprint
        Timestamped   = ($null -ne $signature.TimeStamperCertificate)
        Description   = $description
    }
}

function Find-OpenPathNativeHostSignedCandidate {
    <#
    .SYNOPSIS
        Locates the staged signed native host and its anchor hash.
    .DESCRIPTION
        Phase 8: the offline template and the scripts zip stage
        native-host\signed\OpenPath-NativeHost.exe next to
        OpenPath-NativeHost.signing.json. The primary anchor is the payload
        manifest entry for that relative path; when the manifest exists without
        the entry the candidate is rejected (an offline install must never
        trust a signed file it did not ship a hash for). Without a payload
        manifest (development checkouts, scripts zip) the staging metadata hash
        anchors the verification.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OpenPathRoot,
        [string]$SourceSha256 = '',
        [string]$PayloadManifestPath = ''
    )

    $candidate = [ordered]@{
        Found          = $false
        ExecutablePath = ''
        MetadataPath   = ''
        ExpectedSha256 = ''
        AnchorSource   = ''
        SourceSha256   = ''
        Reason         = 'signed-candidate-missing'
    }
    $signedRoot = Join-Path $OpenPathRoot 'native-host\signed'
    $executablePath = Join-Path $signedRoot 'OpenPath-NativeHost.exe'
    $metadataPath = Join-Path $signedRoot 'OpenPath-NativeHost.signing.json'
    if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) { return [pscustomobject]$candidate }
    $candidate.Found = $true
    $candidate.ExecutablePath = $executablePath

    $metadataSource = ''
    $metadataHash = ''
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
        $candidate.MetadataPath = $metadataPath
        try {
            $metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
            if ($metadata.PSObject.Properties['sourceSha256']) { $metadataSource = ([string]$metadata.sourceSha256).ToLowerInvariant() }
            if ($metadata.PSObject.Properties['executableSha256']) { $metadataHash = ([string]$metadata.executableSha256).ToLowerInvariant() }
        }
        catch { }
    }
    $candidate.SourceSha256 = $metadataSource
    if ($SourceSha256 -and $metadataSource -and $metadataSource -ne $SourceSha256.ToLowerInvariant()) {
        $candidate.Reason = 'signed-candidate-source-mismatch'
        return [pscustomobject]$candidate
    }

    if (-not $PayloadManifestPath) { $PayloadManifestPath = Join-Path $OpenPathRoot 'payload-manifest.json' }
    if (Test-Path -LiteralPath $PayloadManifestPath -PathType Leaf) {
        $entryHash = ''
        try {
            $manifest = Get-Content -LiteralPath $PayloadManifestPath -Raw | ConvertFrom-Json
            $entry = @($manifest.payloads) |
                Where-Object { $_.path -and (($_.path -replace '\\', '/') -eq 'native-host/signed/OpenPath-NativeHost.exe') } |
                Select-Object -First 1
            if ($entry) { $entryHash = ([string]$entry.sha256).ToLowerInvariant() }
        }
        catch { $entryHash = '' }
        if (-not $entryHash) {
            $candidate.Reason = 'signed-candidate-payload-anchor-missing'
            return [pscustomobject]$candidate
        }
        $candidate.ExpectedSha256 = $entryHash
        $candidate.AnchorSource = 'payload-manifest'
    }
    elseif ($metadataHash) {
        $candidate.ExpectedSha256 = $metadataHash
        $candidate.AnchorSource = 'signing-metadata'
    }
    if (-not $candidate.ExpectedSha256) {
        $candidate.Reason = 'signed-candidate-anchor-missing'
        return [pscustomobject]$candidate
    }
    $candidate.Reason = 'signed-candidate-found'
    return [pscustomobject]$candidate
}

function Test-OpenPathNativeHostSignedExecutable {
    <#
    .SYNOPSIS
        Verifies a staged prebuilt native host against the anchor hash and the
        publisher pin.
    .DESCRIPTION
        Phase 8: the sha256 must equal the anchor hash (payload manifest), the
        Authenticode signature must be Valid with a timestamp and the signer
        subject/issuer must equal the pin; a pinned description must match when
        the signature exposes one. Never runs an executable that does not pass.
        Read-only and best-effort.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ExecutablePath,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [AllowNull()][object]$Pin = $null,
        # Test seam: returns the normalized signature projection for a path.
        [scriptblock]$SignatureReader = $null
    )

    $result = [ordered]@{
        Valid            = $false
        Reason           = ''
        ExecutableSha256 = ''
        Status           = ''
        StatusMessage    = ''
        Subject          = ''
        Issuer           = ''
        Thumbprint       = ''
        Timestamped      = $false
        Description      = ''
    }
    if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
        $result.Reason = 'signed-executable-missing'
        return [pscustomobject]$result
    }
    try {
        $result.ExecutableSha256 = (Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    catch {
        $result.Reason = 'signed-hash-unreadable'
        return [pscustomobject]$result
    }
    if (-not $ExpectedSha256 -or $result.ExecutableSha256 -ne $ExpectedSha256.ToLowerInvariant()) {
        $result.Reason = 'signed-sha256-mismatch'
        return [pscustomobject]$result
    }

    if ($null -eq $Pin) { $Pin = Get-OpenPathNativeHostSignaturePin }
    $pinSubject = [string]$Pin.Subject
    $pinIssuer = [string]$Pin.Issuer
    $pinDescription = [string]$Pin.Description
    if ([string]::IsNullOrWhiteSpace($pinSubject) -or [string]::IsNullOrWhiteSpace($pinIssuer)) {
        $result.Reason = 'signature-pin-not-configured'
        return [pscustomobject]$result
    }

    try {
        if ($SignatureReader) { $signature = & $SignatureReader $ExecutablePath }
        else { $signature = Get-OpenPathNativeHostSignatureProjection -ExecutablePath $ExecutablePath }
    }
    catch {
        $result.Reason = "signature-read-failed: $($_.Exception.Message)"
        return [pscustomobject]$result
    }
    $result.Status = [string]$signature.Status
    $result.StatusMessage = [string]$signature.StatusMessage
    $result.Subject = [string]$signature.Subject
    $result.Issuer = [string]$signature.Issuer
    $result.Thumbprint = [string]$signature.Thumbprint
    $result.Timestamped = [bool]$signature.Timestamped
    $result.Description = [string]$signature.Description

    if ($result.Status -ne 'Valid') {
        $result.Reason = if ($result.StatusMessage) { "signature-invalid: $($result.StatusMessage)" } else { 'signature-invalid' }
        return [pscustomobject]$result
    }
    if (-not $result.Timestamped) {
        $result.Reason = 'signature-not-timestamped'
        return [pscustomobject]$result
    }
    if (-not $result.Subject.Trim().Equals($pinSubject.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
        $result.Reason = 'signature-subject-mismatch'
        return [pscustomobject]$result
    }
    if (-not $result.Issuer.Trim().Equals($pinIssuer.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
        $result.Reason = 'signature-issuer-mismatch'
        return [pscustomobject]$result
    }
    if (-not [string]::IsNullOrWhiteSpace($pinDescription)) {
        if ([string]::IsNullOrWhiteSpace($result.Description)) {
            $result.Reason = 'signature-description-unavailable'
            return [pscustomobject]$result
        }
        if (-not $result.Description.Trim().Equals($pinDescription.Trim(), [System.StringComparison]::OrdinalIgnoreCase)) {
            $result.Reason = 'signature-description-mismatch'
            return [pscustomobject]$result
        }
    }
    $result.Valid = $true
    $result.Reason = 'signature-valid'
    return [pscustomobject]$result
}

function Invoke-OpenPathNativeHostCompilation {
    <#
    .SYNOPSIS
        Compiles the host source to the requested output with csc.exe.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        # Empty when a CompilerInvoker seam replaces the real csc call.
        [AllowEmptyString()][string]$CompilerPath = '',
        # Test seam: replaces the real csc invocation.
        [scriptblock]$CompilerInvoker = $null
    )

    $result = [ordered]@{
        Success  = $false
        ExitCode = -1
        Output   = ''
    }
    if ($CompilerInvoker) {
        try {
            $invoked = & $CompilerInvoker $SourcePath $OutputPath
            $result.ExitCode = if ($null -ne $invoked -and $invoked.PSObject.Properties['ExitCode']) { [int]$invoked.ExitCode } else { 0 }
            $result.Output = if ($null -ne $invoked -and $invoked.PSObject.Properties['Output']) { [string]$invoked.Output } else { '' }
            $result.Success = ($result.ExitCode -eq 0 -and (Test-Path -LiteralPath $OutputPath -PathType Leaf))
            return [pscustomobject]$result
        }
        catch {
            $result.Output = [string]$_
            return [pscustomobject]$result
        }
    }

    try {
        if (-not (Test-Path -LiteralPath $CompilerPath -PathType Leaf)) {
            $result.Output = 'compiler-missing'
            return [pscustomobject]$result
        }
        $arguments = @(
            '/nologo',
            '/target:exe',
            '/optimize+',
            '/r:System.dll',
            ('/out:' + $OutputPath),
            $SourcePath
        )
        $compileOutput = & $CompilerPath @arguments 2>&1 | Out-String
        $result.ExitCode = [int]$LASTEXITCODE
        $result.Output = [string]$compileOutput
        $result.Success = ($result.ExitCode -eq 0 -and (Test-Path -LiteralPath $OutputPath -PathType Leaf))
    }
    catch {
        $result.Output = [string]$_
    }
    return [pscustomobject]$result
}

function Test-OpenPathNativeHostExecutable {
    <#
    .SYNOPSIS
        Framed ping health check: starts the host, sends one ping and requires a
        pong with protocolVersion 2. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ExecutablePath,
        [int]$TimeoutSeconds = 20,
        # Test seam: replaces the process launch.
        [scriptblock]$ProcessInvoker = $null
    )

    $result = [ordered]@{
        Healthy         = $false
        Version         = ''
        ProtocolVersion = 0
        Capabilities    = @()
        ElapsedMs       = -1
        Error           = ''
    }
    if ($ProcessInvoker) {
        try {
            $invoked = & $ProcessInvoker $ExecutablePath
            foreach ($name in @('Healthy', 'Version', 'ProtocolVersion', 'Capabilities', 'ElapsedMs', 'Error')) {
                if ($null -ne $invoked -and $invoked.PSObject.Properties[$name]) { $result[$name] = $invoked.$name }
            }
            return [pscustomobject]$result
        }
        catch {
            $result.Error = [string]$_
            return [pscustomobject]$result
        }
    }

    $process = $null
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
            $result.Error = 'executable-missing'
            return [pscustomobject]$result
        }
        $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $ExecutablePath
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [System.Diagnostics.Process]::Start($startInfo)
        $message = '{"action":"ping","id":"health-1"}'
        $messageBytes = [System.Text.Encoding]::UTF8.GetBytes($message)
        $process.StandardInput.BaseStream.Write([System.BitConverter]::GetBytes([int]$messageBytes.Length), 0, 4)
        $process.StandardInput.BaseStream.Write($messageBytes, 0, $messageBytes.Length)
        $process.StandardInput.BaseStream.Flush()

        $deadline = (Get-Date).AddSeconds([Math]::Max(1, $TimeoutSeconds))
        $lengthBuffer = New-Object byte[] 4
        $read = 0
        while ($read -lt 4 -and (Get-Date) -lt $deadline) {
            $readTask = $process.StandardOutput.BaseStream.ReadAsync($lengthBuffer, $read, 4 - $read)
            if ($readTask.Wait([Math]::Max(1, [int](($deadline - (Get-Date)).TotalMilliseconds))) -and $readTask.Result -gt 0) {
                $read += $readTask.Result
            }
            elseif ((Get-Date) -ge $deadline) { break }
        }
        if ($read -lt 4) {
            $result.Error = 'health-check-timeout'
            return [pscustomobject]$result
        }
        $length = [System.BitConverter]::ToInt32($lengthBuffer, 0)
        if ($length -le 0 -or $length -gt 1MB) {
            $result.Error = 'health-check-length'
            return [pscustomobject]$result
        }
        $payload = New-Object byte[] $length
        $offset = 0
        while ($offset -lt $length -and (Get-Date) -lt $deadline) {
            $readTask = $process.StandardOutput.BaseStream.ReadAsync($payload, $offset, $length - $offset)
            if ($readTask.Wait([Math]::Max(1, [int](($deadline - (Get-Date)).TotalMilliseconds))) -and $readTask.Result -gt 0) {
                $offset += $readTask.Result
            }
            elseif ((Get-Date) -ge $deadline) { break }
        }
        if ($offset -lt $length) {
            $result.Error = 'health-check-body'
            return [pscustomobject]$result
        }
        $response = [System.Text.Encoding]::UTF8.GetString($payload) | ConvertFrom-Json
        $result.Version = [string]$response.version
        $result.ProtocolVersion = if ($response.PSObject.Properties['protocolVersion']) { [int]$response.protocolVersion } else { 0 }
        $result.Capabilities = @(if ($response.PSObject.Properties['capabilities']) { $response.capabilities } else { @() })
        $result.Healthy = ($response.success -eq $true -and [string]$response.message -eq 'pong' -and $result.ProtocolVersion -ge 2)
        if (-not $result.Healthy) { $result.Error = 'health-check-response' }
    }
    catch {
        $result.Error = [string]$_
    }
    finally {
        if ($process) {
            try {
                if (-not $process.HasExited) {
                    $process.StandardInput.Close()
                    if (-not $process.WaitForExit(5000)) {
                        try { $process.Kill($true) }
                        catch { try { $process.Kill() } catch { } }
                    }
                }
            }
            catch { }
            $process.Dispose()
        }
        $stopwatch.Stop()
        $result.ElapsedMs = [int]$stopwatch.ElapsedMilliseconds
    }
    return [pscustomobject]$result
}

function Build-OpenPathFirefoxNativeHostExecutable {
    <#
    .SYNOPSIS
        Compiles the compiled native host when the source changed and swaps it in
        only after a framed ping health check; otherwise keeps the previous host.
    .DESCRIPTION
        Outcomes (never throws):
          - BuildSkipped: source unchanged, executable present and previously
            health-checked.
          - Built: new executable swapped in atomically and health-checked.
          - Fallback: compile/health failed; the previous executable (if any) or
            the cmd/PowerShell host stays registered, with diagnostics on disk.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$NativeRoot,
        [Parameter(Mandatory = $true)][string]$OpenPathRoot,
        [string]$SourcePath = '',
        [string]$PayloadManifestPath = '',
        [switch]$Force,
        # Test seams.
        [scriptblock]$CompilerInvoker = $null,
        [scriptblock]$ProcessInvoker = $null,
        [scriptblock]$SignatureReader = $null,
        # Test seam: overrides the empty-until-Phase-8.1 publisher pin.
        [AllowNull()][object]$SignaturePin = $null,
        [string]$CompilerPath = ''
    )

    $executablePath = Join-Path $NativeRoot (Get-OpenPathNativeHostExecutableName)
    $manifestPath = Join-Path $NativeRoot (Get-OpenPathNativeHostBuildManifestName)
    $diagnosticsPath = Join-Path $NativeRoot (Get-OpenPathNativeHostBuildDiagnosticsName)
    $result = [ordered]@{
        Status          = 'Fallback'
        ExecutablePath  = ''
        ManifestPath    = $manifestPath
        SourcePath      = ''
        SourceSha256    = ''
        ExecutableSha256 = ''
        Health          = $null
        Error           = ''
        BuiltNow        = $false
        # Phase 5.2 D2: a failed attempt backs off for an hour while the source
        # is unchanged; the state fields explain a Fallback without a build.
        BackoffActive   = $false
        NextAttemptAt   = ''
        # Phase 8: which channel produced the installed host ('signed-prebuilt'
        # or 'compiled') and the signature outcome that gated the candidate.
        HostSource      = ''
        Signature       = $null
        SignedCandidatePath = ''
        SignatureRejectedReason = ''
    }
    $writeDiagnostics = {
        param([string]$Status, [string]$Error)
        try {
            $attempts = 1
            $previousAttempts = 0
            if (Test-Path -LiteralPath $diagnosticsPath -PathType Leaf) {
                try {
                    $previousDiagnostics = Get-Content -LiteralPath $diagnosticsPath -Raw -ErrorAction Stop | ConvertFrom-Json
                    if ($previousDiagnostics.PSObject.Properties['attempts']) { $previousAttempts = [int]$previousDiagnostics.attempts }
                }
                catch { }
            }
            $attempts = $previousAttempts + 1
            $attemptedAt = [DateTime]::UtcNow
            $diagnostics = [ordered]@{
                status          = $Status
                error           = $Error
                sourcePath      = $result.SourcePath
                sourceSha256    = $result.SourceSha256
                attempts        = $attempts
                attemptedAt     = $attemptedAt.ToString('o')
                nextAttemptAt   = if ($Status -eq 'Built') { '' } else { $attemptedAt.AddSeconds(3600).ToString('o') }
                smartAppControl = Get-OpenPathSmartAppControlState
                hostSource      = $result.HostSource
                signatureRejectedReason = $result.SignatureRejectedReason
                checkedAt       = $attemptedAt.ToString('o')
            }
            [IO.File]::WriteAllText($diagnosticsPath, ($diagnostics | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        }
        catch { }
    }
    $failedDiagnosticStatuses = @('CompilationFailed', 'HealthCheckFailed', 'SourceMissing', 'Failed')

    try {
        if (-not (Test-Path -LiteralPath $NativeRoot)) { New-Item -ItemType Directory -Path $NativeRoot -Force | Out-Null }
        if ([string]::IsNullOrWhiteSpace($SourcePath)) {
            $SourcePath = Get-OpenPathNativeHostInstalledSourcePath -OpenPathRoot $OpenPathRoot -NativeRoot $NativeRoot
        }
        $result.SourcePath = $SourcePath
        $sourceExists = ($SourcePath -and (Test-Path -LiteralPath $SourcePath -PathType Leaf))
        $sourceHash = ''
        if ($sourceExists) { $sourceHash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToLowerInvariant() }
        $result.SourceSha256 = $sourceHash

        # Phase 8: a valid signed executable for the current source is preferred
        # over compiling; a rejected candidate is recorded and never executed.
        $signedCandidate = Find-OpenPathNativeHostSignedCandidate -OpenPathRoot $OpenPathRoot -SourceSha256 $sourceHash -PayloadManifestPath $PayloadManifestPath
        $signedVerification = $null
        if ($signedCandidate.Found -and $signedCandidate.Reason -eq 'signed-candidate-found') {
            $signedVerification = Test-OpenPathNativeHostSignedExecutable -ExecutablePath $signedCandidate.ExecutablePath -ExpectedSha256 $signedCandidate.ExpectedSha256 -Pin $SignaturePin -SignatureReader $SignatureReader
            $result.Signature = $signedVerification
            $result.SignedCandidatePath = $signedCandidate.ExecutablePath
            if (-not $signedVerification.Valid) { $result.SignatureRejectedReason = $signedVerification.Reason }
        }
        elseif ($signedCandidate.Found) {
            $result.SignatureRejectedReason = $signedCandidate.Reason
        }
        $signedUsable = ($signedVerification -and $signedVerification.Valid)

        $existing = $null
        if ((Test-Path -LiteralPath $manifestPath -PathType Leaf) -and (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
            try { $existing = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $existing = $null }
        }
        if (-not $Force -and $existing -and
            [string]$existing.sourceSha256 -eq $sourceHash -and
            [string]$existing.executableSha256 -eq (Get-FileHash -LiteralPath $executablePath -Algorithm SHA256).Hash.ToLowerInvariant() -and
            [string]$existing.healthStatus -eq 'healthy') {
            # An installed signed host is final; a compiled host is replaced
            # once a valid signed candidate for the same source shows up.
            $existingIsSigned = ([string]$existing.hostSource -eq 'signed-prebuilt')
            if ($existingIsSigned -or -not $signedUsable) {
                $result.Status = 'BuildSkipped'
                $result.ExecutablePath = $executablePath
                $result.ExecutableSha256 = [string]$existing.executableSha256
                $result.HostSource = if ($existingIsSigned) { 'signed-prebuilt' } else { 'compiled' }
                return [pscustomobject]$result
            }
        }

        # Phase 5.2 D2: honour the failure backoff while the source is
        # unchanged (a new source hash clears it), so a broken compiler or a
        # missing payload can never trigger a compile loop. Phase 8: a valid
        # signed candidate bypasses the backoff because no compilation is
        # involved.
        if (-not $Force -and -not $signedUsable -and (Test-Path -LiteralPath $diagnosticsPath -PathType Leaf)) {
            $previousFailure = $null
            try { $previousFailure = Get-Content -LiteralPath $diagnosticsPath -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $previousFailure = $null }
            if ($previousFailure -and ($failedDiagnosticStatuses -contains [string]$previousFailure.status)) {
                $sameSource = ([string]$previousFailure.sourceSha256 -eq $sourceHash)
                $attemptedAt = $null
                try { $attemptedAt = ([datetime]$previousFailure.attemptedAt).ToUniversalTime() } catch { $attemptedAt = $null }
                if ($sameSource -and $attemptedAt -and (((Get-Date).ToUniversalTime() - $attemptedAt).TotalSeconds -lt 3600)) {
                    $result.Error = 'native-host-compile-backoff'
                    $result.BackoffActive = $true
                    $result.NextAttemptAt = $attemptedAt.AddSeconds(3600).ToString('o')
                    if (Test-Path -LiteralPath $executablePath -PathType Leaf) { $result.ExecutablePath = $executablePath }
                    return [pscustomobject]$result
                }
            }
        }

        if ($signedUsable) {
            # Phase 8: install the verified prebuilt with the same atomic swap,
            # temporary copy and SYSTEM health ping as the compiled path.
            $temporaryExecutable = "$executablePath.$([guid]::NewGuid().ToString('N')).tmp"
            try {
                Copy-Item -LiteralPath $signedCandidate.ExecutablePath -Destination $temporaryExecutable -Force
            }
            catch {
                $result.Error = "signed-candidate-copy-failed: $($_.Exception.Message)"
                & $writeDiagnostics 'Failed' $result.Error
                if (Test-Path -LiteralPath $executablePath -PathType Leaf) { $result.ExecutablePath = $executablePath }
                return [pscustomobject]$result
            }
            $health = Test-OpenPathNativeHostExecutable -ExecutablePath $temporaryExecutable -ProcessInvoker $ProcessInvoker
            $result.Health = $health
            if (-not $health.Healthy) {
                $result.Error = if ($health.Error) { [string]$health.Error } else { 'native-host-health-check-failed' }
                Remove-Item -LiteralPath $temporaryExecutable -Force -ErrorAction SilentlyContinue
                & $writeDiagnostics 'HealthCheckFailed' $result.Error
                if (Test-Path -LiteralPath $executablePath -PathType Leaf) { $result.ExecutablePath = $executablePath }
                return [pscustomobject]$result
            }
            Move-Item -LiteralPath $temporaryExecutable -Destination $executablePath -Force
            $executableHash = (Get-FileHash -LiteralPath $executablePath -Algorithm SHA256).Hash.ToLowerInvariant()
            $result.ExecutablePath = $executablePath
            $result.ExecutableSha256 = $executableHash
            $result.BuiltNow = $true
            $result.Status = 'Built'
            $result.HostSource = 'signed-prebuilt'
            $signingMetadata = $null
            if (Test-Path -LiteralPath $signedCandidate.MetadataPath -PathType Leaf) {
                try { $signingMetadata = Get-Content -LiteralPath $signedCandidate.MetadataPath -Raw | ConvertFrom-Json } catch { $signingMetadata = $null }
            }
            $manifest = [ordered]@{
                schemaVersion    = 1
                source           = [IO.Path]::GetFileName($SourcePath)
                sourceSha256     = $sourceHash
                executable       = [IO.Path]::GetFileName($executablePath)
                executableSha256 = $executableHash
                protocolVersion  = [int]$health.ProtocolVersion
                healthStatus     = 'healthy'
                compiledAt       = [DateTime]::UtcNow.ToString('o')
                hostSource       = 'signed-prebuilt'
                signerSubject    = if ($signingMetadata -and $signingMetadata.PSObject.Properties['signerSubject']) { [string]$signingMetadata.signerSubject } else { $signedVerification.Subject }
                signerIssuer     = if ($signingMetadata -and $signingMetadata.PSObject.Properties['signerIssuer']) { [string]$signingMetadata.signerIssuer } else { $signedVerification.Issuer }
                signerThumbprint = if ($signingMetadata -and $signingMetadata.PSObject.Properties['signerThumbprint']) { [string]$signingMetadata.signerThumbprint } else { $signedVerification.Thumbprint }
                timestamped      = [bool]$signedVerification.Timestamped
                anchorSource     = [string]$signedCandidate.AnchorSource
            }
            [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
            & $writeDiagnostics 'Built' ''
            return [pscustomobject]$result
        }

        if (-not $sourceExists) {
            $result.Error = 'native-host-source-missing'
            & $writeDiagnostics 'SourceMissing' $result.Error
            return [pscustomobject]$result
        }

        if ([string]::IsNullOrWhiteSpace($CompilerPath)) { $CompilerPath = Get-OpenPathNativeHostCompilerPath }
        $temporaryExecutable = "$executablePath.$([guid]::NewGuid().ToString('N')).tmp"
        $compilation = Invoke-OpenPathNativeHostCompilation -SourcePath $SourcePath -OutputPath $temporaryExecutable -CompilerPath $CompilerPath -CompilerInvoker $CompilerInvoker
        if (-not $compilation.Success) {
            $result.Error = if ($compilation.Output) { ([string]$compilation.Output).Trim() } else { 'native-host-compilation-failed' }
            Remove-Item -LiteralPath $temporaryExecutable -Force -ErrorAction SilentlyContinue
            & $writeDiagnostics 'CompilationFailed' $result.Error
            if (Test-Path -LiteralPath $executablePath -PathType Leaf) { $result.ExecutablePath = $executablePath }
            return [pscustomobject]$result
        }

        $health = Test-OpenPathNativeHostExecutable -ExecutablePath $temporaryExecutable -ProcessInvoker $ProcessInvoker
        $result.Health = $health
        if (-not $health.Healthy) {
            $result.Error = if ($health.Error) { [string]$health.Error } else { 'native-host-health-check-failed' }
            $sac = Get-OpenPathSmartAppControlState
            if ($sac.State -eq 'enforcement') {
                $result.Error = "$($result.Error) (Smart App Control is enforcing and may block the unsigned compiled host)"
            }
            Remove-Item -LiteralPath $temporaryExecutable -Force -ErrorAction SilentlyContinue
            & $writeDiagnostics 'HealthCheckFailed' $result.Error
            if (Test-Path -LiteralPath $executablePath -PathType Leaf) { $result.ExecutablePath = $executablePath }
            return [pscustomobject]$result
        }

        # Atomic swap: the new executable only replaces the previous one after a
        # successful health check, and the manifest is written after the move.
        Move-Item -LiteralPath $temporaryExecutable -Destination $executablePath -Force
        $executableHash = (Get-FileHash -LiteralPath $executablePath -Algorithm SHA256).Hash.ToLowerInvariant()
        $result.ExecutablePath = $executablePath
        $result.ExecutableSha256 = $executableHash
        $result.BuiltNow = $true
        $result.Status = 'Built'
        $result.HostSource = 'compiled'
        $manifest = [ordered]@{
            schemaVersion    = 1
            source           = [IO.Path]::GetFileName($SourcePath)
            sourceSha256     = $sourceHash
            executable       = [IO.Path]::GetFileName($executablePath)
            executableSha256 = $executableHash
            protocolVersion  = [int]$health.ProtocolVersion
            healthStatus     = 'healthy'
            compiledAt       = [DateTime]::UtcNow.ToString('o')
            hostSource       = 'compiled'
        }
        [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
        & $writeDiagnostics 'Built' ''
        return [pscustomobject]$result
    }
    catch {
        $result.Error = [string]$_
        try { & $writeDiagnostics 'Failed' $result.Error } catch { }
        if (Test-Path -LiteralPath $executablePath -PathType Leaf) { $result.ExecutablePath = $executablePath }
        return [pscustomobject]$result
    }
}

function Get-OpenPathNativeHostLaunchPath {
    <#
    .SYNOPSIS
        Returns the executable the Firefox manifest should point at: the
        health-checked compiled host when present, else the cmd wrapper.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$NativeRoot
    )

    $executablePath = Join-Path $NativeRoot (Get-OpenPathNativeHostExecutableName)
    $manifestPath = Join-Path $NativeRoot (Get-OpenPathNativeHostBuildManifestName)
    if ((Test-Path -LiteralPath $executablePath -PathType Leaf) -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        try {
            $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json
            if ([string]$manifest.healthStatus -eq 'healthy' -and
                [string]$manifest.executableSha256 -eq (Get-FileHash -LiteralPath $executablePath -Algorithm SHA256).Hash.ToLowerInvariant()) {
                return $executablePath
            }
        }
        catch { }
    }
    return (Join-Path $NativeRoot 'OpenPath-NativeHost.cmd')
}

function Remove-OpenPathNativeHostExecutableArtifacts {
    <#
    .SYNOPSIS
        Removes the compiled host, its manifest/diagnostics and any temp files.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$NativeRoot)

    $patterns = @(
        (Get-OpenPathNativeHostExecutableName),
        (Get-OpenPathNativeHostBuildManifestName),
        (Get-OpenPathNativeHostBuildDiagnosticsName)
    )
    foreach ($name in $patterns) {
        Remove-Item -LiteralPath (Join-Path $NativeRoot $name) -Force -ErrorAction SilentlyContinue
    }
    Get-ChildItem -LiteralPath $NativeRoot -Filter ((Get-OpenPathNativeHostExecutableName) + '.*.tmp') -File -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}
