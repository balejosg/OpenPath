# OpenPath Firefox network autoconfig for Windows

. (Join-Path $PSScriptRoot 'internal\WindowsRoot.ps1')
$script:OpenPathRoot = Resolve-OpenPathWindowsRoot
Import-Module "$PSScriptRoot\Common.psm1" -ErrorAction SilentlyContinue
Import-Module "$PSScriptRoot\Browser.Common.psm1" -Force -ErrorAction Stop

$script:OpenPathFirefoxConfigMarker = '// OpenPath managed Firefox network hardening'

function New-OpenPathFirefoxNetworkAutoconfigContent {
    # returns an object with AutoconfigJs and MozillaCfg strings that lock Firefox DNS settings to native resolution
    [CmdletBinding()]
    param()

    return [PSCustomObject]@{
        AutoconfigJs = @"
$script:OpenPathFirefoxConfigMarker
pref("general.config.filename", "mozilla.cfg");
pref("general.config.obscure_value", 0);
"@
        MozillaCfg = @"
$script:OpenPathFirefoxConfigMarker
lockPref("network.trr.mode", 5);
lockPref("network.trr.uri", "");
lockPref("network.dns.disablePrefetch", true);
lockPref("network.dnsCacheExpiration", 0);
lockPref("network.dnsCacheExpirationGracePeriod", 0);
"@
    }
}

function Get-OpenPathFirefoxInstallDirectories {
    # returns all existing Firefox install directories from the standard 64-bit and 32-bit program files locations
    [CmdletBinding()]
    param()

    return @(
        "$env:ProgramFiles\Mozilla Firefox",
        "${env:ProgramFiles(x86)}\Mozilla Firefox"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
}

function Sync-OpenPathFirefoxNetworkAutoconfig {
    # writes autoconfig.js and mozilla.cfg into each Firefox install directory; skips files not already OpenPath-managed; returns true if at least one directory was updated
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $firefoxDirs = @(Get-OpenPathFirefoxInstallDirectories)
    if ($firefoxDirs.Count -eq 0) {
        Write-OpenPathLog 'Firefox not detected; network autoconfig skipped' -Level WARN
        return $false
    }

    $content = New-OpenPathFirefoxNetworkAutoconfigContent
    $written = 0
    foreach ($firefoxDir in $firefoxDirs) {
        $defaultsPrefDir = Join-Path $firefoxDir 'defaults\pref'
        $autoconfigPath = Join-Path $defaultsPrefDir 'autoconfig.js'
        $mozillaCfgPath = Join-Path $firefoxDir 'mozilla.cfg'

        try {
            if ($PSCmdlet.ShouldProcess($firefoxDir, 'Write OpenPath Firefox network autoconfig')) {
                $canWrite = $true
                foreach ($existingPath in @($autoconfigPath, $mozillaCfgPath)) {
                    if (Test-Path $existingPath) {
                        $existingContent = Get-Content $existingPath -Raw -ErrorAction Stop
                        if ($existingContent -notlike "*$script:OpenPathFirefoxConfigMarker*") {
                            Write-OpenPathLog "Skipping Firefox network autoconfig in $firefoxDir because $existingPath is not OpenPath-managed" -Level WARN
                            $canWrite = $false
                            break
                        }
                    }
                }
                if (-not $canWrite) { continue }
                Write-OpenPathUtf8NoBomFile -Path $autoconfigPath -Value $content.AutoconfigJs
                Write-OpenPathUtf8NoBomFile -Path $mozillaCfgPath -Value $content.MozillaCfg
                $written++
            }
        }
        catch {
            Write-OpenPathLog "Failed to write Firefox network autoconfig in $firefoxDir : $_" -Level WARN
        }
    }

    return ($written -gt 0)
}

function Remove-OpenPathFirefoxNetworkAutoconfig {
    # removes OpenPath-managed autoconfig files from each Firefox install directory; silently skips files not bearing the OpenPath marker
    [CmdletBinding(SupportsShouldProcess)]
    param()

    foreach ($firefoxDir in @(Get-OpenPathFirefoxInstallDirectories)) {
        $paths = @(
            (Join-Path $firefoxDir 'defaults\pref\autoconfig.js'),
            (Join-Path $firefoxDir 'mozilla.cfg')
        )

        foreach ($path in $paths) {
            if (-not (Test-Path $path)) { continue }
            try {
                $content = Get-Content $path -Raw -ErrorAction Stop
                if ($content -notlike "*$script:OpenPathFirefoxConfigMarker*") {
                    Write-OpenPathLog "Skipping non-OpenPath Firefox autoconfig file: $path" -Level WARN
                    continue
                }
                if ($PSCmdlet.ShouldProcess($path, 'Remove OpenPath Firefox network autoconfig')) {
                    Remove-Item $path -Force -ErrorAction SilentlyContinue
                }
            }
            catch {
                Write-OpenPathLog "Failed to remove Firefox network autoconfig file $path : $_" -Level WARN
            }
        }
    }
}

Export-ModuleMember -Function @(
    'New-OpenPathFirefoxNetworkAutoconfigContent',
    'Get-OpenPathFirefoxInstallDirectories',
    'Sync-OpenPathFirefoxNetworkAutoconfig',
    'Remove-OpenPathFirefoxNetworkAutoconfig'
)
