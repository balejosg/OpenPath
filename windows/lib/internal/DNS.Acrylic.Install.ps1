function Get-AcrylicPath {
    <#
    .SYNOPSIS
        Returns the directory where AcrylicService.exe is installed, or null if Acrylic is not found
    #>
    $defaultPath = "${env:ProgramFiles(x86)}\Acrylic DNS Proxy"
    try {
        $config = Get-OpenPathConfig
        if ($config.acrylicPath -and (Test-Path (Join-Path $config.acrylicPath 'AcrylicService.exe'))) {
            return $config.acrylicPath
        }
    }
    catch {
        Write-Debug "Config not available: $_"
    }

    $candidatePaths = @(
        $defaultPath,
        "$env:ProgramFiles\Acrylic DNS Proxy",
        "$env:ProgramData\chocolatey\lib\acrylic-dns-proxy\tools",
        "$env:ProgramData\chocolatey\lib\acrylic-dns-proxy"
    )

    if ($env:ChocolateyInstall) {
        $candidatePaths += @(
            (Join-Path $env:ChocolateyInstall 'lib\acrylic-dns-proxy\tools'),
            (Join-Path $env:ChocolateyInstall 'lib\acrylic-dns-proxy')
        )
    }

    foreach ($candidatePath in @($candidatePaths | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Path (Join-Path $candidatePath 'AcrylicService.exe')) {
            return $candidatePath
        }
    }

    $searchRoots = @(
        "$env:ProgramData\chocolatey\lib\acrylic-dns-proxy",
        $(if ($env:ChocolateyInstall) { Join-Path $env:ChocolateyInstall 'lib\acrylic-dns-proxy' })
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    foreach ($searchRoot in $searchRoots) {
        $serviceExecutable = Get-ChildItem -Path $searchRoot -Filter 'AcrylicService.exe' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($serviceExecutable) {
            return $serviceExecutable.DirectoryName
        }
    }
    return $null
}

function Test-AcrylicInstalled {
    <#
    .SYNOPSIS
        Returns true when AcrylicService.exe exists at the detected Acrylic installation path
    #>
    $path = Get-AcrylicPath
    return ($null -ne $path -and (Test-Path "$path\AcrylicService.exe"))
}

function Get-AcrylicRegisteredService {
    <#
    .SYNOPSIS
        Returns the Windows service object for the Acrylic DNS proxy, or null if not registered
    #>
    $service = Get-Service -Name 'AcrylicDNSProxySvc' -ErrorAction SilentlyContinue
    if ($service) { return $service }

    return Get-Service -DisplayName '*Acrylic*' -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Register-AcrylicServiceFromPath {
    <#
    .SYNOPSIS
        Registers the Acrylic Windows service from an existing installation directory
    .PARAMETER AcrylicPath
        Directory that contains AcrylicService.exe
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$AcrylicPath)

    $servicePath = Join-Path $AcrylicPath 'AcrylicService.exe'
    if (-not (Test-Path $servicePath)) { return $false }

    $service = Get-AcrylicRegisteredService
    if ($service) { return $true }

    $installProcess = $null
    try {
        $installProcess = Start-Process -FilePath $servicePath -ArgumentList '/INSTALL' -PassThru -WindowStyle Hidden -ErrorAction Stop
        if (-not $installProcess.WaitForExit(15000)) {
            Stop-Process -Id $installProcess.Id -Force -ErrorAction SilentlyContinue
            Write-OpenPathLog 'Acrylic service registration process timed out; falling back to direct service registration' -Level WARN
        }
    }
    catch {
        Write-OpenPathLog "Acrylic service registration executable failed: $_" -Level WARN
    }

    Start-Sleep -Seconds 2
    $service = Get-AcrylicRegisteredService
    if (-not $service) {
        try {
            New-Service -Name 'AcrylicDNSProxySvc' `
                -BinaryPathName ('"{0}"' -f $servicePath) `
                -DisplayName 'Acrylic DNS Proxy Service' `
                -StartupType Automatic `
                -ErrorAction Stop | Out-Null
            Start-Sleep -Seconds 1
            $service = Get-AcrylicRegisteredService
        }
        catch {
            Write-OpenPathLog "Direct Acrylic service registration failed: $_" -Level WARN
        }
    }

    return ($null -ne $service)
}

function Invoke-AcrylicPortableDownload {
    <#
    .SYNOPSIS
        Downloads a file from the given URL to the destination path, using curl when available and WebClient otherwise
    .PARAMETER Url
        Source URL to download
    .PARAMETER DestinationPath
        Local file path to write the downloaded content
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    $userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) OpenPathInstaller'
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & $curl.Source -fL -sS --retry 3 --retry-delay 2 -A $userAgent -o $DestinationPath $Url
        if ($LASTEXITCODE -eq 0 -and (Test-Path $DestinationPath)) {
            return
        }
    }

    $webClient = $null
    try {
        $webClient = New-Object System.Net.WebClient
        $webClient.Headers.Add('user-agent', $userAgent)
        $webClient.DownloadFile($Url, $DestinationPath)
    }
    finally {
        if ($null -ne $webClient) {
            $webClient.Dispose()
        }
    }
}

