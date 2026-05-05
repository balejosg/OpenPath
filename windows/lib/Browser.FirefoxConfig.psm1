# OpenPath Firefox network autoconfig for Windows

$script:OpenPathRoot = "C:\OpenPath"
Import-Module "$PSScriptRoot\Common.psm1" -ErrorAction SilentlyContinue
Import-Module "$PSScriptRoot\Browser.Common.psm1" -Force -ErrorAction Stop

$script:OpenPathFirefoxConfigMarker = '// OpenPath managed Firefox network hardening'

function New-OpenPathFirefoxNetworkAutoconfigContent {
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
    [CmdletBinding()]
    param()

    return @(
        "$env:ProgramFiles\Mozilla Firefox",
        "${env:ProgramFiles(x86)}\Mozilla Firefox"
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique
}

function Sync-OpenPathFirefoxNetworkAutoconfig {
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
