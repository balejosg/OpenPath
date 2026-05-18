# OpenPath App Control Module for Windows
# Applies AppLocker policy for non-admin users on managed endpoints.

if (Test-Path (Join-Path $PSScriptRoot 'internal\WindowsRoot.ps1')) {
    . (Join-Path $PSScriptRoot 'internal\WindowsRoot.ps1')
}
$script:OpenPathRoot = if (Get-Command -Name Resolve-OpenPathWindowsRoot -ErrorAction SilentlyContinue) { Resolve-OpenPathWindowsRoot } else { "C:\OpenPath" }
Import-Module "$PSScriptRoot\Common.psm1" -ErrorAction SilentlyContinue

$script:OpenPathAppControlRulePrefix = 'OpenPath non-admin app control'
$script:OpenPathAppLockerBackupPath = "$script:OpenPathRoot\data\applocker-backup.xml"

function ConvertTo-OpenPathXmlAttribute {
    param(
        [AllowNull()]
        [string]$Value
    )

    return [System.Security.SecurityElement]::Escape([string]$Value)
}

function Get-OpenPathAppLockerRuleName {
    param(
        [AllowNull()]
        [object]$Rule
    )

    if (-not $Rule) {
        return ''
    }

    if ($Rule -is [System.Xml.XmlElement]) {
        if ($Rule.HasAttribute('Name')) {
            return [string]$Rule.GetAttribute('Name')
        }
        return ''
    }

    if ($Rule.PSObject.Methods.Name -contains 'GetAttribute') {
        try {
            return [string]$Rule.GetAttribute('Name')
        }
        catch {
            return ''
        }
    }

    if ($Rule.PSObject.Properties['Name']) {
        return [string]$Rule.Name
    }

    return ''
}

function Test-OpenPathAppLockerRuleManaged {
    param(
        [AllowNull()]
        [object]$Rule
    )

    $ruleName = Get-OpenPathAppLockerRuleName -Rule $Rule
    return ($ruleName -like "$script:OpenPathAppControlRulePrefix*")
}

