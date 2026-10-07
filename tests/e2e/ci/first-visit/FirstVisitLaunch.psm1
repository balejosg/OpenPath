# Phase 6.1 A: first-visit launch wrapper body.
#
# The wrapper runs as the student (through the session launcher) and starts
# the managed Firefox. The MOZ_LOG capture is enabled only for the real-site
# canary. The body builder is pure so the lane tests can assert the exact
# wrapper shape without a VM: every cmd directive on its own line, exactly one
# launch line carrying the quoted browser path, -new-window and the URL.
#
# Phase 6.1 fix: the previous here-string glued its last `set` directive to the
# launch line (`set MOZ_LOG_FILE_MAX_SIZE=4194304"C:\...\firefox.exe" ...`), so
# the wrapper never started Firefox. MOZ_LOG rotation now uses Firefox's own
# `rotate:16` option (four .0-.3 files) instead of the unsupported
# MOZ_LOG_FILE_MAX_SIZE environment variable.

function ConvertTo-OpenPathFirstVisitFirefoxCmdBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FirefoxPath,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Tag,
        [Parameter(Mandatory = $true)][string]$Root,
        [bool]$MozLog = $false,
        [string]$MozLogSpec = 'timestamp,rotate:16,nsHostResolver:5',
        [string]$MozLogFile = ''
    )
    if (-not $MozLogFile) { $MozLogFile = "$Root\moz\hostresolver.log" }
    $lines = @('@echo off')
    $lines += "echo launch %DATE% %TIME% user=%USERNAME% tag=$Tag >> ""$Root\logs\launch.log"""
    if ($MozLog) {
        # One directive per line; never a here-string that can glue them.
        $lines += "set MOZ_LOG=$MozLogSpec"
        $lines += "set MOZ_LOG_FILE=$MozLogFile"
    }
    $lines += """$FirefoxPath"" -new-window ""$Url"" >> ""$Root\logs\firefox-$Tag.log"" 2>&1"
    $lines += "echo exit %ERRORLEVEL% >> ""$Root\logs\launch.log"""
    return (($lines -join "`r`n") + "`r`n")
}

Export-ModuleMember -Function ConvertTo-OpenPathFirstVisitFirefoxCmdBody
