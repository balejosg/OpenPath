# OpenPath policy store for Windows
# Single write path for OpenPath values under HKLM\SOFTWARE\Policies.
# Merges each value into the local GPO (Registry.pol + gpt.ini bump) so a Registry CSE
# refresh cannot overwrite it, mirrors it into the registry, and refuses to write when a
# domain GPO or MDM owns the value.

. (Join-Path $PSScriptRoot 'internal\WindowsRoot.ps1')
$script:OpenPathRoot = Resolve-OpenPathWindowsRoot
Import-Module "$PSScriptRoot\Common.psm1" -ErrorAction Stop

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

function Get-OpenPathPolicyStoreLedgerPath {
    return (Join-Path (Join-Path $script:OpenPathRoot 'data') 'policy-store-ledger.json')
}

function Start-OpenPathGpUpdateProcess {
    # Isolated process launch so tests can assert the argument string.
    param([string]$Arguments, [int]$TimeoutSeconds = 120)

    $process = Start-Process -FilePath 'gpupdate.exe' -ArgumentList $Arguments -PassThru -WindowStyle Hidden -ErrorAction Stop
    $waitMs = ([Math]::Max($TimeoutSeconds, 0) + 30) * 1000
    if (-not $process.WaitForExit($waitMs)) {
        try { $process.Kill() } catch { $null = $_ }
        return -1
    }
    return [int]$process.ExitCode
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

function New-OpenPathPolicyStoreResult {
    return [pscustomobject]@{ Applied = $false; Changed = $false; Owner = ''; GpoName = ''; FailureCode = '' }
}

function Get-OpenPathPolicyStoreGate {
    # Resolves the owner of a value. Blocked=$true means no write may happen.
    param([string]$Key, [AllowEmptyString()][string]$ValueName, [string]$PolPath)

    $gate = [pscustomobject]@{ Blocked = $false; FailureCode = ''; Owner = ''; GpoName = '' }
    try {
        $owner = Get-OpenPathPolicyValueOwner -Key $Key -ValueName $ValueName -LocalPolPath $PolPath
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

function Read-OpenPathPolicyStoreEntries {
    # Plain array of Registry.pol entries; throws local-gpo-unreadable on a corrupt file.
    param([string]$PolPath)
    return @(Read-OpenPathRegistryPolFile -Path $PolPath)
}

function Save-OpenPathPolicyStoreEntries {
    param([object[]]$Entries, [string]$PolPath, [string]$GptIniPath)
    Write-OpenPathRegistryPolFile -Path $PolPath -Entries $Entries
    Step-OpenPathLocalGpoMachineVersion -GptIniPath $GptIniPath | Out-Null
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
    $ledger = [pscustomobject]@{ Lists = @{}; LastOwners = @{} }
    $path = Get-OpenPathPolicyStoreLedgerPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $ledger }
    try {
        $json = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($json -and $json.lists) {
            foreach ($p in $json.lists.PSObject.Properties) { $ledger.Lists[[string]$p.Name] = @($p.Value | ForEach-Object { [string]$_ }) }
        }
        if ($json -and $json.lastOwners) {
            foreach ($p in $json.lastOwners.PSObject.Properties) { $ledger.LastOwners[[string]$p.Name] = [string]$p.Value }
        }
    }
    catch {
        Write-OpenPathLog "Policy store: ledger unreadable, treating as empty ($($_.Exception.Message))" -Level WARN
        $ledger = [pscustomobject]@{ Lists = @{}; LastOwners = @{} }
    }
    return $ledger
}

function Write-OpenPathPolicyStoreLedger {
    param($Ledger)

    $lists = [ordered]@{}
    foreach ($k in ($Ledger.Lists.Keys | Sort-Object)) { $lists[[string]$k] = [string[]]@($Ledger.Lists[$k]) }
    $owners = [ordered]@{}
    foreach ($k in ($Ledger.LastOwners.Keys | Sort-Object)) { $owners[[string]$k] = [string]$Ledger.LastOwners[$k] }
    $json = ([ordered]@{ lists = $lists; lastOwners = $owners } | ConvertTo-Json -Depth 5)

    $path = Get-OpenPathPolicyStoreLedgerPath
    $directory = Split-Path -Parent $path
    if ($directory -and -not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
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
                return [pscustomobject]@{
                    Type = $typeName
                    Value = (ConvertFrom-OpenPathRegistryPolData -Type $entry.Type -Data $entry.Data)
                    Source = 'LocalGpo'
                }
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
        elseif ($value -is [array]) { $typeName = 'MultiString' }
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
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowEmptyCollection()][object]$Value
    )

    $result = New-OpenPathPolicyStoreResult
    $paths = Get-OpenPathLocalGpoPaths
    $gate = Get-OpenPathPolicyStoreGate -Key $Key -ValueName $ValueName -PolPath $paths.RegistryPol
    $result.Owner = $gate.Owner
    $result.GpoName = $gate.GpoName
    if ($gate.Blocked) { $result.FailureCode = $gate.FailureCode; return $result }

    try { $entries = @(Read-OpenPathPolicyStoreEntries -PolPath $paths.RegistryPol) }
    catch {
        if ([string]$_.Exception.Message -like 'local-gpo-unreadable*') { $result.FailureCode = 'local-gpo-unreadable'; return $result }
        throw
    }

    $data = ConvertTo-OpenPathRegistryPolData -Type $Type -Value $Value
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

    if (-not $PSCmdlet.ShouldProcess("$Key|$ValueName", 'Set managed policy value')) { return $result }

    if ($changed) {
        try { Save-OpenPathPolicyStoreEntries -Entries @($newEntries.ToArray()) -PolPath $paths.RegistryPol -GptIniPath $paths.GptIni }
        catch {
            Write-OpenPathLog "Policy store: Registry.pol write failed for $Key|$ValueName ($($_.Exception.Message))" -Level ERROR
            $result.FailureCode = 'local-gpo-write-failed'
            return $result
        }
    }
    $result.Changed = $changed

    try { Set-OpenPathPolicyRegistryValue -Key $Key -ValueName $ValueName -Type $Type -Value $Value }
    catch {
        Write-OpenPathLog "Policy store: registry mirror failed for $Key|$ValueName ($($_.Exception.Message))" -Level ERROR
        $result.FailureCode = 'registry-write-failed'
        return $result
    }
    $result.Applied = $true
    return $result
}

function Remove-OpenPathManagedPolicyValue {
    <#
    .SYNOPSIS
    Removes a value from local Registry.pol (bumping gpt.ini if it was present) and from the registry.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$ValueName
    )

    $result = [pscustomobject]@{ Removed = $false; FailureCode = '' }
    $paths = Get-OpenPathLocalGpoPaths
    $gate = Get-OpenPathPolicyStoreGate -Key $Key -ValueName $ValueName -PolPath $paths.RegistryPol
    if ($gate.Blocked) { $result.FailureCode = $gate.FailureCode; return $result }

    try { $entries = @(Read-OpenPathPolicyStoreEntries -PolPath $paths.RegistryPol) }
    catch {
        if ([string]$_.Exception.Message -like 'local-gpo-unreadable*') { $result.FailureCode = 'local-gpo-unreadable'; return $result }
        throw
    }

    $kept = @($entries | Where-Object { -not ((Test-OpenPathPolicyKeyEqual $_.Key $Key) -and (Test-OpenPathPolicyNameEqual $_.ValueName $ValueName)) })
    if ($kept.Count -ne $entries.Count) {
        try { Save-OpenPathPolicyStoreEntries -Entries $kept -PolPath $paths.RegistryPol -GptIniPath $paths.GptIni }
        catch {
            Write-OpenPathLog "Policy store: Registry.pol write failed removing $Key|$ValueName ($($_.Exception.Message))" -Level ERROR
            $result.FailureCode = 'local-gpo-write-failed'
            return $result
        }
        $result.Removed = $true
    }

    try { if (Remove-OpenPathPolicyRegistryValue -Key $Key -ValueName $ValueName) { $result.Removed = $true } }
    catch {
        Write-OpenPathLog "Policy store: registry removal failed for $Key|$ValueName ($($_.Exception.Message))" -Level ERROR
        $result.FailureCode = 'registry-write-failed'
    }
    return $result
}

