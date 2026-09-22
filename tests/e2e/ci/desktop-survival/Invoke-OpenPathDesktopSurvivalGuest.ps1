<##
.SYNOPSIS
    In-guest desktop-survival harness for one Proxmox scenario step.
.DESCRIPTION
    Runs inside the disposable Windows guest through the QEMU guest agent and
    performs the real acceptance work of the desktop-survival matrix: baseline
    verification, personalized installer execution, strict AppControl commit
    verification, interactive session management, restricted-student boundary
    probes, rollback and cleanup verification.

    The controller owns hypervisor actions (snapshot, reboot, screendump) and
    calls this harness once per step. Every step writes a JSON result to
    -ResultPath and prints it to stdout. The harness never claims acceptance by
    itself: it reports what it observed and fails closed on unexpected results.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('prepare', 'observe', 'afterReboot', 'cleanup')][string]$Phase,
    [Parameter(Mandatory = $true)][ValidateSet(
        'install',
        'admin-autologon', 'admin-verify',
        'student-autologon', 'student-verify',
        'login-screen',
        'boundary',
        'uninstall',
        'verify-clean'
    )][string]$Step,
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$ScenarioId,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [string]$TemplatePath = '',
    [string]$PersonalizedExePath = '',
    [string]$StudentUserName = 'alumno',
    [string]$AdminUserName = 'opadmin',
    [string]$Secret = '',
    [string]$StatePath = 'C:\ProgramData\openpath-desktop-survival\state.json',
    [string]$ProbeRoot = 'C:\Users\Public\OpenPathProbes'
)

$ErrorActionPreference = 'Stop'
$script:Failures = New-Object System.Collections.Generic.List[string]

function Add-OpenPathLabFailure {
    param([Parameter(Mandatory = $true)][string]$Message)
    $script:Failures.Add($Message) | Out-Null
}

function Get-TargetUserSid {
    param([Parameter(Mandatory = $true)][string]$UserName)
    $account = New-Object System.Security.Principal.NTAccount($UserName)
    return $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
}

function Get-AppLockerXmlText {
    try { return [string](Get-AppLockerPolicy -Local -Xml -ErrorAction Stop) }
    catch { return '' }
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Read-OpenPathLabState {
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        try { return (Get-Content -LiteralPath $StatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) }
        catch { return $null }
    }
    return $null
}

function Write-OpenPathLabState {
    param([Parameter(Mandatory = $true)][object]$Value)
    $parent = Split-Path -Parent $StatePath
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = "$StatePath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 24), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $StatePath -Force
    }
    finally { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
}

function Test-PolicyHasOpenPathRules {
    $xml = Get-AppLockerXmlText
    return [bool]($xml -match 'OpenPath non-admin app control')
}

function Get-OpenPathStateSummary {
    $summary = [ordered]@{
        rootExists   = Test-Path -LiteralPath 'C:\OpenPath'
        configExists = $false
        config       = $null
        uninstaller  = Test-Path -LiteralPath 'C:\OpenPath\Uninstall-OpenPath.ps1'
        groupExists  = [bool](Get-LocalGroup -Name 'OpenPath-Restricted' -ErrorAction SilentlyContinue)
        groupMembers = @()
        tasks        = @()
        policySha256 = ''
        policyHasOpenPathRules = $false
    }
    try {
        if (Test-Path -LiteralPath 'C:\OpenPath\data\config.json') {
            $summary.configExists = $true
            $summary.config = Get-Content -LiteralPath 'C:\OpenPath\data\config.json' -Raw | ConvertFrom-Json
        }
    }
    catch { Add-OpenPathLabFailure "config-unreadable: $($_.Exception.Message)" }
    $summary.catalogApplicationCount = 0
    if ($summary.config) {
        foreach ($candidate in @('applications', 'catalog', 'applicationCatalog')) {
            $value = $null
            if ($summary.config.PSObject.Properties[$candidate]) { $value = $summary.config.$candidate }
            if ($null -eq $value -or $value -is [string]) { continue }
            if ($value -is [System.Collections.IEnumerable]) { $summary.catalogApplicationCount = @($value).Count }
            elseif ($value.PSObject.Properties['applications']) { $summary.catalogApplicationCount = @($value.applications).Count }
            break
        }
    }
    try {
        $summary.groupMembers = @(Get-LocalGroupMember -Group 'OpenPath-Restricted' -ErrorAction Stop |
            ForEach-Object { [string]$_.Name } | Sort-Object)
    }
    catch {}
    $summary.tasks = @(Get-ScheduledTask -TaskName 'OpenPath-*' -ErrorAction SilentlyContinue |
        ForEach-Object { [string]$_.TaskName } | Sort-Object)
    $summary.policySha256 = Get-Sha256Hex -Text (Get-AppLockerXmlText)
    $summary.policyHasOpenPathRules = Test-PolicyHasOpenPathRules
    return $summary
}

