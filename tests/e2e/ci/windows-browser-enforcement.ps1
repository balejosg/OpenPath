param(
    [ValidateSet('Report', 'Student', 'Admin', 'All')][string]$Scope = 'Report',
    [switch]$ExecuteProbes,
    [switch]$PrepareProbeFiles,
    [string]$ArtifactsRoot = $(if ($env:OPENPATH_STUDENT_ARTIFACTS_DIR) { $env:OPENPATH_STUDENT_ARTIFACTS_DIR } else { Join-Path $PSScriptRoot '..\artifacts\windows-browser-enforcement' }),
    [string]$BlockedPathUrl = $(if ($env:OPENPATH_BROWSER_ENFORCEMENT_BLOCKED_PATH_URL) { $env:OPENPATH_BROWSER_ENFORCEMENT_BLOCKED_PATH_URL } else { 'https://blocked.127.0.0.1.sslip.io/game' }),
    [string]$GoogleSearchGameUrl = $(if ($env:OPENPATH_BROWSER_ENFORCEMENT_GOOGLE_GAME_URL) { $env:OPENPATH_BROWSER_ENFORCEMENT_GOOGLE_GAME_URL } else { 'https://www.google.com/fbx?fbx=snake_arcade' }),
    [string]$BlockedHost = $(if ($env:OPENPATH_BROWSER_ENFORCEMENT_BLOCKED_HOST) { $env:OPENPATH_BROWSER_ENFORCEMENT_BLOCKED_HOST } else { 'blocked.127.0.0.1.sslip.io' }),
    [int]$ProbeTimeoutSeconds = 10
)

$ErrorActionPreference = 'Stop'

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$script:Results = @()

function Test-OpenPathWindowsHost {
    $isWindowsVariable = Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $isWindowsVariable) {
        return [bool]$isWindowsVariable
    }

    return $env:OS -eq 'Windows_NT'
}

function Test-CurrentUserIsAdmin {
    if (-not (Test-OpenPathWindowsHost)) {
        return $false
    }

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-CurrentUserName {
    if (Test-OpenPathWindowsHost) {
        try {
            return [Security.Principal.WindowsIdentity]::GetCurrent().Name
        }
        catch {
            return [Environment]::UserName
        }
    }

    return [Environment]::UserName
}

function Assert-WindowsProbeHost {
    if (-not (Test-OpenPathWindowsHost)) {
        throw 'Windows browser enforcement execution probes must run on Windows. Use -Scope Report for local dry-run documentation on non-Windows hosts.'
    }
}

function Add-ProbeResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('student', 'admin', 'report')][string]$Section,
        [Parameter(Mandatory = $true)][ValidateSet('pass', 'fail', 'skip', 'info')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Detail,
        [hashtable]$Evidence = @{}
    )

    $script:Results += [pscustomobject]@{
            name      = $Name
            section   = $Section
            status    = $Status
            detail    = $Detail
            evidence  = [pscustomobject]$Evidence
            timestamp = (Get-Date).ToString('o')
        }
}

function Resolve-Executable {
    param([Parameter(Mandatory = $true)][string[]]$Candidates)

    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $expanded = [Environment]::ExpandEnvironmentVariables($candidate)
        if (Test-Path $expanded -PathType Leaf) {
            return $expanded
        }
    }

    return $null
}

