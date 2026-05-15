function ConvertTo-OpenPathRedactedValue {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [string]) {
        $text = [string]$Value
        $text = $text -replace '/w/[^/\s?#]+/whitelist\.txt', '/w/[redacted]/whitelist.txt'
        $text = $text -replace '(?i)(token=)[^&\s]+', '$1[redacted]'
        return $text
    }

    return $Value
}

function ConvertTo-OpenPathRedactedObject {
    param(
        [AllowNull()]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [string]) {
        return (ConvertTo-OpenPathRedactedValue -Value $InputObject)
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $redacted = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $redacted[$key] = ConvertTo-OpenPathRedactedObject -InputObject $InputObject[$key]
        }
        return [PSCustomObject]$redacted
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        return @($InputObject | ForEach-Object { ConvertTo-OpenPathRedactedObject -InputObject $_ })
    }

    if ($InputObject.PSObject -and $InputObject.PSObject.Properties.Count -gt 0) {
        $redacted = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $redacted[$property.Name] = ConvertTo-OpenPathRedactedObject -InputObject $property.Value
        }
        return [PSCustomObject]$redacted
    }

    return (ConvertTo-OpenPathRedactedValue -Value $InputObject)
}