function Set-OpenPathAutologon {
    param(
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][string]$Password
    )
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -LiteralPath $winlogon -Name 'AutoAdminLogon' -Value '1'
    Set-ItemProperty -LiteralPath $winlogon -Name 'DefaultUserName' -Value $UserName
    Set-ItemProperty -LiteralPath $winlogon -Name 'DefaultDomainName' -Value $env:COMPUTERNAME
    Set-ItemProperty -LiteralPath $winlogon -Name 'DefaultPassword' -Value $Password
    Remove-ItemProperty -LiteralPath $winlogon -Name 'AutoLogonCount' -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath $winlogon -Name 'AutoLogonSID' -ErrorAction SilentlyContinue
    return 'autologon-set'
}

function Clear-OpenPathAutologon {
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -LiteralPath $winlogon -Name 'AutoAdminLogon' -Value '0'
    Remove-ItemProperty -LiteralPath $winlogon -Name 'DefaultPassword' -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath $winlogon -Name 'AutoLogonCount' -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath $winlogon -Name 'AutoLogonSID' -ErrorAction SilentlyContinue
    return 'autologon-cleared'
}

function Get-InteractiveSession {
    param([Parameter(Mandatory = $true)][string]$UserName)
    try {
        $consoleUser = [string](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop | Select-Object -ExpandProperty UserName)
        if ($consoleUser -and $consoleUser -match "\\$([regex]::Escape($UserName))$") { return $consoleUser }
    }
    catch {}
    foreach ($explorer in @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue)) {
        try {
            $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner -ErrorAction Stop
            if ([string]$owner.User -eq $UserName) { return "$($owner.Domain)\$($owner.User)" }
        }
        catch {}
    }
    return ''
}

function Get-StudentLogonEvents {
    param(
        [Parameter(Mandatory = $true)][string]$Sid,
        [Parameter(Mandatory = $true)][datetime]$AfterUtc
    )
    $events = @()
    try { $raw = Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 4624; StartTime = $AfterUtc } -ErrorAction Stop }
    catch { return @() }
    foreach ($entry in $raw) {
        try {
            [xml]$xml = $entry.ToXml()
            $data = @{}
            foreach ($node in $xml.Event.EventData.Data) { $data[[string]$node.Name] = [string]$node.'#text' }
            if ([string]$data['TargetUserSid'] -ne $Sid) { continue }
            if ([string]$data['LogonType'] -notin @('2', '10', '11')) { continue }
            $events += [ordered]@{
                timeUtc   = $entry.TimeCreated.ToUniversalTime().ToString('o')
                logonType = [string]$data['LogonType']
                user      = [string]$data['TargetUserName']
            }
        }
        catch {}
    }
    return @($events)
}

function Ensure-OpenPathProbeDirectory {
    if (-not (Test-Path -LiteralPath $ProbeRoot)) {
        New-Item -ItemType Directory -Path $ProbeRoot -Force | Out-Null
    }
    & icacls.exe $ProbeRoot /grant '*S-1-5-32-545:(OI)(CI)M' 2>&1 | Out-Null
}