function Test-ChromiumBrowserManaged {
    param([Parameter(Mandatory = $true)][ValidateSet('Edge', 'Chrome')][string]$Browser)

    $policyRoot = if ($Browser -eq 'Edge') {
        'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    }
    else {
        'HKLM:\SOFTWARE\Policies\Google\Chrome'
    }

    $forceListPath = Join-Path $policyRoot 'ExtensionInstallForcelist'
    $urlBlocklistPath = Join-Path $policyRoot 'URLBlocklist'
    $dohMode = $null
    try {
        $policy = Get-ItemProperty -Path $policyRoot -ErrorAction Stop
        $dohMode = [string]$policy.DnsOverHttpsMode
    }
    catch {
        $dohMode = $null
    }

    $forceList = @()
    if (Test-Path $forceListPath) {
        $forceList = @((Get-ItemProperty -Path $forceListPath).PSObject.Properties |
            Where-Object { $_.Name -match '^\d+$' } |
            ForEach-Object { [string]$_.Value })
    }

    $urlBlocklist = @()
    if (Test-Path $urlBlocklistPath) {
        $urlBlocklist = @((Get-ItemProperty -Path $urlBlocklistPath).PSObject.Properties |
            Where-Object { $_.Name -match '^\d+$' } |
            ForEach-Object { [string]$_.Value })
    }

    $hasManagedExtension = [bool]($forceList | Where-Object { $_ -match '/api/extensions/chromium/updates\.xml' } | Select-Object -First 1)
    $requiredGoogleBlocks = @(
        '*://www.google.*/search*',
        '*://www.google.*/fbx?fbx=snake_arcade*',
        '*://doodles.google/*',
        '*://*.doodles.google/*',
        '*://www.google.*/logos/*'
    )
    $missingGoogleBlocks = @(
        $requiredGoogleBlocks | Where-Object {
            $required = $_
            -not [bool]($urlBlocklist | Where-Object { $_ -ieq $required } | Select-Object -First 1)
        }
    )
    $hasGoogleGameBlock = [bool]($missingGoogleBlocks.Count -eq 0)

    return [pscustomobject]@{
        Managed             = [bool]($hasManagedExtension -and $dohMode -eq 'off' -and $hasGoogleGameBlock)
        HasManagedExtension = $hasManagedExtension
        DnsOverHttpsMode    = $dohMode
        HasGoogleGameBlock  = $hasGoogleGameBlock
        MissingGoogleBlocks = $missingGoogleBlocks
        ForceList           = $forceList
        UrlBlocklist        = $urlBlocklist
    }
}

function Test-FirefoxManaged {
    $policyPath = Join-Path $env:ProgramFiles 'Mozilla Firefox\distribution\policies.json'
    if (-not (Test-Path $policyPath)) {
        $policyPath = Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox\distribution\policies.json'
    }

    $nativeHostPath = 'HKLM:\SOFTWARE\Mozilla\NativeMessagingHosts\openpath_native'
    $policyText = if (Test-Path $policyPath) { Get-Content $policyPath -Raw } else { '' }
    $hasExtension = $policyText -match 'ExtensionSettings' -and $policyText -match 'install_url'
    $hasNativeHost = Test-Path $nativeHostPath

    return [pscustomobject]@{
        Managed       = [bool]($hasExtension -and $hasNativeHost)
        PolicyPath    = $policyPath
        HasPolicy     = [bool](Test-Path $policyPath)
        HasExtension  = $hasExtension
        HasNativeHost = $hasNativeHost
    }
}

function Invoke-ProcessDeniedProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [switch]$ExpectBlocked
    )

    if (-not $ExecuteProbes) {
        Add-ProbeResult -Name $Name -Section student -Status info -Detail 'Dry run: process launch not attempted.' -Evidence @{ path = $FilePath; arguments = $ArgumentList }
        return
    }

    $resolvedFilePath = $FilePath
    if (-not (Test-Path $resolvedFilePath -PathType Leaf)) {
        $command = Get-Command $FilePath -ErrorAction SilentlyContinue
        if ($command -and $command.Source) {
            $resolvedFilePath = $command.Source
        }
        else {
            Add-ProbeResult -Name $Name -Section student -Status skip -Detail 'Executable or script was not present on this image.' -Evidence @{ path = $FilePath }
            return
        }
    }

    try {
        $process = Start-Process -FilePath $resolvedFilePath -ArgumentList $ArgumentList -PassThru -WindowStyle Hidden -ErrorAction Stop
        $exited = $process.WaitForExit($ProbeTimeoutSeconds * 1000)
        if (-not $exited) {
            try {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
            catch {
                # Best effort cleanup of the process this probe just started.
            }
        }

        if ($ExpectBlocked) {
            Add-ProbeResult -Name $Name -Section student -Status fail -Detail 'Process started; expected AppLocker or policy denial.' -Evidence @{ path = $resolvedFilePath; requestedPath = $FilePath; exitCode = $process.ExitCode; stillRunning = -not $exited }
        }
        else {
            Add-ProbeResult -Name $Name -Section student -Status pass -Detail 'Managed browser launch was permitted; operator must confirm the displayed page is blocked before claiming target-platform symptom cleared.' -Evidence @{ path = $resolvedFilePath; requestedPath = $FilePath; exitCode = $process.ExitCode; stillRunning = -not $exited }
        }
    }
    catch {
        if ($ExpectBlocked) {
            Add-ProbeResult -Name $Name -Section student -Status pass -Detail "Process launch failed as expected: $($_.Exception.Message)" -Evidence @{ path = $resolvedFilePath; requestedPath = $FilePath }
        }
        else {
            Add-ProbeResult -Name $Name -Section student -Status fail -Detail "Process launch failed: $($_.Exception.Message)" -Evidence @{ path = $resolvedFilePath; requestedPath = $FilePath }
        }
    }
}