function New-OpenPathNonAdminAppLockerPolicySpec {
    [CmdletBinding()]
    param(
        [string]$OpenPathRoot = $script:OpenPathRoot,

        [ValidateSet('AuditOnly', 'Enforced')]
        [string]$Mode = 'Enforced',

        [string[]]$ApprovedBrowsers = @('Firefox')
    )

    $openPathRuntimePath = "$($OpenPathRoot.TrimEnd('\'))\*"
    $approvedBrowserSet = @{}
    foreach ($browser in @($ApprovedBrowsers)) {
        $normalized = ([string]$browser).Trim().ToLowerInvariant()
        if (-not $normalized) {
            continue
        }
        if ($normalized -in @('firefox', 'mozilla firefox')) {
            $approvedBrowserSet.Firefox = $true
        }
        elseif ($normalized -in @('edge', 'microsoft edge')) {
            $approvedBrowserSet.Edge = $true
        }
        elseif ($normalized -in @('chrome', 'google chrome')) {
            $approvedBrowserSet.Chrome = $true
        }
    }

    $firefoxPaths = @(
        '%PROGRAMFILES%\Mozilla Firefox\firefox.exe',
        '%PROGRAMFILES(X86)%\Mozilla Firefox\firefox.exe',
        'C:\Program Files\Mozilla Firefox\firefox.exe',
        'C:\Program Files (x86)\Mozilla Firefox\firefox.exe'
    )
    $firefoxUserWritablePaths = @(
        '%LOCALAPPDATA%\Mozilla Firefox\firefox.exe'
    )
    $edgePaths = @(
        '%PROGRAMFILES%\Microsoft\Edge\Application\msedge.exe',
        '%PROGRAMFILES(X86)%\Microsoft\Edge\Application\msedge.exe',
        'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
        'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
    )
    $edgeUserWritablePaths = @(
        '%LOCALAPPDATA%\Microsoft\Edge\Application\msedge.exe'
    )
    $chromePaths = @(
        '%PROGRAMFILES%\Google\Chrome\Application\chrome.exe',
        '%PROGRAMFILES(X86)%\Google\Chrome\Application\chrome.exe',
        'C:\Program Files\Google\Chrome\Application\chrome.exe',
        'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
    )
    $chromeUserWritablePaths = @(
        '%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe'
    )
    $alwaysDeniedBrowserPaths = @(
        '%PROGRAMFILES%\BraveSoftware\Brave-Browser\Application\brave.exe',
        '%PROGRAMFILES(X86)%\BraveSoftware\Brave-Browser\Application\brave.exe',
        'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe',
        'C:\Program Files (x86)\BraveSoftware\Brave-Browser\Application\brave.exe',
        '%LOCALAPPDATA%\BraveSoftware\Brave-Browser\Application\brave.exe',
        '%PROGRAMFILES%\Opera\launcher.exe',
        '%PROGRAMFILES(X86)%\Opera\launcher.exe',
        'C:\Program Files\Opera\launcher.exe',
        'C:\Program Files (x86)\Opera\launcher.exe',
        '%LOCALAPPDATA%\Programs\Opera\launcher.exe',
        '%PROGRAMFILES%\Opera\opera.exe',
        '%PROGRAMFILES(X86)%\Opera\opera.exe',
        'C:\Program Files\Opera\opera.exe',
        'C:\Program Files (x86)\Opera\opera.exe',
        '%LOCALAPPDATA%\Programs\Opera\opera.exe',
        '%PROGRAMFILES%\Opera GX\launcher.exe',
        '%PROGRAMFILES(X86)%\Opera GX\launcher.exe',
        'C:\Program Files\Opera GX\launcher.exe',
        'C:\Program Files (x86)\Opera GX\launcher.exe',
        '%LOCALAPPDATA%\Programs\Opera GX\launcher.exe',
        '%PROGRAMFILES%\Vivaldi\Application\vivaldi.exe',
        '%PROGRAMFILES(X86)%\Vivaldi\Application\vivaldi.exe',
        'C:\Program Files\Vivaldi\Application\vivaldi.exe',
        'C:\Program Files (x86)\Vivaldi\Application\vivaldi.exe',
        '%LOCALAPPDATA%\Vivaldi\Application\vivaldi.exe',
        '%PROGRAMFILES%\Tor Browser\Browser\firefox.exe',
        '%PROGRAMFILES(X86)%\Tor Browser\Browser\firefox.exe',
        'C:\Program Files\Tor Browser\Browser\firefox.exe',
        'C:\Program Files (x86)\Tor Browser\Browser\firefox.exe',
        '%PROGRAMFILES%\Chromium\Application\chrome.exe',
        '%PROGRAMFILES(X86)%\Chromium\Application\chrome.exe',
        'C:\Program Files\Chromium\Application\chrome.exe',
        'C:\Program Files (x86)\Chromium\Application\chrome.exe',
        '%LOCALAPPDATA%\Chromium\Application\chrome.exe',
        '%PROGRAMFILES%\Chromium\Application\chromium.exe',
        '%PROGRAMFILES(X86)%\Chromium\Application\chromium.exe',
        'C:\Program Files\Chromium\Application\chromium.exe',
        'C:\Program Files (x86)\Chromium\Application\chromium.exe',
        '%LOCALAPPDATA%\Chromium\Application\chromium.exe',
        '%PROGRAMFILES%\Ungoogled Chromium\Application\chrome.exe',
        '%PROGRAMFILES(X86)%\Ungoogled Chromium\Application\chrome.exe',
        'C:\Program Files\Ungoogled Chromium\Application\chrome.exe',
        'C:\Program Files (x86)\Ungoogled Chromium\Application\chrome.exe',
        '%LOCALAPPDATA%\Ungoogled Chromium\Application\chrome.exe',
        '%PROGRAMFILES%\Ungoogled Chromium\Application\chromium.exe',
        '%PROGRAMFILES(X86)%\Ungoogled Chromium\Application\chromium.exe',
        'C:\Program Files\Ungoogled Chromium\Application\chromium.exe',
        'C:\Program Files (x86)\Ungoogled Chromium\Application\chromium.exe',
        '%LOCALAPPDATA%\Ungoogled Chromium\Application\chromium.exe',
        '%PROGRAMFILES%\Floorp\floorp.exe',
        '%PROGRAMFILES(X86)%\Floorp\floorp.exe',
        'C:\Program Files\Floorp\floorp.exe',
        'C:\Program Files (x86)\Floorp\floorp.exe',
        '%LOCALAPPDATA%\Floorp\floorp.exe',
        '%PROGRAMFILES%\Internet Explorer\iexplore.exe',
        '%PROGRAMFILES(X86)%\Internet Explorer\iexplore.exe',
        'C:\Program Files\Internet Explorer\iexplore.exe',
        'C:\Program Files (x86)\Internet Explorer\iexplore.exe'
    )
    $windowsAppsPaths = @(
        '%PROGRAMFILES%\WindowsApps\Microsoft.*\*',
        '%PROGRAMFILES%\WindowsApps\MicrosoftWindows.*\*',
        'C:\Program Files\WindowsApps\Microsoft.*\*',
        'C:\Program Files\WindowsApps\MicrosoftWindows.*\*'
    )

    $allowPaths = @(
        '%WINDIR%\*',
        $openPathRuntimePath,
        '%PROGRAMFILES%\*',
        '%PROGRAMFILES(X86)%\*',
        'C:\Program Files\*',
        'C:\Program Files (x86)\*'
    )
    $allowPaths += $windowsAppsPaths
    if ($approvedBrowserSet.Firefox) {
        $allowPaths += $firefoxPaths
    }
    if ($approvedBrowserSet.Edge) {
        $allowPaths += $edgePaths
    }
    if ($approvedBrowserSet.Chrome) {
        $allowPaths += $chromePaths
    }

    $unapprovedBrowserDenyPaths = @()
    if (-not $approvedBrowserSet.Firefox) {
        $unapprovedBrowserDenyPaths += $firefoxPaths
    }
    $unapprovedBrowserDenyPaths += $firefoxUserWritablePaths
    if (-not $approvedBrowserSet.Edge) {
        $unapprovedBrowserDenyPaths += $edgePaths
    }
    $unapprovedBrowserDenyPaths += $edgeUserWritablePaths
    if (-not $approvedBrowserSet.Chrome) {
        $unapprovedBrowserDenyPaths += $chromePaths
    }
    $unapprovedBrowserDenyPaths += $chromeUserWritablePaths
    $unapprovedBrowserDenyPaths += $alwaysDeniedBrowserPaths

    return [PSCustomObject]@{
        Mode = $Mode
        EnforcementMode = if ($Mode -eq 'AuditOnly') { 'AuditOnly' } else { 'Enabled' }
        NonAdminSid = 'S-1-5-32-545'
        AdminSid = 'S-1-5-32-544'
        SystemSid = 'S-1-5-18'
        ApprovedBrowsers = @($approvedBrowserSet.Keys | Sort-Object)
        AllowPaths = @($allowPaths)
        UnapprovedBrowserDenyPaths = @($unapprovedBrowserDenyPaths)
        BlockedWindowsTools = @(
            '%WINDIR%\System32\curl.exe',
            '%WINDIR%\SysWOW64\curl.exe',
            '%WINDIR%\System32\nslookup.exe',
            '%WINDIR%\SysWOW64\nslookup.exe',
            '%WINDIR%\System32\ssh.exe',
            '%WINDIR%\SysWOW64\ssh.exe',
            '%LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe',
            '%PROGRAMFILES%\WindowsApps\Microsoft.DesktopAppInstaller_*\winget.exe',
            '%WINDIR%\System32\certutil.exe',
            '%WINDIR%\SysWOW64\certutil.exe',
            '%WINDIR%\System32\bitsadmin.exe',
            '%WINDIR%\SysWOW64\bitsadmin.exe',
            '%WINDIR%\System32\mshta.exe',
            '%WINDIR%\SysWOW64\mshta.exe',
            '%WINDIR%\System32\wscript.exe',
            '%WINDIR%\SysWOW64\wscript.exe',
            '%WINDIR%\System32\cscript.exe',
            '%WINDIR%\SysWOW64\cscript.exe'
        )
        UserWritableDenyPaths = @(
            '%USERPROFILE%\Downloads\*',
            '%USERPROFILE%\Desktop\*',
            '%LOCALAPPDATA%\Temp\*',
            '%TEMP%\*'
        )
    }
}