function Invoke-OpenPathStudentTask {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [int]$WaitSeconds = 45
    )
    $taskName = "OpenPathProbe-$Name"
    & schtasks.exe /create /tn $taskName /tr $CommandLine /sc once /st 23:59 /ru $StudentUserName /rp $Secret /it /f 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { return [ordered]@{ status = 'task-create-failed' } }
    & schtasks.exe /run /tn $taskName 2>&1 | Out-Null
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $finished = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 750
        $query = (& schtasks.exe /query /tn $taskName /fo LIST /v 2>&1 | Out-String)
        if ($query -match 'Status:\s+Running') { continue }
        if ($query -match 'Last Result:') { $finished = $true; break }
    }
    $query = (& schtasks.exe /query /tn $taskName /fo LIST /v 2>&1 | Out-String)
    $lastResult = ''
    if ($query -match 'Last Result:\s+(-?\d+)') { $lastResult = $Matches[1] }
    & schtasks.exe /delete /tn $taskName /f 2>&1 | Out-Null
    return [ordered]@{
        status     = if ($finished) { 'finished' } else { 'timeout' }
        lastResult = $lastResult
    }
}

function New-OpenPathProbeLauncher {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$Arguments = '',
        [int]$GraceSeconds = 6
    )
    $escapedPath = $FilePath.Replace("'", "''")
    $escapedArgs = $Arguments.Replace("'", "''")
    $body = @"
`$ErrorActionPreference = 'Continue'
`$result = [ordered]@{ name = '$Name'; startedAt = (Get-Date).ToUniversalTime().ToString('o') }
try {
    `$p = Start-Process -FilePath '$escapedPath' -ArgumentList '$escapedArgs' -PassThru -ErrorAction Stop
    Start-Sleep -Seconds $GraceSeconds
    `$live = Get-Process -Id `$p.Id -ErrorAction SilentlyContinue
    `$result.started = `$true
    `$result.stillRunning = [bool]`$live
    if (`$live) {
        `$result.loadedModules = @(`$live.Modules | ForEach-Object { `$_.ModuleName } | Where-Object { `$_ -match 'mozglue|nss3|xul' } | Select-Object -First 5)
        Stop-Process -Id `$p.Id -Force -ErrorAction SilentlyContinue
    }
}
catch {
    `$result.started = `$false
    `$result.error = `$_.Exception.Message
    `$result.nativeError = `$_.Exception.NativeErrorCode
}
`$result | ConvertTo-Json -Compress | Set-Content -LiteralPath '$ProbeRoot/$Name.result.json' -Encoding UTF8
"@
    $launcher = Join-Path $ProbeRoot "$Name.ps1"
    [IO.File]::WriteAllText($launcher, $body, [Text.UTF8Encoding]::new($false))
    return "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $launcher"
}

function Get-ProbeDecision {
    param([Parameter(Mandatory = $true)][string]$Name)
    $resultFile = Join-Path $ProbeRoot "$Name.result.json"
    if (-not (Test-Path -LiteralPath $resultFile)) { return [ordered]@{ observed = 'no-result'; started = $null } }
    try { return [ordered]@{ observed = (Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json); started = [bool](Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json).started } }
    catch { return [ordered]@{ observed = 'unparsable'; started = $null } }
}