function Invoke-CurlFailureProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
    if (-not $curl) {
        Add-ProbeResult -Name $Name -Section student -Status skip -Detail 'curl.exe was not found on PATH.'
        return
    }

    if (-not $ExecuteProbes) {
        Add-ProbeResult -Name $Name -Section student -Status info -Detail 'Dry run: curl command not executed.' -Evidence @{ command = "curl.exe $($Arguments -join ' ')" }
        return
    }

    $stdout = Join-Path $ArtifactsRoot "$($Name -replace '[^A-Za-z0-9_.-]', '-').out.log"
    $stderr = Join-Path $ArtifactsRoot "$($Name -replace '[^A-Za-z0-9_.-]', '-').err.log"
    try {
        $process = Start-Process -FilePath $curl -ArgumentList $Arguments -NoNewWindow -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    }
    catch {
        Add-ProbeResult -Name $Name -Section student -Status pass -Detail "curl launch failed as expected under enforcement: $($_.Exception.Message)" -Evidence @{ stdout = $stdout; stderr = $stderr }
        return
    }

    $exited = $process.WaitForExit($ProbeTimeoutSeconds * 1000)
    if (-not $exited) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }
        catch {
            # Best effort cleanup of the curl process this probe just started.
        }
    }

    if (($exited) -and ($process.ExitCode -ne 0)) {
        Add-ProbeResult -Name $Name -Section student -Status pass -Detail 'curl failed as expected under enforcement.' -Evidence @{ exitCode = $process.ExitCode; stdout = $stdout; stderr = $stderr }
    }
    else {
        Add-ProbeResult -Name $Name -Section student -Status fail -Detail 'curl command did not fail; bypass may still be open.' -Evidence @{ exitCode = $process.ExitCode; timedOut = -not $exited; stdout = $stdout; stderr = $stderr }
    }
}

function New-ProbeFiles {
    if (-not $PrepareProbeFiles) {
        return
    }

    foreach ($path in @(
            (Join-Path $env:USERPROFILE 'Downloads\test.ps1'),
            (Join-Path $env:USERPROFILE 'Downloads\test.bat')
        )) {
        if (-not (Test-Path $path)) {
            $parent = Split-Path $path -Parent
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            if ($path -like '*.ps1') {
                Set-Content -Path $path -Value 'Write-Output "openpath probe should not execute"' -Encoding UTF8
            }
            else {
                Set-Content -Path $path -Value '@echo openpath probe should not execute' -Encoding ASCII
            }
        }
    }
}

