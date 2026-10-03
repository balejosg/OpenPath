# Phase 3A.3 L3: first-visit guest result contract.
#
# Shared by the in-guest harness (staged next to it by the controller) and the
# controller-side parser. It exists because a guest step must never lose its
# result:
#   - the harness writes the result JSON to `-ResultPath` before printing it, so
#     a killed or hung stdout still leaves the evidence on disk;
#   - serialization is key-by-key, so one unserializable value cannot take the
#     whole result down (the failing key is named in the result itself);
#   - the controller can recover the result from either the stdout markers or
#     the result file (Phase 3A.2 red-b r1 had markers with an empty body).

function Get-FirstVisitResultField {
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

function Test-FirstVisitSerializableValue {
    param([AllowNull()][object]$Value, [int]$Depth = 12)
    try {
        $probe = [ordered]@{ value = $Value }
        $json = $probe | ConvertTo-Json -Depth $Depth -Compress
        return -not [string]::IsNullOrWhiteSpace($json)
    }
    catch {
        return $false
    }
}

function ConvertTo-FirstVisitResultJson {
    <#
    .SYNOPSIS
    Serializes a harness result payload without ever returning empty.
    .DESCRIPTION
    First tries the whole payload. On failure it keeps every key whose subtree
    serializes on its own (body.state key-by-key included) and records the keys
    that failed under `bodySerializationFailures`, so the rest of the result
    still reaches the controller.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        # Test seam: a custom probe forces the key-by-key path so the contract
        # ('the failing key is named, the rest arrives') is deterministic on
        # every PowerShell version.
        [scriptblock]$SerializableProbe = $null
    )
    $customProbe = $null -ne $SerializableProbe
    if (-not $customProbe) {
        try {
            $json = $Payload | ConvertTo-Json -Depth 12 -Compress
            if (-not [string]::IsNullOrWhiteSpace($json)) { return [string]$json }
        }
        catch { }
    }
    $probe = if ($customProbe) { $SerializableProbe } else { { param($Value) Test-FirstVisitSerializableValue -Value $Value } }
    $failures = New-Object System.Collections.Generic.List[string]
    $reduced = [ordered]@{}
    foreach ($key in @($Payload.Keys)) {
        if ($key -eq 'body') { continue }
        if (& $probe $Payload[$key]) {
            $reduced[[string]$key] = $Payload[$key]
        }
        else {
            $failures.Add([string]$key)
        }
    }
    $body = Get-FirstVisitResultField -InputObject $Payload -Name 'body'
    $reducedBody = [ordered]@{}
    $state = [ordered]@{}
    if ($body) {
        foreach ($key in @($body.Keys)) {
            if ($key -eq 'state') { continue }
            $value = Get-FirstVisitResultField -InputObject $body -Name $key
            if (& $probe $value) { $reducedBody[[string]$key] = $value }
            else { $failures.Add("body.$key") }
        }
        $stateObject = Get-FirstVisitResultField -InputObject $body -Name 'state'
        if ($stateObject) {
            foreach ($key in @($stateObject.Keys)) {
                $value = Get-FirstVisitResultField -InputObject $stateObject -Name $key
                if (& $probe $value) { $state[[string]$key] = $value }
                else { $failures.Add("body.state.$key") }
            }
        }
    }
    $reducedBody['state'] = $state
    $reducedBody['bodySerializationFailures'] = @($failures.ToArray())
    $reduced['body'] = $reducedBody
    if (-not $reduced.Contains('status')) { $reduced['status'] = [string](Get-FirstVisitResultField -InputObject $Payload -Name 'status') }
    if (-not $reduced.Contains('step')) { $reduced['step'] = [string](Get-FirstVisitResultField -InputObject $Payload -Name 'step') }
    if (-not $reduced.Contains('failures')) { $reduced['failures'] = @($failures | ForEach-Object { "serialization-failed:$_" }) }
    try {
        $fallbackJson = $reduced | ConvertTo-Json -Depth 12 -Compress
        if (-not [string]::IsNullOrWhiteSpace($fallbackJson)) { return [string]$fallbackJson }
    }
    catch { }
    return '{"status":"failed","step":"unknown","failures":["result-serialization-failed"],"body":{"state":{}}}'
}

function Get-FirstVisitResultFromOutput {
    <#
    .SYNOPSIS
    Extracts the harness result JSON from the captured stdout markers.
    .DESCRIPTION
    Returns $null when the markers are absent or the body between them is empty
    (Phase 3A.2 red-b r1: markers present, empty body). Never falls back to any
    brace heuristic: a partial line is not a result.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Output)
    if ([string]::IsNullOrWhiteSpace($Output)) { return $null }
    $match = [regex]::Match($Output, '(?s)<<<GUEST_RESULT>>>\s*(\{.*\})\s*<<<END_GUEST_RESULT>>>')
    if (-not $match.Success) { return $null }
    $candidate = $match.Groups[1].Value.Trim()
    if (-not $candidate) { return $null }
    return $candidate
}

function Resolve-FirstVisitGuestResult {
    <#
    .SYNOPSIS
    Chooses the valid guest result between stdout and the result file.
    .DESCRIPTION
    `-FileText` is the raw content of the harness result file when the controller
    managed to read it from the guest. The stdout result wins when it parses;
    otherwise the file is used. Both invalid is a missing result.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][string]$Output,
        [AllowNull()][string]$FileText
    )
    $stdoutResult = Get-FirstVisitResultFromOutput -Output $Output
    $stdoutValid = $false
    if ($stdoutResult) {
        try {
            $parsed = $stdoutResult | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne (Get-FirstVisitResultField -InputObject $parsed -Name 'status')) { $stdoutValid = $true }
        }
        catch { $stdoutValid = $false }
    }
    $fileResult = $null
    $fileValid = $false
    if (-not [string]::IsNullOrWhiteSpace($FileText) -and $FileText.Trim() -ne 'MISSING') {
        $trimmed = $FileText.Trim()
        try {
            $parsed = $trimmed | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne (Get-FirstVisitResultField -InputObject $parsed -Name 'status')) {
                $fileValid = $true
                $fileResult = $trimmed
            }
        }
        catch { $fileValid = $false }
    }
    if ($stdoutValid) {
        return [pscustomobject][ordered]@{ json = $stdoutResult; source = 'stdout'; stdoutValid = $true; fileValid = $fileValid; error = '' }
    }
    if ($fileValid) {
        return [pscustomobject][ordered]@{ json = $fileResult; source = 'result-file'; stdoutValid = $false; fileValid = $true; error = '' }
    }
    return [pscustomobject][ordered]@{ json = $null; source = ''; stdoutValid = $false; fileValid = $false; error = 'first-visit-guest-result-missing' }
}

Export-ModuleMember -Function ConvertTo-FirstVisitResultJson, Get-FirstVisitResultFromOutput, Resolve-FirstVisitGuestResult, Test-FirstVisitSerializableValue
