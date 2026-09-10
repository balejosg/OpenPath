# Windows evidence lane for the personalized NSIS executable.
#
# This is intentionally separate from the read-only trailer helper: it launches
# the generated .exe, lets the NSIS runtime extract and validate its payload,
# invokes the existing offline Install-OpenPath.ps1 path, observes pending
# enrollment, and then exercises the existing retry path against a local HTTPS
# enrollment fixture. The runner must be ephemeral or reset after this lane.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ExecutablePath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedClassroomId,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://localhost:\d+$')]
    [string]$ExpectedApiUrl,

    [string]$OpenPathRoot = '',

    [int]$ConnectivityPort = 18443,

    [string]$EvidencePath = ''
)

$ErrorActionPreference = 'Stop'
$script:CurrentStage = 'preflight'
$installExitCode = $null

function Get-AvailablePowerShell {
    $command = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if (-not $command) {
        $command = Get-Command pwsh -ErrorAction SilentlyContinue
    }
    if (-not $command) {
        throw 'powershell-runtime-missing'
    }
    return $command.Source
}

function Write-SafeEvidence {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Payload,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $Payload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Assert-EqualValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Actual,

        [Parameter(Mandatory = $true)]
        [string]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Code
    )

    if ($Actual.TrimEnd('/') -ne $Expected.TrimEnd('/')) {
        throw $Code
    }
}

function Get-SafeInstallerStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 'missing'
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
    }
    catch {
        return 'unreadable'
    }

    if ($bytes.Length -ne 2) {
        return 'invalid'
    }

    $stage = [int]$bytes[0]
    $exitCode = [int]$bytes[1]
    switch ($stage) {
        5 {
            if ($exitCode -eq 1) { return 'native-powershell-context-error' }
            if ($exitCode -eq 2) { return 'native-powershell-missing' }
        }
        10 {
            if ($exitCode -eq 255) { return 'read-trailer-start' }
        }
        11 {
            if ($exitCode -eq 254) { return 'read-trailer-exec-error' }
            if ($exitCode -eq 253) { return 'read-trailer-exec-timeout' }
            return "read-trailer-exit-$exitCode"
        }
        12 {
            if ($exitCode -eq 0) { return 'read-trailer-ok' }
        }
        13 {
            if ($exitCode -eq 0) { return 'read-trailer-output-present' }
        }
        14 {
            if ($exitCode -eq 0) { return 'read-trailer-output-missing' }
        }
        15 {
            if ($exitCode -eq 0) { return 'read-trailer-marker-present' }
        }
        16 {
            if ($exitCode -eq 0) { return 'read-trailer-marker-missing' }
        }
        20 {
            if ($exitCode -eq 255) { return 'extract-start' }
        }
        21 {
            if ($exitCode -eq 0) { return 'extract-ok' }
        }
        30 {
            if ($exitCode -eq 255) { return 'run-installer-start' }
        }
        31 {
            if ($exitCode -eq 254) { return 'run-installer-exec-error' }
            if ($exitCode -eq 253) { return 'run-installer-exec-timeout' }
            return "run-installer-exit-$exitCode"
        }
    }

    return 'invalid'
}

function Get-SafeInstallerStatusSnapshot {
    param([Parameter(Mandatory = $true)][string]$NamePrefix)

    $transportRoots = Get-InstallerTransportRoots
    return @(
        $transportRoots | ForEach-Object {
            Get-ChildItem -LiteralPath $_ -Filter "$NamePrefix-status*.txt" -File -ErrorAction SilentlyContinue
        } |
            Sort-Object -Property Name |
            ForEach-Object { Get-SafeInstallerStatus -Path $_.FullName }
    )
}

function Get-InstallerTransportRoots {
    return @(
        [System.IO.Path]::GetTempPath()
        (Join-Path $env:WINDIR 'Temp')
    ) | Select-Object -Unique
}

function Resolve-InstallerTransportPath {
    param([Parameter(Mandatory = $true)][string]$FileName)

    foreach ($root in (Get-InstallerTransportRoots)) {
        $candidate = Join-Path $root $FileName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return Join-Path ([System.IO.Path]::GetTempPath()) $FileName
}

function Get-InstallerTransportPaths {
    param([Parameter(Mandatory = $true)][string]$FileName)

    return @(Get-InstallerTransportRoots | ForEach-Object { Join-Path $_ $FileName })
}

function Get-SafeInstallerChildRuntime {
    param([Parameter(Mandatory = $true)][string]$Path)

    $notObserved = [pscustomobject][ordered]@{
        status = 'not-observed'
        powerShellProcessArchitecture = 'not-observed'
        localAccountsCapability = 'not-observed'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $notObserved
    }

    try {
        $runtime = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([int]$runtime.SchemaVersion -ne 1 -or
            [string]$runtime.PowerShellProcessArchitecture -notmatch '^(32-bit|64-bit)$' -or
            [string]$runtime.LocalAccountsCapability -notmatch '^(available|unavailable)$') {
            throw 'invalid installer child runtime status'
        }
        return [pscustomobject][ordered]@{
            status = 'observed'
            powerShellProcessArchitecture = [string]$runtime.PowerShellProcessArchitecture
            localAccountsCapability = [string]$runtime.LocalAccountsCapability
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            status = 'invalid'
            powerShellProcessArchitecture = 'not-observed'
            localAccountsCapability = 'not-observed'
        }
    }
}

function Get-SafeInstallerFailurePhase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 'missing'
    }

    try {
        $phase = (Get-Content -LiteralPath $Path -Raw).Trim()
    }
    catch {
        return 'unreadable'
    }

    if ($phase -match '^[A-Za-z0-9-]{1,64}$') {
        return $phase
    }

    return 'invalid'
}