function Invoke-StudentProbes {
    $isAdmin = Test-CurrentUserIsAdmin
    if ($isAdmin) {
        Add-ProbeResult -Name 'standard non-admin student context' -Section student -Status fail -Detail 'Student probes must run as a standard non-admin account, but current token is administrator.'
        if (-not $ExecuteProbes) {
            return
        }
    }

    New-ProbeFiles

    $firefoxPath = Resolve-Executable @('%PROGRAMFILES%\Mozilla Firefox\firefox.exe', '%PROGRAMFILES(X86)%\Mozilla Firefox\firefox.exe')
    $edgePath = Resolve-Executable @('%PROGRAMFILES%\Microsoft\Edge\Application\msedge.exe', '%PROGRAMFILES(X86)%\Microsoft\Edge\Application\msedge.exe')
    $chromePath = Resolve-Executable @('%PROGRAMFILES%\Google\Chrome\Application\chrome.exe', '%PROGRAMFILES(X86)%\Google\Chrome\Application\chrome.exe')

    $firefoxManaged = Test-FirefoxManaged
    if ($firefoxPath -and $firefoxManaged.Managed) {
        Invoke-ProcessDeniedProbe -Name 'Firefox managed path blocks known blocked path' -FilePath $firefoxPath -ArgumentList @('-new-window', $BlockedPathUrl)
    }
    else {
        Add-ProbeResult -Name 'Firefox managed path blocks known blocked path' -Section student -Status skip -Detail 'Firefox is missing or not managed in this boundary run; Selenium student-policy flow covers Firefox page blocking.' -Evidence @{ path = $firefoxPath; managed = $firefoxManaged.Managed; policyPath = $firefoxManaged.PolicyPath }
    }

    if ($edgePath) {
        $edgeManagedForGameProbe = Test-ChromiumBrowserManaged -Browser Edge
        if ($edgeManagedForGameProbe.Managed) {
            Add-ProbeResult -Name 'Edge Google game URL cannot run as student' -Section student -Status fail -Detail 'Edge is approved/managed, but OpenPath does not yet have an Edge Selenium proof for Google game page blocking. Keep Edge out of approvedStudentBrowsers until that proof exists.' -Evidence @{ path = $edgePath; dnsOverHttpsMode = $edgeManagedForGameProbe.DnsOverHttpsMode; hasManagedExtension = $edgeManagedForGameProbe.HasManagedExtension; hasGoogleGameBlock = $edgeManagedForGameProbe.HasGoogleGameBlock; missingGoogleBlocks = $edgeManagedForGameProbe.MissingGoogleBlocks }
        }
        else {
            Invoke-ProcessDeniedProbe -Name 'Edge Google game URL cannot run as student' -FilePath $edgePath -ArgumentList @('--new-window', $GoogleSearchGameUrl) -ExpectBlocked
        }
    }
    else {
        Add-ProbeResult -Name 'Edge Google game URL cannot run as student' -Section student -Status skip -Detail 'Microsoft Edge is not installed on this image.'
    }

    foreach ($browser in @(
            [pscustomobject]@{ Name = 'Edge'; Path = $edgePath; Managed = if ($edgePath) { Test-ChromiumBrowserManaged -Browser Edge } else { $null }; Args = @('--new-window', $BlockedPathUrl) },
            [pscustomobject]@{ Name = 'Chrome'; Path = $chromePath; Managed = if ($chromePath) { Test-ChromiumBrowserManaged -Browser Chrome } else { $null }; Args = @('--new-window', $BlockedPathUrl) }
        )) {
        $probeName = "$($browser.Name) only if managed and blocks known blocked path"
        if (-not $browser.Path) {
            Add-ProbeResult -Name $probeName -Section student -Status skip -Detail "$($browser.Name) is not installed on this image."
            continue
        }

        if (-not $browser.Managed.Managed) {
            Add-ProbeResult -Name $probeName -Section student -Status pass -Detail "$($browser.Name) is installed but unmanaged, so it must not be used as an approved probe browser." -Evidence @{ path = $browser.Path; managed = $false; dnsOverHttpsMode = $browser.Managed.DnsOverHttpsMode; hasManagedExtension = $browser.Managed.HasManagedExtension; hasGoogleGameBlock = $browser.Managed.HasGoogleGameBlock }
            Invoke-ProcessDeniedProbe -Name "$($browser.Name) unmanaged browser cannot start" -FilePath $browser.Path -ArgumentList @('about:blank') -ExpectBlocked
            continue
        }

        Invoke-ProcessDeniedProbe -Name $probeName -FilePath $browser.Path -ArgumentList $browser.Args
    }

    foreach ($candidate in @(
            [pscustomobject]@{ Name = 'Brave cannot start'; Paths = @('%PROGRAMFILES%\BraveSoftware\Brave-Browser\Application\brave.exe', '%PROGRAMFILES(X86)%\BraveSoftware\Brave-Browser\Application\brave.exe', '%LOCALAPPDATA%\BraveSoftware\Brave-Browser\Application\brave.exe') },
            [pscustomobject]@{ Name = 'Opera cannot start'; Paths = @('%PROGRAMFILES%\Opera\opera.exe', '%PROGRAMFILES(X86)%\Opera\opera.exe', '%LOCALAPPDATA%\Programs\Opera\opera.exe') },
            [pscustomobject]@{ Name = 'Vivaldi cannot start'; Paths = @('%PROGRAMFILES%\Vivaldi\Application\vivaldi.exe', '%PROGRAMFILES(X86)%\Vivaldi\Application\vivaldi.exe', '%LOCALAPPDATA%\Vivaldi\Application\vivaldi.exe') },
            [pscustomobject]@{ Name = 'Tor cannot start'; Paths = @('%PROGRAMFILES%\Tor Browser\Browser\firefox.exe', '%PROGRAMFILES(X86)%\Tor Browser\Browser\firefox.exe', '%USERPROFILE%\Desktop\Tor Browser\Browser\firefox.exe', '%USERPROFILE%\Downloads\Tor Browser\Browser\firefox.exe') }
        )) {
        $path = Resolve-Executable $candidate.Paths
        if ($path) {
            Invoke-ProcessDeniedProbe -Name $candidate.Name -FilePath $path -ArgumentList @('about:blank') -ExpectBlocked
        }
        else {
            Add-ProbeResult -Name $candidate.Name -Section student -Status pass -Detail 'Browser executable not present on this image.'
        }
    }

    foreach ($portable in @(
            [pscustomobject]@{ Name = 'Portable browser from Downloads cannot start'; Root = (Join-Path $env:USERPROFILE 'Downloads') },
            [pscustomobject]@{ Name = 'Portable browser from Desktop cannot start'; Root = (Join-Path $env:USERPROFILE 'Desktop') }
        )) {
        $portableExe = Get-ChildItem -Path $portable.Root -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'firefox|chrome|chromium|brave|opera|vivaldi|tor' } |
            Select-Object -First 1
        if ($portableExe) {
            Invoke-ProcessDeniedProbe -Name $portable.Name -FilePath $portableExe.FullName -ArgumentList @('about:blank') -ExpectBlocked
        }
        else {
            Add-ProbeResult -Name $portable.Name -Section student -Status skip -Detail 'No portable browser executable found in the probe root.' -Evidence @{ root = $portable.Root }
        }
    }

    Add-ProbeResult -Name 'PowerShell script from Downloads cannot execute' -Section student -Status skip -Detail 'PowerShell remains available for the CI probe harness; browser and network bypass probes are enforced separately.'
    Invoke-ProcessDeniedProbe -Name 'Batch file from Downloads cannot execute' -FilePath (Join-Path $env:USERPROFILE 'Downloads\test.bat') -ExpectBlocked

    foreach ($runtime in @('python.exe', 'node.exe')) {
        $source = (Get-Command $runtime -ErrorAction SilentlyContinue).Source
        if (-not $source) {
            Add-ProbeResult -Name "$runtime copied into user-writable path cannot execute if present" -Section student -Status skip -Detail "$runtime was not present on PATH for copy probe."
            continue
        }

        $destination = Join-Path $env:USERPROFILE "Downloads\$runtime"
        if (($PrepareProbeFiles) -and (-not (Test-Path $destination))) {
            Copy-Item -Path $source -Destination $destination -Force
        }
        Invoke-ProcessDeniedProbe -Name "$runtime copied into user-writable path cannot execute if present" -FilePath $destination -ArgumentList @('--version') -ExpectBlocked
    }

    if ($firefoxPath -and $firefoxManaged.Managed) {
        Invoke-ProcessDeniedProbe -Name 'Google search game result is blocked' -FilePath $firefoxPath -ArgumentList @('-new-window', $GoogleSearchGameUrl)
    }
    elseif ($edgePath -and (Test-ChromiumBrowserManaged -Browser Edge).Managed) {
        Invoke-ProcessDeniedProbe -Name 'Google search game result is blocked' -FilePath $edgePath -ArgumentList @('--new-window', $GoogleSearchGameUrl)
    }
    elseif ($chromePath -and (Test-ChromiumBrowserManaged -Browser Chrome).Managed) {
        Invoke-ProcessDeniedProbe -Name 'Google search game result is blocked' -FilePath $chromePath -ArgumentList @('--new-window', $GoogleSearchGameUrl)
    }
    else {
        Add-ProbeResult -Name 'Google search game result is blocked' -Section student -Status skip -Detail 'No managed approved browser is available in this boundary run; Edge direct Google game launch is covered by the AppLocker boundary probe.'
    }

    Invoke-CurlFailureProbe -Name '1.1.1.1 DoH-by-IP cannot resolve blocked host' -Arguments @('--doh-url', 'https://1.1.1.1/dns-query', '--max-time', "$ProbeTimeoutSeconds", "https://$BlockedHost/")
    Invoke-CurlFailureProbe -Name 'curl --resolve Cloudflare bypass command fails' -Arguments @('--resolve', 'cloudflare-dns.com:443:1.1.1.1', '--max-time', "$ProbeTimeoutSeconds", 'https://cloudflare-dns.com/dns-query')
}

