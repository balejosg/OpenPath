# Serialized AppLocker mutation journal.  AppControl owns policy cmdlets; this
# module owns the machine-wide lock, durable journal, and recovery inspection.
Set-StrictMode -Version Latest

$script:TransactionStates = @('prepared', 'apply-attempted', 'applied', 'validated', 'committed', 'rollback-attempted', 'rolled-back', 'aborted', 'recovery-required')
$script:TerminalStates = @('committed', 'rolled-back', 'aborted')
$script:HeldMutexNames = @{}
$script:MachineMutexName = 'Global\OpenPath-AppControl-v1'

function Test-OpenPathTransactionWindows {
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -or [string]$env:OS -eq 'Windows_NT'
}

function Get-OpenPathTransactionRoot {
    param([Parameter(Mandatory = $true)][string]$OpenPathRoot)
    $canonical = [IO.Path]::GetFullPath($OpenPathRoot)
    Join-Path (Join-Path $canonical 'data') 'appcontrol-transactions'
}

function Get-OpenPathTransactionSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Get-OpenPathTransactionBytes {
    param([Parameter(Mandatory = $true)][string]$Path)
    [IO.File]::ReadAllBytes($Path)
}

function Write-OpenPathTransactionCreateNew {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Content)
    $parent = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Content)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function Write-OpenPathTransactionAtomic {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Content)
    $parent = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $Content, [Text.UTF8Encoding]::new($false))
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { $stream.Flush($true) } finally { $stream.Dispose() }
        Move-Item -LiteralPath $temporary -Destination $Path -Force -ErrorAction Stop
        Set-OpenPathTransactionAcl -Path $Path
    }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

function Set-OpenPathTransactionAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Directory
    )
    if (-not (Test-OpenPathTransactionWindows)) { return }
    try {
        # Replacing the descriptor with a small canonical SDDL is more reliable
        # than removing inherited ACEs one at a time.  The latter can leave a
        # non-canonical descriptor on Windows runner images and make every
        # transaction fail closed even when the caller is an administrator.
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $sddl = if ($Directory) {
            'O:SYG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'
        }
        else {
            'O:SYG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)'
        }
        $acl.SetSecurityDescriptorSddlForm($sddl)
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop

        $verified = Get-Acl -LiteralPath $Path -ErrorAction Stop
        if (-not $verified.AreAccessRulesProtected) { throw 'appcontrol_transaction_security_failed' }
        $allowedSids = @('S-1-5-18', 'S-1-5-32-544')
        $observedSids = @(
            $verified.Access | ForEach-Object {
                try { [string]$_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value }
                catch {
                    if ([string]$_.IdentityReference -match '(?i)SYSTEM') { 'S-1-5-18' }
                    elseif ([string]$_.IdentityReference -match '(?i)Administrators') { 'S-1-5-32-544' }
                    else { [string]$_.IdentityReference }
                }
            }
        )
        if (@($observedSids | Where-Object { $allowedSids -notcontains $_ }).Count -gt 0 -or
            @($allowedSids | Where-Object { $observedSids -notcontains $_ }).Count -gt 0) {
            throw 'appcontrol_transaction_security_failed'
        }
    }
    catch { throw 'appcontrol_transaction_security_failed' }
}

function Get-OpenPathMutexAclAssembly {
    $assembly = @([AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq 'System.Threading.AccessControl' } |
        Select-Object -First 1)
    if ($assembly.Count -eq 1) { return $assembly[0] }

    try { Add-Type -AssemblyName 'System.Threading.AccessControl' -ErrorAction Stop } catch {}
    $assembly = @([AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq 'System.Threading.AccessControl' } |
        Select-Object -First 1)
    if ($assembly.Count -eq 1) { return $assembly[0] }

    try { return [System.Reflection.Assembly]::Load('System.Threading.AccessControl') }
    catch { return $null }
}

function Get-OpenPathMutexAclExtensionType {
    $assembly = Get-OpenPathMutexAclAssembly
    if ($null -eq $assembly) { return $null }
    try { return $assembly.GetType('System.Threading.ThreadingAclExtensions', $false) }
    catch { return $null }
}

function Get-OpenPathMutexAclFactoryType {
    $assembly = Get-OpenPathMutexAclAssembly
    if ($null -eq $assembly) { return $null }
    try { return $assembly.GetType('System.Threading.MutexAcl', $false) }
    catch { return $null }
}

