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

function Get-OpenPathAcrylicArtifactSpec {
    <#
    .SYNOPSIS
        Returns the pinned Acrylic release version, hashes, and download URLs.
    .DESCRIPTION
        Single source of truth for the online installer, the offline package validator,
        the local cache, and the watchdog repair path.
    #>
    [CmdletBinding()]
    param()

    $version = '2.2.1'
    return [PSCustomObject]@{
        Version = $version
        PortableZipSha256 = '26a5601c813257c186cd69da617ee1fff254b84f3ecb542483af8f4a5cc520cd'
        ExecutableInstallerSha256 = 'be60bde686766a889a8878c8b27446ea3584e425583070eeef85b0b31c60adbc'
        PortableZipUrls = @(
            "https://github.com/balejosg/openpath/releases/download/acrylic-mirror-v$version/Acrylic-Portable.zip",
            "https://downloads.sourceforge.net/project/acrylic/Acrylic/$version/Acrylic-Portable.zip",
            "https://sourceforge.net/projects/acrylic/files/Acrylic/$version/Acrylic-Portable.zip/download",
            "https://master.dl.sourceforge.net/project/acrylic/Acrylic/$version/Acrylic-Portable.zip?viasf=1"
        )
        ExecutableInstallerUrls = @(
            "https://downloads.sourceforge.net/project/acrylic/Acrylic/$version/Acrylic.exe",
            "https://sourceforge.net/projects/acrylic/files/Acrylic/$version/Acrylic.exe/download",
            "https://master.dl.sourceforge.net/project/acrylic/Acrylic/$version/Acrylic.exe?viasf=1"
        )
    }
}

function Get-OpenPathAcrylicDataRoot {
    <#
    .SYNOPSIS
        Resolves the agent data directory that holds the Acrylic cache and repair state.
    #>
    param([string]$OpenPathRoot = '')

    if (Get-Command -Name Get-OpenPathCapabilityStorageRoot -ErrorAction SilentlyContinue) {
        return (Get-OpenPathCapabilityStorageRoot -OpenPathRoot $OpenPathRoot)
    }

    if ([string]::IsNullOrWhiteSpace($OpenPathRoot)) {
        $OpenPathRoot = if ($script:OpenPathRoot) { $script:OpenPathRoot } else { 'C:\OpenPath' }
    }
    return [System.IO.Path]::Combine($OpenPathRoot, 'data')
}

function Get-OpenPathAcrylicCachePath {
    <#
    .SYNOPSIS
        Returns the verified portable ZIP cache path under the agent data directory.
    #>
    param([string]$OpenPathRoot = '')

    $dataRoot = Get-OpenPathAcrylicDataRoot -OpenPathRoot $OpenPathRoot
    return [System.IO.Path]::Combine($dataRoot, 'cache', 'acrylic', 'Acrylic-Portable.zip')
}

function Get-OpenPathAcrylicRepairStatePath {
    <#
    .SYNOPSIS
        Returns the repair throttle/attempt state path under the agent data directory.
    #>
    param([string]$OpenPathRoot = '')

    $dataRoot = Get-OpenPathAcrylicDataRoot -OpenPathRoot $OpenPathRoot
    return [System.IO.Path]::Combine($dataRoot, 'acrylic-repair-state.json')
}