function Get-SafeDiagnosticObservationValue {
    param(
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$PropertyName
    )

    if ($null -eq $Object -or $null -eq $Object.PSObject.Properties[$PropertyName]) {
        return 'not-observed'
    }
    $value = $Object.$PropertyName
    if ($value -is [bool]) {
        return $value
    }
    if ([string]$value -eq 'not-observed') {
        return 'not-observed'
    }
    throw "invalid observed diagnostic field: $PropertyName"
}

function Get-SafeInstallerFailureDiagnostic {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $notObserved = [ordered]@{
        status = 'not-observed'
        stage = 'not-observed'
        substep = 'not-observed'
        reasonCodes = @()
        detail = 'not-observed'
        targetSid = ''
        groupSid = ''
        profilePath = ''
        expected = $null
        observed = $null
        appControlCommitState = 'not-observed'
        internalRollbackAttempted = 'not-observed'
        internalRollbackSucceeded = 'not-observed'
        installerRollbackAttempted = 'not-observed'
        installerRollbackSucceeded = 'not-observed'
        installerRollbackVerifiedNonOperational = 'not-observed'
        installerRollbackErrorCount = 'not-observed'
        installerRollbackErrorCategories = @()
        cleanupAttempted = 'not-observed'
        cleanupSucceeded = 'not-observed'
        validationErrorCode = 'not-observed'
        powerShellProcessArchitecture = 'not-observed'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]$notObserved
    }

    try {
        $document = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $documentPhase = [string]$document.Phase
        if ($documentPhase -notmatch '^[A-Za-z0-9-]{1,64}$') {
            throw 'invalid diagnostic envelope'
        }
        $appControl = $document.AppControlDiagnostic
        if ($null -eq $appControl -and $documentPhase -ne 'app-control') {
            return [pscustomobject]$notObserved
        }
        if ($null -eq $appControl) {
            throw 'missing AppControl diagnostic'
        }

        $reasonCodes = @($appControl.ReasonCodes | ForEach-Object { [string]$_ })
        if (@($reasonCodes | Where-Object { $_ -notmatch '^appcontrol_[a-z0-9_]{1,80}$' }).Count -gt 0) {
            throw 'invalid AppControl reason code'
        }
        $detail = [string]$appControl.Detail
        if ($detail -notmatch '^(not-observed|resolved|group-missing|group-sid-unresolvable|group-empty|member-sid-unresolvable|member-profile-unavailable)$') {
            throw 'invalid AppControl detail'
        }
        foreach ($sid in @([string]$appControl.TargetSid, [string]$appControl.GroupSid)) {
            if ($sid -and $sid -notmatch '^S-1-(?:\d+-){1,14}\d+$') {
                throw 'invalid SID diagnostic'
            }
        }
        $profilePath = [string]$appControl.ProfilePath
        if ($profilePath.Length -gt 512 -or $profilePath -match '[\x00-\x1f]') {
            throw 'invalid profile path diagnostic'
        }
        $stage = [string]$appControl.Stage
        $substep = [string]$appControl.Substep
        if ($stage -ne 'app-control' -or $substep -notmatch '^[a-z][a-z0-9-]{0,63}$') {
            throw 'invalid AppControl stage diagnostic'
        }

        $expected = [ordered]@{
            restrictedTarget = [string]$appControl.Expected.RestrictedTarget
            appIdentityService = [string]$appControl.Expected.AppIdentityService
            localPolicy = [string]$appControl.Expected.LocalPolicy
            effectivePolicy = [string]$appControl.Expected.EffectivePolicy
            runtimeBoundary = [string]$appControl.Expected.RuntimeBoundary
        }
        foreach ($value in $expected.Values) {
            if ($value.Length -gt 96 -or $value -match '[^A-Za-z0-9-]') {
                throw 'invalid expected diagnostic value'
            }
        }

        $safeRuntimeDecisions = @()
        foreach ($decision in @($appControl.Observed.RuntimeDecisions)) {
            $decisionPath = [string]$decision.FilePath
            if ([string]$decision.Kind -notmatch '^(arbitrary-executable|edge|firefox)$' -or
                [string]$decision.Expected -notmatch '^(DeniedOrDeniedByDefault|Allowed)$' -or
                [string]$decision.Observed -notmatch '^[A-Za-z]{1,40}$' -or
                $decisionPath.Length -gt 512 -or $decisionPath -match '[\x00-\x1f]') {
                throw 'invalid runtime decision diagnostic'
            }
            $safeRuntimeDecisions += [ordered]@{
                kind = [string]$decision.Kind
                filePath = $decisionPath
                expected = [string]$decision.Expected
                observed = [string]$decision.Observed
            }
        }
        if ($safeRuntimeDecisions.Count -gt 16) {
            throw 'too many runtime decision diagnostics'
        }
        $observedRestrictedTarget = [string]$appControl.Observed.RestrictedTarget
        $observedAppIdentityService = [string]$appControl.Observed.AppIdentityService
        if ($observedRestrictedTarget -notmatch '^(not-observed|resolved|group-missing|group-sid-unresolvable|group-empty|member-sid-unresolvable|member-profile-unavailable)$' -or
            $observedAppIdentityService -notmatch '^(not-observed|Running|not-running-or-unavailable)$') {
            throw 'invalid observed AppControl state'
        }
        $observed = [ordered]@{
            restrictedTarget = $observedRestrictedTarget
            appIdentityService = $observedAppIdentityService
            localPolicyPresent = Get-SafeDiagnosticObservationValue -Object $appControl.Observed -PropertyName 'LocalPolicyPresent'
            localPolicyValid = Get-SafeDiagnosticObservationValue -Object $appControl.Observed -PropertyName 'LocalPolicyValid'
            effectivePolicyPresent = Get-SafeDiagnosticObservationValue -Object $appControl.Observed -PropertyName 'EffectivePolicyPresent'
            effectivePolicyValid = Get-SafeDiagnosticObservationValue -Object $appControl.Observed -PropertyName 'EffectivePolicyValid'
            runtimeDecisions = $safeRuntimeDecisions
        }

        $rollbackAttempted = Get-SafeDiagnosticObservationValue -Object $document -PropertyName 'RollbackAttempted'
        $rollbackSucceeded = 'not-observed'
        $rollbackVerified = 'not-observed'
        $rollbackErrorCount = 'not-observed'
        $rollbackErrorCategories = @()
        if ($document.RollbackResult) {
            $rollbackSucceeded = Get-SafeDiagnosticObservationValue -Object $document.RollbackResult -PropertyName 'Success'
            $rollbackVerified = Get-SafeDiagnosticObservationValue -Object $document.RollbackResult -PropertyName 'VerifiedNonOperational'
            $rollbackErrorCount = @($document.RollbackResult.Errors).Count
            foreach ($rollbackError in @($document.RollbackResult.Errors)) {
                $category = ([string]$rollbackError -split ':', 2)[0]
                if ($category -notin @('tasks', 'dns', 'firewall', 'applocker', 'restrictedGroup', 'browserArtifacts', 'acrylic', 'config', 'applockerVerify')) {
                    throw 'invalid rollback error category'
                }
                $rollbackErrorCategories += $category
            }
        }
        $appControlCommitState = [string]$appControl.AppControlCommitState
        if ($appControlCommitState -notmatch '^(not-observed|not-committed|committed)$') {
            throw 'invalid AppControl commit state'
        }
        $powerShellProcessArchitecture = [string]$appControl.PowerShellProcessArchitecture
        if ($powerShellProcessArchitecture -notmatch '^(32-bit|64-bit)$') {
            throw 'invalid PowerShell process architecture'
        }

        return [pscustomobject][ordered]@{
            status = 'observed'
            stage = $stage
            substep = $substep
            reasonCodes = $reasonCodes
            detail = $detail
            targetSid = [string]$appControl.TargetSid
            groupSid = [string]$appControl.GroupSid
            profilePath = $profilePath
            expected = $expected
            observed = $observed
            appControlCommitState = $appControlCommitState
            internalRollbackAttempted = Get-SafeDiagnosticObservationValue -Object $appControl -PropertyName 'InternalRollbackAttempted'
            internalRollbackSucceeded = Get-SafeDiagnosticObservationValue -Object $appControl -PropertyName 'InternalRollbackSucceeded'
            installerRollbackAttempted = $rollbackAttempted
            installerRollbackSucceeded = $rollbackSucceeded
            installerRollbackVerifiedNonOperational = $rollbackVerified
            installerRollbackErrorCount = $rollbackErrorCount
            installerRollbackErrorCategories = @($rollbackErrorCategories)
            cleanupAttempted = Get-SafeDiagnosticObservationValue -Object $appControl -PropertyName 'CleanupAttempted'
            cleanupSucceeded = Get-SafeDiagnosticObservationValue -Object $appControl -PropertyName 'CleanupSucceeded'
            validationErrorCode = 'not-observed'
            powerShellProcessArchitecture = $powerShellProcessArchitecture
        }
    }
    catch {
        $notObserved.status = 'invalid'
        $safeValidationErrors = @(
            'invalid diagnostic envelope',
            'missing AppControl diagnostic',
            'invalid AppControl reason code',
            'invalid AppControl detail',
            'invalid SID diagnostic',
            'invalid profile path diagnostic',
            'invalid AppControl stage diagnostic',
            'invalid expected diagnostic value',
            'invalid runtime decision diagnostic',
            'too many runtime decision diagnostics',
            'invalid observed AppControl state',
            'invalid AppControl commit state',
            'invalid PowerShell process architecture'
            'invalid rollback error category'
        )
        $notObserved.validationErrorCode = if ($_.Exception.Message -in $safeValidationErrors) {
            $_.Exception.Message -replace ' ', '-'
        }
        else {
            'invalid-diagnostic-field'
        }
        return [pscustomobject]$notObserved
    }
}

function Get-SafeTrailerDiagnosticStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return 'missing'
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
    }
    catch {
        return 'unreadable'
    }

    if ($bytes.Length -ne 2) {
        return 'invalid'
    }

    $stage = [int]$bytes[0]
    $result = [int]$bytes[1]
    if ($result -eq 0) {
        switch ($stage) {
            3 { return 'payload-ok' }
            5 { return 'output-ok' }
        }
    }
    if ($result -eq 255) {
        switch ($stage) {
            1 { return 'bootstrap-start' }
            2 { return 'module-start' }
            3 { return 'payload-start' }
            4 { return 'config-start' }
        }
    }
    if ($result -eq 1) {
        switch ($stage) {
            1 { return 'bootstrap-failed' }
            2 { return 'module-failed' }
            3 { return 'payload-failed' }
            4 { return 'config-failed' }
            5 { return 'output-failed' }
        }
    }

    return 'invalid'
}

function Start-EnrollmentFixture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prefix,

        [Parameter(Mandatory = $true)]
        [string]$ClassroomId,

        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    return Start-Job -ScriptBlock {
        param(
            [string]$ListenerPrefix,
            [string]$ExpectedClassroom,
            [int]$ListenerPort
        )

        $listener = [System.Net.HttpListener]::new()
        $listener.Prefixes.Add($ListenerPrefix)
        $listener.Start()
        try {
            while ($true) {
                $context = $listener.GetContext()
                try {
                    $path = $context.Request.Url.AbsolutePath
                    if ($context.Request.HttpMethod -ne 'POST' -or $path -ne '/api/machines/register') {
                        $context.Response.StatusCode = 404
                        $context.Response.Close()
                        continue
                    }

                    $body = @{
                        success = $true
                        machineHostname = 'openpath-exe-e2e-machine'
                        reportedHostname = 'openpath-exe-e2e-machine'
                        whitelistUrl = "https://localhost:$ListenerPort/w/e2e-machine-token/whitelist.txt"
                        classroomName = 'Windows EXE E2E'
                        classroomId = $ExpectedClassroom
                    } | ConvertTo-Json -Compress
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
                    $context.Response.StatusCode = 200
                    $context.Response.ContentType = 'application/json'
                    $context.Response.ContentLength64 = $bytes.Length
                    $context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $context.Response.Close()
                }
                catch {
                    $context.Response.Abort()
                }
            }
        }
        finally {
            $listener.Stop()
            $listener.Close()
        }
    } -ArgumentList $Prefix, $ClassroomId, $Port
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'windows-only-lane'
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'administrator-required'
}

