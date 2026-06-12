function Get-WatchdogFailCount {
    # reads the integer fail count from $WatchdogFailCountPath; returns 0 when the file is absent or unreadable.
    param(
        [Parameter(Mandatory = $true)]
        [string]$WatchdogFailCountPath
    )

    if (-not (Test-Path $WatchdogFailCountPath)) {
        return 0
    }

    try {
        $rawValue = Get-Content $WatchdogFailCountPath -Raw -ErrorAction Stop
        return [int]$rawValue
    }
    catch {
        return 0
    }
}

function Set-WatchdogFailCount {
    # writes $Count (floored at 0) to $WatchdogFailCountPath as a UTF-8 encoded integer.
    param(
        [Parameter(Mandatory = $true)]
        [string]$WatchdogFailCountPath,

        [Parameter(Mandatory = $true)]
        [int]$Count
    )

    Set-Content $WatchdogFailCountPath -Value ([Math]::Max($Count, 0)) -Encoding UTF8
}

function Increment-WatchdogFailCount {
    # increments the stored fail count by one and returns the new value.
    param(
        [Parameter(Mandatory = $true)]
        [string]$WatchdogFailCountPath
    )

    $newCount = (Get-WatchdogFailCount -WatchdogFailCountPath $WatchdogFailCountPath) + 1
    Set-WatchdogFailCount -WatchdogFailCountPath $WatchdogFailCountPath -Count $newCount
    return $newCount
}

function Reset-WatchdogFailCount {
    # resets the stored fail count to zero.
    param(
        [Parameter(Mandatory = $true)]
        [string]$WatchdogFailCountPath
    )

    Set-WatchdogFailCount -WatchdogFailCountPath $WatchdogFailCountPath -Count 0
}