function Invoke-OpenPathMutexAclExtension {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GetAccessControl', 'SetAccessControl')][string]$MethodName,
        [Parameter(Mandatory = $true)][object]$Mutex,
        [AllowNull()][object]$Security
    )
    $type = Get-OpenPathMutexAclExtensionType
    if ($null -eq $type) { throw 'appcontrol_transaction_security_failed' }
    $parameterCount = if ($MethodName -eq 'GetAccessControl') { 1 } else { 2 }
    $method = @($type.GetMethods([System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static) |
        Where-Object {
            if ($_.Name -ne $MethodName) { return $false }
            $parameters = $_.GetParameters()
            if ($parameters.Count -ne $parameterCount -or $parameters[0].ParameterType -ne [System.Threading.Mutex]) { return $false }
            if ($MethodName -eq 'SetAccessControl' -and
                $parameters[1].ParameterType -ne [System.Security.AccessControl.MutexSecurity]) { return $false }
            return $true
        } |
        Select-Object -First 1)
    if ($method.Count -ne 1) { throw 'appcontrol_transaction_security_failed' }
    $mutexValue = if ($Mutex -is [System.Management.Automation.PSObject]) {
        $Mutex.PSObject.BaseObject
    }
    else { $Mutex }
    if ($MethodName -eq 'GetAccessControl') {
        $security = $method[0].Invoke($null, [object[]]@($mutexValue))
        if ($security -is [System.Management.Automation.PSObject]) {
            return $security.PSObject.BaseObject
        }
        return $security
    }
    $securityValue = if ($Security -is [System.Management.Automation.PSObject]) {
        $Security.PSObject.BaseObject
    }
    else { $Security }
    [void]$method[0].Invoke($null, [object[]]@($mutexValue, $securityValue))
}

function New-OpenPathNamedMutex {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Security
    )

    $factoryType = Get-OpenPathMutexAclFactoryType
    if ($null -ne $factoryType) {
        $createMethod = @($factoryType.GetMethods([System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static) |
            Where-Object {
                if ($_.Name -ne 'Create') { return $false }
                $parameters = $_.GetParameters()
                if ($parameters.Count -ne 4) { return $false }
                return $parameters[0].ParameterType -eq [bool] -and
                    $parameters[1].ParameterType -eq [string] -and
                    $parameters[2].ParameterType.IsByRef -and
                    $parameters[2].ParameterType.GetElementType() -eq [bool] -and
                    $parameters[3].ParameterType -eq [System.Security.AccessControl.MutexSecurity]
            } |
            Select-Object -First 1)
        if ($createMethod.Count -eq 1) {
            try {
                # Reflection updates the boxed third argument for the out bool.
                $securityValue = if ($Security -is [System.Management.Automation.PSObject]) {
                    $Security.PSObject.BaseObject
                }
                else { $Security }
                $arguments = [object[]]@($false, $Name, $false, $securityValue)
                $mutex = $createMethod[0].Invoke($null, $arguments)
                if ($mutex -is [System.Management.Automation.PSObject]) {
                    $mutex = $mutex.PSObject.BaseObject
                }
                return [PSCustomObject][ordered]@{
                    Mutex = $mutex
                    CreatedNew = [bool]$arguments[2]
                }
            }
            catch {
                $createDetail = [string]$_.Exception.Message
                if ($_.Exception.InnerException) {
                    $createDetail = "$createDetail | inner: $([string]$_.Exception.InnerException.Message)"
                }
                Write-Warning "OpenPath MutexAcl.Create diagnostic: $createDetail"
                throw 'appcontrol_transaction_security_failed'
            }
        }
    }

    $createdNew = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false, $Name, [ref]$createdNew)
        return [PSCustomObject][ordered]@{ Mutex = $mutex; CreatedNew = [bool]$createdNew }
    }
    catch { throw 'appcontrol_transaction_security_failed' }
}