$shell = Get-AvailablePowerShell
$resolvedExecutable = (Resolve-Path -LiteralPath $ExecutablePath).Path
$expectedApiUri = [System.Uri]$ExpectedApiUrl
if ($expectedApiUri.Port -ne $ConnectivityPort) {
    throw 'ExpectedApiUrl port must match ConnectivityPort'
}
$previousOpenPathRoot = $env:OPENPATH_WINDOWS_ROOT
if (-not $OpenPathRoot) {
    $OpenPathRoot = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-exe-e2e-$([guid]::NewGuid().ToString('N'))"
}
if (Test-Path -LiteralPath $OpenPathRoot) {
    throw 'OpenPathRoot must be a new isolated directory'
}

$evidencePathWasSupplied = [bool]$EvidencePath
if (-not $EvidencePath) {
    $EvidencePath = Join-Path ([System.IO.Path]::GetTempPath()) 'openpath-windows-offline-installer-exe-evidence.json'
}

$stubJob = $null
$certificate = $null
$certificateFile = $null
$sslBindingAdded = $false
$urlAclAdded = $false
$sslAppId = '{4c9e7d9c-2d7c-4e4e-bb3e-2f5f0b7e7c42}'
$urlAcl = "https://localhost:$ConnectivityPort/"
$trailerConfigFile = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-exe-trailer-$([guid]::NewGuid().ToString('N')).json"
$transportNamePrefix = "OpenPathOfflineSetup-$([System.IO.Path]::GetFileName($resolvedExecutable))"
$installerStatusPath = Join-Path ([System.IO.Path]::GetTempPath()) "$transportNamePrefix-status.txt"
$trailerDiagnosticPath = Join-Path ([System.IO.Path]::GetTempPath()) "$transportNamePrefix-trailer-status.txt"
$failurePhasePath = Join-Path ([System.IO.Path]::GetTempPath()) "$transportNamePrefix-installer-failure-phase.txt"
$failureDiagnosticPath = "$failurePhasePath.json"
$installerChildRuntimePath = Join-Path ([System.IO.Path]::GetTempPath()) "$transportNamePrefix-installer-runtime.json"
$installerStatus = 'missing'
$installerStatusSnapshot = @()
$installerFailurePhase = 'missing'
$installerFailureDiagnostic = Get-SafeInstallerFailureDiagnostic -Path $failureDiagnosticPath
$installerChildRuntime = Get-SafeInstallerChildRuntime -Path $installerChildRuntimePath
$trailerDiagnosticStatus = 'missing'
$trailerDiagnosticSource = 'installer-child'
$result = $null
$disposableTarget = $null
$targetCleanup = $null
$boundaryEvidence = $null

