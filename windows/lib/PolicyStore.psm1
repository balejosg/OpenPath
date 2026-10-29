# OpenPath policy store for Windows
# Single write path for OpenPath values under HKLM\SOFTWARE\Policies.
# Merges each value into the local GPO (Registry.pol + gpt.ini bump) so a Registry CSE
# refresh cannot overwrite it, mirrors it into the registry, and refuses to write when a
# domain GPO or MDM owns the value.

. (Join-Path $PSScriptRoot 'internal\WindowsRoot.ps1')
$script:OpenPathRoot = Resolve-OpenPathWindowsRoot
Import-Module "$PSScriptRoot\Common.psm1" -ErrorAction Stop

# Store-wide lock: every Registry.pol + ledger read-modify-write runs under this mutex, waits at most
# LocalGpoLockTimeoutMs, and retries a merge when another writer (e.g. AppLocker) replaced Registry.pol.
$script:LocalGpoMutexName = 'Global\OpenPath-LocalGpo-v1'
$script:LocalGpoLockTimeoutMs = 30000
$script:LocalGpoMaxWriteAttempts = 3

$script:PolicyStoreHelperRoot = Join-Path $PSScriptRoot 'internal'
. (Join-Path $script:PolicyStoreHelperRoot 'PolicyStore.RegistryPol.ps1')
. (Join-Path $script:PolicyStoreHelperRoot 'PolicyStore.Owner.ps1')

function Get-OpenPathLocalGpoPaths {
    <#
    .SYNOPSIS
    Returns the local GPO Registry.pol and gpt.ini paths (mockable for tests).
    #>
    $systemRoot = [string]$env:SystemRoot
    if ([string]::IsNullOrWhiteSpace($systemRoot)) { $systemRoot = 'C:\Windows' }
    $groupPolicy = Join-Path (Join-Path $systemRoot 'System32') 'GroupPolicy'
    return [pscustomobject]@{
        RegistryPol = Join-Path (Join-Path $groupPolicy 'Machine') 'Registry.pol'
        GptIni = Join-Path $groupPolicy 'gpt.ini'
    }
}

# The ledger lives in the registry, outside the install root, so a reinstall or an admin wiping
# <OpenPathRoot>\data cannot orphan OpenPath's own local GPO entries as "foreign".
$script:PolicyStoreRegistryPath = 'HKLM:\SOFTWARE\OpenPath\PolicyStore'
$script:PolicyStoreLedgerValueName = 'Ledger'

function Get-OpenPathPolicyStoreLegacyLedgerPath {
    # Ledger file used by earlier builds; migrated into the registry once, then deleted.
    return (Join-Path (Join-Path $script:OpenPathRoot 'data') 'policy-store-ledger.json')
}

function Read-OpenPathPolicyStoreLedgerText {
    # Raw ledger JSON from the registry, or $null when absent (mockable). Throws when unreadable.
    $path = $script:PolicyStoreRegistryPath
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $props = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
    if (-not $props -or -not $props.PSObject.Properties[$script:PolicyStoreLedgerValueName]) { return $null }
    return [string]$props.($script:PolicyStoreLedgerValueName)
}

function Write-OpenPathPolicyStoreLedgerText {
    # Stores the raw ledger JSON as a REG_SZ value (mockable). Throws on failure.
    param([Parameter(Mandatory = $true)][string]$Text)

    $path = $script:PolicyStoreRegistryPath
    if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -Path $path -Name $script:PolicyStoreLedgerValueName -PropertyType String -Value $Text -Force -ErrorAction Stop | Out-Null
}

function Get-OpenPathPolicyStoreLedgerSourceText {
    # Registry ledger first; otherwise migrates the legacy data\ file once (registry write, then delete).
    $text = Read-OpenPathPolicyStoreLedgerText
    if ($null -ne $text) { return $text }

    $legacyPath = Get-OpenPathPolicyStoreLegacyLedgerPath
    if (-not $legacyPath -or -not (Test-Path -LiteralPath $legacyPath -PathType Leaf)) { return $null }
    $legacyText = [System.IO.File]::ReadAllText($legacyPath)
    try {
        Write-OpenPathPolicyStoreLedgerText -Text $legacyText
        Remove-Item -LiteralPath $legacyPath -Force -ErrorAction Stop
        Write-OpenPathLog "Policy store: ledger migrated from $legacyPath into the registry" -Level INFO
    }
    catch {
        Write-OpenPathLog "Policy store: could not migrate the ledger file $legacyPath into the registry; using it as is ($($_.Exception.Message))" -Level WARN
    }
    return $legacyText
}

function Remove-OpenPathPolicyStoreLedger {
    <#
    .SYNOPSIS
    Deletes the policy store ledger (registry key and any legacy file). Uninstall only. Never throws.
    #>
    [CmdletBinding()]
    param()

    try {
        if (Test-Path -LiteralPath $script:PolicyStoreRegistryPath) {
            Remove-Item -LiteralPath $script:PolicyStoreRegistryPath -Recurse -Force -ErrorAction Stop
        }
        $legacyPath = Get-OpenPathPolicyStoreLegacyLedgerPath
        if ($legacyPath -and (Test-Path -LiteralPath $legacyPath -PathType Leaf)) {
            Remove-Item -LiteralPath $legacyPath -Force -ErrorAction Stop
        }
        return $true
    }
    catch {
        Write-OpenPathLog "Policy store: could not delete the ledger ($($_.Exception.Message))" -Level WARN
        return $false
    }
}

function Start-OpenPathGpUpdateProcess {
    # Isolated process launch so tests can assert the argument string. stdin is redirected and
    # answered with N, so a "restart now?" prompt (policies that need a reboot) can never block.
    param([string]$Arguments, [int]$TimeoutSeconds = 120, [string]$FilePath = 'gpupdate.exe')

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    # Output stays hidden as with the former hidden window; both pipes are drained so they cannot fill up.
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $null = $process.StandardOutput.ReadToEndAsync()
        $null = $process.StandardError.ReadToEndAsync()
        try {
            $process.StandardInput.WriteLine('N')
            $process.StandardInput.WriteLine('N')
            $process.StandardInput.Close()
        }
        catch { $null = $_ }
        $waitMs = ([Math]::Max($TimeoutSeconds, 0) + 30) * 1000
        if (-not $process.WaitForExit($waitMs)) {
            try { $process.Kill() } catch { $null = $_ }
            return -1
        }
        return [int]$process.ExitCode
    }
    finally { $process.Dispose() }
}

