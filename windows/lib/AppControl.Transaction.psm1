# Serialized AppLocker mutation journal.  The module deliberately does not
# apply policy; AppControl owns the cmdlets and uses this context to make every
# mutation attributable and recoverable.

Set-StrictMode -Version Latest

$script:TransactionStates = @('prepared','apply-attempted','applied','validated','committed','rollback-attempted','rolled-back','recovery-required')
$script:HeldMutexNames = @{}

function Get-OpenPathTransactionRoot {
    param([Parameter(Mandatory)][string]$OpenPathRoot)
    Join-Path (Join-Path $OpenPathRoot 'data') 'appcontrol-transactions'
}

function Write-OpenPathTransactionAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    $parent = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, $Content, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
    } finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

function Enter-OpenPathAppControlTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OpenPathRoot, [int]$TimeoutMilliseconds = 15000)
    $canonicalRoot = [IO.Path]::GetFullPath($OpenPathRoot).TrimEnd('\').ToLowerInvariant()
    $mutexName = 'Global\OpenPath-AppControl-' + (([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($canonicalRoot)) | ForEach-Object { $_.ToString('x2') }) -join '')
    if ($script:HeldMutexNames.ContainsKey($mutexName)) { return [PSCustomObject]@{ Acquired = $false; ReasonCode = 'appcontrol_transaction_busy'; Mutex = $null; MutexName = $mutexName } }
    $mutex = [Threading.Mutex]::new($false, $mutexName)
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        try {
            $security = [Threading.MutexSecurity]::new()
            foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
                $identity = [Security.Principal.SecurityIdentifier]::new($sid)
                $rule = [Threading.MutexAccessRule]::new($identity, [Threading.MutexRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow)
                $security.AddAccessRule($rule)
            }
            $mutex.SetAccessControl($security)
        } catch { }
    }
    try {
        if (-not $mutex.WaitOne($TimeoutMilliseconds)) { $mutex.Dispose(); return [PSCustomObject]@{ Acquired = $false; ReasonCode = 'appcontrol_transaction_busy'; Mutex = $null } }
    } catch {
        $mutex.Dispose()
        return [PSCustomObject]@{ Acquired = $false; ReasonCode = 'appcontrol_transaction_busy'; Mutex = $null }
    }
    $script:HeldMutexNames[$mutexName] = $true
    [PSCustomObject]@{ Acquired = $true; ReasonCode = $null; Mutex = $mutex; MutexName = $mutexName }
}

function Exit-OpenPathAppControlTransaction {
    param([AllowNull()][object]$Lock)
    if ($Lock -and $Lock.Acquired -and $Lock.Mutex) {
        try { $Lock.Mutex.ReleaseMutex() } catch {}
        $Lock.Mutex.Dispose()
        if ($Lock.MutexName) { $script:HeldMutexNames.Remove([string]$Lock.MutexName) | Out-Null }
    }
}

function New-OpenPathAppControlTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OpenPathRoot,
        [Parameter(Mandatory)][string]$LocalPolicyXml,
        [Parameter(Mandatory)][string]$EffectivePolicyXml,
        [string]$Operation = 'apply'
    )
    $id = [guid]::NewGuid().ToString()
    $directory = Join-Path (Get-OpenPathTransactionRoot -OpenPathRoot $OpenPathRoot) $id
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $localPath = Join-Path $directory 'before-local.xml'
    $effectivePath = Join-Path $directory 'before-effective.xml'
    $candidatePath = Join-Path $directory 'candidate.xml'
    $statePath = Join-Path $directory 'state.json'
    Write-OpenPathTransactionAtomic -Path $localPath -Content $LocalPolicyXml
    Write-OpenPathTransactionAtomic -Path $effectivePath -Content $EffectivePolicyXml
    $state = [ordered]@{ SchemaVersion = 1; TransactionId = $id; Operation = $Operation; State = 'prepared'; BeforeLocal = $localPath; BeforeEffective = $effectivePath; Candidate = $candidatePath; StateFile = $statePath; CreatedAt = [DateTime]::UtcNow.ToString('O'); ApplyAttempted = $false; InternalRollbackSucceeded = $false; ReasonCodes = @() }
    Write-OpenPathTransactionAtomic -Path $statePath -Content ($state | ConvertTo-Json -Depth 10)
    [pscustomobject]$state
}