function Sync-OpenPathManagedPolicyList {
    <#
    .SYNOPSIS
    Replaces OpenPath-owned numbered entries of a list key (e.g. Chromium extension lists), keeping foreign ones.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Values
    )

    $result = New-OpenPathPolicyStoreResult
    $paths = Get-OpenPathLocalGpoPaths
    $gate = Get-OpenPathPolicyStoreGate -Key $Key -ValueName '' -PolPath $paths.RegistryPol
    $result.Owner = $gate.Owner
    $result.GpoName = $gate.GpoName
    if ($gate.Blocked) { $result.FailureCode = $gate.FailureCode; return $result }

    try { $entries = @(Read-OpenPathPolicyStoreEntries -PolPath $paths.RegistryPol) }
    catch {
        if ([string]$_.Exception.Message -like 'local-gpo-unreadable*') { $result.FailureCode = 'local-gpo-unreadable'; return $result }
        throw
    }

    $ledger = Read-OpenPathPolicyStoreLedger
    $owned = @()
    if ($ledger.Lists.ContainsKey($Key)) { $owned = @($ledger.Lists[$Key]) }
    $newValues = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })

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
            $isOwned = ($null -ne $text) -and (@($owned | Where-Object { Test-OpenPathPolicyNameEqual $_ $text }).Count -gt 0)
            if ($isOwned) {
                if ($insertAt -lt 0) { $insertAt = $merged.Count }
                continue
            }
            $number = 0
            if ([int]::TryParse([string]$entry.ValueName, [ref]$number) -and $number -gt $maxForeign) { $maxForeign = $number }
        }
        [void]$merged.Add($entry)
        if ($isListKey) { $lastKeyIndex = $merged.Count - 1 }
    }

    $added = @()
    $n = $maxForeign
    foreach ($v in $newValues) {
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

    if (-not $PSCmdlet.ShouldProcess($Key, 'Sync managed policy list')) { return $result }

    if ($changed) {
        try { Save-OpenPathPolicyStoreEntries -Entries $newEntries -PolPath $paths.RegistryPol -GptIniPath $paths.GptIni }
        catch {
            Write-OpenPathLog "Policy store: Registry.pol write failed for list $Key ($($_.Exception.Message))" -Level ERROR
            $result.FailureCode = 'local-gpo-write-failed'
            return $result
        }
    }
    $result.Changed = $changed

    $ledgerDiffers = (($owned -join "`n") -ne ($newValues -join "`n")) -or ($newValues.Count -eq 0 -and $ledger.Lists.ContainsKey($Key))
    if ($ledgerDiffers) {
        if ($newValues.Count -gt 0) { $ledger.Lists[$Key] = $newValues } else { $ledger.Lists.Remove($Key) }
        try { Write-OpenPathPolicyStoreLedger -Ledger $ledger }
        catch {
            Write-OpenPathLog "Policy store: ledger write failed for $Key ($($_.Exception.Message))" -Level ERROR
            $result.FailureCode = 'ledger-write-failed'
            return $result
        }
    }

    try {
        foreach ($p in @(Get-OpenPathPolicyRegistryProperties -Key $Key | Where-Object { $_.Name -match '^\d+$' })) {
            Remove-ItemProperty -Path "HKLM:\$($Key.Trim('\'))" -Name $p.Name -Force -ErrorAction Stop
        }
        foreach ($entry in $newEntries) {
            if (-not (Test-OpenPathPolicyKeyEqual $entry.Key $Key) -or ([string]$entry.ValueName -notmatch '^\d+$')) { continue }
            $typeName = Get-OpenPathPolicyTypeName -Type $entry.Type
            if (-not $typeName) { continue }
            $value = ConvertFrom-OpenPathRegistryPolData -Type $entry.Type -Data $entry.Data
            Set-OpenPathPolicyRegistryValue -Key $Key -ValueName $entry.ValueName -Type $typeName -Value $value
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

function Remove-OpenPathManagedPolicyList {
    <#
    .SYNOPSIS
    Removes only the ledger-owned entries of a list key from Registry.pol and the registry.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Key)

    $result = [pscustomobject]@{ Removed = $false; FailureCode = '' }
    $paths = Get-OpenPathLocalGpoPaths
    $gate = Get-OpenPathPolicyStoreGate -Key $Key -ValueName '' -PolPath $paths.RegistryPol
    if ($gate.Blocked) { $result.FailureCode = $gate.FailureCode; return $result }

    try { $entries = @(Read-OpenPathPolicyStoreEntries -PolPath $paths.RegistryPol) }
    catch {
        if ([string]$_.Exception.Message -like 'local-gpo-unreadable*') { $result.FailureCode = 'local-gpo-unreadable'; return $result }
        throw
    }

    $ledger = Read-OpenPathPolicyStoreLedger
    $owned = @()
    if ($ledger.Lists.ContainsKey($Key)) { $owned = @($ledger.Lists[$Key]) }
    $isOwnedText = { param($text) ($null -ne $text) -and (@($owned | Where-Object { Test-OpenPathPolicyNameEqual $_ $text }).Count -gt 0) }

    $kept = @($entries | Where-Object {
        $drop = $false
        if ((Test-OpenPathPolicyKeyEqual $_.Key $Key) -and ([string]$_.ValueName -match '^\d+$') -and ([int]$_.Type -eq 1)) {
            $drop = & $isOwnedText ([string](ConvertFrom-OpenPathRegistryPolData -Type $_.Type -Data $_.Data))
        }
        -not $drop
    })
    if ($kept.Count -ne $entries.Count) {
        try { Save-OpenPathPolicyStoreEntries -Entries $kept -PolPath $paths.RegistryPol -GptIniPath $paths.GptIni }
        catch {
            Write-OpenPathLog "Policy store: Registry.pol write failed removing list $Key ($($_.Exception.Message))" -Level ERROR
            $result.FailureCode = 'local-gpo-write-failed'
            return $result
        }
        $result.Removed = $true
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
    'Get-OpenPathPolicyValueOwner'
)