function Invoke-AdminProbes {
    if (-not (Test-CurrentUserIsAdmin)) {
        Add-ProbeResult -Name 'admin context' -Section admin -Status fail -Detail 'Admin probes must run from an elevated administrator token.'
        return
    }

    Add-ProbeResult -Name 'Admin can run management tools' -Section admin -Status pass -Detail 'Current token is elevated and can invoke Windows management tooling.'

    try {
        $policy = Get-AppLockerPolicy -Local -ErrorAction Stop
        Add-ProbeResult -Name 'Admin can inspect policies' -Section admin -Status pass -Detail 'Get-AppLockerPolicy -Local succeeded.' -Evidence @{ ruleCollections = @($policy.RuleCollections).Count }
    }
    catch {
        Add-ProbeResult -Name 'Admin can inspect policies' -Section admin -Status fail -Detail $_.Exception.Message
    }

    $recoveryScript = 'C:\OpenPath\Uninstall-OpenPath.ps1'
    $appControlModule = 'C:\OpenPath\lib\AppControl.psm1'
    if ((Test-Path $recoveryScript) -or (Test-Path $appControlModule)) {
        Add-ProbeResult -Name 'Admin can recover OpenPath' -Section admin -Status pass -Detail 'Recovery entrypoints are present. Run Uninstall-OpenPath.ps1 or Remove-OpenPathNonAdminAppControl from an elevated shell for rollback.' -Evidence @{ uninstall = (Test-Path $recoveryScript); appControlModule = (Test-Path $appControlModule) }
    }
    else {
        Add-ProbeResult -Name 'Admin can recover OpenPath' -Section admin -Status fail -Detail 'Recovery entrypoints were not found under C:\OpenPath.'
    }

    try {
        $xml = [xml](Get-AppLockerPolicy -Local -Xml)
        $adminAllowAllRules = @($xml.AppLockerPolicy.RuleCollection.FilePathRule | Where-Object {
                $_.Action -eq 'Allow' -and $_.UserOrGroupSid -eq 'S-1-5-32-544' -and $_.Conditions.FilePathCondition.Path -eq '*'
            })
        if ($adminAllowAllRules.Count -gt 0) {
            Add-ProbeResult -Name 'AppLocker admin allow-all remains intact' -Section admin -Status pass -Detail 'Admin allow-all AppLocker rule is present.'
        }
        else {
            Add-ProbeResult -Name 'AppLocker admin allow-all remains intact' -Section admin -Status fail -Detail 'Admin allow-all AppLocker rule was not found.'
        }
    }
    catch {
        Add-ProbeResult -Name 'AppLocker admin allow-all remains intact' -Section admin -Status fail -Detail $_.Exception.Message
    }
}