function Set-OpenPathAppControlTransactionState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Transaction, [Parameter(Mandatory)][ValidateSet('prepared','apply-attempted','applied','validated','committed','rollback-attempted','rolled-back','recovery-required')][string]$State, [string[]]$ReasonCodes = @())
    $current = Get-Content -LiteralPath $Transaction.StateFile -Raw | ConvertFrom-Json
    $current.State = $State
    $current.ApplyAttempted = $State -in @('apply-attempted','applied','validated','committed','rollback-attempted','rolled-back','recovery-required')
    if ($ReasonCodes.Count -gt 0) { $current.ReasonCodes = @($ReasonCodes) }
    Write-OpenPathTransactionAtomic -Path $Transaction.StateFile -Content ($current | ConvertTo-Json -Depth 10)
    return $current
}

function Write-OpenPathAppControlTransactionCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Transaction, [Parameter(Mandatory)][string]$CandidateXml)
    Write-OpenPathTransactionAtomic -Path $Transaction.Candidate -Content $CandidateXml
    return Set-OpenPathAppControlTransactionState -Transaction $Transaction -State 'prepared'
}

function Invoke-OpenPathAppControlTransactionRollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Transaction,
        [Parameter(Mandatory)][scriptblock]$ApplyLocalPolicy,
        [Parameter(Mandatory)][scriptblock]$ReadLocalPolicy,
        [scriptblock]$ComparePolicy
    )
    Set-OpenPathAppControlTransactionState -Transaction $Transaction -State 'rollback-attempted' | Out-Null
    try {
        & $ApplyLocalPolicy ([string](Get-Content -LiteralPath $Transaction.BeforeLocal -Raw))
        $readback = [string](& $ReadLocalPolicy)
        $same = if ($ComparePolicy) { [bool](& $ComparePolicy ([string](Get-Content -LiteralPath $Transaction.BeforeLocal -Raw)) $readback) } else { $readback.Trim() -eq ([string](Get-Content -LiteralPath $Transaction.BeforeLocal -Raw)).Trim() }
        if (-not $same) { Set-OpenPathAppControlTransactionState -Transaction $Transaction -State 'recovery-required' -ReasonCodes @('appcontrol_rollback_verification_failed') | Out-Null; return $false }
        $state = Set-OpenPathAppControlTransactionState -Transaction $Transaction -State 'rolled-back'
        $state.InternalRollbackSucceeded = $true
        Write-OpenPathTransactionAtomic -Path $Transaction.StateFile -Content ($state | ConvertTo-Json -Depth 10)
        return $true
    } catch {
        Set-OpenPathAppControlTransactionState -Transaction $Transaction -State 'recovery-required' -ReasonCodes @('appcontrol_recovery_required') | Out-Null
        return $false
    }
}

function Get-OpenPathAppControlTransaction {
    param([Parameter(Mandatory)][string]$StateFile)
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) { return $null }
    Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
}

function Get-OpenPathAppControlPendingRecovery {
    param([Parameter(Mandatory)][string]$OpenPathRoot)
    $root = Get-OpenPathTransactionRoot -OpenPathRoot $OpenPathRoot
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $null }
    foreach ($stateFile in @(Get-ChildItem -LiteralPath $root -Filter 'state.json' -File -Recurse -ErrorAction SilentlyContinue)) {
        $state = Get-OpenPathAppControlTransaction -StateFile $stateFile.FullName
        if ($state -and [string]$state.State -eq 'recovery-required') { return $state }
    }
    return $null
}

Export-ModuleMember -Function Enter-OpenPathAppControlTransaction, Exit-OpenPathAppControlTransaction, New-OpenPathAppControlTransaction, Set-OpenPathAppControlTransactionState, Write-OpenPathAppControlTransactionCandidate, Invoke-OpenPathAppControlTransactionRollback, Get-OpenPathAppControlTransaction, Get-OpenPathAppControlPendingRecovery