# ---- internal helpers -------------------------------------------------------

function Test-OpenPathPolicyNameEqual {
    param([string]$A, [string]$B)
    return [string]::Equals($A, $B, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-OpenPathPolicyKeyEqual {
    param([string]$A, [string]$B)
    return [string]::Equals(([string]$A).Trim('\'), ([string]$B).Trim('\'), [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-OpenPathPolicyEntryEqual {
    param($A, $B)
    if ($A.Key -cne $B.Key -or $A.ValueName -cne $B.ValueName -or [uint32]$A.Type -ne [uint32]$B.Type) { return $false }
    $da = [byte[]]$A.Data
    $db = [byte[]]$B.Data
    if ($da.Length -ne $db.Length) { return $false }
    for ($i = 0; $i -lt $da.Length; $i++) { if ($da[$i] -ne $db[$i]) { return $false } }
    return $true
}

function Test-OpenPathPolicyEntrySequenceEqual {
    param([object[]]$A, [object[]]$B)
    if ($A.Count -ne $B.Count) { return $false }
    for ($i = 0; $i -lt $A.Count; $i++) {
        if (-not (Test-OpenPathPolicyEntryEqual -A $A[$i] -B $B[$i])) { return $false }
    }
    return $true
}

function Test-OpenPathPolicyValueInSet {
    param([string[]]$Set, [AllowNull()][string]$Text)
    if ($null -eq $Text) { return $false }
    foreach ($item in @($Set)) { if (Test-OpenPathPolicyNameEqual $item $Text) { return $true } }
    return $false
}

function New-OpenPathPolicyStoreResult {
    return [pscustomobject]@{ Applied = $false; Changed = $false; Owner = ''; GpoName = ''; FailureCode = '' }
}

function Get-OpenPathPolicyStoreGate {
    # Resolves the owner of a value. Blocked=$true means no write may happen.
    # A caller that already resolved the owner (Set-ChromePolicy for its legacy check) passes it in.
    param([string]$Key, [AllowEmptyString()][string]$ValueName, [string]$PolPath, [AllowNull()][object]$PrecomputedOwner = $null)

    $gate = [pscustomobject]@{ Blocked = $false; FailureCode = ''; Owner = ''; GpoName = '' }
    try {
        if ($PrecomputedOwner) { $owner = $PrecomputedOwner }
        else { $owner = Get-OpenPathPolicyValueOwner -Key $Key -ValueName $ValueName -LocalPolPath $PolPath }
    }
    catch {
        if ([string]$_.Exception.Message -like 'local-gpo-unreadable*') {
            $gate.Blocked = $true
            $gate.FailureCode = 'local-gpo-unreadable'
            Write-OpenPathLog "Policy store: Registry.pol unreadable, no writes for $Key ($($_.Exception.Message))" -Level WARN
            return $gate
        }
        throw
    }

    $gate.Owner = [string]$owner.Owner
    $gate.GpoName = [string]$owner.GpoName
    if ($gate.Owner -eq 'DomainGpo' -or $gate.Owner -eq 'Mdm') {
        $gate.Blocked = $true
        $gate.FailureCode = 'policy-externally-managed'
        Write-OpenPathLog "Policy store: $Key|$ValueName is managed by $($gate.Owner) '$($gate.GpoName)'; not writing" -Level WARN
    }
    return $gate
}

function Enter-OpenPathLocalGpoLock {
    # Takes the store-wide mutex that serializes every Registry.pol + ledger read-modify-write.
    # Returns the held mutex, or $null when it stayed busy for the bounded wait (callers then report
    # local-gpo-busy and write nothing). An abandoned mutex counts as acquired.
    param([int]$TimeoutMs = $script:LocalGpoLockTimeoutMs)

    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, $script:LocalGpoMutexName)
        $acquired = $false
        try {
            $acquired = $mutex.WaitOne($TimeoutMs)
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
            Write-OpenPathLog 'Policy store: previous holder of the local GPO lock exited without releasing it; continuing' -Level WARN
        }
        if ($acquired) { return $mutex }
        $mutex.Dispose()
        Write-OpenPathLog "Policy store: local GPO lock still busy after $TimeoutMs ms; not writing" -Level WARN
        return $null
    }
    catch {
        if ($mutex) { $mutex.Dispose() }
        Write-OpenPathLog "Policy store: cannot take the local GPO lock ($($_.Exception.Message)); not writing" -Level WARN
        return $null
    }
}

function Exit-OpenPathLocalGpoLock {
    param([AllowNull()][object]$Lock)

    if (-not $Lock) { return }
    try { $Lock.ReleaseMutex() } catch { $null = $_ }
    $Lock.Dispose()
}

function Read-OpenPathPolicyStoreEntries {
    # Plain array of Registry.pol entries; throws local-gpo-unreadable on a corrupt file.
    param([string]$PolPath)
    return @(Read-OpenPathRegistryPolFile -Path $PolPath)
}

function Read-OpenPathPolicyStoreBytes {
    # Raw Registry.pol bytes, or $null when the file does not exist. -BeforeReplace marks the
    # optimistic-concurrency re-read right before a replace. Throws local-gpo-unreadable.
    param([string]$PolPath, [switch]$BeforeReplace)

    if (-not (Test-Path -LiteralPath $PolPath -PathType Leaf)) { return $null }
    try { $bytes = [System.IO.File]::ReadAllBytes($PolPath) }
    catch { throw "local-gpo-unreadable: cannot read ${PolPath}: $($_.Exception.Message)" }
    return , $bytes
}

function Read-OpenPathPolicyStoreSnapshot {
    # The bytes a merge is computed from plus their parsed entries. Throws local-gpo-unreadable.
    param([string]$PolPath)

    $bytes = Read-OpenPathPolicyStoreBytes -PolPath $PolPath
    $entries = @()
    if ($null -ne $bytes) { $entries = @(ConvertFrom-OpenPathRegistryPolBytes -Bytes $bytes -Path $PolPath) }
    return [pscustomobject]@{ Bytes = $bytes; Entries = $entries }
}

function Test-OpenPathPolicyStoreBaseCurrent {
    # True when Registry.pol still holds exactly the bytes a merge was computed from (AppLocker and
    # other writers may replace the file without taking the OpenPath lock).
    param([string]$PolPath, [AllowNull()][byte[]]$BaseBytes)

    $current = Read-OpenPathPolicyStoreBytes -PolPath $PolPath -BeforeReplace
    if ($null -eq $current -or $null -eq $BaseBytes) { return ($null -eq $current -and $null -eq $BaseBytes) }
    return ([Convert]::ToBase64String([byte[]]$current) -ceq [Convert]::ToBase64String($BaseBytes))
}

function Save-OpenPathPolicyStoreEntries {
    # Never throws. Conflict=$true (nothing written) when Registry.pol changed since BaseBytes were read.
    # Written=$true once Registry.pol was replaced; FailureCode reports a write or gpt.ini bump failure.
    param([object[]]$Entries, [string]$PolPath, [string]$GptIniPath, [AllowNull()][byte[]]$BaseBytes)

    $out = [pscustomobject]@{ Written = $false; FailureCode = ''; Conflict = $false }
    try {
        if (-not (Test-OpenPathPolicyStoreBaseCurrent -PolPath $PolPath -BaseBytes $BaseBytes)) {
            Write-OpenPathLog 'Policy store: Registry.pol changed while merging; recomputing from the new content' -Level INFO
            $out.Conflict = $true
            return $out
        }
    }
    catch {
        Write-OpenPathLog "Policy store: Registry.pol unreadable before replace ($($_.Exception.Message))" -Level ERROR
        $out.FailureCode = 'local-gpo-unreadable'
        return $out
    }
    try {
        Write-OpenPathRegistryPolFile -Path $PolPath -Entries $Entries
        $out.Written = $true
    }
    catch {
        Write-OpenPathLog "Policy store: Registry.pol write failed ($($_.Exception.Message))" -Level ERROR
        $out.FailureCode = 'local-gpo-write-failed'
        return $out
    }
    try { Step-OpenPathLocalGpoMachineVersion -GptIniPath $GptIniPath | Out-Null }
    catch {
        Write-OpenPathLog "Policy store: gpt.ini version bump failed ($($_.Exception.Message))" -Level ERROR
        $out.FailureCode = 'gpt-ini-bump-failed'
    }
    return $out
}

function Get-OpenPathPolicyStoreBusyMessage {
    param([string]$Target)
    return "Policy store: Registry.pol kept changing while writing $Target; giving up after $($script:LocalGpoMaxWriteAttempts) attempts"
}

function Get-OpenPathPolicyTypeName {
    param([uint32]$Type)
    switch ([int]$Type) {
        1 { return 'String' }
        7 { return 'MultiString' }
        4 { return 'DWord' }
        default { return $null }
    }
}

function Read-OpenPathPolicyStoreLedger {
    # Missing or corrupt ledger is treated as empty; never throws.
    # Lists: OpenPath-owned numbered values per list key. LastOwners: last observed owner per value.
    # Originals: per scalar "Key|ValueName", the Registry.pol state before OpenPath's first write.
    $ledger = [pscustomobject]@{ Lists = @{}; LastOwners = @{}; Originals = @{} }
    try {
        $text = Get-OpenPathPolicyStoreLedgerSourceText
        if ([string]::IsNullOrWhiteSpace($text)) { return $ledger }
        $json = $text | ConvertFrom-Json -ErrorAction Stop
        if ($json -and $json.lists) {
            foreach ($p in $json.lists.PSObject.Properties) { $ledger.Lists[[string]$p.Name] = @($p.Value | ForEach-Object { [string]$_ }) }
        }
        if ($json -and $json.lastOwners) {
            foreach ($p in $json.lastOwners.PSObject.Properties) { $ledger.LastOwners[[string]$p.Name] = [string]$p.Value }
        }
        if ($json -and $json.originals) {
            foreach ($p in $json.originals.PSObject.Properties) {
                $o = $p.Value
                if ($o -and [bool]$o.inPol) {
                    $ledger.Originals[[string]$p.Name] = [pscustomobject]@{
                        InPol = $true
                        Type = [uint32]$o.type
                        Data = [byte[]][Convert]::FromBase64String([string]$o.dataBase64)
                    }
                }
                elseif ($o) {
                    $ledger.Originals[[string]$p.Name] = [pscustomobject]@{ InPol = $false; Type = [uint32]0; Data = [byte[]]@() }
                }
            }
        }
    }
    catch {
        Write-OpenPathLog "Policy store: ledger unreadable, treating as empty ($($_.Exception.Message))" -Level WARN
        $ledger = [pscustomobject]@{ Lists = @{}; LastOwners = @{}; Originals = @{} }
    }
    return $ledger
}

function Write-OpenPathPolicyStoreLedger {
    param($Ledger)

    $lists = [ordered]@{}
    foreach ($k in ($Ledger.Lists.Keys | Sort-Object)) { $lists[[string]$k] = [string[]]@($Ledger.Lists[$k]) }
    $owners = [ordered]@{}
    foreach ($k in ($Ledger.LastOwners.Keys | Sort-Object)) { $owners[[string]$k] = [string]$Ledger.LastOwners[$k] }
    $originals = [ordered]@{}
    if ($Ledger.PSObject.Properties['Originals'] -and $Ledger.Originals) {
        foreach ($k in ($Ledger.Originals.Keys | Sort-Object)) {
            $o = $Ledger.Originals[$k]
            if ($o.InPol) {
                $originals[[string]$k] = [ordered]@{ inPol = $true; type = [int64][uint32]$o.Type; dataBase64 = [Convert]::ToBase64String([byte[]]$o.Data) }
            }
            else {
                $originals[[string]$k] = [ordered]@{ inPol = $false }
            }
        }
    }
    $json = ([ordered]@{ lists = $lists; lastOwners = $owners; originals = $originals } | ConvertTo-Json -Depth 5 -Compress)
    Write-OpenPathPolicyStoreLedgerText -Text $json
}

function Get-OpenPathPolicyStoreOriginalId {
    param([string]$Key, [string]$ValueName)
    return "$($Key.Trim('\'))|$ValueName"
}

function Get-OpenPathPolicyStoreOriginal {
    <#
    .SYNOPSIS
    Returns the Registry.pol state of a scalar value before OpenPath's first write ({ InPol; Type; Data }), or $null when none is recorded.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$ValueName
    )

    $ledger = Read-OpenPathPolicyStoreLedger
    $id = Get-OpenPathPolicyStoreOriginalId -Key $Key -ValueName $ValueName
    if ($ledger.Originals.ContainsKey($id)) { return $ledger.Originals[$id] }
    return $null
}

function Get-OpenPathPolicyStoreLastOwner {
    <#
    .SYNOPSIS
    Returns the last recorded owner of a policy value from the ledger, or '' when unknown. Never throws.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$ValueName
    )

    try {
        $ledger = Read-OpenPathPolicyStoreLedger
        $id = "$($Key.Trim('\'))|$ValueName"
        if ($ledger.LastOwners.ContainsKey($id)) { return [string]$ledger.LastOwners[$id] }
    }
    catch { }
    return ''
}