function Open-OpenPathNamedMutexFullControl {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Mutex
    )

    $factoryType = Get-OpenPathMutexAclFactoryType
    if ($null -eq $factoryType) { return $Mutex }
    $openMethod = @($factoryType.GetMethods([System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static) |
        Where-Object {
            if ($_.Name -ne 'OpenExisting') { return $false }
            $parameters = $_.GetParameters()
            return $parameters.Count -eq 2 -and
                $parameters[0].ParameterType -eq [string] -and
                $parameters[1].ParameterType -eq [System.Security.AccessControl.MutexRights]
        } |
        Select-Object -First 1)
    if ($openMethod.Count -ne 1) { return $Mutex }
    try {
        $opened = $openMethod[0].Invoke($null, [object[]]@($Name, [System.Security.AccessControl.MutexRights]::FullControl))
        if ($opened -is [System.Management.Automation.PSObject]) {
            $opened = $opened.PSObject.BaseObject
        }
        if ($null -ne $opened -and $opened -ne $Mutex) {
            return $opened
        }
    }
    catch { throw 'appcontrol_transaction_security_failed' }
    return $Mutex
}

function Get-OpenPathMutexAccessControl {
    param([Parameter(Mandatory = $true)][object]$Mutex)
    try { return $Mutex.GetAccessControl() }
    catch { return Invoke-OpenPathMutexAclExtension -MethodName GetAccessControl -Mutex $Mutex }
}

function Set-OpenPathMutexAccessControl {
    param(
        [Parameter(Mandatory = $true)][object]$Mutex,
        [Parameter(Mandatory = $true)][object]$Security
    )
    try { $Mutex.SetAccessControl($Security); return }
    catch { Invoke-OpenPathMutexAclExtension -MethodName SetAccessControl -Mutex $Mutex -Security $Security }
}

function Get-OpenPathMutexSecurity {
    try {
        $security = New-Object System.Security.AccessControl.MutexSecurity
        foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
            $sid = New-Object System.Security.Principal.SecurityIdentifier($sidText)
            $rights = [System.Security.AccessControl.MutexRights]::FullControl
            $rule = New-Object System.Security.AccessControl.MutexAccessRule($sid, $rights, [System.Security.AccessControl.AccessControlType]::Allow)
            [void]$security.AddAccessRule($rule)
        }
        return $security
    }
    catch { throw 'appcontrol_transaction_security_failed' }
}

