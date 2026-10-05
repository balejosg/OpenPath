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

function ConvertTo-FirstVisitPlainString {
    <#
    .SYNOPSIS
    Returns a fresh plain string (or a bounded ToString) with no ETS wrapper.
    .DESCRIPTION
    Phase 5.3 B1: strings that came out of `Get-Content -Raw` carry ETS
    properties (PSPath, PSDrive, PSProvider) on their PowerShell wrapper; that
    wrapper is what the PS 5.1 serializer walked in the Phase 5.2 collect
    wedge. `.ToString()` returns the raw .NET string, which PowerShell wraps
    again without those properties.
    #>
    param([AllowNull()][object]$Value, [int]$MaxChars = 8192)
    if ($null -eq $Value) { return $null }
    # A wrapped string keeps its ETS properties through a cast; ToString()
    # returns the raw .NET value that PowerShell re-wraps clean.
    $text = if ($Value -is [string]) { $Value.ToString() } else { [string]$Value }
    if ($text.Length -gt $MaxChars) { return $text.Substring(0, $MaxChars) + '...truncated' }
    return $text
}

function Limit-FirstVisitResultValue {
    <#
    .SYNOPSIS
    Bounds strings and collections before serialization.
    .DESCRIPTION
    Phase 5.2: the acceptance runs spent >500 s inside the PS 5.1 serializer on
    an unbounded collect body. Phase 5.3: every string is returned as a fresh
    plain string (Get-Content ETS properties are dropped) and any object that
    is not a dictionary, a property bag, an enumerable or a primitive is
    reduced to its trimmed ToString(). PowerShell property bags
    ([pscustomobject]) are recursed as dictionaries instead of being flattened,
    because the harness payload legitimately stores parsed JSON objects (the
    student probe result) that must reach the evidence.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Value,
        [int]$MaxStringChars = 8192,
        [int]$MaxItems = 2000,
        [int]$Depth = 0
    )
    if ($null -eq $Value) { return $null }
    if ($Depth -gt 8) { return ConvertTo-FirstVisitPlainString -Value $Value -MaxChars $MaxStringChars }
    if ($Value -is [string]) {
        # Force a fresh wrapper (ETS dropped) and keep the size cap.
        return ConvertTo-FirstVisitPlainString -Value $Value -MaxChars $MaxStringChars
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $limited = [ordered]@{}
        foreach ($key in @($Value.Keys)) {
            # Read the child directly: Get-FirstVisitResultField (and an
            # if-statement RHS) unrolls an empty array to no output, which
            # would turn [] into null here.
            $childValue = $Value[$key]
            $limited[[string]$key] = Limit-FirstVisitResultValue -Value $childValue -MaxStringChars $MaxStringChars -MaxItems $MaxItems -Depth ($Depth + 1)
        }
        return $limited
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $properties = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties)) {
            if (-not $property.IsGettable) { continue }
            if ($property.MemberType -notin @('NoteProperty', 'Property', 'AliasProperty', 'ScriptProperty')) { continue }
            $childValue = $null
            try { $childValue = $property.Value } catch { continue }
            $properties[[string]$property.Name] = Limit-FirstVisitResultValue -Value $childValue -MaxStringChars $MaxStringChars -MaxItems $MaxItems -Depth ($Depth + 1)
        }
        return $properties
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
        $items = New-Object System.Collections.ArrayList
        $count = 0
        foreach ($item in $Value) {
            if ($count -ge $MaxItems) { break }
            $null = $items.Add((Limit-FirstVisitResultValue -Value $item -MaxStringChars $MaxStringChars -MaxItems $MaxItems -Depth ($Depth + 1)))
            $count += 1
        }
        # Preserve empty arrays as empty arrays (a plain 'return @()' unrolls to
        # no output and the caller would store $null, changing [] into null).
        $array = [object[]]$items.ToArray()
        return ,$array
    }
    $type = $Value.GetType()
    if ($type.IsPrimitive -or $type.IsEnum -or $Value -is [datetime] -or $Value -is [datetimeoffset] -or $Value -is [timespan] -or $Value -is [guid] -or $Value -is [decimal]) {
        return $Value
    }
    # Everything else: a bounded ToString(), never its hidden object graph.
    return ConvertTo-FirstVisitPlainString -Value $Value -MaxChars $MaxStringChars
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