function Test-AcrylicPortableArchive {
    <#
    .SYNOPSIS
        Returns true when the ZIP at the given path contains AcrylicService.exe, confirming it is a valid portable release
    .PARAMETER Path
        Path to the downloaded ZIP file to inspect
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path $Path)) { return $false }

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            return ($archive.Entries | Where-Object { $_.FullName -match 'AcrylicService\.exe$' } | Select-Object -First 1) -ne $null
        }
        finally {
            $archive.Dispose()
        }
    }
    catch {
        Write-OpenPathLog "Downloaded Acrylic archive is invalid: $_" -Level WARN
        return $false
    }
}

function Assert-AcrylicDownloadHash {
    <#
    .SYNOPSIS
        Throws if the SHA256 of the file at Path does not match ExpectedSha256
    .PARAMETER Path
        Local file to hash
    .PARAMETER ExpectedSha256
        Hex string of the expected SHA256 digest
    .PARAMETER ArtifactName
        Display name included in the error message on mismatch
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$ArtifactName
    )

    $actualSha256 = (Get-FileHash -Path $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "$ArtifactName SHA256 mismatch. Expected $ExpectedSha256, got $actualSha256"
    }
}

function Install-AcrylicDNS {
    <#
    .SYNOPSIS
        Downloads and installs Acrylic DNS Proxy, falling back to Chocolatey when the direct download fails
    .PARAMETER Force
        Reinstalls even when Acrylic is already present
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [switch]$Force
    )

    if ((Test-AcrylicInstalled) -and -not $Force) {
        Write-OpenPathLog "Acrylic DNS Proxy already installed"
        return $true
    }

    if (-not $PSCmdlet.ShouldProcess("Acrylic DNS Proxy", "Install")) {
        return $false
    }

    Write-OpenPathLog "Installing Acrylic DNS Proxy..."
    $installerVersion = "2.2.1"
    $portableZipSha256 = '26a5601c813257c186cd69da617ee1fff254b84f3ecb542483af8f4a5cc520cd'
    $executableInstallerSha256 = 'be60bde686766a889a8878c8b27446ea3584e425583070eeef85b0b31c60adbc'
    $githubMirrorUrl = "https://github.com/balejosg/openpath/releases/download/acrylic-mirror-v$installerVersion/Acrylic-Portable.zip"
    $installerUrl = "https://downloads.sourceforge.net/project/acrylic/Acrylic/$installerVersion/Acrylic-Portable.zip"
    $installerFallbackUrl = "https://sourceforge.net/projects/acrylic/files/Acrylic/$installerVersion/Acrylic-Portable.zip/download"
    $installerMirrorUrl = "https://master.dl.sourceforge.net/project/acrylic/Acrylic/$installerVersion/Acrylic-Portable.zip?viasf=1"
    $executableInstallerUrls = @(
        "https://downloads.sourceforge.net/project/acrylic/Acrylic/$installerVersion/Acrylic.exe",
        "https://sourceforge.net/projects/acrylic/files/Acrylic/$installerVersion/Acrylic.exe/download",
        "https://master.dl.sourceforge.net/project/acrylic/Acrylic/$installerVersion/Acrylic.exe?viasf=1"
    )
    $tempDir = "$env:TEMP\acrylic-install"
    $installDir = "${env:ProgramFiles(x86)}\Acrylic DNS Proxy"

    try {
        if (Test-Path $tempDir) {
            Remove-Item $tempDir -Recurse -Force
        }
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        Write-OpenPathLog "Downloading Acrylic..."
        $zipPath = "$tempDir\acrylic.zip"
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

        $downloadError = $null
        foreach ($candidateUrl in @($githubMirrorUrl, $installerUrl, $installerFallbackUrl, $installerMirrorUrl)) {
            try {
                if (Test-Path $zipPath) {
                    Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                }
                Invoke-AcrylicPortableDownload -Url $candidateUrl -DestinationPath $zipPath
                Assert-AcrylicDownloadHash -Path $zipPath -ExpectedSha256 $portableZipSha256 -ArtifactName 'Acrylic-Portable.zip'
                if (-not (Test-AcrylicPortableArchive -Path $zipPath)) {
                    throw "Downloaded Acrylic archive from ${candidateUrl} was not a valid portable release"
                }
                $downloadError = $null
                break
            }
            catch {
                $downloadError = $_
                Write-OpenPathLog "Acrylic download failed from ${candidateUrl}: $downloadError" -Level WARN
            }
        }

        if ($downloadError) {
            $executableInstallError = $null
            $exePath = "$tempDir\Acrylic.exe"
            foreach ($candidateUrl in $executableInstallerUrls) {
                try {
                    if (Test-Path $exePath) {
                        Remove-Item $exePath -Force -ErrorAction SilentlyContinue
                    }
                    Invoke-AcrylicPortableDownload -Url $candidateUrl -DestinationPath $exePath
                    Assert-AcrylicDownloadHash -Path $exePath -ExpectedSha256 $executableInstallerSha256 -ArtifactName 'Acrylic.exe'
                    & $exePath /S
                    $exeExitCode = $LASTEXITCODE
                    if ($exeExitCode -ne 0) {
                        throw "Acrylic executable installer exited with code $exeExitCode"
                    }
                    Start-Sleep -Seconds 2
                    $acrylicPath = Get-AcrylicPath
                    if ($acrylicPath -and (Register-AcrylicServiceFromPath -AcrylicPath $acrylicPath) -and (Test-AcrylicInstalled)) {
                        Write-OpenPathLog "Acrylic DNS Proxy installed successfully via executable installer"
                        return $true
                    }
                    throw "Acrylic direct executable install did not produce AcrylicService.exe"
                }
                catch {
                    $executableInstallError = $_
                    Write-OpenPathLog "Acrylic executable install failed from ${candidateUrl}: $executableInstallError" -Level WARN
                }
            }
            if ($executableInstallError) { throw $executableInstallError }
            throw $downloadError
        }

        Write-OpenPathLog "Extracting..."
        Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force
        if (-not (Test-Path $installDir)) {
            New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        }
        $extractedDir = Get-ChildItem $tempDir -Directory | Select-Object -First 1
        if ($extractedDir) {
            Copy-Item "$($extractedDir.FullName)\*" $installDir -Recurse -Force
        }
        else {
            Copy-Item "$tempDir\*" $installDir -Recurse -Force -Exclude "*.zip"
        }
        Write-OpenPathLog "Installing Acrylic service..."
        if (Test-Path (Join-Path $installDir 'AcrylicService.exe')) {
            Register-AcrylicServiceFromPath -AcrylicPath $installDir | Out-Null
        }
        Write-OpenPathLog "Acrylic DNS Proxy installed successfully"
        return $true
    }
    catch {
        $directInstallError = $_
        Write-OpenPathLog "Direct Acrylic install failed: $directInstallError" -Level WARN
        $choco = Get-Command choco -ErrorAction SilentlyContinue
        if ($choco) {
            Write-OpenPathLog "Falling back to Chocolatey package acrylic-dns-proxy..."
            & $choco.Source install acrylic-dns-proxy -y --no-progress
            $chocoExitCode = $LASTEXITCODE
            $validExitCodes = @(0, 1605, 1614, 1641, 3010)
            if ($validExitCodes -contains $chocoExitCode) {
                Start-Sleep -Seconds 2
                $acrylicPath = Get-AcrylicPath
                if ($acrylicPath -and (Register-AcrylicServiceFromPath -AcrylicPath $acrylicPath)) {
                    Write-OpenPathLog "Acrylic DNS Proxy installed successfully via Chocolatey"
                    return $true
                }
                Write-OpenPathLog "Chocolatey fallback completed with exit code $chocoExitCode but AcrylicService.exe was not found" -Level WARN
            }
            Write-OpenPathLog "Chocolatey fallback failed with exit code $chocoExitCode" -Level ERROR
        }
        Write-OpenPathLog "Failed to install Acrylic: $directInstallError" -Level ERROR
        return $false
    }
    finally {
        if (Test-Path $tempDir) {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