function New-OpenPathFilePathRuleXml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CollectionType,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Sid,

        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string[]]$Exceptions = @()
    )

    $id = [guid]::NewGuid().ToString()
    $escapedName = ConvertTo-OpenPathXmlAttribute -Value $Name
    $escapedSid = ConvertTo-OpenPathXmlAttribute -Value $Sid
    $escapedPath = ConvertTo-OpenPathXmlAttribute -Value $Path
    $escapedAction = ConvertTo-OpenPathXmlAttribute -Value $Action
    $xml = "      <FilePathRule Id=`"$id`" Name=`"$escapedName`" Description=`"Managed by OpenPath`" UserOrGroupSid=`"$escapedSid`" Action=`"$escapedAction`">`n"
    $xml += "        <Conditions>`n"
    $xml += "          <FilePathCondition Path=`"$escapedPath`" />`n"
    $xml += "        </Conditions>`n"
    if ($Exceptions.Count -gt 0) {
        $xml += "        <Exceptions>`n"
        foreach ($exception in $Exceptions) {
            $escapedException = ConvertTo-OpenPathXmlAttribute -Value $exception
            $xml += "          <FilePathCondition Path=`"$escapedException`" />`n"
        }
        $xml += "        </Exceptions>`n"
    }
    $xml += "      </FilePathRule>"
    return $xml
}