function Set-OpenPathPolicyStoreLastOwner {
    <#
    .SYNOPSIS
    Records the last observed owner of a policy value in the ledger (preserving managed lists). Never throws.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$ValueName,
        [Parameter(Mandatory = $true)][string]$Owner
    )

    $lock = Enter-OpenPathLocalGpoLock
    if (-not $lock) { return $false }
    try {
        $ledger = Read-OpenPathPolicyStoreLedger
        $ledger.LastOwners["$($Key.Trim('\'))|$ValueName"] = $Owner
        Write-OpenPathPolicyStoreLedger -Ledger $ledger
        return $true
    }
    catch {
        Write-OpenPathLog "Policy store: could not record owner for $Key|$ValueName ($($_.Exception.Message))" -Level WARN
        return $false
    }
    finally { Exit-OpenPathLocalGpoLock -Lock $lock }
}

function Set-OpenPathPolicyRegistryValue {
    param([string]$Key, [string]$ValueName, [string]$Type, $Value)

    $path = "HKLM:\$($Key.Trim('\'))"
    if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
    switch ($Type) {
        'DWord' { $typed = [int]$Value }
        'MultiString' { $typed = [string[]]@($Value) }
        default { $typed = [string]$Value }
    }
    New-ItemProperty -Path $path -Name $ValueName -PropertyType $Type -Value $typed -Force -ErrorAction Stop | Out-Null
}