function Invoke-OpenPathBoundaryProbes {
    Ensure-OpenPathProbeDirectory
    $probes = [ordered]@{}
    $critical = New-Object System.Collections.Generic.List[string]

    function Add-ProbeResult {
        param(
            [string]$Key,
            [string]$Expected,
            [object]$Observed,
            [string]$Fixture = ''
        )
        # "ran" is the truthful execution signal: a launcher reports whether the
        # target process started, the script probe whether its marker exists and
        # the MSI probe whether the package actually installed.
        $ran = $null
        if ($Observed -is [System.Collections.IDictionary]) {
            if ($Observed.Contains('decision') -and $Observed.decision -is [System.Collections.IDictionary] -and $Observed.decision.Contains('started')) {
                $ran = [bool]$Observed.decision.started
            }
            elseif ($Observed.Contains('installed')) { $ran = [bool]$Observed.installed }
            elseif ($Observed.Contains('started') -and $null -ne $Observed.started) { $ran = [bool]$Observed.started }
            elseif ($Observed.Contains('markerPresent')) { $ran = [bool]$Observed.markerPresent }
        }
        $probes[$Key] = [ordered]@{ expected = $Expected; fixture = $Fixture; ran = $ran; observed = $Observed }
        if ($Expected -eq 'allowed' -and $ran -ne $true) { $critical.Add($Key) | Out-Null }
        if ($Expected -eq 'denied' -and ($ran -eq $true -or $null -eq $ran)) { $critical.Add($Key) | Out-Null }
    }

    # 1. Approved browser (Firefox) must run for the restricted student.
    $firefox = 'C:\Program Files\Mozilla Firefox\firefox.exe'
    if (Test-Path -LiteralPath $firefox) {
        $task = Invoke-OpenPathStudentTask -Name 'allowed-browser' -CommandLine (New-OpenPathProbeLauncher -Name 'allowed-browser' -FilePath $firefox -Arguments '-foreground' -GraceSeconds 10) -WaitSeconds 60
        Add-ProbeResult -Key 'allowedBrowser' -Expected 'allowed' -Fixture 'exeAndDll' -Observed ([ordered]@{ task = $task; decision = (Get-ProbeDecision -Name 'allowed-browser') })
    }
    else {
        Add-OpenPathLabFailure 'firefox-missing'
        Add-ProbeResult -Key 'allowedBrowser' -Expected 'allowed' -Fixture 'exeAndDll' -Observed ([ordered]@{ error = 'firefox-missing' })
    }

    # 2. Windows runtime base allow: in-box signed Win32 binary plus its DLLs.
    $systemExe = 'C:\Windows\System32\charmap.exe'
    $task = Invoke-OpenPathStudentTask -Name 'allowed-system-exe' -CommandLine (New-OpenPathProbeLauncher -Name 'allowed-system-exe' -FilePath $systemExe -GraceSeconds 4) -WaitSeconds 45
    Add-ProbeResult -Key 'allowedSystemExe' -Expected 'allowed' -Fixture 'exeAndDll' -Observed ([ordered]@{ task = $task; decision = (Get-ProbeDecision -Name 'allowed-system-exe') })

    # 3. Unapproved browser surface must be denied.
    $edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
    if (Test-Path -LiteralPath $edge) {
        $task = Invoke-OpenPathStudentTask -Name 'denied-browser' -CommandLine (New-OpenPathProbeLauncher -Name 'denied-browser' -FilePath $edge -Arguments 'about:blank' -GraceSeconds 4) -WaitSeconds 45
        Add-ProbeResult -Key 'deniedBrowser' -Expected 'denied' -Observed ([ordered]@{ task = $task; decision = (Get-ProbeDecision -Name 'denied-browser') })
    }
    else {
        Add-OpenPathLabFailure 'edge-missing'
        Add-ProbeResult -Key 'deniedBrowser' -Expected 'denied' -Observed ([ordered]@{ error = 'edge-missing' })
    }

    # 4. A user-writable executable copy must be denied.
    $userExe = Join-Path $ProbeRoot 'fixture-user-exe.exe'
    Copy-Item -LiteralPath $systemExe -Destination $userExe -Force -ErrorAction SilentlyContinue
    $task = Invoke-OpenPathStudentTask -Name 'denied-user-exe' -CommandLine (New-OpenPathProbeLauncher -Name 'denied-user-exe' -FilePath $userExe -GraceSeconds 4) -WaitSeconds 45
    Add-ProbeResult -Key 'deniedUserExe' -Expected 'denied' -Observed ([ordered]@{ task = $task; decision = (Get-ProbeDecision -Name 'denied-user-exe') })

    # 5. A user-writable script must not run (Script collection implicit deny).
    $marker = Join-Path $ProbeRoot 'script-marker.txt'
    Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    $scriptFile = Join-Path $ProbeRoot 'fixture-script.ps1'
    [IO.File]::WriteAllText($scriptFile, "'ran' | Set-Content -LiteralPath '$marker'", [Text.UTF8Encoding]::new($false))
    $scriptTask = Invoke-OpenPathStudentTask -Name 'denied-script' -CommandLine "powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptFile" -WaitSeconds 45
    $scriptRan = Test-Path -LiteralPath $marker
    Add-ProbeResult -Key 'deniedScript' -Expected 'denied' -Fixture 'msiAndScript' -Observed ([ordered]@{ task = $scriptTask; markerPresent = $scriptRan; started = $scriptRan })

    # 6. A user-writable MSI package must be denied (Msi collection implicit deny).
    $msiSource = Get-ChildItem -Path 'D:\', 'E:\', 'F:\' -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($msiSource) {
        $msiFile = Join-Path $ProbeRoot 'fixture-package.msi'
        Copy-Item -LiteralPath $msiSource.FullName -Destination $msiFile -Force -ErrorAction SilentlyContinue
        $msiLog = Join-Path $ProbeRoot 'msi.log'
        Remove-Item -LiteralPath $msiLog -Force -ErrorAction SilentlyContinue
        $msiTask = Invoke-OpenPathStudentTask -Name 'denied-msi' -CommandLine "msiexec.exe /i `"$msiFile`" /qn /norestart /l*v `"$msiLog`"" -WaitSeconds 90
        $policyBlocked = $false
        $msiInstalled = $false
        if (Test-Path -LiteralPath $msiLog) {
            $policyBlocked = [bool](Select-String -LiteralPath $msiLog -Pattern '1625|forbidden by system policy|AppLocker' -Quiet -ErrorAction SilentlyContinue)
            $msiInstalled = [bool](Select-String -LiteralPath $msiLog -Pattern 'Installation success or error status: 0\b' -Quiet -ErrorAction SilentlyContinue)
        }
        Add-ProbeResult -Key 'deniedMsi' -Expected 'denied' -Fixture 'msiAndScript' -Observed ([ordered]@{ task = $msiTask; policyBlocked = $policyBlocked; installed = $msiInstalled; started = $msiInstalled })
    }
    else {
        Add-OpenPathLabFailure 'msi-fixture-source-missing'
        Add-ProbeResult -Key 'deniedMsi' -Expected 'denied' -Fixture 'msiAndScript' -Observed ([ordered]@{ error = 'msi-fixture-source-missing' })
    }

    # 7. Unapproved packaged app activation must be denied under strict mode.
    $task = Invoke-OpenPathStudentTask -Name 'packaged-app' -CommandLine (New-OpenPathProbeLauncher -Name 'packaged-app' -FilePath "$env:SystemRoot\System32\calc.exe" -GraceSeconds 4) -WaitSeconds 45
    Add-ProbeResult -Key 'packagedApp' -Expected 'denied' -Fixture 'packagedAppExecution' -Observed ([ordered]@{ task = $task; decision = (Get-ProbeDecision -Name 'packaged-app') })

    $fixtures = [ordered]@{
        exeAndDll            = if ($probes.allowedBrowser.ran -eq $true -and $probes.allowedSystemExe.ran -eq $true) { 'passed' } else { 'failed' }
        msiAndScript         = if ($probes.deniedScript.ran -eq $false -and $probes.deniedMsi.ran -eq $false -and $probes.deniedMsi.observed.policyBlocked -eq $true) { 'passed' } else { 'failed' }
        packagedAppExecution = if ($probes.packagedApp.ran -eq $false) { 'passed' } else { 'failed' }
    }
    $criticalDenials = @()
    foreach ($entry in $probes.GetEnumerator()) {
        if ($entry.Value.expected -eq 'allowed' -and $entry.Value.ran -ne $true) { $criticalDenials += [string]$entry.Key }
        if ($entry.Value.expected -eq 'denied' -and ($entry.Value.ran -eq $true -or $null -eq $entry.Value.ran)) { $criticalDenials += [string]$entry.Key }
    }

    return [ordered]@{
        probes                    = $probes
        fixtures                  = $fixtures
        criticalUnexpectedDenials = @($criticalDenials)
    }
}