function Enter-OpenPathAppControlTransaction {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$OpenPathRoot, [int]$TimeoutMilliseconds = 15000)
    if ($TimeoutMilliseconds -lt 1) { throw 'appcontrol_transaction_security_failed' }
    $mutexName = $script:MachineMutexName
    if ($script:HeldMutexNames.ContainsKey($mutexName)) {
        return [PSCustomObject][ordered]@{ Acquired = $false; Abandoned = $false; ReasonCode = 'appcontrol_transaction_busy'; Mutex = $null; MutexName = $mutexName }
    }
    $createdNew = $false
    $mutex = $null
    $aclMutex = $null
    if (Test-OpenPathTransactionWindows) {
        $securityStage = 'security-build'
        try {
            $security = Get-OpenPathMutexSecurity
            $securityStage = 'mutex-create'
            $mutexInfo = New-OpenPathNamedMutex -Name $mutexName -Security $security
            $mutex = $mutexInfo.Mutex
            $createdNew = [bool]$mutexInfo.CreatedNew
            # MutexAcl.Create may return a handle with the constructor's
            # default rights even when it applied the requested DACL. Always
            # reopen the named object with FullControl before reading or
            # normalizing its descriptor; this also repairs a stale object
            # left by an interrupted process. Keep the Create handle for
            # WaitOne so process death remains observable as abandonment.
            $securityStage = 'mutex-open-full-control'
            $aclMutex = Open-OpenPathNamedMutexFullControl -Name $mutexName -Mutex $mutex
            $securityStage = 'mutex-set-acl'
            Set-OpenPathMutexAccessControl -Mutex $aclMutex -Security $security
            $securityStage = 'mutex-read-acl'
            $existing = Get-OpenPathMutexAccessControl -Mutex $aclMutex
            if ($null -eq $existing) { throw 'appcontrol_transaction_security_failed' }
            $allowedSids = @('S-1-5-18', 'S-1-5-32-544')
            $securityStage = 'mutex-verify-acl'
            $existingRules = @($existing.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
            foreach ($sidText in @('S-1-5-18', 'S-1-5-32-544')) {
                $hasRule = @($existingRules | Where-Object {
                        try { [string]$_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -eq $sidText }
                        catch {
                            if ($sidText -eq 'S-1-5-18') { [string]$_.IdentityReference -match '(?i)SYSTEM' }
                            else { [string]$_.IdentityReference -match '(?i)Administrators' }
                        }
                }).Count -gt 0
                if (-not $hasRule) { throw 'appcontrol_transaction_security_failed' }
            }
            foreach ($ace in $existingRules) {
                try { $aceSid = [string]$ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value }
                catch { $aceSid = [string]$ace.IdentityReference }
                if ($aceSid -and $allowedSids -notcontains $aceSid) { throw 'appcontrol_transaction_security_failed' }
            }
            if ($null -ne $aclMutex -and $aclMutex -ne $mutex) { $aclMutex.Dispose(); $aclMutex = $null }
        }
        catch {
            $securityDetail = [string]$_.Exception.Message
            if ($_.Exception.InnerException) {
                $securityDetail = "$securityDetail | inner: $([string]$_.Exception.InnerException.Message)"
            }
            Write-Warning "OpenPath AppControl mutex ACL diagnostic: stage=$securityStage; $securityDetail"
            if ($null -ne $aclMutex -and $aclMutex -ne $mutex) { $aclMutex.Dispose() }
            if ($null -ne $mutex) { $mutex.Dispose() }
            throw 'appcontrol_transaction_security_failed'
        }
    }
    else {
        try { $mutex = New-Object System.Threading.Mutex($false, $mutexName, [ref]$createdNew) }
        catch { throw 'appcontrol_transaction_security_failed' }
    }
    $abandoned = $false
    try {
        $acquired = $mutex.WaitOne($TimeoutMilliseconds)
    }
    catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
        $abandoned = $true
    }
    catch {
        $mutex.Dispose()
        return [PSCustomObject][ordered]@{ Acquired = $false; Abandoned = $false; ReasonCode = 'appcontrol_transaction_busy'; Mutex = $null; MutexName = $mutexName }
    }
    if (-not $acquired) {
        $mutex.Dispose()
        return [PSCustomObject][ordered]@{ Acquired = $false; Abandoned = $false; ReasonCode = 'appcontrol_transaction_busy'; Mutex = $null; MutexName = $mutexName }
    }
    $script:HeldMutexNames[$mutexName] = $true
    [PSCustomObject][ordered]@{ Acquired = $true; Abandoned = $abandoned; ReasonCode = $null; Mutex = $mutex; MutexName = $mutexName; OpenPathRoot = [IO.Path]::GetFullPath($OpenPathRoot) }
}

function Exit-OpenPathAppControlTransaction {
    param([AllowNull()][object]$Lock)
    if ($null -ne $Lock -and $Lock.Acquired -and $null -ne $Lock.Mutex) {
        try { $Lock.Mutex.ReleaseMutex() } catch {}
        $Lock.Mutex.Dispose()
        if ($Lock.MutexName) { [void]$script:HeldMutexNames.Remove([string]$Lock.MutexName) }
    }
}