foreach ($transportFileName in @(
    "$transportNamePrefix-status.txt",
    "$transportNamePrefix-trailer-status.txt",
    "$transportNamePrefix-installer-failure-phase.txt",
    "$transportNamePrefix-installer-failure-phase.txt.json",
    "$transportNamePrefix-installer-runtime.json"
)) {
    Get-InstallerTransportPaths -FileName $transportFileName |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

try {
    $script:CurrentStage = 'prepare-disposable-standard-target'
    Import-Module (Join-Path $PSScriptRoot 'DisposableWindowsTarget.psm1') -Force -ErrorAction Stop
    $disposableTarget = New-OpenPathDisposableStandardTarget

    $script:CurrentStage = 'launch-executable'
    $env:OPENPATH_WINDOWS_ROOT = $OpenPathRoot
    $installProcess = Start-Process -FilePath $resolvedExecutable -ArgumentList @('/S') -Wait -PassThru
    $installExitCode = [int]$installProcess.ExitCode
    $installerStatusPath = Resolve-InstallerTransportPath -FileName "$transportNamePrefix-status.txt"
    $trailerDiagnosticPath = Resolve-InstallerTransportPath -FileName "$transportNamePrefix-trailer-status.txt"
    $failurePhasePath = Resolve-InstallerTransportPath -FileName "$transportNamePrefix-installer-failure-phase.txt"
    $failureDiagnosticPath = Resolve-InstallerTransportPath -FileName "$transportNamePrefix-installer-failure-phase.txt.json"
    $installerChildRuntimePath = Resolve-InstallerTransportPath -FileName "$transportNamePrefix-installer-runtime.json"
    $installerStatus = Get-SafeInstallerStatus -Path $installerStatusPath
    $installerStatusSnapshot = Get-SafeInstallerStatusSnapshot -NamePrefix $transportNamePrefix
    $installerFailurePhase = Get-SafeInstallerFailurePhase -Path $failurePhasePath
    $installerFailureDiagnostic = Get-SafeInstallerFailureDiagnostic -Path $failureDiagnosticPath
    $installerChildRuntime = Get-SafeInstallerChildRuntime -Path $installerChildRuntimePath
    $trailerDiagnosticStatus = Get-SafeTrailerDiagnosticStatus -Path $trailerDiagnosticPath
    $script:CurrentStage = 'validate-installer-child-runtime'
    $installerChildPowerShellArchitecture = [string]$installerChildRuntime.powerShellProcessArchitecture
    if ($installerChildPowerShellArchitecture -ne '64-bit') {
        throw 'installer-child-powershell-not-64-bit'
    }
    $installerChildLocalAccountsCapability = [string]$installerChildRuntime.localAccountsCapability
    if ($installerChildLocalAccountsCapability -ne 'available') {
        throw 'installer-child-localaccounts-unavailable'
    }
    $script:CurrentStage = 'validate-installer-exit'
    if ($installExitCode -ne 60) {
        throw 'offline-install-did-not-reach-pending-state'
    }

    $script:CurrentStage = 'validate-installed-state'
    $pendingStatePath = Join-Path $OpenPathRoot 'data\pending-enrollment.json.dpapi'
    $installedConfigPath = Join-Path $OpenPathRoot 'data\config.json'
    if (-not (Test-Path -LiteralPath $pendingStatePath -PathType Leaf)) {
        throw 'pending-enrollment-state-missing'
    }
    if (-not (Test-Path -LiteralPath $installedConfigPath -PathType Leaf)) {
        throw 'installed-config-missing'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $OpenPathRoot 'lib\install\Installer.Offline.ps1') -PathType Leaf)) {
        throw 'offline-runtime-missing'
    }

    $script:CurrentStage = 'validate-installed-config'
    $installedConfig = Get-Content -LiteralPath $installedConfigPath -Raw | ConvertFrom-Json
    Assert-EqualValue -Actual ([string]$installedConfig.classroomId) -Expected $ExpectedClassroomId -Code 'installed-classroom-mismatch'
    Assert-EqualValue -Actual ([string]$installedConfig.apiUrl) -Expected $ExpectedApiUrl -Code 'installed-api-url-mismatch'

    $script:CurrentStage = 'validate-trailer'
    $reader = Join-Path $PSScriptRoot '..\..\..\windows\offline-installer\scripts\Read-Trailer.ps1'
    if (-not (Test-Path -LiteralPath $reader -PathType Leaf)) {
        throw 'offline-trailer-reader-missing'
    }
    & $shell -NoProfile -ExecutionPolicy Bypass -File $reader -ExecutablePath $resolvedExecutable -OutputConfigPath $trailerConfigFile *> $null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $trailerConfigFile -PathType Leaf)) {
        throw 'trailer-validation-failed'
    }
    $trailerConfig = Get-Content -LiteralPath $trailerConfigFile -Raw | ConvertFrom-Json
    Assert-EqualValue -Actual ([string]$trailerConfig.classroomId) -Expected $ExpectedClassroomId -Code 'trailer-classroom-mismatch'
    Assert-EqualValue -Actual ([string]$trailerConfig.apiUrl) -Expected $ExpectedApiUrl -Code 'trailer-api-url-mismatch'

    $script:CurrentStage = 'configure-local-https'
    $certificate = New-SelfSignedCertificate -DnsName 'localhost' -CertStoreLocation 'Cert:\LocalMachine\My'
    $certificateFile = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-exe-e2e-$([guid]::NewGuid().ToString('N')).cer"
    Export-Certificate -Cert $certificate -FilePath $certificateFile -Type CERT | Out-Null
    Import-Certificate -FilePath $certificateFile -CertStoreLocation 'Cert:\LocalMachine\Root' | Out-Null
    & netsh http add sslcert "ipport=0.0.0.0:$ConnectivityPort" "certhash=$($certificate.Thumbprint)" "appid=$sslAppId" "certstorename=MY" *> $null
    if ($LASTEXITCODE -ne 0) {
        throw 'local-https-binding-failed'
    }
    $sslBindingAdded = $true

    & netsh http add urlacl "url=$urlAcl" 'user=Everyone' *> $null
    if ($LASTEXITCODE -ne 0) {
        throw 'local-https-urlacl-failed'
    }
    $urlAclAdded = $true

    $script:CurrentStage = 'start-enrollment-fixture'
    $stubJob = Start-EnrollmentFixture -Prefix $urlAcl -ClassroomId $ExpectedClassroomId -Port $ConnectivityPort
    Start-Sleep -Seconds 2
    if ($stubJob.State -eq 'Failed') {
        Receive-Job -Job $stubJob -ErrorAction SilentlyContinue | Out-Null
        throw 'local-enrollment-fixture-failed'
    }

    $script:CurrentStage = 'retry-pending-enrollment'
    . (Join-Path $OpenPathRoot 'lib\install\Installer.Offline.ps1')
    $retry = Invoke-OpenPathPendingEnrollmentRetry -OpenPathRoot $OpenPathRoot
    if ([string]$retry.Outcome -ne 'REGISTERED') {
        throw 'pending-enrollment-retry-did-not-complete'
    }
    if (Test-Path -LiteralPath $pendingStatePath -PathType Leaf) {
        throw 'pending-enrollment-state-not-cleared'
    }

    $script:CurrentStage = 'validate-completed-state'
    $completedConfig = Get-Content -LiteralPath $installedConfigPath -Raw | ConvertFrom-Json
    Assert-EqualValue -Actual ([string]$completedConfig.classroomId) -Expected $ExpectedClassroomId -Code 'completed-classroom-mismatch'
    if ([string]::IsNullOrWhiteSpace([string]$completedConfig.whitelistUrl)) {
        throw 'completed-whitelist-url-missing'
    }

    $script:CurrentStage = 'validate-prepared-target-installed'
    $installedTarget = Assert-OpenPathPreparedTargetInstalled -Target $disposableTarget
    $script:CurrentStage = 'run-installed-boundary-probes'
    $boundaryEvidence = Invoke-OpenPathInstalledBoundaryProbes -Target $disposableTarget -OpenPathRoot $OpenPathRoot

    $result = [ordered]@{
        status = 'ok'
        installerExitCode = $installExitCode
        installerStatus = $installerStatus
        installerFailurePhase = $installerFailurePhase
        installerFailureDiagnostic = $installerFailureDiagnostic
        installerChildRuntime = $installerChildRuntime
        trailerDiagnosticStatus = $trailerDiagnosticStatus
        trailerDiagnosticSource = $trailerDiagnosticSource
        trailerValidated = $true
        payloadManifestValidated = $true
        pendingStateObserved = $true
        retryOutcome = [string]$retry.Outcome
        pendingStateCleared = $true
        preparedTarget = [ordered]@{
            sid = [string]$installedTarget.Sid
            profilePath = [string]$installedTarget.profilePath
            enabled = [bool]$installedTarget.enabled
            administrator = [bool]$installedTarget.administrator
            profileMaterialized = [bool]$installedTarget.profileMaterialized
            profileSpecial = [bool]$installedTarget.profileSpecial
            restrictedGroupMember = [bool]$installedTarget.restrictedGroupMember
        }
        boundary = $boundaryEvidence
        cleanupAttempted = 'not-observed'
        cleanupSucceeded = 'not-observed'
    }
    Write-SafeEvidence -Payload $result -Path $EvidencePath
    $result | ConvertTo-Json -Compress
    exit 0
}
catch {
    $boundaryFailureCode = if ($script:CurrentStage -eq 'run-installed-boundary-probes' -and $_.Exception.Message -match '^boundary-[a-z0-9-]{1,96}$') {
        [string]$_.Exception.Message
    }
    else {
        'not-observed'
    }
    $installerStatus = Get-SafeInstallerStatus -Path $installerStatusPath
    $installerStatusSnapshot = Get-SafeInstallerStatusSnapshot -NamePrefix $transportNamePrefix
    $installerFailurePhase = Get-SafeInstallerFailurePhase -Path $failurePhasePath
    $installerFailureDiagnostic = Get-SafeInstallerFailureDiagnostic -Path $failureDiagnosticPath
    $installerChildRuntime = Get-SafeInstallerChildRuntime -Path $installerChildRuntimePath
    $trailerDiagnosticStatus = Get-SafeTrailerDiagnosticStatus -Path $trailerDiagnosticPath
    if ($trailerDiagnosticStatus -eq 'missing') {
        $reader = Join-Path $PSScriptRoot '..\..\..\windows\offline-installer\scripts\Read-Trailer.ps1'
        if (Test-Path -LiteralPath $reader -PathType Leaf) {
            try {
                & $shell -NoProfile -ExecutionPolicy Bypass -File $reader `
                    -ExecutablePath $resolvedExecutable `
                    -OutputConfigPath $trailerConfigFile `
                    -StatusPath $trailerDiagnosticPath *> $null
            }
            catch {
                # Keep the diagnostic best-effort; the original EXE result
                # remains the only pass/fail signal for this lane.
            }
            $trailerDiagnosticStatus = Get-SafeTrailerDiagnosticStatus -Path $trailerDiagnosticPath
            $trailerDiagnosticSource = 'post-process'
        }
    }
    $edgeBoundaryEvidence = $null
    $edgeFailureContract = $null
    $getBoundaryFailureEvidence = Get-Command -Name Get-OpenPathLastBoundaryProbeFailureEvidence -ErrorAction SilentlyContinue
    if ($script:CurrentStage -eq 'run-installed-boundary-probes' -and $getBoundaryFailureEvidence) {
        $initialBoundaryEvidence = & $getBoundaryFailureEvidence
        if ($initialBoundaryEvidence -and [string]$initialBoundaryEvidence.probeName -eq 'Canonical Edge deny') {
            $edgeBoundaryEvidence = [ordered]@{
                initial = $initialBoundaryEvidence
                repeat = $null
            }
            $runBoundaryDiagnostic = Get-Command -Name Invoke-OpenPathEdgeBoundaryDiagnostic -ErrorAction SilentlyContinue
            if ($runBoundaryDiagnostic -and $disposableTarget -and $disposableTarget.UserName -and $disposableTarget.Password) {
                try {
                    $edgeBoundaryEvidence.repeat = & $runBoundaryDiagnostic `
                        -UserName $disposableTarget.UserName `
                        -Password $disposableTarget.Password `
                        -ExecutablePath $initialBoundaryEvidence.executablePath `
                        -StudentSid $initialBoundaryEvidence.studentSid
                }
                catch {
                    $edgeBoundaryEvidence.repeat = [ordered]@{
                        status = 'unavailable'
                        code = 'edge-boundary-diagnostic-failed'
                    }
                }
            }
            $getEdgeFailureContract = Get-Command -Name Get-OpenPathFlatEdgeBoundaryFailureContract -ErrorAction SilentlyContinue
            if ($getEdgeFailureContract) {
                $edgeFailureContract = & $getEdgeFailureContract -Evidence $initialBoundaryEvidence -Diagnostic $edgeBoundaryEvidence.repeat
            }
        }
    }
    $edge = if ($edgeFailureContract) {
        [ordered]@{
            expectedPath = $edgeFailureContract.edge.expectedPath
            observedExactProcess = $edgeFailureContract.edge.observedExactProcess
            observedPid = $edgeFailureContract.edge.observedPid
            studentSid = $edgeFailureContract.edge.studentSid
            restrictedGroupSid = $edgeFailureContract.edge.restrictedGroupSid
            restrictedGroupSamMember = $edgeFailureContract.edge.restrictedGroupSamMember
            restrictedGroupTokenMember = $edgeFailureContract.edge.restrictedGroupTokenMember
            testAppLockerPolicyDecision = $edgeFailureContract.edge.testAppLockerPolicyDecision
            appLocker8002 = $edgeFailureContract.edge.appLocker8002
            appLocker8004 = $edgeFailureContract.edge.appLocker8004
            appLocker8020 = $edgeFailureContract.edge.appLocker8020
            appLocker8022 = $edgeFailureContract.edge.appLocker8022
        }
    }
    else { $null }
    $failure = [ordered]@{
        status = 'failed'
        code = 'windows-offline-installer-exe-e2e-failed'
        failureStage = $script:CurrentStage
        failureDetailCode = $boundaryFailureCode
        installerExitCode = $installExitCode
        installerStatus = $installerStatus
        installerStatusSnapshot = $installerStatusSnapshot
        installerFailurePhase = $installerFailurePhase
        installerFailureDiagnostic = $installerFailureDiagnostic
        installerChildRuntime = $installerChildRuntime
        trailerDiagnosticStatus = $trailerDiagnosticStatus
        trailerDiagnosticSource = $trailerDiagnosticSource
        edgeBoundaryEvidence = $edgeBoundaryEvidence
        edge = $edge
        edgeName = if ($edgeFailureContract) { $edgeFailureContract.edgeName } else { $null }
        edgeStudentSid = if ($edgeFailureContract) { $edgeFailureContract.edgeStudentSid } else { $null }
        edgeExecutablePath = if ($edgeFailureContract) { $edgeFailureContract.edgeExecutablePath } else { $null }
        edgeFailureCode = if ($edgeFailureContract) { $edgeFailureContract.edgeFailureCode } else { $null }
        edgeExpectedEventIds = if ($edgeFailureContract) { $edgeFailureContract.edgeExpectedEventIds } else { @() }
        edgeSamSid = if ($edgeFailureContract) { $edgeFailureContract.edgeSamSid } else { $null }
        edgeTokenUserSid = if ($edgeFailureContract) { $edgeFailureContract.edgeTokenUserSid } else { $null }
        edgeSamGroupName = if ($edgeFailureContract) { $edgeFailureContract.edgeSamGroupName } else { $null }
        edgeSamGroupSid = if ($edgeFailureContract) { $edgeFailureContract.edgeSamGroupSid } else { $null }
        edgeSamGroupMemberPresent = if ($edgeFailureContract) { $edgeFailureContract.edgeSamGroupMemberPresent } else { $null }
        edgeSamGroupMemberCount = if ($edgeFailureContract) { $edgeFailureContract.edgeSamGroupMemberCount } else { $null }
        edgeRestrictedGroupSid = if ($edgeFailureContract) { $edgeFailureContract.edgeRestrictedGroupSid } else { $null }
        edgeRestrictedGroupPresent = if ($edgeFailureContract) { $edgeFailureContract.edgeRestrictedGroupPresent } else { $null }
        edgeRestrictedGroupAttributes = if ($edgeFailureContract) { $edgeFailureContract.edgeRestrictedGroupAttributes } else { $null }
        edgeRestrictedGroupEnabled = if ($edgeFailureContract) { $edgeFailureContract.edgeRestrictedGroupEnabled } else { $null }
        edgeRestrictedGroupDenyOnly = if ($edgeFailureContract) { $edgeFailureContract.edgeRestrictedGroupDenyOnly } else { $null }
        edgeRestrictedGroupDisabled = if ($edgeFailureContract) { $edgeFailureContract.edgeRestrictedGroupDisabled } else { $null }
        edgeTaskRegisteredAtUtc = if ($edgeFailureContract) { $edgeFailureContract.edgeTaskRegisteredAtUtc } else { $null }
        edgeEventId = if ($edgeFailureContract) { $edgeFailureContract.edgeEventId } else { $null }
        edgeEventProcessId = if ($edgeFailureContract) { $edgeFailureContract.edgeEventProcessId } else { $null }
        edgeEventPidStatus = if ($edgeFailureContract) { $edgeFailureContract.edgeEventPidStatus } else { 'unavailable' }
        edgeObservedPath = if ($edgeFailureContract) { $edgeFailureContract.edgeObservedPath } else { $null }
        edgeObservedPackage = if ($edgeFailureContract) { $edgeFailureContract.edgeObservedPackage } else { $null }
        edgeObservedRuleId = if ($edgeFailureContract) { $edgeFailureContract.edgeObservedRuleId } else { $null }
        edgeObservedRuleName = if ($edgeFailureContract) { $edgeFailureContract.edgeObservedRuleName } else { $null }
        edgeObservedUserSid = if ($edgeFailureContract) { $edgeFailureContract.edgeObservedUserSid } else { $null }
        edgeAttempts = if ($edgeFailureContract) { $edgeFailureContract.edgeAttempts } else { @() }
        cleanupAttempted = 'not-observed'
        cleanupSucceeded = 'not-observed'
    }
    $result = $failure
    try {
        Write-SafeEvidence -Payload $failure -Path $EvidencePath
    }
    catch {
        # Evidence serialization is secondary; preserve the original failure
        # object and exit contract on the console even when the sink is broken.
    }
    $failure | ConvertTo-Json -Compress
    exit 1
}
finally {
    $e2eCleanupAttempted = $true
    $targetCleanupSucceeded = $null -eq $disposableTarget
    if ($stubJob) {
        Stop-Job -Job $stubJob -ErrorAction SilentlyContinue
        Remove-Job -Job $stubJob -Force -ErrorAction SilentlyContinue
    }
    if ($sslBindingAdded) {
        & netsh http delete sslcert "ipport=0.0.0.0:$ConnectivityPort" *> $null
    }
    if ($urlAclAdded) {
        & netsh http delete urlacl "url=$urlAcl" *> $null
    }
    if ($null -ne $disposableTarget) {
        try {
            $targetCleanup = Remove-OpenPathDisposableStandardTarget -Target $disposableTarget
            $targetCleanupSucceeded = [bool]($targetCleanup.userRightRemoved -and $targetCleanup.profileRemoved -and $targetCleanup.userRemoved -and $targetCleanup.credentialDestroyed)
        }
        catch {
            $targetCleanupSucceeded = $false
        }
    }
    if ($certificate) {
        Remove-Item -LiteralPath "Cert:\LocalMachine\My\$($certificate.Thumbprint)" -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath "Cert:\LocalMachine\Root\$($certificate.Thumbprint)" -Force -ErrorAction SilentlyContinue
    }
    if ($certificateFile -and (Test-Path -LiteralPath $certificateFile)) {
        Remove-Item -LiteralPath $certificateFile -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $trailerConfigFile) {
        Remove-Item -LiteralPath $trailerConfigFile -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $installerStatusPath) {
        Remove-Item -LiteralPath $installerStatusPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $trailerDiagnosticPath) {
        Remove-Item -LiteralPath $trailerDiagnosticPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $failurePhasePath) {
        Remove-Item -LiteralPath $failurePhasePath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $failureDiagnosticPath) {
        Remove-Item -LiteralPath $failureDiagnosticPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $installerChildRuntimePath) {
        Remove-Item -LiteralPath $installerChildRuntimePath -Force -ErrorAction SilentlyContinue
    }
    Get-InstallerTransportRoots | ForEach-Object {
        Get-ChildItem -LiteralPath $_ -Filter "$transportNamePrefix-status*.txt" -File -ErrorAction SilentlyContinue
    } | Remove-Item -Force -ErrorAction SilentlyContinue
    $uninstaller = Join-Path $OpenPathRoot 'Uninstall-OpenPath.ps1'
    if (Test-Path -LiteralPath $uninstaller -PathType Leaf) {
        & $shell -NoProfile -ExecutionPolicy Bypass -File $uninstaller *> $null
    }
    if (Test-Path -LiteralPath $OpenPathRoot) {
        Remove-Item -LiteralPath $OpenPathRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $previousOpenPathRoot) {
        Remove-Item Env:OPENPATH_WINDOWS_ROOT -ErrorAction SilentlyContinue
    }
    else {
        $env:OPENPATH_WINDOWS_ROOT = $previousOpenPathRoot
    }
    $e2eCleanupSucceeded = [bool]($targetCleanupSucceeded -and
        -not (Test-Path -LiteralPath $OpenPathRoot) -and
        -not (Test-Path -LiteralPath $installerStatusPath) -and
        -not (Test-Path -LiteralPath $trailerDiagnosticPath) -and
        -not (Test-Path -LiteralPath $failurePhasePath) -and
        -not (Test-Path -LiteralPath $failureDiagnosticPath))
    if ($null -ne $result) {
        $result.cleanupAttempted = $e2eCleanupAttempted
        $result.cleanupSucceeded = $e2eCleanupSucceeded
        if ($null -ne $targetCleanup) {
            $result.targetCleanup = $targetCleanup
        }
        if ($evidencePathWasSupplied) {
            try {
                Write-SafeEvidence -Payload $result -Path $EvidencePath
            }
            catch {
                # Cleanup evidence is best-effort and cannot replace the primary installer result.
            }
        }
    }
    if (-not $evidencePathWasSupplied -and (Test-Path -LiteralPath $EvidencePath)) {
        Remove-Item -LiteralPath $EvidencePath -Force -ErrorAction SilentlyContinue
    }
}