function Save-OpenPathAcrylicArtifactToCache {
    <#
    .SYNOPSIS
        Verifies a portable Acrylic ZIP and copies it into the local repair cache.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [string]$ExpectedSha256 = '',
        [string]$OpenPathRoot = ''
    )

    $spec = Get-OpenPathAcrylicArtifactSpec
    if ([string]::IsNullOrWhiteSpace($ExpectedSha256)) {
        $ExpectedSha256 = $spec.PortableZipSha256
    }

    Assert-AcrylicDownloadHash -Path $SourcePath -ExpectedSha256 $ExpectedSha256 -ArtifactName 'Acrylic-Portable.zip'
    if (-not (Test-AcrylicPortableArchive -Path $SourcePath)) {
        throw 'Acrylic artifact is not a valid portable release'
    }

    $cachePath = Get-OpenPathAcrylicCachePath -OpenPathRoot $OpenPathRoot
    $cacheDir = Split-Path -Parent $cachePath
    if (-not (Test-Path $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force -ErrorAction Stop | Out-Null
    }
    if ([System.IO.Path]::GetFullPath($SourcePath) -ne [System.IO.Path]::GetFullPath($cachePath)) {
        Copy-Item -LiteralPath $SourcePath -Destination $cachePath -Force -ErrorAction Stop
    }
    Write-OpenPathLog "Cached verified Acrylic artifact at $cachePath"
    return $cachePath
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

    $uiPath = Join-Path $AcrylicPath 'AcrylicUI.exe'
    $installProcess = $null
    if (Test-Path $uiPath) {
        try {
            # AcrylicService.exe is the service runtime, not the installer. The
            # portable release documents service registration through its UI.
            $installProcess = Start-Process `
                -FilePath $uiPath `
                -ArgumentList 'InstallAcrylicService' `
                -WorkingDirectory $AcrylicPath `
                -PassThru `
                -WindowStyle Hidden `
                -ErrorAction Stop
            if (-not $installProcess.WaitForExit(15000)) {
                Stop-Process -Id $installProcess.Id -Force -ErrorAction SilentlyContinue
                Write-OpenPathLog 'Acrylic UI service registration timed out; falling back to direct service registration' -Level WARN
            }
        }
        catch {
            Write-OpenPathLog "Acrylic UI service registration failed: $_" -Level WARN
        }
    }
    else {
        Write-OpenPathLog 'AcrylicUI.exe is absent; falling back to direct service registration' -Level WARN
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

function Get-AcrylicFileSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    # The offline bootstrapper invokes Windows PowerShell 5.1 with -NoProfile;
    # hash the literal file stream without relying on Get-FileHash module loading.
    $stream = $null
    $algorithm = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        $algorithm = [System.Security.Cryptography.SHA256]::Create()
        $digest = $algorithm.ComputeHash($stream)
        return ([System.BitConverter]::ToString($digest).Replace('-', '')).ToLowerInvariant()
    }
    finally {
        if ($algorithm) {
            $algorithm.Dispose()
        }
        if ($stream) {
            $stream.Dispose()
        }
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

    $actualSha256 = Get-AcrylicFileSha256 -Path $Path
    if ($actualSha256 -ne $ExpectedSha256.ToLowerInvariant()) {
        throw "$ArtifactName SHA256 mismatch. Expected $ExpectedSha256, got $actualSha256"
    }
}

function Install-OpenPathAcrylicFromVerifiedArchive {
    <#
    .SYNOPSIS
        Extracts a hash-verified Acrylic portable ZIP and registers its service.
    .DESCRIPTION
        Shared core for the offline installer and the watchdog reinstall path. The caller
        is responsible for hash and archive validation; this function only stages files
        and registers the service. Offline install-phase diagnostics are emitted when the
        offline helper is loaded.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)][string]$AcrylicZipPath,
        [string]$InstallDir = "${env:ProgramFiles(x86)}\Acrylic DNS Proxy",
        [string]$FailureStatusPath = ''
    )

    if (-not (Test-Path $AcrylicZipPath)) {
        throw "Acrylic ZIP not found: $AcrylicZipPath"
    }

    if (-not $PSCmdlet.ShouldProcess("Acrylic DNS Proxy from $AcrylicZipPath", 'Install locally')) {
        return $false
    }

    $writePhase = {
        param([string]$Phase)

        if ($FailureStatusPath -and (Get-Command -Name Write-OpenPathOfflineInstallPhase -ErrorAction SilentlyContinue)) {
            Write-OpenPathOfflineInstallPhase -Path $FailureStatusPath -Phase $Phase
        }
    }

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("acrylic-offline-" + [Guid]::NewGuid().ToString('N'))

    try {
        & $writePhase 'acrylic-local-create-temp'
        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        & $writePhase 'acrylic-local-extract'
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [System.IO.Compression.ZipFile]::ExtractToDirectory($AcrylicZipPath, $tempDir)
        if (-not (Test-Path $InstallDir)) {
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        }

        & $writePhase 'acrylic-local-stage'
        # The pinned Acrylic archive is flat. Preserve the historical
        # flattening of a single wrapper directory, while copying every root
        # entry when the archive has a mixed or flat layout.
        $extractedItems = @(Get-ChildItem -LiteralPath $tempDir -Force)
        $extractedDirectories = @($extractedItems | Where-Object { $_.PSIsContainer })
        $extractedFiles = @($extractedItems | Where-Object { -not $_.PSIsContainer })
        if ($extractedDirectories.Count -eq 1 -and $extractedFiles.Count -eq 0) {
            foreach ($nestedItem in @(Get-ChildItem -LiteralPath $extractedDirectories[0].FullName -Force)) {
                Copy-Item -LiteralPath $nestedItem.FullName -Destination $InstallDir -Recurse -Force
            }
        }
        else {
            foreach ($extractedItem in $extractedItems) {
                Copy-Item -LiteralPath $extractedItem.FullName -Destination $InstallDir -Recurse -Force
            }
        }

        & $writePhase 'acrylic-local-validate-output'
        if (-not (Test-Path (Join-Path $InstallDir 'AcrylicService.exe'))) {
            throw 'Local Acrylic install did not produce AcrylicService.exe'
        }

        & $writePhase 'acrylic-local-register'
        Register-AcrylicServiceFromPath -AcrylicPath $InstallDir | Out-Null
        & $writePhase 'acrylic-local-complete'
        Write-OpenPathLog 'Acrylic DNS Proxy installed from a verified local archive'
        return $true
    }
    finally {
        if (Test-Path $tempDir) {
            Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
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
    $artifact = Get-OpenPathAcrylicArtifactSpec
    $portableZipSha256 = $artifact.PortableZipSha256
    $executableInstallerSha256 = $artifact.ExecutableInstallerSha256
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
        foreach ($candidateUrl in @($artifact.PortableZipUrls)) {
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
            foreach ($candidateUrl in @($artifact.ExecutableInstallerUrls)) {
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

        try {
            Save-OpenPathAcrylicArtifactToCache -SourcePath $zipPath -ExpectedSha256 $portableZipSha256 | Out-Null
        }
        catch {
            Write-OpenPathLog "Could not cache the verified Acrylic artifact: $_" -Level WARN
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