function New-OpenPathFilePublisherRuleXml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Sid,

        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [string]$PublisherName,

        [Parameter(Mandatory = $true)]
        [string]$ProductName,

        [Parameter(Mandatory = $true)]
        [string]$BinaryName
    )

    $id = [guid]::NewGuid().ToString()
    $escapedName = ConvertTo-OpenPathXmlAttribute -Value $Name
    $escapedSid = ConvertTo-OpenPathXmlAttribute -Value $Sid
    $escapedAction = ConvertTo-OpenPathXmlAttribute -Value $Action
    $escapedPublisherName = ConvertTo-OpenPathXmlAttribute -Value $PublisherName
    $escapedProductName = ConvertTo-OpenPathXmlAttribute -Value $ProductName
    $escapedBinaryName = ConvertTo-OpenPathXmlAttribute -Value $BinaryName
    $xml = "      <FilePublisherRule Id=`"$id`" Name=`"$escapedName`" Description=`"Managed by OpenPath`" UserOrGroupSid=`"$escapedSid`" Action=`"$escapedAction`">`n"
    $xml += "        <Conditions>`n"
    $xml += "          <FilePublisherCondition PublisherName=`"$escapedPublisherName`" ProductName=`"$escapedProductName`" BinaryName=`"$escapedBinaryName`">`n"
    $xml += "            <BinaryVersionRange LowSection=`"*`" HighSection=`"*`" />`n"
    $xml += "          </FilePublisherCondition>`n"
    $xml += "        </Conditions>`n"
    $xml += "      </FilePublisherRule>"
    return $xml
}

function New-OpenPathAppLockerPolicyXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Spec
    )

    $ruleCollections = @()
    foreach ($collectionType in @('Exe', 'Script')) {
        $rules = @()
        $denyPaths = @($Spec.UserWritableDenyPaths)
        if ($collectionType -eq 'Exe') {
            $denyPaths += @($Spec.UnapprovedBrowserDenyPaths)
        }

        foreach ($path in $denyPaths) {
            $pathId = ($path -replace '[^0-9A-Za-z]+', '-').Trim('-')
            $rules += New-OpenPathFilePathRuleXml -CollectionType $collectionType -Name "$script:OpenPathAppControlRulePrefix $collectionType users deny $pathId" -Sid $Spec.NonAdminSid -Action 'Deny' -Path $path
        }

        $rules += New-OpenPathFilePathRuleXml -CollectionType $collectionType -Name "$script:OpenPathAppControlRulePrefix $collectionType administrators allow all" -Sid $Spec.AdminSid -Action 'Allow' -Path '*'
        $rules += New-OpenPathFilePathRuleXml -CollectionType $collectionType -Name "$script:OpenPathAppControlRulePrefix $collectionType system allow all" -Sid $Spec.SystemSid -Action 'Allow' -Path '*'

        foreach ($path in @($Spec.AllowPaths)) {
            $exceptions = @()
            if ($collectionType -eq 'Exe' -and $path -eq '%WINDIR%\*') {
                $exceptions = @($Spec.BlockedWindowsTools)
            }

            $pathId = ($path -replace '[^0-9A-Za-z]+', '-').Trim('-')
            $rules += New-OpenPathFilePathRuleXml -CollectionType $collectionType -Name "$script:OpenPathAppControlRulePrefix $collectionType users allow $pathId" -Sid $Spec.NonAdminSid -Action 'Allow' -Path $path -Exceptions $exceptions
        }

        $ruleCollections += "    <RuleCollection Type=`"$collectionType`" EnforcementMode=`"$($Spec.EnforcementMode)`">`n$($rules -join "`n")`n    </RuleCollection>"
    }

    $appxRules = @(
        New-OpenPathFilePublisherRuleXml -Name "$script:OpenPathAppControlRulePrefix Appx users allow signed packaged apps" -Sid 'S-1-1-0' -Action 'Allow' -PublisherName '*' -ProductName '*' -BinaryName '*'
    )
    $ruleCollections += "    <RuleCollection Type=`"Appx`" EnforcementMode=`"$($Spec.EnforcementMode)`">`n$($appxRules -join "`n")`n    </RuleCollection>"

    return @"
<AppLockerPolicy Version="1">
$($ruleCollections -join "`n")
    <RuleCollection Type="Dll" EnforcementMode="NotConfigured" />
    <RuleCollection Type="Msi" EnforcementMode="NotConfigured" />
</AppLockerPolicy>
"@
}

function Merge-OpenPathAppLockerPolicyXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [xml]$CurrentPolicy,

        [Parameter(Mandatory = $true)]
        [xml]$OpenPathPolicy
    )

    foreach ($sourceCollection in @($OpenPathPolicy.AppLockerPolicy.RuleCollection)) {
        if (@($sourceCollection.ChildNodes).Count -eq 0) {
            continue
        }

        $collectionType = $sourceCollection.GetAttribute('Type')
        $targetCollection = @($CurrentPolicy.AppLockerPolicy.RuleCollection | Where-Object { $_.GetAttribute('Type') -eq $collectionType })[0]

        if (-not $targetCollection) {
            $targetCollection = $CurrentPolicy.ImportNode($sourceCollection, $false)
            [void]$CurrentPolicy.AppLockerPolicy.AppendChild($targetCollection)
        }

        if ($sourceCollection.HasAttribute('EnforcementMode')) {
            $targetCollection.SetAttribute('EnforcementMode', $sourceCollection.GetAttribute('EnforcementMode'))
        }

        foreach ($rule in @($targetCollection.ChildNodes)) {
            if (Test-OpenPathAppLockerRuleManaged -Rule $rule) {
                [void]$targetCollection.RemoveChild($rule)
            }
        }

        foreach ($rule in @($sourceCollection.ChildNodes)) {
            $importedRule = $CurrentPolicy.ImportNode($rule, $true)
            [void]$targetCollection.AppendChild($importedRule)
        }
    }

    return $CurrentPolicy
}

function Test-OpenPathAppControlAvailable {
    [CmdletBinding()]
    param()

    $requiredCommands = @('Set-AppLockerPolicy', 'Get-AppLockerPolicy')
    foreach ($command in $requiredCommands) {
        if (-not (Get-Command -Name $command -ErrorAction SilentlyContinue)) {
            return $false
        }
    }

    return $true
}

