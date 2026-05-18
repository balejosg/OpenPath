function New-OpenPathInternetShortcut {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Url
    )

    $shortcutContent = @('[InternetShortcut]', "URL=$Url") -join [Environment]::NewLine
    Set-Content -Path $Path -Value $shortcutContent -Encoding ASCII
}

function Get-OpenPathChromiumBrowserTargets {
    param(
        [string]$ChromeStoreUrl = '',
        [string]$EdgeStoreUrl = ''
    )

    $browserTargets = @()
    if ($ChromeStoreUrl) {
        $chromeExecutablePath = @(
            "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
            "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
            "$env:LocalAppData\Google\Chrome\Application\chrome.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1

        $browserTargets += [PSCustomObject]@{
            Name = 'Google Chrome'
            ExecutablePath = [string]$chromeExecutablePath
            StoreUrl = [string]$ChromeStoreUrl
            ShortcutName = 'Install OpenPath for Google Chrome.url'
        }
    }

    if ($EdgeStoreUrl) {
        $edgeExecutablePath = @(
            "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
            "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
            "$env:LocalAppData\Microsoft\Edge\Application\msedge.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1

        $browserTargets += [PSCustomObject]@{
            Name = 'Microsoft Edge'
            ExecutablePath = [string]$edgeExecutablePath
            StoreUrl = [string]$EdgeStoreUrl
            ShortcutName = 'Install OpenPath for Microsoft Edge.url'
        }
    }

    return @($browserTargets)
}

function Install-OpenPathChromiumUnmanagedGuidance {
    param(
        [string]$ChromeStoreUrl = '',
        [string]$EdgeStoreUrl = '',
        [switch]$Unattended
    )

    $browserTargets = Get-OpenPathChromiumBrowserTargets -ChromeStoreUrl $ChromeStoreUrl -EdgeStoreUrl $EdgeStoreUrl
    if ($browserTargets.Count -eq 0) { return $false }

    $guidanceRoot = "$OpenPathRoot\browser-extension\chromium-unmanaged"
    Remove-Item $guidanceRoot -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $guidanceRoot -Force | Out-Null

    foreach ($browserTarget in $browserTargets) {
        $shortcutPath = Join-Path $guidanceRoot $browserTarget.ShortcutName
        New-OpenPathInternetShortcut -Path $shortcutPath -Url $browserTarget.StoreUrl
        Write-InstallerVerbose "  Chromium store guidance staged in $shortcutPath"

        if (-not $Unattended) {
            if ($browserTarget.ExecutablePath) {
                try {
                    Start-Process -FilePath $browserTarget.ExecutablePath -ArgumentList $browserTarget.StoreUrl | Out-Null
                    Write-InstallerVerbose "  Opened $($browserTarget.Name) store page for OpenPath extension"
                }
                catch {
                    Write-InstallerWarning "  WARNING: Could not open $($browserTarget.Name) automatically: $_"
                }
            }
            else {
                Write-InstallerWarning "  WARNING: $($browserTarget.Name) was not detected locally; open $shortcutPath manually"
            }
        }
    }

    if ($Unattended) {
        Write-InstallerWarning "  Chromium store guidance staged for unattended install"
    }

    return $true
}
