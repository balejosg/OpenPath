# Owner detection for a Windows policy value: RSoP -> local Registry.pol -> MDM -> registry.

function Get-OpenPathRsopRegistryPolicySetting {
    # Isolated CIM query so tests can mock it. Throws when RSoP is unavailable.
    return @(Get-CimInstance -Namespace 'root\rsop\computer' -ClassName 'RSOP_RegistryPolicySetting' -ErrorAction Stop)
}

function Get-OpenPathRsopGpo {
    return @(Get-CimInstance -Namespace 'root\rsop\computer' -ClassName 'RSOP_GPO' -ErrorAction Stop)
}

function Test-OpenPathPolicyNameMatch {
    param([string]$RecordValueName, [string]$ValueName)

    if ([string]::IsNullOrEmpty($ValueName)) { return $true }
    return [string]::Equals([string]$RecordValueName, $ValueName, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-OpenPathPolicyMdmAreaMarker {
    param([string]$Key)

    if ($Key -match '(?i)mozilla|firefox') { return 'Firefox' }
    if ($Key -match '(?i)google|chrome') { return 'Chrome' }
    if ($Key -match '(?i)edge') { return 'Edge' }
    return ''
}

function Get-OpenPathPolicyValueOwner {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowEmptyString()][Parameter(Mandatory = $true)][string]$ValueName,
        [string]$LocalPolPath
    )

    $evidence = New-Object System.Collections.Generic.List[string]
    $normalizedKey = $Key.Trim('\')
    $result = { param($owner, $gpoName)
        [pscustomobject]@{ Owner = $owner; GpoName = $gpoName; Evidence = $evidence.ToArray() }
    }

    # 1. RSoP
    $rsop = @()
    try {
        $rsop = @(Get-OpenPathRsopRegistryPolicySetting)
    }
    catch {
        $evidence.Add('rsop-unavailable')
    }
    $rsopHits = @($rsop | Where-Object {
        $_ -and
        [string]::Equals(([string]$_.registryKey).Trim('\'), $normalizedKey, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-OpenPathPolicyNameMatch -RecordValueName $_.valueName -ValueName $ValueName)
    })
    $withId = @($rsopHits | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.GPOID) })
    if ($withId.Count -lt $rsopHits.Count) { $evidence.Add('rsop-gpoid-missing') }
    $rsopHits = $withId
    if ($rsopHits.Count -gt 0) {
        $rank = { param($r) if ($null -eq $r.precedence -or [string]$r.precedence -eq '') { [int64][int]::MaxValue } else { [int64]$r.precedence } }
        $minPrecedence = ($rsopHits | ForEach-Object { & $rank $_ } | Measure-Object -Minimum).Minimum
        $top = @($rsopHits | Where-Object { (& $rank $_) -eq $minPrecedence })
        # Whole-key lookups can tie at the top; prefer an externally managed record (fail safe).
        $winner = $top | Where-Object { [string]$_.GPOID -ne 'LocalGPO' } | Select-Object -First 1
        if (-not $winner) { $winner = $top[0] }
        $gpoId = [string]$winner.GPOID
        if ($gpoId -eq 'LocalGPO') {
            $evidence.Add('rsop:LocalGPO')
            return (& $result 'LocalGpo' '')
        }
        $gpoName = ''
        try {
            $gpo = @(Get-OpenPathRsopGpo) | Where-Object { $_ -and [string]$_.id -eq $gpoId } | Select-Object -First 1
            if ($gpo) { $gpoName = [string]$gpo.name }
        }
        catch {
            $evidence.Add('rsop-gpo-name-unavailable')
        }
        $evidence.Add("rsop:$gpoId")
        return (& $result 'DomainGpo' $gpoName)
    }

    # 2. Local Registry.pol (an unreadable file propagates local-gpo-unreadable)
    if ([string]::IsNullOrWhiteSpace($LocalPolPath)) {
        $LocalPolPath = Join-Path $env:SystemRoot 'System32\GroupPolicy\Machine\Registry.pol'
    }
    $polEntries = @(Read-OpenPathRegistryPolFile -Path $LocalPolPath)
    $inPol = @($polEntries | Where-Object {
        [string]::Equals(([string]$_.Key).Trim('\'), $normalizedKey, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-OpenPathPolicyNameMatch -RecordValueName $_.ValueName -ValueName $ValueName)
    })
    if ($inPol.Count -gt 0) {
        $evidence.Add('registry-pol')
        return (& $result 'LocalGpo' '')
    }

    # 3. MDM PolicyManager area
    $marker = Get-OpenPathPolicyMdmAreaMarker -Key $normalizedKey
    if ($marker) {
        $areas = @(Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device' -ErrorAction SilentlyContinue)
        foreach ($area in $areas) {
            $name = [string]$area.PSChildName
            if (-not $name) { $name = [string]$area.Name }
            if ($name -like "*$marker*") {
                $evidence.Add("mdm:$name")
                return (& $result 'Mdm' '')
            }
        }
    }

    # 4. Value present in the registry (direct writer, e.g. an older OpenPath)
    $regPath = "HKLM:\$normalizedKey"
    if (Test-Path -LiteralPath $regPath) {
        $props = Get-ItemProperty -LiteralPath $regPath -ErrorAction SilentlyContinue
        if ($props) {
            $names = @($props.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { $_.Name })
            $present = $false
            if ([string]::IsNullOrEmpty($ValueName)) { $present = ($names.Count -gt 0) }
            else { $present = (@($names | Where-Object { [string]::Equals($_, $ValueName, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) }
            if ($present) {
                $evidence.Add('registry-value')
                return (& $result 'Unknown' '')
            }
        }
    }

    return (& $result 'None' '')
}
