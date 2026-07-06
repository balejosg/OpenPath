# Single owner of the captive-portal state-file read (marker + observation JSON
# under data\). Used by CaptivePortal.psm1 (admin context) and by
# NativeHost.Actions.CaptivePortal.ps1 (unelevated native host; staged via
# NativeHost.ArtifactCatalog.ps1). Pure read-only helper: returns $null when the
# file is absent, empty, or unparseable. Path derivation deliberately stays with
# the callers (see the data/ state-store refactor plan).

function Read-OpenPathCaptivePortalStateJson {
    <#
    .SYNOPSIS
        Reads and deserializes a captive-portal state JSON file (marker or observation).
    .PARAMETER Path
        Full path to the JSON state file.
    .OUTPUTS
        PSCustomObject or $null
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path $Path -ErrorAction SilentlyContinue)) {
        return $null
    }

    try {
        $raw = Get-Content $Path -Raw -ErrorAction Stop
        if (-not $raw) {
            return $null
        }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $null
    }
}