function Get-OpenPathTransactionStateObject {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $state = $text | ConvertFrom-Json -ErrorAction Stop
    }
    catch { throw 'appcontrol_recovery_required' }
    foreach ($field in @('TransactionId', 'State', 'BeforeLocal', 'BeforeEffective', 'Candidate', 'StateFile', 'Operation', 'SchemaVersion', 'BeforeLocalSha256', 'BeforeEffectiveSha256')) {
        if ($null -eq $state.PSObject.Properties[$field] -or [string]::IsNullOrWhiteSpace([string]$state.$field)) { throw 'appcontrol_recovery_required' }
    }
    if ([int]$state.SchemaVersion -ne 2) { throw 'appcontrol_recovery_required' }
    if ($state.State -notin $script:TransactionStates) { throw 'appcontrol_recovery_required' }
    if (-not [string]::Equals([IO.Path]::GetFullPath([string]$state.StateFile), [IO.Path]::GetFullPath($Path), [StringComparison]::OrdinalIgnoreCase)) { throw 'appcontrol_recovery_required' }
    try {
        $directory = [IO.Path]::GetFullPath((Split-Path -Parent $Path)).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        foreach ($entry in @(
            @{ Name = 'BeforeLocal'; File = 'before-local.xml' },
            @{ Name = 'BeforeEffective'; File = 'before-effective.xml' },
            @{ Name = 'Candidate'; File = 'candidate.xml' },
            @{ Name = 'StateFile'; File = 'state.json' }
        )) {
            $candidatePath = [IO.Path]::GetFullPath([string]$state.($entry.Name))
            if (-not $candidatePath.StartsWith($directory, [StringComparison]::OrdinalIgnoreCase) -or
                [IO.Path]::GetFileName($candidatePath) -ne $entry.File) { throw 'appcontrol_recovery_required' }
            $state.($entry.Name) = $candidatePath
        }
        foreach ($snapshot in @(
            @{ Path = [string]$state.BeforeLocal; Hash = [string]$state.BeforeLocalSha256 },
            @{ Path = [string]$state.BeforeEffective; Hash = [string]$state.BeforeEffectiveSha256 }
        )) {
            if (-not (Test-Path -LiteralPath $snapshot.Path -PathType Leaf) -or
                -not [string]::Equals((Get-OpenPathTransactionSha256 -Bytes (Get-OpenPathTransactionBytes -Path $snapshot.Path)), $snapshot.Hash, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'appcontrol_recovery_required'
            }
        }
        if ([string]$state.State -eq 'prepared' -and
            $null -eq $state.CandidateSha256 -and
            (Test-Path -LiteralPath ([string]$state.Candidate) -PathType Leaf)) {
            throw 'appcontrol_recovery_required'
        }
        $candidateRequired = [string]$state.State -ne 'prepared' -or $null -ne $state.CandidateSha256
        if ($candidateRequired) {
            if (-not (Test-Path -LiteralPath ([string]$state.Candidate) -PathType Leaf) -or [string]::IsNullOrWhiteSpace([string]$state.CandidateSha256) -or
                -not [string]::Equals((Get-OpenPathTransactionSha256 -Bytes (Get-OpenPathTransactionBytes -Path ([string]$state.Candidate))), [string]$state.CandidateSha256, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'appcontrol_recovery_required'
            }
        }
    }
    catch { throw 'appcontrol_recovery_required' }
    $state
}

function New-OpenPathAppControlTransaction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OpenPathRoot,
        [Parameter(Mandatory = $true)][string]$LocalPolicyXml,
        [Parameter(Mandatory = $true)][string]$EffectivePolicyXml,
        [string]$Operation = 'apply',
        [hashtable]$ConfigurationMetadata = @{}
    )
    $root = Get-OpenPathTransactionRoot -OpenPathRoot $OpenPathRoot
    [IO.Directory]::CreateDirectory($root) | Out-Null
    Set-OpenPathTransactionAcl -Path $root -Directory
    $id = [guid]::NewGuid().ToString()
    $directory = Join-Path $root $id
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    Set-OpenPathTransactionAcl -Path $directory -Directory
    $localPath = Join-Path $directory 'before-local.xml'
    $effectivePath = Join-Path $directory 'before-effective.xml'
    $candidatePath = Join-Path $directory 'candidate.xml'
    $statePath = Join-Path $directory 'state.json'
    Write-OpenPathTransactionCreateNew -Path $localPath -Content $LocalPolicyXml
    Write-OpenPathTransactionCreateNew -Path $effectivePath -Content $EffectivePolicyXml
    Set-OpenPathTransactionAcl -Path $localPath
    Set-OpenPathTransactionAcl -Path $effectivePath
    $normalizedMetadata = [ordered]@{}
    foreach ($property in @($ConfigurationMetadata.Keys)) { $normalizedMetadata[$property] = $ConfigurationMetadata[$property] }
    if (-not $normalizedMetadata.Contains('RequireConfigCommit')) { $normalizedMetadata.RequireConfigCommit = $Operation -eq 'apply' }
    if ($normalizedMetadata.RequireConfigCommit -eq $true -and -not $normalizedMetadata.Contains('CommitVerified')) { $normalizedMetadata.CommitVerified = $false }
    $state = [ordered]@{
        SchemaVersion = 2
        TransactionId = $id
        Operation = $Operation
        State = 'prepared'
        BeforeLocal = $localPath
        BeforeEffective = $effectivePath
        Candidate = $candidatePath
        StateFile = $statePath
        CreatedAt = [DateTime]::UtcNow.ToString('O')
        UpdatedAt = [DateTime]::UtcNow.ToString('O')
        BeforeLocalSha256 = Get-OpenPathTransactionSha256 -Bytes (Get-OpenPathTransactionBytes -Path $localPath)
        BeforeEffectiveSha256 = Get-OpenPathTransactionSha256 -Bytes (Get-OpenPathTransactionBytes -Path $effectivePath)
        CandidateSha256 = $null
        ApplyAttempted = $false
        InternalRollbackSucceeded = $false
        ReasonCodes = @()
        ConfigurationMetadata = $normalizedMetadata
    }
    Write-OpenPathTransactionAtomic -Path $statePath -Content ($state | ConvertTo-Json -Depth 20)
    Set-OpenPathTransactionAcl -Path $statePath
    [PSCustomObject]$state
}