function Get-OpenPathPolicyRegistryProperties {
    param([string]$Key)
    $path = "HKLM:\$($Key.Trim('\'))"
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $props = Get-ItemProperty -LiteralPath $path -ErrorAction SilentlyContinue
    if (-not $props) { return @() }
    return @($props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })
}

function Remove-OpenPathPolicyRegistryValue {
    # Returns $true when a registry value was present and removed.
    param([string]$Key, [string]$ValueName)
    $match = @(Get-OpenPathPolicyRegistryProperties -Key $Key | Where-Object { Test-OpenPathPolicyNameEqual $_.Name $ValueName })
    if ($match.Count -eq 0) { return $false }
    Remove-ItemProperty -Path "HKLM:\$($Key.Trim('\'))" -Name $match[0].Name -Force -ErrorAction Stop
    return $true
}

# ---- public API -------------------------------------------------------------

function Get-OpenPathManagedPolicyValue {
    <#
    .SYNOPSIS
    Reads a policy value from local Registry.pol first, then from the registry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$ValueName
    )

    $paths = Get-OpenPathLocalGpoPaths
    try {
        $entry = Read-OpenPathPolicyStoreEntries -PolPath $paths.RegistryPol |
            Where-Object { (Test-OpenPathPolicyKeyEqual $_.Key $Key) -and (Test-OpenPathPolicyNameEqual $_.ValueName $ValueName) } |
            Select-Object -First 1
        if ($entry) {
            $typeName = Get-OpenPathPolicyTypeName -Type $entry.Type
            if ($typeName) {
                $polValue = ConvertFrom-OpenPathRegistryPolData -Type $entry.Type -Data $entry.Data
                if ($typeName -eq 'MultiString') { $polValue = [string[]]@($polValue) }
                return [pscustomobject]@{ Type = $typeName; Value = $polValue; Source = 'LocalGpo' }
            }
        }
    }
    catch {
        Write-OpenPathLog "Policy store: cannot read Registry.pol, falling back to registry ($($_.Exception.Message))" -Level WARN
    }

    $prop = Get-OpenPathPolicyRegistryProperties -Key $Key | Where-Object { Test-OpenPathPolicyNameEqual $_.Name $ValueName } | Select-Object -First 1
    if ($prop) {
        $value = $prop.Value
        $typeName = 'String'
        if ($value -is [int] -or $value -is [uint32]) { $typeName = 'DWord' }
        elseif ($value -is [array]) { $typeName = 'MultiString'; $value = [string[]]@($value) }
        return [pscustomobject]@{ Type = $typeName; Value = $value; Source = 'Registry' }
    }
    return [pscustomobject]@{ Type = $null; Value = $null; Source = 'None' }
}