function Get-FirstVisitSerializationError {
    <#
    .SYNOPSIS
    Returns '' when a value serializes on its own, or the exception type and
    message when it does not.
    .DESCRIPTION
    Phase 5 A2: the previous contract only kept the failing key name, so a
    serializer failure could not be explained from the evidence. The error text
    travels in serializationDiagnostics.
    #>
    param([AllowNull()][object]$Value, [int]$Depth = 12)
    try {
        $probe = [ordered]@{ value = $Value }
        $json = $probe | ConvertTo-Json -Depth $Depth -Compress
        if ([string]::IsNullOrWhiteSpace($json)) { return 'empty-serialization' }
        return ''
    }
    catch {
        $type = $_.Exception.GetType().Name
        $message = ([string]$_.Exception.Message) -replace '\s+', ' '
        if ($message.Length -gt 300) { $message = $message.Substring(0, 300) }
        return ("{0}: {1}" -f $type, $message)
    }
}

function ConvertTo-FirstVisitResultJson {
    <#
    .SYNOPSIS
    Serializes a harness result payload without ever returning empty.
    .DESCRIPTION
    The whole payload is attempted first. On failure (or when it exceeds the
    inline cap) it is reduced key by key: every value that serializes on its own
    is kept (body.state key-by-key included), values over the per-value cap move
    to a part file next to the result, and the keys that could not serialize are
    named under `bodySerializationFailures` with their error text under
    `serializationDiagnostics`. The reduced payload is always small enough to
    serialize; the last-resort payload carries only plain strings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Payload,
        # Per-value inline cap; values above it are written to PartsDirectory.
        # 0 disables splitting (used by callers that consume one message only).
        [int]$MaxInlineBytes = 49152,
        # When set, oversized values are written here as <flat-key>.json.
        [AllowNull()][string]$PartsDirectory = $null,
        # Test seam: a custom probe forces the key-by-key path so the contract
        # ('the failing key is named, the rest arrives') is deterministic on
        # every PowerShell version.
        [scriptblock]$SerializableProbe = $null
    )
    $customProbe = $null -ne $SerializableProbe
    # Phase 5.2: bound the payload before any ConvertTo-Json attempt.
    $Payload = Limit-FirstVisitResultValue -Value $Payload
    if (-not $customProbe) {
        try {
            $json = $Payload | ConvertTo-Json -Depth 12 -Compress
            if (-not [string]::IsNullOrWhiteSpace($json) -and ($MaxInlineBytes -le 0 -or -not $PartsDirectory -or $json.Length -le $MaxInlineBytes)) { return [string]$json }
        }
        catch { }
    }
    $probe = if ($customProbe) { $SerializableProbe } else { { param($Value) Test-FirstVisitSerializableValue -Value $Value } }
    $failures = New-Object System.Collections.Generic.List[string]
    $diagnostics = [ordered]@{}
    $parts = [ordered]@{}
    $writePart = {
        param([string]$FlatKey, [object]$Value, [AllowNull()][string]$PrecomputedJson = $null)
        if (-not $PartsDirectory) { return $false }
        try {
            $valueJson = $PrecomputedJson
            if (-not $valueJson) { $valueJson = $Value | ConvertTo-Json -Depth 12 -Compress }
            if ([string]::IsNullOrWhiteSpace($valueJson)) { return $false }
            if ($MaxInlineBytes -gt 0 -and $valueJson.Length -le $MaxInlineBytes) { return $false }
            if (-not (Test-Path -LiteralPath $PartsDirectory)) { New-Item -ItemType Directory -Path $PartsDirectory -Force | Out-Null }
            $partName = ($FlatKey -replace '[^A-Za-z0-9._-]', '_') + '.json'
            [IO.File]::WriteAllText((Join-Path $PartsDirectory $partName), $valueJson, [Text.UTF8Encoding]::new($false))
            return $partName
        }
        catch {
            return $false
        }
    }
    $encode = {
        param([string]$FlatKey, [object]$Value, [int]$Depth = 0)
        # Returns [ordered]@{ ok = $true; value = <inline value|part> } or
        # @{ ok = $false } when rejected. The wrapper exists because $null, $null
        # and an empty array all collapse to 'no output' when a function returns
        # them; Phase 5.2 found empty arrays and null state values being listed
        # as serialization failures (body.state.session, failures).
        $probeOk = & $probe $Value
        $valueJson = $null
        $oversized = $false
        if ($probeOk -and $MaxInlineBytes -gt 0 -and $PartsDirectory) {
            try { $valueJson = $Value | ConvertTo-Json -Depth 12 -Compress } catch { $valueJson = $null }
            $oversized = ($valueJson -and $valueJson.Length -gt $MaxInlineBytes)
        }
        if ((($oversized) -or (-not $probeOk)) -and $Depth -lt 3 -and ($Value -is [System.Collections.IDictionary])) {
            # Split the big or unserializable value by its own keys: healthy
            # children still reach the controller (a big one as a part file, a
            # small one inline) and only the failing children are named under
            # serializationDiagnostics/bodySerializationFailures.
            $child = [ordered]@{}
            foreach ($childKey in @($Value.Keys)) {
                $childValue = Get-FirstVisitResultField -InputObject $Value -Name $childKey
                $encodedChild = & $encode ("$FlatKey.$childKey") $childValue ($Depth + 1)
                if (-not $encodedChild.ok) {
                    $failures.Add("$FlatKey.$childKey")
                    continue
                }
                $child[[string]$childKey] = $encodedChild.value
            }
            return [ordered]@{ ok = $true; value = $child }
        }
        if (-not $probeOk) {
            if ($customProbe) { $diagnostics[$FlatKey] = 'custom-probe-rejected' }
            else { $diagnostics[$FlatKey] = (Get-FirstVisitSerializationError -Value $Value) }
            return [ordered]@{ ok = $false }
        }
        $partName = & $writePart $FlatKey $Value $valueJson
        if ($partName) {
            $count = -1
            if ($Value -is [System.Collections.ICollection]) { $count = $Value.Count }
            $parts[$FlatKey] = [string]$partName
            $sha = ''
            try {
                $sha = (Get-FileHash -LiteralPath (Join-Path $PartsDirectory $partName) -Algorithm SHA256).Hash.ToLowerInvariant()
            }
            catch { }
            return [ordered]@{ ok = $true; value = [ordered]@{ firstVisitPart = [string]$partName; bytes = 0; count = $count; sha256 = $sha } }
        }
        return [ordered]@{ ok = $true; value = $Value }
    }
    $reduced = [ordered]@{}
    foreach ($key in @($Payload.Keys)) {
        if ($key -eq 'body') { continue }
        $encoded = & $encode ([string]$key) $Payload[$key]
        if ($encoded.ok) { $reduced[[string]$key] = $encoded.value }
        else { $failures.Add([string]$key) }
    }
    $body = Get-FirstVisitResultField -InputObject $Payload -Name 'body'
    $reducedBody = [ordered]@{}
    $state = [ordered]@{}
    if ($body) {
        foreach ($key in @($body.Keys)) {
            if ($key -eq 'state') { continue }
            $value = Get-FirstVisitResultField -InputObject $body -Name $key
            $encoded = & $encode ("body.$key") $value
            if ($encoded.ok) { $reducedBody[[string]$key] = $encoded.value }
            else { $failures.Add("body.$key") }
        }
        $stateObject = Get-FirstVisitResultField -InputObject $body -Name 'state'
        if ($stateObject -and ($stateObject -is [System.Collections.IDictionary] -or $stateObject.PSObject)) {
            foreach ($key in @($stateObject.Keys)) {
                $value = Get-FirstVisitResultField -InputObject $stateObject -Name $key
                $encoded = & $encode ("body.state.$key") $value
                if ($encoded.ok) { $state[[string]$key] = $encoded.value }
                else { $failures.Add("body.state.$key") }
            }
        }
    }
    $reducedBody['state'] = $state
    $reducedBody['bodySerializationFailures'] = @($failures.ToArray())
    if ($diagnostics.Count -gt 0) { $reducedBody['serializationDiagnostics'] = $diagnostics }
    if ($parts.Count -gt 0) { $reducedBody['resultParts'] = $parts }
    $reduced['body'] = $reducedBody
    if (-not $reduced.Contains('status')) { $reduced['status'] = [string](Get-FirstVisitResultField -InputObject $Payload -Name 'status') }
    if (-not $reduced.Contains('step')) { $reduced['step'] = [string](Get-FirstVisitResultField -InputObject $Payload -Name 'step') }
    if (-not $reduced.Contains('failures')) { $reduced['failures'] = @($failures | ForEach-Object { "serialization-failed:$_" }) }
    try {
        $fallbackJson = $reduced | ConvertTo-Json -Depth 12 -Compress
        if (-not [string]::IsNullOrWhiteSpace($fallbackJson)) { return [string]$fallbackJson }
    }
    catch { }
    # Last resort: only plain strings and string arrays, so it always serializes.
    $minimal = [ordered]@{
        status   = [string](Get-FirstVisitResultField -InputObject $Payload -Name 'status')
        step     = [string](Get-FirstVisitResultField -InputObject $Payload -Name 'step')
        failures = @($failures | ForEach-Object { "serialization-failed:$_" })
        body     = [ordered]@{ state = [ordered]@{}; bodySerializationFailures = @($failures.ToArray()) }
    }
    try { return [string]($minimal | ConvertTo-Json -Depth 6 -Compress) } catch { }
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

Export-ModuleMember -Function ConvertTo-FirstVisitResultJson, Get-FirstVisitResultFromOutput, Resolve-FirstVisitGuestResult, Test-FirstVisitSerializableValue, Get-FirstVisitSerializationError, Limit-FirstVisitResultValue, ConvertTo-FirstVisitPlainString