function Test-OpenPathTransactionTransition {
    param([Parameter(Mandatory = $true)][string]$From, [Parameter(Mandatory = $true)][string]$To)
    $allowed = @{
        prepared = @('apply-attempted', 'aborted')
        'apply-attempted' = @('applied', 'rollback-attempted', 'recovery-required')
        applied = @('validated', 'rollback-attempted', 'recovery-required')
        validated = @('committed', 'rollback-attempted', 'recovery-required')
        'rollback-attempted' = @('rolled-back', 'recovery-required')
        committed = @()
        'rolled-back' = @()
        aborted = @()
        'recovery-required' = @()
    }
    return $allowed.ContainsKey($From) -and $allowed[$From] -contains $To
}

function Set-OpenPathAppControlTransactionState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Transaction, [Parameter(Mandatory = $true)][ValidateSet('prepared', 'apply-attempted', 'applied', 'validated', 'committed', 'rollback-attempted', 'rolled-back', 'aborted', 'recovery-required')][string]$State, [string[]]$ReasonCodes = @())
    $current = Get-OpenPathTransactionStateObject -Path $Transaction.StateFile
    if (-not (Test-OpenPathTransactionTransition -From ([string]$current.State) -To $State) -and [string]$current.State -ne $State) {
        throw 'appcontrol_recovery_required'
    }
    if ([string]$current.State -eq 'apply-attempted' -and $State -eq 'prepared') { throw 'appcontrol_recovery_required' }
    $current.State = $State
    $current.ApplyAttempted = $State -in @('apply-attempted', 'applied', 'validated', 'committed', 'rollback-attempted', 'rolled-back', 'recovery-required')
    $current.UpdatedAt = [DateTime]::UtcNow.ToString('O')
    if ($ReasonCodes.Count -gt 0) { $current.ReasonCodes = @($ReasonCodes | Sort-Object -Unique) }
    Write-OpenPathTransactionAtomic -Path $Transaction.StateFile -Content ($current | ConvertTo-Json -Depth 20)
    $current
}

function Write-OpenPathAppControlTransactionCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Transaction, [Parameter(Mandatory = $true)][string]$CandidateXml)
    $current = Get-OpenPathTransactionStateObject -Path $Transaction.StateFile
    if ([string]$current.State -ne 'prepared') { throw 'appcontrol_recovery_required' }
    if (Test-Path -LiteralPath $Transaction.Candidate -PathType Leaf) { throw 'appcontrol_recovery_required' }
    Write-OpenPathTransactionCreateNew -Path $Transaction.Candidate -Content $CandidateXml
    Set-OpenPathTransactionAcl -Path $Transaction.Candidate
    $current.CandidateSha256 = Get-OpenPathTransactionSha256 -Bytes (Get-OpenPathTransactionBytes -Path $Transaction.Candidate)
    Write-OpenPathTransactionAtomic -Path $Transaction.StateFile -Content ($current | ConvertTo-Json -Depth 20)
    $current
}

function Confirm-OpenPathAppControlTransactionConfigurationCommit {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Transaction)
    $current = Get-OpenPathTransactionStateObject -Path $Transaction.StateFile
    if ($current.ConfigurationMetadata.RequireConfigCommit -ne $true -or
        [string]::IsNullOrWhiteSpace([string]$current.ConfigurationMetadata.profile) -or
        [string]::IsNullOrWhiteSpace([string]$current.ConfigurationMetadata.mode)) {
        throw 'appcontrol_commit_metadata_invalid'
    }
    if ($current.ConfigurationMetadata.PSObject.Properties['CommitVerified']) { $current.ConfigurationMetadata.CommitVerified = $true }
    else { $current.ConfigurationMetadata | Add-Member -NotePropertyName CommitVerified -NotePropertyValue $true }
    $committedAt = [DateTime]::UtcNow.ToString('O')
    if ($current.ConfigurationMetadata.PSObject.Properties['CommittedAt']) { $current.ConfigurationMetadata.CommittedAt = $committedAt }
    else { $current.ConfigurationMetadata | Add-Member -NotePropertyName CommittedAt -NotePropertyValue $committedAt }
    $current.UpdatedAt = [DateTime]::UtcNow.ToString('O')
    Write-OpenPathTransactionAtomic -Path $Transaction.StateFile -Content ($current | ConvertTo-Json -Depth 20)
    $current
}