function Set-OpenPathManagedPolicyValue {
    <#
    .SYNOPSIS
    Writes a value into local Registry.pol (bumping gpt.ini only when bytes change) and mirrors it in the registry.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$ValueName,
        [Parameter(Mandatory = $true)][ValidateSet('String', 'MultiString', 'DWord')][string]$Type,
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowEmptyCollection()][object]$Value,

        # The write hands the value back (e.g. Firefox removal keeping only vendor entries): record no
        # original and clear any recorded one afterwards.
        [switch]$ReleaseOriginal
    )

    $result = New-OpenPathPolicyStoreResult
    $lock = Enter-OpenPathLocalGpoLock
    if (-not $lock) { $result.FailureCode = 'local-gpo-busy'; return $result }
    try {
        $paths = Get-OpenPathLocalGpoPaths
        $gate = Get-OpenPathPolicyStoreGate -Key $Key -ValueName $ValueName -PolPath $paths.RegistryPol
        $result.Owner = $gate.Owner
        $result.GpoName = $gate.GpoName
        if ($gate.Blocked) { $result.FailureCode = $gate.FailureCode; return $result }

        $data = ConvertTo-OpenPathRegistryPolData -Type $Type -Value $Value
        $ledger = Read-OpenPathPolicyStoreLedger
        $originalId = Get-OpenPathPolicyStoreOriginalId -Key $Key -ValueName $ValueName
        $confirmed = $false
        $done = $false
        for ($attempt = 1; $attempt -le $script:LocalGpoMaxWriteAttempts; $attempt++) {
            try { $snapshot = Read-OpenPathPolicyStoreSnapshot -PolPath $paths.RegistryPol }
            catch {
                if ([string]$_.Exception.Message -like 'local-gpo-unreadable*') { $result.FailureCode = 'local-gpo-unreadable'; return $result }
                throw
            }
            $entries = @($snapshot.Entries)

            $newEntries = New-Object System.Collections.ArrayList
            $found = $false
            foreach ($entry in $entries) {
                if (-not $found -and (Test-OpenPathPolicyKeyEqual $entry.Key $Key) -and (Test-OpenPathPolicyNameEqual $entry.ValueName $ValueName)) {
                    $found = $true
                    [void]$newEntries.Add([pscustomobject]@{ Key = $entry.Key; ValueName = $entry.ValueName; Type = $data.Type; Data = $data.Data })
                }
                else { [void]$newEntries.Add($entry) }
            }
            if (-not $found) {
                [void]$newEntries.Add([pscustomobject]@{ Key = $Key.Trim('\'); ValueName = $ValueName; Type = $data.Type; Data = $data.Data })
            }
            $changed = -not (Test-OpenPathPolicyEntrySequenceEqual -A $entries -B @($newEntries.ToArray()))

            if (-not $confirmed) {
                if (-not $PSCmdlet.ShouldProcess("$Key|$ValueName", 'Set managed policy value')) { return $result }
                $confirmed = $true
            }
            if (-not $changed) { $done = $true; break }

            # Ledger first (fail closed): remember the Registry.pol state before OpenPath's first write so
            # Remove can hand a vendor value back. An existing original is never overwritten.
            if (-not $ReleaseOriginal -and -not $ledger.Originals.ContainsKey($originalId)) {
                $current = @($entries | Where-Object { (Test-OpenPathPolicyKeyEqual $_.Key $Key) -and (Test-OpenPathPolicyNameEqual $_.ValueName $ValueName) } | Select-Object -First 1)
                if ($current.Count -gt 0) {
                    $ledger.Originals[$originalId] = [pscustomobject]@{ InPol = $true; Type = [uint32]$current[0].Type; Data = [byte[]]$current[0].Data }
                }
                else {
                    $ledger.Originals[$originalId] = [pscustomobject]@{ InPol = $false; Type = [uint32]0; Data = [byte[]]@() }
                }
                try { Write-OpenPathPolicyStoreLedger -Ledger $ledger }
                catch {
                    $ledger.Originals.Remove($originalId)
                    Write-OpenPathLog "Policy store: ledger write failed for $Key|$ValueName, aborting without changes ($($_.Exception.Message))" -Level ERROR
                    $result.FailureCode = 'ledger-write-failed'
                    return $result
                }
            }

            $save = Save-OpenPathPolicyStoreEntries -Entries @($newEntries.ToArray()) -PolPath $paths.RegistryPol -GptIniPath $paths.GptIni -BaseBytes $snapshot.Bytes
            if ($save.Conflict) { continue }
            if (-not $save.Written) { $result.FailureCode = $save.FailureCode; return $result }
            $result.Changed = $true
            if ($save.FailureCode) { $result.FailureCode = $save.FailureCode; return $result }
            $done = $true
            break
        }
        if (-not $done) {
            Write-OpenPathLog (Get-OpenPathPolicyStoreBusyMessage -Target "$Key|$ValueName") -Level WARN
            $result.FailureCode = 'local-gpo-busy'
            return $result
        }

        try { Set-OpenPathPolicyRegistryValue -Key $Key -ValueName $ValueName -Type $Type -Value $Value }
        catch {
            Write-OpenPathLog "Policy store: registry mirror failed for $Key|$ValueName ($($_.Exception.Message))" -Level ERROR
            $result.FailureCode = 'registry-write-failed'
            return $result
        }
        if ($ReleaseOriginal -and $ledger.Originals.ContainsKey($originalId)) {
            $ledger.Originals.Remove($originalId)
            try { Write-OpenPathPolicyStoreLedger -Ledger $ledger }
            catch { Write-OpenPathLog "Policy store: could not clear the original of $Key|$ValueName ($($_.Exception.Message))" -Level WARN }
        }
        $result.Applied = $true
        return $result
    }
    finally { Exit-OpenPathLocalGpoLock -Lock $lock }
}

function Remove-OpenPathManagedPolicyValue {
    <#
    .SYNOPSIS
    Removes OpenPath's value from local Registry.pol and the registry, restoring the vendor value it replaced.
    .DESCRIPTION
    When the ledger recorded that Registry.pol held another value before OpenPath's first write, that
    entry is put back (in Registry.pol and the registry mirror); when it recorded no entry, or recorded
    nothing at all (lost or legacy ledger), the value is deleted. The recorded original is then cleared.
    -DiscardOriginal always deletes. -KeepRegistryValue removes only the Registry.pol entry and leaves
    the registry value for the caller to overwrite in place (no delete-then-recreate window).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$ValueName,
        [switch]$DiscardOriginal,
        [switch]$KeepRegistryValue
    )

    $result = [pscustomobject]@{ Removed = $false; Restored = $false; FailureCode = '' }
    $lock = Enter-OpenPathLocalGpoLock
    if (-not $lock) { $result.FailureCode = 'local-gpo-busy'; return $result }
    try {
        $paths = Get-OpenPathLocalGpoPaths
        $gate = Get-OpenPathPolicyStoreGate -Key $Key -ValueName $ValueName -PolPath $paths.RegistryPol
        if ($gate.Blocked) { $result.FailureCode = $gate.FailureCode; return $result }

        $ledger = Read-OpenPathPolicyStoreLedger
        $originalId = Get-OpenPathPolicyStoreOriginalId -Key $Key -ValueName $ValueName
        $original = $null
        if ($ledger.Originals.ContainsKey($originalId)) { $original = $ledger.Originals[$originalId] }
        $restore = [bool]($original -and $original.InPol -and -not $DiscardOriginal)

        $done = $false
        for ($attempt = 1; $attempt -le $script:LocalGpoMaxWriteAttempts; $attempt++) {
            try { $snapshot = Read-OpenPathPolicyStoreSnapshot -PolPath $paths.RegistryPol }
            catch {
                if ([string]$_.Exception.Message -like 'local-gpo-unreadable*') { $result.FailureCode = 'local-gpo-unreadable'; return $result }
                throw
            }
            $entries = @($snapshot.Entries)
            $newEntries = New-Object System.Collections.ArrayList
            $placed = $false
            foreach ($entry in $entries) {
                if ((Test-OpenPathPolicyKeyEqual $entry.Key $Key) -and (Test-OpenPathPolicyNameEqual $entry.ValueName $ValueName)) {
                    if ($restore -and -not $placed) {
                        [void]$newEntries.Add([pscustomobject]@{ Key = $entry.Key; ValueName = $entry.ValueName; Type = [uint32]$original.Type; Data = [byte[]]$original.Data })
                        $placed = $true
                    }
                    continue
                }
                [void]$newEntries.Add($entry)
            }
            if ($restore -and -not $placed) {
                [void]$newEntries.Add([pscustomobject]@{ Key = $Key.Trim('\'); ValueName = $ValueName; Type = [uint32]$original.Type; Data = [byte[]]$original.Data })
            }
            $kept = @($newEntries.ToArray())
            if (Test-OpenPathPolicyEntrySequenceEqual -A $entries -B $kept) { $done = $true; break }

            $save = Save-OpenPathPolicyStoreEntries -Entries $kept -PolPath $paths.RegistryPol -GptIniPath $paths.GptIni -BaseBytes $snapshot.Bytes
            if ($save.Conflict) { continue }
            if (-not $save.Written) { $result.FailureCode = $save.FailureCode; return $result }
            $result.Removed = $true
            if ($save.FailureCode) { $result.FailureCode = $save.FailureCode }
            $done = $true
            break
        }
        if (-not $done) {
            Write-OpenPathLog (Get-OpenPathPolicyStoreBusyMessage -Target "$Key|$ValueName") -Level WARN
            $result.FailureCode = 'local-gpo-busy'
            return $result
        }

        try {
            $typeName = $null
            if ($restore) { $typeName = Get-OpenPathPolicyTypeName -Type $original.Type }
            if ($typeName) {
                $restoredValue = ConvertFrom-OpenPathRegistryPolData -Type $original.Type -Data $original.Data
                Set-OpenPathPolicyRegistryValue -Key $Key -ValueName $ValueName -Type $typeName -Value $restoredValue
                $result.Restored = $true
            }
            else {
                if ($restore) {
                    Write-OpenPathLog "Policy store: restored $Key|$ValueName in Registry.pol only (registry type $($original.Type) is not mirrored); Group Policy re-applies it" -Level WARN
                    $result.Restored = $true
                }
                if (-not $KeepRegistryValue -and (Remove-OpenPathPolicyRegistryValue -Key $Key -ValueName $ValueName)) { $result.Removed = $true }
            }
        }
        catch {
            Write-OpenPathLog "Policy store: registry removal failed for $Key|$ValueName ($($_.Exception.Message))" -Level ERROR
            $result.FailureCode = 'registry-write-failed'
            return $result
        }

        if ($null -ne $original) {
            $ledger.Originals.Remove($originalId)
            try { Write-OpenPathPolicyStoreLedger -Ledger $ledger }
            catch { Write-OpenPathLog "Policy store: could not clear the original of $Key|$ValueName ($($_.Exception.Message))" -Level WARN }
        }
        return $result
    }
    finally { Exit-OpenPathLocalGpoLock -Lock $lock }
}

function Sync-OpenPathManagedPolicyList {
    <#
    .SYNOPSIS
    Replaces OpenPath-owned numbered entries of a list key (e.g. Chromium extension lists), keeping foreign ones.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Values,

        # Owner already resolved by the caller for this key (skips a second lookup).
        [AllowNull()][object]$PrecomputedOwner = $null,

        # The key was registry-only (written directly by a pre-store version): once Registry.pol holds
        # the list, the registry mirror also deletes numbered values that are not in it.
        [switch]$PruneUnownedRegistryValues
    )

    $result = New-OpenPathPolicyStoreResult
    $lock = Enter-OpenPathLocalGpoLock
    if (-not $lock) { $result.FailureCode = 'local-gpo-busy'; return $result }
    try {
        $paths = Get-OpenPathLocalGpoPaths
        $gate = Get-OpenPathPolicyStoreGate -Key $Key -ValueName '' -PolPath $paths.RegistryPol -PrecomputedOwner $PrecomputedOwner
        $result.Owner = $gate.Owner
        $result.GpoName = $gate.GpoName
        if ($gate.Blocked) { $result.FailureCode = $gate.FailureCode; return $result }

        $ledger = Read-OpenPathPolicyStoreLedger
        $oldOwned = @()
        if ($ledger.Lists.ContainsKey($Key)) { $oldOwned = @($ledger.Lists[$Key]) }
        $storedOwned = @($oldOwned)
        $requested = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })

        $confirmed = $false
        $done = $false
        for ($attempt = 1; $attempt -le $script:LocalGpoMaxWriteAttempts; $attempt++) {
            try { $snapshot = Read-OpenPathPolicyStoreSnapshot -PolPath $paths.RegistryPol }
            catch {
                if ([string]$_.Exception.Message -like 'local-gpo-unreadable*') { $result.FailureCode = 'local-gpo-unreadable'; return $result }
                throw
            }
            $entries = @($snapshot.Entries)

            # Classify the key's numbered entries: ledger-owned ones are dropped, the rest are foreign and kept.
            $foreignTexts = New-Object System.Collections.Generic.List[string]
            $merged = New-Object System.Collections.ArrayList
            $insertAt = -1
            $lastKeyIndex = -1
            $maxForeign = 0
            foreach ($entry in $entries) {
                $isListKey = Test-OpenPathPolicyKeyEqual $entry.Key $Key
                $isNumbered = $isListKey -and ([string]$entry.ValueName -match '^\d+$')
                if ($isNumbered) {
                    $text = $null
                    if ([int]$entry.Type -eq 1) { $text = [string](ConvertFrom-OpenPathRegistryPolData -Type $entry.Type -Data $entry.Data) }
                    if (Test-OpenPathPolicyValueInSet -Set $oldOwned -Text $text) {
                        if ($insertAt -lt 0) { $insertAt = $merged.Count }
                        continue
                    }
                    if ($null -ne $text) { $foreignTexts.Add($text) }
                    $number = 0
                    if ([int]::TryParse([string]$entry.ValueName, [ref]$number) -and $number -gt $maxForeign) { $maxForeign = $number }
                }
                [void]$merged.Add($entry)
                if ($isListKey) { $lastKeyIndex = $merged.Count - 1 }
            }

            # A requested value that already exists as a foreign entry is satisfied by it: not re-added, not owned.
            $ownedList = New-Object System.Collections.Generic.List[string]
            foreach ($v in $requested) {
                if (Test-OpenPathPolicyValueInSet -Set @($foreignTexts) -Text $v) { continue }
                if (Test-OpenPathPolicyValueInSet -Set @($ownedList) -Text $v) { continue }
                $ownedList.Add($v)
            }
            $newOwned = @($ownedList)

            $added = @()
            $n = $maxForeign
            foreach ($v in $newOwned) {
                $n++
                $d = ConvertTo-OpenPathRegistryPolData -Type String -Value $v
                $added += [pscustomobject]@{ Key = $Key.Trim('\'); ValueName = [string]$n; Type = $d.Type; Data = $d.Data }
            }
            if ($insertAt -lt 0) {
                if ($lastKeyIndex -ge 0) { $insertAt = $lastKeyIndex + 1 } else { $insertAt = $merged.Count }
            }
            for ($i = 0; $i -lt $added.Count; $i++) { $merged.Insert($insertAt + $i, $added[$i]) }
            $newEntries = @($merged.ToArray())
            $changed = -not (Test-OpenPathPolicyEntrySequenceEqual -A $entries -B $newEntries)

            if (-not $confirmed) {
                if (-not $PSCmdlet.ShouldProcess($Key, 'Sync managed policy list')) { return $result }
                $confirmed = $true
            }

            # Ledger first (fail closed): record old + new owned values before Registry.pol can contain the new ones,
            # so a failed ledger write can never leave untracked OpenPath entries behind.
            $union = @($storedOwned)
            foreach ($v in $newOwned) { if (-not (Test-OpenPathPolicyValueInSet -Set $union -Text $v)) { $union += $v } }
            if ($union.Count -ne $storedOwned.Count) {
                $ledger.Lists[$Key] = [string[]]$union
                try { Write-OpenPathPolicyStoreLedger -Ledger $ledger }
                catch {
                    Write-OpenPathLog "Policy store: ledger write failed for $Key, aborting without changes ($($_.Exception.Message))" -Level ERROR
                    $result.FailureCode = 'ledger-write-failed'
                    return $result
                }
                $storedOwned = @($union)
            }

            if (-not $changed) { $done = $true; break }
            $save = Save-OpenPathPolicyStoreEntries -Entries $newEntries -PolPath $paths.RegistryPol -GptIniPath $paths.GptIni -BaseBytes $snapshot.Bytes
            if ($save.Conflict) { continue }
            if (-not $save.Written) { $result.FailureCode = $save.FailureCode; return $result }
            $result.Changed = $true
            if ($save.FailureCode) { $result.FailureCode = $save.FailureCode; return $result }
            $done = $true
            break
        }
        if (-not $done) {
            Write-OpenPathLog (Get-OpenPathPolicyStoreBusyMessage -Target $Key) -Level WARN
            $result.FailureCode = 'local-gpo-busy'
            return $result
        }

        # Narrow the ledger to the new owned set; a failure here is harmless (extra values simply no longer match pol).
        $union = @($storedOwned)
        if (($union -join "`n") -ne ($newOwned -join "`n")) {
            if ($newOwned.Count -gt 0) { $ledger.Lists[$Key] = [string[]]$newOwned } else { $ledger.Lists.Remove($Key) }
            try { Write-OpenPathPolicyStoreLedger -Ledger $ledger }
            catch { Write-OpenPathLog "Policy store: could not narrow ledger for $Key ($($_.Exception.Message))" -Level WARN }
        }

        # Diff-based registry mirror: only numbered names; never touch other values.
        try {
            $desired = @{}
            foreach ($entry in $newEntries) {
                if (-not (Test-OpenPathPolicyKeyEqual $entry.Key $Key) -or ([string]$entry.ValueName -notmatch '^\d+$')) { continue }
                $typeName = Get-OpenPathPolicyTypeName -Type $entry.Type
                if (-not $typeName) { continue }
                $desired[[string]$entry.ValueName] = [pscustomobject]@{
                    Type = $typeName
                    Value = (ConvertFrom-OpenPathRegistryPolData -Type $entry.Type -Data $entry.Data)
                }
            }
            $current = @{}
            foreach ($p in @(Get-OpenPathPolicyRegistryProperties -Key $Key | Where-Object { $_.Name -match '^\d+$' })) { $current[[string]$p.Name] = $p.Value }

            $pruned = 0
            foreach ($name in @($current.Keys)) {
                if ($desired.ContainsKey($name)) { continue }
                $currentText = [string](@($current[$name]) | Select-Object -First 1)
                $isOwned = Test-OpenPathPolicyValueInSet -Set $union -Text $currentText
                if ($isOwned -or $PruneUnownedRegistryValues) {
                    Remove-ItemProperty -Path "HKLM:\$($Key.Trim('\'))" -Name $name -Force -ErrorAction Stop
                    if (-not $isOwned) { $pruned++ }
                }
            }
            if ($pruned -gt 0) {
                Write-OpenPathLog "Policy store: removed $pruned legacy registry-only value(s) from $Key after syncing it through the local GPO" -Level INFO
            }
            foreach ($name in @($desired.Keys)) {
                $want = $desired[$name]
                if ($current.ContainsKey($name) -and ((@($current[$name]) -join "`n") -ceq (@($want.Value) -join "`n"))) { continue }
                Set-OpenPathPolicyRegistryValue -Key $Key -ValueName $name -Type $want.Type -Value $want.Value
            }
        }
        catch {
            Write-OpenPathLog "Policy store: registry mirror failed for list $Key ($($_.Exception.Message))" -Level ERROR
            $result.FailureCode = 'registry-write-failed'
            return $result
        }
        $result.Applied = $true
        return $result
    }
    finally { Exit-OpenPathLocalGpoLock -Lock $lock }
}

function Remove-OpenPathManagedPolicyList {
    <#
    .SYNOPSIS
    Removes only the ledger-owned entries of a list key from Registry.pol and the registry.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Key)

    $result = [pscustomobject]@{ Removed = $false; FailureCode = '' }
    $lock = Enter-OpenPathLocalGpoLock
    if (-not $lock) { $result.FailureCode = 'local-gpo-busy'; return $result }
    try {
        $paths = Get-OpenPathLocalGpoPaths
        $gate = Get-OpenPathPolicyStoreGate -Key $Key -ValueName '' -PolPath $paths.RegistryPol
        if ($gate.Blocked) { $result.FailureCode = $gate.FailureCode; return $result }

        $ledger = Read-OpenPathPolicyStoreLedger
        $owned = @()
        if ($ledger.Lists.ContainsKey($Key)) { $owned = @($ledger.Lists[$Key]) }
        $isOwnedText = { param($text) ($null -ne $text) -and (@($owned | Where-Object { Test-OpenPathPolicyNameEqual $_ $text }).Count -gt 0) }

        $done = $false
        for ($attempt = 1; $attempt -le $script:LocalGpoMaxWriteAttempts; $attempt++) {
            try { $snapshot = Read-OpenPathPolicyStoreSnapshot -PolPath $paths.RegistryPol }
            catch {
                if ([string]$_.Exception.Message -like 'local-gpo-unreadable*') { $result.FailureCode = 'local-gpo-unreadable'; return $result }
                throw
            }
            $entries = @($snapshot.Entries)
            $kept = @($entries | Where-Object {
                $drop = $false
                if ((Test-OpenPathPolicyKeyEqual $_.Key $Key) -and ([string]$_.ValueName -match '^\d+$') -and ([int]$_.Type -eq 1)) {
                    $drop = & $isOwnedText ([string](ConvertFrom-OpenPathRegistryPolData -Type $_.Type -Data $_.Data))
                }
                -not $drop
            })
            if ($kept.Count -eq $entries.Count) { $done = $true; break }

            $save = Save-OpenPathPolicyStoreEntries -Entries $kept -PolPath $paths.RegistryPol -GptIniPath $paths.GptIni -BaseBytes $snapshot.Bytes
            if ($save.Conflict) { continue }
            if (-not $save.Written) { $result.FailureCode = $save.FailureCode; return $result }
            $result.Removed = $true
            if ($save.FailureCode) { $result.FailureCode = $save.FailureCode }
            $done = $true
            break
        }
        if (-not $done) {
            Write-OpenPathLog (Get-OpenPathPolicyStoreBusyMessage -Target $Key) -Level WARN
            $result.FailureCode = 'local-gpo-busy'
            return $result
        }

        try {
            foreach ($p in @(Get-OpenPathPolicyRegistryProperties -Key $Key | Where-Object { $_.Name -match '^\d+$' })) {
                if (& $isOwnedText ([string]($p.Value | Select-Object -First 1))) {
                    Remove-ItemProperty -Path "HKLM:\$($Key.Trim('\'))" -Name $p.Name -Force -ErrorAction Stop
                    $result.Removed = $true
                }
            }
        }
        catch {
            Write-OpenPathLog "Policy store: registry removal failed for list $Key ($($_.Exception.Message))" -Level ERROR
            $result.FailureCode = 'registry-write-failed'
        }

        if ($ledger.Lists.ContainsKey($Key)) {
            $ledger.Lists.Remove($Key)
            try { Write-OpenPathPolicyStoreLedger -Ledger $ledger }
            catch {
                Write-OpenPathLog "Policy store: ledger write failed for $Key ($($_.Exception.Message))" -Level ERROR
                if (-not $result.FailureCode) { $result.FailureCode = 'ledger-write-failed' }
            }
        }
        return $result
    }
    finally { Exit-OpenPathLocalGpoLock -Lock $lock }
}

function Invoke-OpenPathPolicyRefresh {
    <#
    .SYNOPSIS
    Runs gpupdate for the computer policy. Never throws.
    #>
    [CmdletBinding()]
    param([switch]$Force, [int]$TimeoutSeconds = 120)

    $arguments = '/target:computer'
    if ($Force) { $arguments += ' /force' }
    $arguments += " /wait:$TimeoutSeconds"

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $exitCode = -1
    try {
        $exitCode = [int](Start-OpenPathGpUpdateProcess -Arguments $arguments -TimeoutSeconds $TimeoutSeconds)
    }
    catch {
        Write-OpenPathLog "Policy store: gpupdate could not run ($($_.Exception.Message))" -Level WARN
        $exitCode = -1
    }
    $stopwatch.Stop()
    if ($exitCode -ne 0) {
        Write-OpenPathLog "Policy store: gpupdate exited with $exitCode; some policy changes may require a restart (a restart prompt is answered N)" -Level WARN
    }
    return [pscustomobject]@{ ExitCode = $exitCode; DurationMs = [int]$stopwatch.ElapsedMilliseconds }
}

Export-ModuleMember -Function @(
    'Get-OpenPathManagedPolicyValue',
    'Set-OpenPathManagedPolicyValue',
    'Remove-OpenPathManagedPolicyValue',
    'Sync-OpenPathManagedPolicyList',
    'Remove-OpenPathManagedPolicyList',
    'Invoke-OpenPathPolicyRefresh',
    'Get-OpenPathLocalGpoPaths',
    'Get-OpenPathPolicyValueOwner',
    'Get-OpenPathPolicyStoreLastOwner',
    'Set-OpenPathPolicyStoreLastOwner',
    'Remove-OpenPathPolicyStoreLedger',
    'Get-OpenPathPolicyStoreOriginal'
)