function Invoke-OpenPathLabStep {
    switch ("$Phase/$Step") {
        'prepare/install' {
            $state = [ordered]@{
                scenarioId              = $ScenarioId
                startedAtUtc            = [DateTime]::UtcNow.ToString('o')
                policyBeforeSha256      = Get-Sha256Hex -Text (Get-AppLockerXmlText)
                policyBeforeHasOpenPath = Test-PolicyHasOpenPathRules
                initialProfileExisted   = Test-Path -LiteralPath "C:\Users\$StudentUserName"
                catalogApplicationCount = 0
            }
            if (Test-Path -LiteralPath 'C:\OpenPath') { Add-OpenPathLabFailure 'baseline-not-clean-openpath-present' }
            if (Get-LocalGroup -Name 'OpenPath-Restricted' -ErrorAction SilentlyContinue) { Add-OpenPathLabFailure 'baseline-not-clean-restricted-group-present' }
            if (-not (Test-Path -LiteralPath $PersonalizedExePath)) { Add-OpenPathLabFailure 'personalized-exe-missing' }
            if (-not (Test-Path -LiteralPath $TemplatePath)) { Add-OpenPathLabFailure 'template-exe-missing' }

            if ($Secret) {
                foreach ($user in @($StudentUserName, $AdminUserName)) {
                    & net.exe user $user $Secret 2>&1 | Out-Null
                    if ($LASTEXITCODE -ne 0) { Add-OpenPathLabFailure "account-reset-failed-$user" }
                }
            }

            if ($script:Failures.Count -eq 0) {
                $stopwatch = [Diagnostics.Stopwatch]::StartNew()
                $process = Start-Process -FilePath $PersonalizedExePath -ArgumentList '/S' -Wait -PassThru
                $stopwatch.Stop()
                $state.installExitCode = $process.ExitCode
                $state.installSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
            }
            $summary = Get-OpenPathStateSummary
            $state.policyAfterSha256 = $summary.policySha256
            $state.config = $summary.config
            $state.groupMembers = $summary.groupMembers
            $state.tasks = $summary.tasks
            $state.uninstaller = $summary.uninstaller
            $state.catalogApplicationCount = $summary.catalogApplicationCount
            $installExit = -1
            $installSecondsValue = 0.0
            if ($state.Contains('installExitCode')) { $installExit = [int]$state.installExitCode }
            if ($state.Contains('installSeconds')) { $installSecondsValue = [double]$state.installSeconds }
            $state.installSummary = [ordered]@{ exitCode = $installExit; seconds = $installSecondsValue }
            $state.summary = $summary
            if (-not $summary.configExists) { Add-OpenPathLabFailure 'install-config-missing' }
            elseif ([string]$summary.config.appControlProfile -ne 'StrictApplicationAllowlist') { Add-OpenPathLabFailure 'install-profile-not-strict' }
            elseif ([string]$summary.config.appControlCommitState -ne 'committed') { Add-OpenPathLabFailure 'install-appcontrol-not-committed' }
            if (-not $summary.uninstaller) { Add-OpenPathLabFailure 'install-uninstaller-missing' }
            if (-not $summary.groupExists) { Add-OpenPathLabFailure 'install-restricted-group-missing' }
            Write-OpenPathLabState -Value $state
            return [ordered]@{ state = $state }
        }
        'observe/admin-autologon' {
            Set-OpenPathAutologon -UserName $AdminUserName -Password $Secret | Out-Null
            return [ordered]@{ autologon = $AdminUserName }
        }
        'observe/admin-verify' {
            return [ordered]@{ session = Get-InteractiveSession -UserName $AdminUserName }
        }
        'observe/student-autologon' {
            Set-OpenPathAutologon -UserName $StudentUserName -Password $Secret | Out-Null
            return [ordered]@{ autologon = $StudentUserName }
        }
        'observe/student-verify' {
            $state = Read-OpenPathLabState
            $logons = Get-StudentLogonEvents -Sid (Get-TargetUserSid -UserName $StudentUserName) -AfterUtc ([datetime]$state.startedAtUtc)
            return [ordered]@{
                session                      = Get-InteractiveSession -UserName $StudentUserName
                studentLogons                = @($logons)
                firstStudentInteractiveLogon = [bool](@($logons).Count -gt 0)
            }
        }
        'observe/boundary' {
            $probe = Invoke-OpenPathBoundaryProbes
            $state = Read-OpenPathLabState
            $state.preRebootProbes = $probe
            Write-OpenPathLabState -Value $state
            return $probe
        }
        'afterReboot/login-screen' {
            Clear-OpenPathAutologon | Out-Null
            return [ordered]@{ autologon = 'cleared' }
        }
        'afterReboot/admin-autologon' {
            Set-OpenPathAutologon -UserName $AdminUserName -Password $Secret | Out-Null
            return [ordered]@{ autologon = $AdminUserName }
        }
        'afterReboot/admin-verify' {
            return [ordered]@{ session = Get-InteractiveSession -UserName $AdminUserName }
        }
        'afterReboot/student-autologon' {
            Set-OpenPathAutologon -UserName $StudentUserName -Password $Secret | Out-Null
            return [ordered]@{ autologon = $StudentUserName }
        }
        'afterReboot/student-verify' {
            return [ordered]@{ session = Get-InteractiveSession -UserName $StudentUserName }
        }
        'afterReboot/boundary' {
            $probe = Invoke-OpenPathBoundaryProbes
            $state = Read-OpenPathLabState
            $state.postRebootProbes = $probe
            Write-OpenPathLabState -Value $state
            return $probe
        }
        'cleanup/uninstall' {
            $state = Read-OpenPathLabState
            Clear-OpenPathAutologon | Out-Null
            $state.uninstallFailed = $false
            if (Test-Path -LiteralPath 'C:\OpenPath\Uninstall-OpenPath.ps1') {
                $stopwatch = [Diagnostics.Stopwatch]::StartNew()
                $process = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', 'C:\OpenPath\Uninstall-OpenPath.ps1'
                ) -Wait -PassThru
                $stopwatch.Stop()
                $state.uninstallExitCode = $process.ExitCode
                $state.uninstallSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
                if ($process.ExitCode -ne 0) { $state.uninstallFailed = $true; Add-OpenPathLabFailure 'uninstall-nonzero-exit' }
            }
            else { $state.uninstallFailed = $true; Add-OpenPathLabFailure 'uninstall-script-missing' }
            $summary = Get-OpenPathStateSummary
            $state.summary = $summary
            $state.policyAfterUninstallSha256 = $summary.policySha256
            if ($summary.rootExists) { Add-OpenPathLabFailure 'rollback-root-remains' }
            if ($summary.groupExists) { Add-OpenPathLabFailure 'rollback-group-remains' }
            if (@($summary.tasks).Count -gt 0) { Add-OpenPathLabFailure 'rollback-tasks-remain' }
            if ($summary.policyHasOpenPathRules) { Add-OpenPathLabFailure 'rollback-openpath-rules-remain' }
            Write-OpenPathLabState -Value $state
            return [ordered]@{ state = $state }
        }
        'cleanup/verify-clean' {
            $state = Read-OpenPathLabState
            $summary = Get-OpenPathStateSummary
            $clean = (-not $summary.rootExists) -and (-not $summary.groupExists) -and (@($summary.tasks).Count -eq 0) -and (-not $summary.policyHasOpenPathRules)
            if (-not $clean) { Add-OpenPathLabFailure 'cleanup-not-clean' }
            return [ordered]@{
                clean                    = $clean
                summary                  = $summary
                policyEqualsBefore       = ($summary.policySha256 -eq $state.policyBeforeSha256)
                policyHasOpenPathRules   = $summary.policyHasOpenPathRules
            }
        }
        default { throw "desktop-survival-step-invalid: $Phase/$Step" }
    }
}

$result = [ordered]@{
    schemaVersion = 2
    scenarioId    = $ScenarioId
    phase         = $Phase
    step          = $Step
    status        = 'passed'
    failures      = @()
    body          = $null
}
try { $result.body = Invoke-OpenPathLabStep }
catch { $result.status = 'failed'; Add-OpenPathLabFailure "step-error: $($_.Exception.Message)" }
$result.failures = @($script:Failures)
if ($script:Failures.Count -gt 0) { $result.status = 'failed' }
$json = $result | ConvertTo-Json -Depth 24
[IO.File]::WriteAllText($ResultPath, $json, [Text.UTF8Encoding]::new($false))
Write-Output $json
if ($result.status -ne 'passed') { exit 1 }
exit 0