function Invoke-OpenPathAppControlTransactionRollback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Transaction,
        [Parameter(Mandatory = $true)][scriptblock]$ApplyLocalPolicy,
        [Parameter(Mandatory = $true)][scriptblock]$ReadLocalPolicy,
        [scriptblock]$ComparePolicy
    )
    try { Set-OpenPathAppControlTransactionState -Transaction $Transaction -State 'rollback-attempted' | Out-Null }
    catch { return $false }
    try {
        $before = [string](Get-Content -LiteralPath $Transaction.BeforeLocal -Raw -ErrorAction Stop)
        & $ApplyLocalPolicy $before
        $readback = [string](& $ReadLocalPolicy)
        $same = if ($ComparePolicy) { [bool](& $ComparePolicy $before $readback) } else { $readback.Trim() -eq $before.Trim() }
        if (-not $same) {
            Set-OpenPathAppControlTransactionState -Transaction $Transaction -State 'recovery-required' -ReasonCodes @('appcontrol_rollback_verification_failed') | Out-Null
            return $false
        }
        $state = Set-OpenPathAppControlTransactionState -Transaction $Transaction -State 'rolled-back'
        $state.InternalRollbackSucceeded = $true
        Write-OpenPathTransactionAtomic -Path $Transaction.StateFile -Content ($state | ConvertTo-Json -Depth 20)
        return $true
    }
    catch {
        try { Set-OpenPathAppControlTransactionState -Transaction $Transaction -State 'recovery-required' -ReasonCodes @('appcontrol_recovery_required') | Out-Null } catch {}
        return $false
    }
}

function Get-OpenPathAppControlTransaction {
    param([Parameter(Mandatory = $true)][string]$StateFile)
    if (-not (Test-Path -LiteralPath $StateFile -PathType Leaf)) { return $null }
    Get-OpenPathTransactionStateObject -Path $StateFile
}

function Get-OpenPathAppControlPendingRecovery {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$OpenPathRoot)
    $root = Get-OpenPathTransactionRoot -OpenPathRoot $OpenPathRoot
    $items = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return @() }
    foreach ($stateFile in @(Get-ChildItem -LiteralPath $root -Filter 'state.json' -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        try {
            $state = Get-OpenPathTransactionStateObject -Path $stateFile.FullName
            if ($state.State -eq 'committed' -and $state.ConfigurationMetadata.RequireConfigCommit -eq $true) {
                if ($state.ConfigurationMetadata.CommitVerified -ne $true -or
                    [string]::IsNullOrWhiteSpace([string]$state.ConfigurationMetadata.profile) -or
                    [string]::IsNullOrWhiteSpace([string]$state.ConfigurationMetadata.mode)) {
                    [void]$items.Add([PSCustomObject][ordered]@{
                            TransactionId = [string]$state.TransactionId
                            State = 'recovery-required'
                            StateFile = [string]$state.StateFile
                            ReasonCodes = @('appcontrol_commit_metadata_invalid')
                        })
                    continue
                }
            }
            if ($state.State -notin $script:TerminalStates) { [void]$items.Add($state) }
        }
        catch {
            [void]$items.Add([PSCustomObject][ordered]@{
                TransactionId = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($stateFile.FullName))
                State = 'recovery-required'
                StateFile = $stateFile.FullName
                ReasonCodes = @('appcontrol_recovery_required')
            })
        }
    }
    foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        $statePath = Join-Path $directory.FullName 'state.json'
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
            [void]$items.Add([PSCustomObject][ordered]@{
                    TransactionId = [string]$directory.Name
                    State = 'recovery-required'
                    StateFile = $statePath
                    ReasonCodes = @('appcontrol_recovery_required')
                })
        }
    }
    return $items.ToArray()
}

