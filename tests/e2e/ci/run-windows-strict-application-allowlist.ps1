[CmdletBinding()]
param(
    [string]$OpenPathRoot = 'C:\OpenPath',

    [string]$EvidencePath = '',

    [string]$StudentSid = '',

    [string]$StudentUserName = '',

    # The password is accepted only for the optional real-process probes.  It is
    # never copied to the evidence object or written to a log.
    [string]$StudentPassword = '',

    [switch]$ExecuteProbes,

    [switch]$RequireFixtures,

    [switch]$KeepFixtures
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-OpenPathStrictWindowsHost {
    $isWindows = Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue
    if ($null -ne $isWindows) {
        return [bool]$isWindows
    }

    return $env:OS -eq 'Windows_NT'
}

function Write-OpenPathStrictEvidence {
    param(
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporaryPath = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        $json = $Evidence | ConvertTo-Json -Depth 18
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-OpenPathStrictConfig {
    param([Parameter(Mandatory = $true)][string]$Root)

    $configPath = Join-Path $Root 'data\config.json'
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "strict-config-missing:$configPath"
    }
    return Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}

function Get-OpenPathStrictConfigValue {
    param(
        [AllowNull()][object]$Config,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$Default = $null
    )

    if ($Config -and $Config.PSObject.Properties[$Name]) {
        return $Config.$Name
    }
    return $Default
}

function Resolve-OpenPathStrictStudentSid {
    param([string]$RequestedSid = '')

    if (-not [string]::IsNullOrWhiteSpace($RequestedSid)) {
        if ($RequestedSid -notmatch '^S-1-') {
            throw 'strict-student-sid-invalid'
        }
        return $RequestedSid
    }

    $members = @(Get-LocalGroupMember -Group 'OpenPath-Restricted' -ErrorAction Stop)
    foreach ($member in $members) {
        if ($member.PSObject.Properties['SID'] -and $member.SID) {
            $sid = [string]$member.SID.Value
            if ($sid -match '^S-1-' -and $sid -ne 'S-1-5-32-545') {
                return $sid
            }
        }
    }
    throw 'strict-student-sid-unavailable'
}

function Get-OpenPathStrictStudentUserName {
    param(
        [string]$RequestedName = '',
        [Parameter(Mandatory = $true)][string]$StudentSid
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedName)) {
        return $RequestedName
    }

    try {
        $member = @(Get-LocalGroupMember -Group 'OpenPath-Restricted' -ErrorAction Stop |
                Where-Object { $_.SID -and [string]$_.SID.Value -eq $StudentSid } | Select-Object -First 1)
        if ($member.Count -eq 1) {
            return [string]$member[0].Name
        }
    }
    catch {
    }
    return ''
}

function Get-OpenPathStrictPolicyDecision {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$StudentSid,
        [Parameter(Mandatory = $true)][string[]]$Expected
    )

    $decision = $null
    try {
        $decision = Get-OpenPathTestAppLockerPolicyDecision `
            -ExecutablePath $Path `
            -StudentSid $StudentSid
        $observed = if ($decision.PSObject.Properties['decision']) { [string]$decision.decision } else { 'unknown' }
        $status = if ($observed -in $Expected) { 'pass' } else { 'fail' }
        return [pscustomobject][ordered]@{
            name = $Name
            kind = 'Test-AppLockerPolicy'
            path = $Path
            expected = @($Expected)
            observed = $observed
            status = $status
            observerStatus = if ($decision.PSObject.Properties['status']) { [string]$decision.status } else { 'unknown' }
            reason = if ($decision.PSObject.Properties['reason']) { [string]$decision.reason } else { $null }
        }
    }
    catch {
        return [pscustomobject][ordered]@{
            name = $Name
            kind = 'Test-AppLockerPolicy'
            path = $Path
            expected = @($Expected)
            observed = 'unknown'
            status = 'unknown'
            observerStatus = 'failed'
            reason = 'policy-evaluation-failed'
        }
    }
}

function Get-OpenPathStrictFixtureResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Expected,
        [string]$Path = '',
        [Parameter(Mandatory = $true)][bool]$RequireFixture
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject][ordered]@{
            name = $Name
            kind = 'fixture'
            path = $null
            expected = $Expected
            observed = 'not-provided'
            status = if ($RequireFixture) { 'fail' } else { 'skip' }
            reason = 'fixture-not-provided'
        }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            name = $Name
            kind = 'fixture'
            path = $Path
            expected = $Expected
            observed = 'missing'
            status = if ($RequireFixture) { 'fail' } else { 'skip' }
            reason = 'fixture-not-found'
        }
    }
    return $null
}

function Get-OpenPathStrictAppxRuleProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Package,
        [Parameter(Mandatory = $true)][xml]$PolicyXml,
        [Parameter(Mandatory = $true)][string]$RestrictedSid,
        [Parameter(Mandatory = $true)][bool]$ExpectedAllowed
    )

    $productName = if ($Package.PSObject.Properties['Name']) { [string]$Package.Name } else { '' }
    $publisherName = if ($Package.PSObject.Properties['Publisher']) { [string]$Package.Publisher } else { '' }
    $rules = @($PolicyXml.AppLockerPolicy.RuleCollection |
        Where-Object { $_.GetAttribute('Type') -eq 'Appx' } |
        ForEach-Object { @($_.FilePublisherRule) } |
        Where-Object {
            $_.GetAttribute('Action') -eq 'Allow' -and
            $_.GetAttribute('UserOrGroupSid') -eq $RestrictedSid
        })
    $matchingRules = @($rules | Where-Object {
            $condition = $_.Conditions.FilePublisherCondition
            $product = [string]$condition.GetAttribute('ProductName')
            $publisher = [string]$condition.GetAttribute('PublisherName')
            ($product -eq '*' -or $product -eq $productName) -and
            ($publisher -eq '*' -or [string]::IsNullOrWhiteSpace($publisherName) -or $publisher -eq $publisherName)
        })
    $allowed = $matchingRules.Count -gt 0
    $status = if ($allowed -eq $ExpectedAllowed) { 'pass' } else { 'fail' }
    return [pscustomobject][ordered]@{
        name = $Name
        kind = 'Appx-policy-rule'
        package = $productName
        publisher = $publisherName
        expected = if ($ExpectedAllowed) { 'Allowed' } else { 'DeniedByDefault' }
        observed = if ($allowed) { 'Allowed' } else { 'DeniedByDefault' }
        matchingRuleCount = $matchingRules.Count
        status = $status
    }
}

function Add-OpenPathStrictProbe {
    param(
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[object]]$Results,
        [AllowNull()][object]$Probe
    )

    if ($null -ne $Probe) {
        [void]$Results.Add($Probe)
    }
}

if (-not (Test-OpenPathStrictWindowsHost)) {
    throw 'strict-application-allowlist-e2e-must-run-on-windows'
}

$evidenceRoot = if ($EvidencePath) {
    $EvidencePath
}
else {
    Join-Path $PSScriptRoot '..\artifacts\windows-strict-application-allowlist'
}
New-Item -ItemType Directory -Path $evidenceRoot -Force | Out-Null
$evidenceRoot = (Resolve-Path -LiteralPath $evidenceRoot).Path
$reportPath = Join-Path $evidenceRoot 'strict-application-allowlist-report.json'
$results = [System.Collections.Generic.List[object]]::new()
$executionResults = [System.Collections.Generic.List[object]]::new()
$createdFixturePaths = [System.Collections.Generic.List[string]]::new()
$harnessError = $null
$profile = $null
$activeProfile = $null
$studentSid = $null

