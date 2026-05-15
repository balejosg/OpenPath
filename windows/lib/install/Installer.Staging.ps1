function Initialize-OpenPathInstallDirectories {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot
    )

    $dirs = @(
        "$OpenPathRoot\lib",
        "$OpenPathRoot\lib\internal",
        "$OpenPathRoot\lib\install",
        "$OpenPathRoot\scripts",
        "$OpenPathRoot\data\logs",
        "$OpenPathRoot\data\runtime-dependency-queue",
        "$OpenPathRoot\browser-extension\firefox",
        "$OpenPathRoot\browser-extension\firefox-release",
        "$OpenPathRoot\browser-extension\chromium-managed",
        "$OpenPathRoot\browser-extension\chromium-unmanaged"
    )

    foreach ($dir in $dirs) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
    Write-InstallerVerbose "  Estructura creada en $OpenPathRoot"

    Write-InstallerVerbose "  Aplicando permisos restrictivos..."
    try {
        $acl = Get-Acl $OpenPathRoot
        $acl.SetAccessRuleProtection($true, $false)
        $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) } | Out-Null

        $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "NT AUTHORITY\SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.AddAccessRule($systemRule)

        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "BUILTIN\Administrators", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $acl.AddAccessRule($adminRule)

        Set-Acl $OpenPathRoot $acl
        Write-InstallerVerbose "  Permisos aplicados (solo SYSTEM y Administradores)"
    }
    catch {
        Write-InstallerWarning "  ADVERTENCIA: No se pudieron restringir permisos: $_"
    }

    $browserExtensionAclPath = "$OpenPathRoot\browser-extension"
    if (Test-Path $browserExtensionAclPath) {
        try {
            $browserExtensionAcl = Get-Acl $browserExtensionAclPath
            $usersReadRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "BUILTIN\Users", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow")
            $browserExtensionAcl.AddAccessRule($usersReadRule)
            Set-Acl $browserExtensionAclPath $browserExtensionAcl
            Write-InstallerVerbose "  Read access granted for browser extension artifacts"
        }
        catch {
            Write-InstallerWarning "  ADVERTENCIA: No se pudo habilitar lectura para browser-extension: $_"
        }
    }

    $runtimeDependencyQueuePath = "$OpenPathRoot\data\runtime-dependency-queue"
    if (Test-Path $runtimeDependencyQueuePath) {
        try {
            $runtimeDependencyQueueAcl = Get-Acl $runtimeDependencyQueuePath
            $usersModifyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                "BUILTIN\Users", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
            $runtimeDependencyQueueAcl.AddAccessRule($usersModifyRule)
            Set-Acl $runtimeDependencyQueuePath $runtimeDependencyQueueAcl
            Write-InstallerVerbose "  Runtime dependency queue write access granted for browser users"
        }
        catch {
            Write-InstallerWarning "  ADVERTENCIA: No se pudo habilitar escritura para runtime-dependency-queue: $_"
        }
    }
}