function Invoke-OpenPathAppControlTransactionRecovery {
    <#
    Reconcile journals while the caller already owns the machine mutex.
    A prepared journal has not crossed the mutation boundary and can be
    aborted.  Every later state is resolved only when the caller can read and
    restore the local policy and prove the readback is the immutable
    before-local snapshot.  A candidate that merely looks valid is never
    committed after a process interruption.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OpenPathRoot,
        [Parameter(Mandatory = $true)][scriptblock]$ApplyLocalPolicy,
        [Parameter(Mandatory = $true)][scriptblock]$ReadLocalPolicy,
        [Parameter(Mandatory = $true)][scriptblock]$ComparePolicy,
        [scriptblock]$RestoreConfiguration
    )
    $pending = @(Get-OpenPathAppControlPendingRecovery -OpenPathRoot $OpenPathRoot)
    if ($pending.Count -eq 0) { return [pscustomobject][ordered]@{ Resolved = $true; Pending = @() } }
    $unresolved = New-Object System.Collections.Generic.List[object]
    foreach ($item in $pending) {
        $state = [string]$item.State
        if ($state -eq 'recovery-required' -or
            $null -eq $item.PSObject.Properties['StateFile'] -or
            $null -eq $item.PSObject.Properties['BeforeLocal']) {
            [void]$unresolved.Add($item)
            continue
        }
        if ($state -eq 'prepared') {
            try {
                Set-OpenPathAppControlTransactionState -Transaction $item -State 'aborted' | Out-Null
            }
            catch {
                [void]$unresolved.Add([pscustomobject][ordered]@{ TransactionId = [string]$item.TransactionId; State = 'recovery-required'; ReasonCodes = @('appcontrol_recovery_required') })
            }
            continue
        }
        if ($state -notin @('apply-attempted', 'applied', 'validated', 'rollback-attempted')) {
            [void]$unresolved.Add($item)
            continue
        }
        try {
            # Read before deciding whether the interrupted mutation is
            # attributable.  Unknown/drifted policy is never overwritten.
            $current = [string](& $ReadLocalPolicy)
            $before = [string](Get-Content -LiteralPath $item.BeforeLocal -Raw -ErrorAction Stop)
            $candidate = [string](Get-Content -LiteralPath $item.Candidate -Raw -ErrorAction Stop)
            $currentIsBefore = [bool](& $ComparePolicy $before $current)
            $currentIsCandidate = [bool](& $ComparePolicy $candidate $current)
            if (-not $currentIsBefore -and -not $currentIsCandidate) {
                throw 'appcontrol_recovery_drift_detected'
            }
            Set-OpenPathAppControlTransactionState -Transaction $item -State 'rollback-attempted' -ReasonCodes @('appcontrol_recovery_required') | Out-Null
            & $ApplyLocalPolicy $before
            $readback = [string](& $ReadLocalPolicy)
            if (-not [bool](& $ComparePolicy $before $readback)) {
                throw 'appcontrol_rollback_verification_failed'
            }
            if ($RestoreConfiguration) { & $RestoreConfiguration $item }
            Set-OpenPathAppControlTransactionState -Transaction $item -State 'rolled-back' -ReasonCodes @('appcontrol_recovery_required') | Out-Null
        }
        catch {
            try {
                Set-OpenPathAppControlTransactionState -Transaction $item -State 'recovery-required' -ReasonCodes @('appcontrol_recovery_required') | Out-Null
            }
            catch {}
            [void]$unresolved.Add([pscustomobject][ordered]@{ TransactionId = [string]$item.TransactionId; State = 'recovery-required'; ReasonCodes = @('appcontrol_recovery_required') })
        }
    }
    [pscustomobject][ordered]@{ Resolved = $unresolved.Count -eq 0; Pending = $unresolved.ToArray() }
}

Export-ModuleMember -Function Enter-OpenPathAppControlTransaction, Exit-OpenPathAppControlTransaction, New-OpenPathAppControlTransaction, Set-OpenPathAppControlTransactionState, Write-OpenPathAppControlTransactionCandidate, Confirm-OpenPathAppControlTransactionConfigurationCommit, Invoke-OpenPathAppControlTransactionRollback, Get-OpenPathAppControlTransaction, Get-OpenPathAppControlPendingRecovery, Invoke-OpenPathAppControlTransactionRecovery