function Set-OpenPathNonAdminAppControl {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$OpenPathRoot = $script:OpenPathRoot,

        [ValidateSet('AuditOnly', 'Enforced')]
        [string]$Mode = 'Enforced',

        [string[]]$ApprovedBrowsers = @('Firefox')
    )

    if (-not (Test-AdminPrivileges)) {
        Write-OpenPathLog 'Administrator privileges required for AppLocker configuration' -Level ERROR
        return $false
    }
    if (-not (Test-OpenPathAppControlAvailable)) {
        Write-OpenPathLog 'AppLocker cmdlets unavailable; non-admin app control not applied' -Level WARN
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess('Windows AppLocker', "Configure OpenPath non-admin app control in $Mode mode")) {
        return $false
    }

    try {
        $appLockerBackupPath = Join-Path (Join-Path $OpenPathRoot 'data') 'applocker-backup.xml'
        $backupDir = Split-Path $appLockerBackupPath -Parent
        if (-not (Test-Path $backupDir)) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        }

        $currentPolicyText = Get-AppLockerPolicy -Local -Xml
        Set-Content -Path $appLockerBackupPath -Value $currentPolicyText -Encoding UTF8

        $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot $OpenPathRoot -Mode $Mode -ApprovedBrowsers $ApprovedBrowsers
        $policyXml = New-OpenPathAppLockerPolicyXml -Spec $spec
        $mergedPolicyXml = Merge-OpenPathAppLockerPolicyXml -CurrentPolicy ([xml]$currentPolicyText) -OpenPathPolicy ([xml]$policyXml)
        $policyPath = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-applocker-$([guid]::NewGuid()).xml"
        $mergedPolicyXml.Save($policyPath)
        Set-AppLockerPolicy -XMLPolicy $policyPath
        Remove-Item $policyPath -Force -ErrorAction SilentlyContinue

        try {
            Set-Service -Name AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name AppIDSvc -ErrorAction SilentlyContinue
        }
        catch {
            Write-OpenPathLog "AppLocker policy applied but AppIDSvc could not be started: $_" -Level WARN
        }

        if (-not (Test-OpenPathNonAdminAppControlActive)) {
            Set-AppLockerPolicy -XMLPolicy $appLockerBackupPath
            Write-OpenPathLog 'AppLocker validation failed after OpenPath policy apply; restored previous policy backup' -Level WARN
            return $false
        }

        Write-OpenPathLog "OpenPath non-admin app control applied in $Mode mode"
        return $true
    }
    catch {
        Write-OpenPathLog "Failed to configure OpenPath non-admin app control: $_" -Level WARN
        return $false
    }
}

function Test-OpenPathNonAdminAppControlActive {
    [CmdletBinding()]
    param()

    if (-not (Test-OpenPathAppControlAvailable)) {
        return $false
    }

    try {
        $policyXml = [xml](Get-AppLockerPolicy -Local -Xml)
        $rules = @($policyXml.AppLockerPolicy.RuleCollection.FilePathRule)
        return [bool](@($rules | Where-Object { Test-OpenPathAppLockerRuleManaged -Rule $_ }).Count -gt 0)
    }
    catch {
        return $false
    }
}

function Remove-OpenPathNonAdminAppControl {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not (Test-OpenPathAppControlAvailable)) {
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess('Windows AppLocker', 'Remove OpenPath non-admin app control rules')) {
        return $false
    }

    try {
        $policyXml = [xml](Get-AppLockerPolicy -Local -Xml)
        foreach ($collection in @($policyXml.AppLockerPolicy.RuleCollection)) {
            foreach ($rule in @($collection.ChildNodes)) {
                if (Test-OpenPathAppLockerRuleManaged -Rule $rule) {
                    [void]$collection.RemoveChild($rule)
                }
            }
        }

        $policyPath = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-applocker-remove-$([guid]::NewGuid()).xml"
        $policyXml.Save($policyPath)
        Set-AppLockerPolicy -XMLPolicy $policyPath
        Remove-Item $policyPath -Force -ErrorAction SilentlyContinue
        Write-OpenPathLog 'OpenPath non-admin app control rules removed'
        return $true
    }
    catch {
        Write-OpenPathLog "Failed to remove OpenPath non-admin app control rules: $_" -Level WARN
        return $false
    }
}

Export-ModuleMember -Function @(
    'New-OpenPathNonAdminAppLockerPolicySpec',
    'New-OpenPathAppLockerPolicyXml',
    'Merge-OpenPathAppLockerPolicyXml',
    'Test-OpenPathAppControlAvailable',
    'Set-OpenPathNonAdminAppControl',
    'Test-OpenPathNonAdminAppControlActive',
    'Remove-OpenPathNonAdminAppControl'
)