function Write-Report {
    if (-not (Test-Path $ArtifactsRoot)) {
        New-Item -ItemType Directory -Path $ArtifactsRoot -Force | Out-Null
    }

    $report = [pscustomobject]@{
        scope             = $Scope
        executeProbes     = [bool]$ExecuteProbes
        prepareProbeFiles = [bool]$PrepareProbeFiles
        currentUser       = Get-CurrentUserName
        currentUserIsAdmin = Test-CurrentUserIsAdmin
        blockedPathUrl    = $BlockedPathUrl
        googleSearchGameUrl = $GoogleSearchGameUrl
        blockedHost       = $BlockedHost
        results           = @($script:Results)
    }

    $jsonPath = Join-Path $ArtifactsRoot 'windows-browser-enforcement-report.json'
    $textPath = Join-Path $ArtifactsRoot 'windows-browser-enforcement-report.txt'
    $report | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8
    @(
        "Windows browser enforcement report"
        "scope=$Scope"
        "executeProbes=$([bool]$ExecuteProbes)"
        "prepareProbeFiles=$([bool]$PrepareProbeFiles)"
        "currentUser=$($report.currentUser)"
        "currentUserIsAdmin=$($report.currentUserIsAdmin)"
        "blockedPathUrl=$BlockedPathUrl"
        "googleSearchGameUrl=$GoogleSearchGameUrl"
        "blockedHost=$BlockedHost"
        ''
        ($script:Results | Format-Table section, status, name, detail -AutoSize | Out-String)
    ) | Set-Content -Path $textPath -Encoding UTF8

    Write-Host "Windows browser enforcement report written to $jsonPath"
    Write-Host "Windows browser enforcement summary written to $textPath"

    $failures = @($script:Results | Where-Object { $_.status -eq 'fail' })
    if ($ExecuteProbes -and $failures.Count -gt 0) {
        throw "Windows browser enforcement probes failed: $($failures.Count)"
    }
}

if ($Scope -eq 'Report') {
    Add-ProbeResult -Name 'Phase 5 prerequisites' -Section report -Status info -Detail 'Run only after Phase 1, Phase 3, and Phase 4 are committed; do not claim target-platform symptom cleared from partial enforcement.'
    Add-ProbeResult -Name 'Reversible runner lab' -Section report -Status info -Detail 'Reset runner, snapshot VM, enroll disposable staging student, run probes, delete disposable staging IDs, rollback VM, restore runner services, and run smoke.'
}
else {
    Assert-WindowsProbeHost
    if ($Scope -in @('Student', 'All')) {
        Invoke-StudentProbes
    }
    if ($Scope -in @('Admin', 'All')) {
        Invoke-AdminProbes
    }
}

Write-Report