function Copy-OpenPathInstallerRuntime {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot,

        [Parameter(Mandatory = $true)]
        [string]$ScriptDir,

        [switch]$Unattended,

        [string]$ChromeExtensionStoreUrl = "",

        [string]$EdgeExtensionStoreUrl = "",

        [string]$FirefoxExtensionId = "",

        [string]$FirefoxExtensionInstallUrl = ""
    )

    $requiredScriptFiles = @(
        'Apply-RuntimeDependencyQueue.ps1',
        'Enroll-Machine.ps1',
        'Pre-Install-Validation.ps1',
        'Start-SSEListener.ps1',
        'Test-DNSHealth.ps1',
        'Update-OpenPath.ps1'
    )

    Get-ChildItem "$ScriptDir\lib\*.psm1" -ErrorAction Stop |
        Copy-Item -Destination "$OpenPathRoot\lib\" -Force -ErrorAction Stop
    Get-ChildItem "$ScriptDir\lib\internal\*.ps1" -ErrorAction Stop |
        Copy-Item -Destination "$OpenPathRoot\lib\internal\" -Force -ErrorAction Stop
    New-Item -ItemType Directory -Path "$OpenPathRoot\lib\install" -Force | Out-Null
    Get-ChildItem "$ScriptDir\lib\install\*.ps1" -ErrorAction Stop |
        Copy-Item -Destination "$OpenPathRoot\lib\install\" -Force -ErrorAction Stop
    if (-not (Test-Path (Join-Path $OpenPathRoot 'lib\install\Installer.Cleanup.ps1'))) {
        throw "Required installer helper was not staged into OpenPath runtime: Installer.Cleanup.ps1"
    }

    $browserPolicySpecCandidates = @(
        (Join-Path $ScriptDir 'runtime\browser-policy-spec.json'),
        [System.IO.Path]::GetFullPath((Join-Path $ScriptDir '..\runtime\browser-policy-spec.json'))
    )
    $browserPolicySpecInstalled = $false

    foreach ($browserPolicySpecSource in $browserPolicySpecCandidates) {
        if (Test-Path $browserPolicySpecSource) {
            Copy-Item $browserPolicySpecSource -Destination "$OpenPathRoot\lib\browser-policy-spec.json" -Force
            $browserPolicySpecInstalled = $true
            break
        }
    }
    if (-not $browserPolicySpecInstalled) {
        throw "Browser policy spec not found in installer runtime ($($browserPolicySpecCandidates -join ', '))"
    }

    foreach ($requiredScriptFile in $requiredScriptFiles) {
        $requiredScriptSource = Join-Path (Join-Path $ScriptDir 'scripts') $requiredScriptFile
        if (-not (Test-Path $requiredScriptSource)) {
            throw "Required installer script missing from bootstrap package: $requiredScriptSource"
        }
    }

    Get-ChildItem "$ScriptDir\scripts\*.ps1" -ErrorAction Stop |
        Copy-Item -Destination "$OpenPathRoot\scripts\" -Force -ErrorAction Stop
    Get-ChildItem "$ScriptDir\scripts\*.cmd" -ErrorAction SilentlyContinue |
        Copy-Item -Destination "$OpenPathRoot\scripts\" -Force -ErrorAction Stop

    foreach ($requiredScriptFile in $requiredScriptFiles) {
        $requiredScriptTarget = Join-Path (Join-Path $OpenPathRoot 'scripts') $requiredScriptFile
        if (-not (Test-Path $requiredScriptTarget)) {
            throw "Required installer script was not staged into OpenPath runtime: $requiredScriptTarget"
        }
    }

    $rootScripts = @('OpenPath.ps1', 'Rotate-Token.ps1')
    foreach ($rootScript in $rootScripts) {
        $sourcePath = Join-Path $ScriptDir $rootScript
        if (Test-Path $sourcePath) {
            Copy-Item $sourcePath -Destination (Join-Path $OpenPathRoot $rootScript) -Force
        }
    }

    $browserExtensionCandidates = @(
        (Join-Path $ScriptDir 'browser-extension\firefox'),
        (Join-Path $ScriptDir 'firefox-extension'),
        (Join-Path (Split-Path $ScriptDir -Parent) 'firefox-extension')
    )
    $browserExtensionSource = $browserExtensionCandidates |
        Where-Object { Test-Path (Join-Path $_ 'manifest.json') } |
        Select-Object -First 1

    if ($browserExtensionSource) {
        $browserExtensionTarget = "$OpenPathRoot\browser-extension\firefox"
        $requiredItems = @('manifest.json', 'dist', 'popup', 'icons', 'blocked')
        $missingItems = @(
            $requiredItems | Where-Object { -not (Test-Path (Join-Path $browserExtensionSource $_)) }
        )

        if ($missingItems.Count -eq 0) {
            Remove-Item $browserExtensionTarget -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $browserExtensionTarget -Force | Out-Null

            foreach ($item in $requiredItems) {
                Copy-Item (Join-Path $browserExtensionSource $item) -Destination $browserExtensionTarget -Recurse -Force
            }

            if (Test-Path (Join-Path $browserExtensionSource 'native')) {
                Copy-Item (Join-Path $browserExtensionSource 'native') -Destination $browserExtensionTarget -Recurse -Force
            }

            Write-InstallerVerbose "  Firefox development extension assets staged in $OpenPathRoot\browser-extension\firefox"
        }
        else {
            Write-InstallerWarning "  ADVERTENCIA: Firefox development extension source incomplete ($($missingItems -join ', '))"
        }
    }
    else {
        Write-InstallerWarning "  ADVERTENCIA: Firefox development extension source not found; local unsigned bundle staging skipped"
    }

    $firefoxNativeHostTarget = "$OpenPathRoot\browser-extension\firefox\native"
    $nativeHostSourceRoot = Join-Path $ScriptDir 'scripts'
    $nativeHostHelperRoot = Join-Path $ScriptDir 'lib\internal'
    $nativeHostArtifacts = @(
        'OpenPath-NativeHost.ps1',
        'OpenPath-NativeHost.cmd',
        'RequestSetup.State.psm1',
        'Common.Redaction.ps1',
        'RuntimeDependency.Policy.ps1',
        'RuntimeDependency.Queue.ps1',
        'RuntimeDependency.Overlay.ps1',
        'NativeHost.State.ps1',
        'NativeHost.Protocol.ps1',
        'NativeHost.Actions.ps1'
    )
    $nativeHostSourceRoots = @($nativeHostSourceRoot, $nativeHostHelperRoot)
    $nativeHostArtifactSources = @{}
    $missingNativeHostArtifacts = @()

    foreach ($nativeHostArtifact in $nativeHostArtifacts) {
        $nativeHostArtifactSource = $nativeHostSourceRoots |
            Where-Object { Test-Path (Join-Path $_ $nativeHostArtifact) } |
            Select-Object -First 1

        if ($nativeHostArtifactSource) {
            $nativeHostArtifactSources[$nativeHostArtifact] = $nativeHostArtifactSource
        }
        else {
            $missingNativeHostArtifacts += $nativeHostArtifact
        }
    }

    if ($missingNativeHostArtifacts.Count -eq 0) {
        New-Item -ItemType Directory -Path $firefoxNativeHostTarget -Force | Out-Null
        foreach ($nativeHostArtifact in $nativeHostArtifacts) {
            Copy-Item (Join-Path $nativeHostArtifactSources[$nativeHostArtifact] $nativeHostArtifact) `
                -Destination (Join-Path $firefoxNativeHostTarget $nativeHostArtifact) `
                -Force
        }

        Write-InstallerVerbose "  Firefox native host assets staged in $OpenPathRoot\browser-extension\firefox\native"
    }
    else {
        Write-InstallerWarning "  ADVERTENCIA: Firefox native host artifacts missing ($($missingNativeHostArtifacts -join ', '))"
    }

    $firefoxReleaseCandidates = @(
        (Join-Path $ScriptDir 'browser-extension\firefox-release'),
        (Join-Path $ScriptDir 'firefox-extension\build\firefox-release'),
        (Join-Path (Split-Path $ScriptDir -Parent) 'firefox-extension\build\firefox-release')
    )
    $firefoxReleaseSource = $firefoxReleaseCandidates |
        Where-Object { Test-Path (Join-Path $_ 'metadata.json') } |
        Select-Object -First 1

    if ($firefoxReleaseSource) {
        $firefoxReleaseTarget = "$OpenPathRoot\browser-extension\firefox-release"
        Remove-Item $firefoxReleaseTarget -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $firefoxReleaseTarget -Force | Out-Null

        Copy-Item (Join-Path $firefoxReleaseSource 'metadata.json') -Destination (Join-Path $firefoxReleaseTarget 'metadata.json') -Force

        $firefoxReleaseXpiSource = Join-Path $firefoxReleaseSource 'openpath-firefox-extension.xpi'
        if (Test-Path $firefoxReleaseXpiSource) {
            Copy-Item $firefoxReleaseXpiSource -Destination (Join-Path $firefoxReleaseTarget 'openpath-firefox-extension.xpi') -Force
        }

        Write-InstallerVerbose "  Signed Firefox Release artifacts staged in $OpenPathRoot\browser-extension\firefox-release"
    }
    elseif (-not ($FirefoxExtensionId -and $FirefoxExtensionInstallUrl)) {
        Write-InstallerWarning "  ADVERTENCIA: Firefox Release extension auto-install requires a signed XPI distribution (AMO, HTTPS URL, or staged signed artifact)."
        Write-InstallerWarning "  Firefox browser policies will not be written until a signed extension distribution is configured."
    }

    $chromiumManagedCandidates = @(
        (Join-Path $ScriptDir 'browser-extension\chromium-managed'),
        (Join-Path $ScriptDir 'firefox-extension\build\chromium-managed'),
        (Join-Path (Split-Path $ScriptDir -Parent) 'firefox-extension\build\chromium-managed')
    )
    $chromiumManagedSource = $chromiumManagedCandidates |
        Where-Object { Test-Path (Join-Path $_ 'metadata.json') } |
        Select-Object -First 1

    if ($chromiumManagedSource) {
        $chromiumManagedTarget = "$OpenPathRoot\browser-extension\chromium-managed"
        Remove-Item $chromiumManagedTarget -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $chromiumManagedTarget -Force | Out-Null
        Copy-Item (Join-Path $chromiumManagedSource 'metadata.json') -Destination (Join-Path $chromiumManagedTarget 'metadata.json') -Force
        Write-InstallerVerbose "  Chromium managed rollout metadata staged in $OpenPathRoot\browser-extension\chromium-managed"
    }
    else {
        Write-InstallerWarning "  ADVERTENCIA: Chromium managed rollout metadata not found in browser-extension\chromium-managed or firefox-extension\build\chromium-managed; Edge/Chrome managed extension install skipped"
    }

    if (-not $chromiumManagedSource) {
        if (-not (Install-OpenPathChromiumUnmanagedGuidance `
            -ChromeStoreUrl $ChromeExtensionStoreUrl `
            -EdgeStoreUrl $EdgeExtensionStoreUrl `
            -Unattended:$Unattended)) {
            Write-InstallerWarning "  ADVERTENCIA: No Chromium store URLs configured; non-managed Chrome/Edge installs require user-initiated store install."
        }
    }

    Write-InstallerWarning "  Chrome/Edge force-install is not available on unmanaged Windows; use store guidance, Firefox auto-install, or a managed CRX/update-manifest rollout."
    Write-InstallerVerbose "  Modulos copiados"
}