try {
    $config = Get-OpenPathStrictConfig -Root $OpenPathRoot
    $profile = [string](Get-OpenPathStrictConfigValue -Config $config -Name 'appControlProfile' -Default 'ManagedBrowserCompatibility')
    $activeProfile = [string](Get-OpenPathStrictConfigValue -Config $config -Name 'activeAppControlProfile' -Default 'none')
    $mode = [string](Get-OpenPathStrictConfigValue -Config $config -Name 'nonAdminAppControlMode' -Default 'Enforced')
    $approvedBrowsers = @((Get-OpenPathStrictConfigValue -Config $config -Name 'approvedStudentBrowsers' -Default @('Firefox')))
    $catalog = Get-OpenPathStrictConfigValue -Config $config -Name 'approvedApplicationCatalog' -Default $null
    $commitState = [string](Get-OpenPathStrictConfigValue -Config $config -Name 'appControlCommitState' -Default '')

    if ([string](Get-OpenPathStrictConfigValue -Config $config -Name 'installState' -Default '') -ne 'complete') {
        throw 'strict-install-state-not-complete'
    }
    if (-not [bool](Get-OpenPathStrictConfigValue -Config $config -Name 'enableNonAdminAppControl' -Default $false)) {
        throw 'strict-appcontrol-disabled'
    }
    if ($profile -ne 'StrictApplicationAllowlist' -or $activeProfile -ne 'StrictApplicationAllowlist') {
        throw "strict-profile-not-active:configured=$profile;active=$activeProfile"
    }
    if ($commitState -ne 'committed') {
        throw "strict-appcontrol-not-committed:$commitState"
    }

    $appControlModule = Join-Path $OpenPathRoot 'lib\AppControl.psm1'
    if (-not (Test-Path -LiteralPath $appControlModule -PathType Leaf)) {
        throw 'strict-appcontrol-module-missing'
    }
    Import-Module $appControlModule -Force -Global -ErrorAction Stop
    Import-Module (Join-Path $OpenPathRoot 'lib\Browser.Inventory.psm1') -Force -Global -ErrorAction Stop
    Import-Module (Join-Path $PSScriptRoot 'BrowserBoundaryProbe.psm1') -Force -Global -ErrorAction Stop

    if (-not (Test-OpenPathApplicationApprovalCatalog -Profile $profile -Catalog $catalog)) {
        throw 'strict-catalog-invalid'
    }

    $studentSid = Resolve-OpenPathStrictStudentSid -RequestedSid $StudentSid
    $resolvedStudentUserName = Get-OpenPathStrictStudentUserName -RequestedName $StudentUserName -StudentSid $studentSid
    if ($ExecuteProbes -and ([string]::IsNullOrWhiteSpace($resolvedStudentUserName) -or [string]::IsNullOrWhiteSpace($StudentPassword))) {
        throw 'strict-runtime-probes-require-student-credentials'
    }

    $health = Get-OpenPathNonAdminAppControlHealth `
        -Mode $mode `
        -ApprovedBrowsers $approvedBrowsers `
        -Profile $profile `
        -ApplicationCatalog $catalog
    if (-not $health -or -not [bool]$health.Healthy) {
        throw "strict-appcontrol-health-failed:$(@($health.ReasonCodes) -join ',')"
    }

    $localPolicyXml = [xml](Get-AppLockerPolicy -Local -Xml -ErrorAction Stop)
    $effectivePolicyXml = [xml](Get-AppLockerPolicy -Effective -Xml -ErrorAction Stop)
    # Test-OpenPathNonAdminAppControlHealth performs the same boundary validator
    # inside the AppControl module (the validator is intentionally private).  Use
    # its two independently captured observations rather than reimplementing or
    # bypassing that contract from the E2E harness.
    $localBoundaryValid = [bool]$health.LocalPolicyValid
    $effectiveBoundaryValid = [bool]$health.EffectivePolicyValid
    Add-OpenPathStrictProbe -Results $results -Probe ([pscustomobject][ordered]@{
            name = 'Strict local policy boundary'
            kind = 'AppLocker-structure'
            expected = 'valid'
            observed = if ($localBoundaryValid) { 'valid' } else { 'invalid' }
            status = if ($localBoundaryValid) { 'pass' } else { 'fail' }
        })
    Add-OpenPathStrictProbe -Results $results -Probe ([pscustomobject][ordered]@{
            name = 'Strict effective policy boundary'
            kind = 'AppLocker-structure'
            expected = 'valid'
            observed = if ($effectiveBoundaryValid) { 'valid' } else { 'invalid' }
            status = if ($effectiveBoundaryValid) { 'pass' } else { 'fail' }
        })

    $futurePath = 'C:\Program Files\FutureBrowser\future.exe'
    $futureManagedRules = @($localPolicyXml.AppLockerPolicy.RuleCollection |
        ForEach-Object { @($_.ChildNodes) } |
        Where-Object {
            ([string]$_.Name -like 'OpenPath non-admin app control*') -and
            ([string]$_.OuterXml -match '(?i)FutureBrowser')
        })
    Add-OpenPathStrictProbe -Results $results -Probe ([pscustomobject][ordered]@{
            name = 'Synthetic FutureBrowser has no explicit managed deny rule'
            kind = 'AppLocker-structure'
            expected = 'absent'
            observed = if ($futureManagedRules.Count -eq 0) { 'absent' } else { 'present' }
            status = if ($futureManagedRules.Count -eq 0) { 'pass' } else { 'fail' }
        })
    Add-OpenPathStrictProbe -Results $results -Probe (Get-OpenPathStrictPolicyDecision `
            -Name 'Synthetic FutureBrowser is denied by strict default' `
            -Path $futurePath `
            -StudentSid $studentSid `
            -Expected @('Denied', 'DeniedByDefault'))

    $runtimeScriptPath = Join-Path $OpenPathRoot 'OpenPath.ps1'
    if (Test-Path -LiteralPath $runtimeScriptPath -PathType Leaf) {
        Add-OpenPathStrictProbe -Results $results -Probe (Get-OpenPathStrictPolicyDecision `
                -Name 'OpenPath runtime script remains available' `
                -Path $runtimeScriptPath `
                -StudentSid $studentSid `
                -Expected @('Allowed'))
    }
    else {
        Add-OpenPathStrictProbe -Results $results -Probe ([pscustomobject][ordered]@{
                name = 'OpenPath runtime script remains available'
                kind = 'fixture'
                expected = 'present'
                observed = 'missing'
                status = 'fail'
                reason = 'openpath-runtime-script-missing'
            })
    }

    $inventory = Get-OpenPathBrowserInventory -Mode ReportOnly
    $approvedBrowserIdentity = @($inventory.ExecutableIdentities | Where-Object {
            $_ -and $_.ExecutablePath -and $_.IsApproved -and
            ([string]$_.Family -in $approvedBrowsers) -and
            (Test-Path -LiteralPath ([string]$_.ExecutablePath) -PathType Leaf)
        } | Select-Object -First 1)
    if ($approvedBrowserIdentity.Count -eq 1) {
        $approvedBrowserPath = [string]$approvedBrowserIdentity[0].ExecutablePath
        Add-OpenPathStrictProbe -Results $results -Probe (Get-OpenPathStrictPolicyDecision `
                -Name "Approved $($approvedBrowserIdentity[0].Family) browser is allowed" `
                -Path $approvedBrowserPath `
                -StudentSid $studentSid `
                -Expected @('Allowed'))
    }
    else {
        $probe = [pscustomobject][ordered]@{
            name = 'An approved browser fixture is available'
            kind = 'fixture'
            path = $null
            expected = 'present'
            observed = 'missing'
            status = if ($RequireFixtures) { 'fail' } else { 'skip' }
            reason = 'approved-browser-not-installed'
        }
        Add-OpenPathStrictProbe -Results $results -Probe $probe
    }

    $catalogApprovedPath = [string]$env:OPENPATH_STRICT_APPROVED_APP_PATH
    if ([string]::IsNullOrWhiteSpace($catalogApprovedPath)) {
        $pathIdentity = @($catalog.applications | Where-Object {
                $_.identity -and [string]$_.identity.type -eq 'Path'
            } | Select-Object -First 1)
        if ($pathIdentity.Count -eq 1) { $catalogApprovedPath = [string]$pathIdentity[0].identity.path }
    }
    $catalogFixture = Get-OpenPathStrictFixtureResult `
        -Name 'Approved classroom application fixture is available' `
        -Expected 'Allowed' `
        -Path $catalogApprovedPath `
        -RequireFixture $RequireFixtures
    if ($catalogFixture) {
        Add-OpenPathStrictProbe -Results $results -Probe $catalogFixture
    }
    else {
        Add-OpenPathStrictProbe -Results $results -Probe (Get-OpenPathStrictPolicyDecision `
                -Name 'Approved classroom application is allowed' `
                -Path $catalogApprovedPath `
                -StudentSid $studentSid `
                -Expected @('Allowed'))
    }

    $siblingPath = [string]$env:OPENPATH_STRICT_SIBLING_APP_PATH
    $siblingFixture = Get-OpenPathStrictFixtureResult `
        -Name 'Unapproved sibling application fixture is available' `
        -Expected 'DeniedOrDeniedByDefault' `
        -Path $siblingPath `
        -RequireFixture $RequireFixtures
    if ($siblingFixture) {
        Add-OpenPathStrictProbe -Results $results -Probe $siblingFixture
    }
    else {
        Add-OpenPathStrictProbe -Results $results -Probe (Get-OpenPathStrictPolicyDecision `
                -Name 'Unapproved sibling application is denied' `
                -Path $siblingPath `
                -StudentSid $studentSid `
                -Expected @('Denied', 'DeniedByDefault'))
    }

    foreach ($fixture in @(
            [pscustomobject]@{ Name = 'Unapproved MSI is denied'; EnvironmentName = 'OPENPATH_STRICT_UNAPPROVED_MSI_PATH' },
            [pscustomobject]@{ Name = 'Unapproved script is denied'; EnvironmentName = 'OPENPATH_STRICT_UNAPPROVED_SCRIPT_PATH' }
        )) {
        $fixtureEntry = Get-Item -Path "Env:$($fixture.EnvironmentName)" -ErrorAction SilentlyContinue
        $fixturePath = if ($fixtureEntry) { [string]$fixtureEntry.Value } else { '' }
        $fixtureResult = Get-OpenPathStrictFixtureResult `
            -Name "$($fixture.Name) fixture is available" `
            -Expected 'DeniedOrDeniedByDefault' `
            -Path $fixturePath `
            -RequireFixture $RequireFixtures
        if ($fixtureResult) {
            Add-OpenPathStrictProbe -Results $results -Probe $fixtureResult
        }
        else {
            Add-OpenPathStrictProbe -Results $results -Probe (Get-OpenPathStrictPolicyDecision `
                    -Name $fixture.Name `
                    -Path $fixturePath `
                    -StudentSid $studentSid `
                    -Expected @('Denied', 'DeniedByDefault'))
        }
    }

    $publisherUpdatePath = [string]$env:OPENPATH_STRICT_UPDATED_PUBLISHER_APP_PATH
    if (-not [string]::IsNullOrWhiteSpace($publisherUpdatePath)) {
        $publisherApplication = @($catalog.applications | Where-Object {
                $_.identity -and [string]$_.identity.type -eq 'Publisher'
            } | Select-Object -First 1)
        if ($publisherApplication.Count -ne 1) {
            Add-OpenPathStrictProbe -Results $results -Probe ([pscustomobject][ordered]@{
                    name = 'Publisher-approved application update remains allowed'
                    kind = 'catalog'
                    path = $publisherUpdatePath
                    expected = 'Publisher'
                    observed = 'no-publisher-identity'
                    status = 'fail'
                    reason = 'publisher-update-identity-not-configured'
                })
        }
        else {
            $fixtureResult = Get-OpenPathStrictFixtureResult `
                -Name 'Publisher-approved application update fixture is available' `
                -Expected 'Allowed' `
                -Path $publisherUpdatePath `
                -RequireFixture $RequireFixtures
            if ($fixtureResult) {
                Add-OpenPathStrictProbe -Results $results -Probe $fixtureResult
            }
            else {
                Add-OpenPathStrictProbe -Results $results -Probe (Get-OpenPathStrictPolicyDecision `
                        -Name 'Publisher-approved application update remains allowed' `
                        -Path $publisherUpdatePath `
                        -StudentSid $studentSid `
                        -Expected @('Allowed'))
            }
        }
    }

    $hashUpdatePath = [string]$env:OPENPATH_STRICT_UPDATED_HASH_APP_PATH
    if (-not [string]::IsNullOrWhiteSpace($hashUpdatePath)) {
        $hashApplication = @($catalog.applications | Where-Object {
                $_.identity -and [string]$_.identity.type -eq 'Hash'
            } | Select-Object -First 1)
        if ($hashApplication.Count -ne 1) {
            Add-OpenPathStrictProbe -Results $results -Probe ([pscustomobject][ordered]@{
                    name = 'Changed hash-approved application is denied until catalog update'
                    kind = 'catalog'
                    path = $hashUpdatePath
                    expected = 'Hash'
                    observed = 'no-hash-identity'
                    status = 'fail'
                    reason = 'hash-update-identity-not-configured'
                })
        }
        else {
            $fixtureResult = Get-OpenPathStrictFixtureResult `
                -Name 'Hash-approved application update fixture is available' `
                -Expected 'DeniedOrDeniedByDefault' `
                -Path $hashUpdatePath `
                -RequireFixture $RequireFixtures
            if ($fixtureResult) {
                Add-OpenPathStrictProbe -Results $results -Probe $fixtureResult
            }
            else {
                try {
                    $observedHash = (Get-FileHash -LiteralPath $hashUpdatePath -Algorithm SHA256 -ErrorAction Stop).Hash
                    $approvedHash = [string]$hashApplication[0].identity.sha256
                    if ($observedHash.Equals($approvedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
                        Add-OpenPathStrictProbe -Results $results -Probe ([pscustomobject][ordered]@{
                                name = 'Changed hash-approved application is denied until catalog update'
                                kind = 'catalog'
                                path = $hashUpdatePath
                                expected = 'different SHA-256 from catalog'
                                observed = 'unchanged'
                                status = 'fail'
                                reason = 'hash-update-fixture-not-changed'
                            })
                    }
                    else {
                        Add-OpenPathStrictProbe -Results $results -Probe (Get-OpenPathStrictPolicyDecision `
                                -Name 'Changed hash-approved application is denied until catalog update' `
                                -Path $hashUpdatePath `
                                -StudentSid $studentSid `
                                -Expected @('Denied', 'DeniedByDefault'))
                    }
                }
                catch {
                    Add-OpenPathStrictProbe -Results $results -Probe ([pscustomobject][ordered]@{
                            name = 'Changed hash-approved application is denied until catalog update'
                            kind = 'Test-AppLockerPolicy'
                            path = $hashUpdatePath
                            expected = @('Denied', 'DeniedByDefault')
                            observed = 'unknown'
                            status = 'unknown'
                            reason = 'hash-update-evaluation-failed'
                        })
                }
            }
        }
    }

    $appxPackage = $null
    $appxFixturePath = [string]$env:OPENPATH_STRICT_UNAPPROVED_APPX_PATH
    if (Get-Command -Name Get-AppxPackage -ErrorAction SilentlyContinue) {
        $packages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
        if ($appxFixturePath) {
            $appxPackage = @($packages | Where-Object { [string]$_.InstallLocation -eq $appxFixturePath } | Select-Object -First 1)
        }
        if ($appxPackage.Count -eq 0) {
            $approvedAppxProducts = @($catalog.applications | Where-Object {
                    $_.identity -and [string]$_.identity.type -eq 'AppxPublisher'
                } | ForEach-Object { [string]$_.identity.productName })
            $appxPackage = @($packages | Where-Object {
                    [string]$_.Name -and [string]$_.Name -notin $approvedAppxProducts
                } | Select-Object -First 1)
        }
    }
    if ($appxPackage.Count -eq 1) {
        Add-OpenPathStrictProbe -Results $results -Probe (Get-OpenPathStrictAppxRuleProbe `
                -Name 'Unapproved Appx package is denied by absence of restricted allow rule' `
                -Package $appxPackage[0] `
                -PolicyXml $effectivePolicyXml `
                -RestrictedSid ([string]$health.GroupSid) `
                -ExpectedAllowed $false)
    }
    else {
        Add-OpenPathStrictProbe -Results $results -Probe ([pscustomobject][ordered]@{
                name = 'Unapproved Appx fixture is available'
                kind = 'fixture'
                expected = 'present'
                observed = 'missing'
                status = if ($RequireFixtures) { 'fail' } else { 'skip' }
                reason = 'unapproved-appx-not-installed'
            })
    }

    $appxAllowedRules = @($effectivePolicyXml.AppLockerPolicy.RuleCollection |
        Where-Object { $_.GetAttribute('Type') -eq 'Appx' } |
        ForEach-Object { @($_.FilePublisherRule) } |
        Where-Object {
            $_.GetAttribute('Action') -eq 'Allow' -and
            $_.GetAttribute('UserOrGroupSid') -eq [string]$health.GroupSid
        })
    Add-OpenPathStrictProbe -Results $results -Probe ([pscustomobject][ordered]@{
            name = 'Strict Appx surface has no broad restricted-user allow'
            kind = 'AppLocker-structure'
            expected = 'no wildcard product allow'
            observed = if (@($appxAllowedRules | Where-Object { $_.Conditions.FilePublisherCondition.GetAttribute('ProductName') -eq '*' }).Count -eq 0) { 'scoped' } else { 'broad' }
            status = if (@($appxAllowedRules | Where-Object { $_.Conditions.FilePublisherCondition.GetAttribute('ProductName') -eq '*' }).Count -eq 0) { 'pass' } else { 'fail' }
        })

    foreach ($collectionType in @('Exe', 'Script', 'Msi', 'Dll')) {
        $collection = @($localPolicyXml.AppLockerPolicy.RuleCollection | Where-Object { $_.GetAttribute('Type') -eq $collectionType })
        $adminRecovery = @($collection | ForEach-Object { @($_.FilePathRule) } | Where-Object {
                $_.GetAttribute('Action') -eq 'Allow' -and
                $_.GetAttribute('UserOrGroupSid') -in @('S-1-5-32-544', 'S-1-5-18') -and
                $_.Conditions.FilePathCondition.GetAttribute('Path') -eq '*'
            })
        Add-OpenPathStrictProbe -Results $results -Probe ([pscustomobject][ordered]@{
                name = "Administrator and SYSTEM $collectionType recovery"
                kind = 'AppLocker-structure'
                expected = 'administrator-and-system-allow-all'
                observed = "$($adminRecovery.Count) recovery rules"
                status = if ($adminRecovery.Count -ge 2) { 'pass' } else { 'fail' }
            })
    }

    $appxRecovery = @($localPolicyXml.AppLockerPolicy.RuleCollection |
        Where-Object { $_.GetAttribute('Type') -eq 'Appx' } |
        ForEach-Object { @($_.FilePublisherRule) } |
        Where-Object {
            $_.GetAttribute('Action') -eq 'Allow' -and
            $_.GetAttribute('UserOrGroupSid') -in @('S-1-5-32-544', 'S-1-5-18') -and
            $_.Conditions.FilePublisherCondition.GetAttribute('PublisherName') -eq '*' -and
            $_.Conditions.FilePublisherCondition.GetAttribute('ProductName') -eq '*' -and
            $_.Conditions.FilePublisherCondition.GetAttribute('BinaryName') -eq '*'
        })
    Add-OpenPathStrictProbe -Results $results -Probe ([pscustomobject][ordered]@{
            name = 'Administrator and SYSTEM Appx recovery'
            kind = 'AppLocker-structure'
            expected = 'administrator-and-system-allow-all'
            observed = "$($appxRecovery.Count) recovery rules"
            status = if ($appxRecovery.Count -ge 2) { 'pass' } else { 'fail' }
        })

    if ($ExecuteProbes) {
        $futureDirectory = Split-Path -Parent $futurePath
        $futureFileExisted = Test-Path -LiteralPath $futurePath -PathType Leaf
        if ($futureFileExisted) {
            throw 'strict-future-browser-fixture-already-exists'
        }
        New-Item -ItemType Directory -Path $futureDirectory -Force | Out-Null
        $createdFixturePaths.Add($futurePath)
        New-OpenPathProbePayloadBinary -OutputPath $futurePath
        $markerPath = Join-Path $evidenceRoot 'future-browser-ran.marker'
        $futureArguments = '"' + $markerPath.Replace('"', '\"') + '"'
        $executionProbe = Invoke-StudentExecutableTaskProbe `
            -ProbeName 'Synthetic FutureBrowser real execution is denied' `
            -UserName $resolvedStudentUserName `
            -Password $StudentPassword `
            -ExecutablePath $futurePath `
            -Arguments $futureArguments `
            -Expectation ExpectDenied `
            -ProcessName 'future' `
            -StudentSid $studentSid `
            -MarkerPath $markerPath `
            -CaptureEnforcementDiagnostics
        [void]$executionResults.Add($executionProbe)

        if ($approvedBrowserIdentity.Count -eq 1) {
            $browserPath = [string]$approvedBrowserIdentity[0].ExecutablePath
            $browserName = [string]$approvedBrowserIdentity[0].Family
            $profileDirectory = Join-Path $evidenceRoot 'approved-browser-profile'
            New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null
            & icacls.exe $profileDirectory /grant "*$studentSid`:(OI)(CI)M" /T *> $null
            $browserArguments = if ($browserName -eq 'Firefox') {
                "-headless -new-instance -profile `"$profileDirectory`" about:blank"
            }
            else {
                "--headless --disable-gpu --user-data-dir=`"$profileDirectory`" about:blank"
            }
            $browserExecutionProbe = Invoke-StudentExecutableTaskProbe `
                -ProbeName "Approved $browserName real execution is allowed" `
                -UserName $resolvedStudentUserName `
                -Password $StudentPassword `
                -ExecutablePath $browserPath `
                -Arguments $browserArguments `
                -Expectation ExpectAllowed `
                -ProcessName ([IO.Path]::GetFileNameWithoutExtension($browserPath)) `
                -StudentSid $studentSid `
                -CaptureEnforcementDiagnostics
            [void]$executionResults.Add($browserExecutionProbe)
        }
    }
}
catch {
    $results.Add([pscustomobject][ordered]@{
            name = 'Strict E2E harness'
            kind = 'harness'
            expected = 'completed'
            observed = 'failed'
            status = 'fail'
            reason = 'strict-e2e-harness-failed'
        })
    $harnessError = $_.Exception.Message
    if (-not [string]::IsNullOrWhiteSpace($StudentPassword)) {
        $harnessError = $harnessError.Replace($StudentPassword, '<redacted>')
    }
}
finally {
    if (-not $KeepFixtures) {
        foreach ($fixturePath in @($createdFixturePaths.ToArray())) {
            Remove-Item -LiteralPath $fixturePath -Force -ErrorAction SilentlyContinue
        }
        $futureDirectory = 'C:\Program Files\FutureBrowser'
        $futureFixtureCreated = @($createdFixturePaths.ToArray() | Where-Object { $_ -like "$futureDirectory\*" }).Count -gt 0
        if ((Test-Path -LiteralPath $futureDirectory -PathType Container) -and $futureFixtureCreated) {
            Remove-Item -LiteralPath $futureDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$allResults = @($results.ToArray()) + @($executionResults.ToArray())
$report = [ordered]@{
    schemaVersion = 1
    profile = 'StrictApplicationAllowlist'
    configuredProfile = $profile
    activeProfile = $activeProfile
    executeProbes = [bool]$ExecuteProbes
    requireFixtures = [bool]$RequireFixtures
    studentSid = $studentSid
    probes = $allResults
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
}
if ($harnessError) {
    $report.harnessError = $harnessError
}
Write-OpenPathStrictEvidence -Evidence $report -Path $reportPath

$failed = @($allResults | Where-Object { $_.status -eq 'fail' -or $_.status -eq 'unknown' })
if ($failed.Count -gt 0) {
    Write-Error "Strict application allowlist E2E failed: $($failed.Count) probe(s). Evidence: $reportPath"
    exit 1
}
Write-Host "Strict application allowlist E2E passed. Evidence: $reportPath"
