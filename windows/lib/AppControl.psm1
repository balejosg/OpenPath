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
    <#
    .SYNOPSIS
    Escapes a value for safe embedding in an XML attribute.
    #>
    param(
        [AllowNull()]
        [string]$Value
    )

    return [System.Security.SecurityElement]::Escape([string]$Value)
}

function Get-OpenPathAppLockerRuleName {
    <#
    .SYNOPSIS
    Extracts the Name attribute from an AppLocker rule object regardless of its underlying type.
    #>
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
    <#
    .SYNOPSIS
    Returns true when an AppLocker rule was created by OpenPath, based on its name prefix.
    #>
    param(
        [AllowNull()]
        [object]$Rule
    )

    $ruleName = Get-OpenPathAppLockerRuleName -Rule $Rule
    return ($ruleName -like "$script:OpenPathAppControlRulePrefix*")
}

function Get-OpenPathApprovedBrowserSet {
    <#
    .SYNOPSIS
    Converts a list of browser name strings into a normalized lookup table keyed by browser family.
    #>
    param(
        [string[]]$ApprovedBrowsers = @('Firefox')
    )

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

    return $approvedBrowserSet
}

function Get-OpenPathEdgeAppxProductNames {
    <#
    .SYNOPSIS
    Returns the set of Microsoft Edge Appx package product names, supplemented by live inventory when available.
    #>
    [CmdletBinding()]
    param()

    $products = @(
        'Microsoft.MicrosoftEdge',
        'Microsoft.MicrosoftEdge.Stable'
    )

    if (Get-Command -Name Get-AppxPackage -ErrorAction SilentlyContinue) {
        try {
            $products += @(
                Get-AppxPackage -Name 'Microsoft.MicrosoftEdge*' -AllUsers -ErrorAction SilentlyContinue |
                    ForEach-Object { [string]$_.Name } |
                    Where-Object { $_ }
            )
        }
        catch {
            # Static product names above keep the policy deterministic when Appx inventory is unavailable.
        }
    }

    return @($products | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-OpenPathAlwaysDeniedAppxProductNames {
    <#
    .SYNOPSIS
    Returns the Appx package product names that must always be denied to non-admins
    regardless of approved-browser configuration.
    .DESCRIPTION
    W-2: the blanket Microsoft-signed Appx allow (PublisherName='O=MICROSOFT CORPORATION*',
    ProductName='*') is intentionally kept so OS inbox and Store-distributed Microsoft
    packages keep working. But several Microsoft-signed packages ship parallel,
    unfiltered network stacks that bypass the name-based DNS whitelist: WSL (full Linux
    userspace with its own resolver), Windows Terminal (a launcher that hosts arbitrary
    consoles), and the OpenSSH/Telnet Appx clients. AppLocker evaluates Deny over Allow,
    so listing these as explicit per-product denies neutralises them while leaving the
    rest of the Microsoft-signed surface allowed. Product names are matched as AppLocker
    publisher ProductName globs.
    #>
    [CmdletBinding()]
    param()

    return @(
        'Microsoft.WSL',
        'WindowsSubsystemForLinux',
        'MicrosoftCorporationII.WindowsSubsystemForLinux',
        'Microsoft.WindowsTerminal',
        'Microsoft.WindowsTerminalPreview',
        'Microsoft.OpenSSHClient',
        'Microsoft.OpenSSHServer',
        'Microsoft.TelnetClient',
        'Microsoft.PowerShell'
    )
}

function New-OpenPathNonAdminAppLockerPolicySpec {
    <#
    .SYNOPSIS
    Builds the full allow/deny path and publisher specification for the non-admin AppLocker policy.
    .DESCRIPTION
    Returns a PSCustomObject describing all allow paths, user-writable deny paths, unapproved browser
    deny paths, and blocked system tools based on the approved browser set and enforcement mode.
    The returned spec is the input for the XML generator and the boundary-policy validator.
    #>
    [CmdletBinding()]
    param(
        [string]$OpenPathRoot = $script:OpenPathRoot,

        [ValidateSet('AuditOnly', 'Enforced')]
        [string]$Mode = 'Enforced',

        [string[]]$ApprovedBrowsers = @('Firefox')
    )

    $openPathRuntimePath = "$($OpenPathRoot.TrimEnd('\'))\*"
    $approvedBrowserSet = Get-OpenPathApprovedBrowserSet -ApprovedBrowsers $ApprovedBrowsers

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
    $unapprovedBrowserDenyAppxProducts = @()
    if (-not $approvedBrowserSet.Edge) {
        $unapprovedBrowserDenyAppxProducts = @(Get-OpenPathEdgeAppxProductNames)
    }

    return [PSCustomObject]@{
        Mode = $Mode
        EnforcementMode = if ($Mode -eq 'AuditOnly') { 'AuditOnly' } else { 'Enabled' }
        NonAdminSid = 'S-1-5-32-545'
        AdminSid = 'S-1-5-32-544'
        SystemSid = 'S-1-5-18'
        ApprovedBrowsers = @($approvedBrowserSet.Keys | Sort-Object)
        AllowPaths = @($allowPaths)
        UnapprovedBrowserDenyPaths = @($unapprovedBrowserDenyPaths)
        UnapprovedBrowserDenyAppxProducts = @($unapprovedBrowserDenyAppxProducts)
        AlwaysDeniedAppxProducts = @(Get-OpenPathAlwaysDeniedAppxProductNames)
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
            '%WINDIR%\SysWOW64\cscript.exe',
            # W-1(a) IP-literal egress: with no transport-level egress floor, any
            # interpreter that can open a socket reaches an arbitrary IP and spoofs
            # the Host header to bypass the name-based whitelist. Block the inbox
            # scripting hosts that a standard user can launch from the protected
            # %WINDIR% allow path. Windows PowerShell lives under WindowsPowerShell\v1.0,
            # not directly in System32, so the full real path is required for the
            # AppLocker FilePathCondition exception to match.
            '%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe',
            '%WINDIR%\SysWOW64\WindowsPowerShell\v1.0\powershell.exe',
            '%PROGRAMFILES%\PowerShell\7\pwsh.exe',
            '%PROGRAMFILES(X86)%\PowerShell\7\pwsh.exe',
            '%WINDIR%\System32\ftp.exe',
            '%WINDIR%\SysWOW64\ftp.exe',
            '%WINDIR%\System32\tftp.exe',
            '%WINDIR%\SysWOW64\tftp.exe'
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
    <#
    .SYNOPSIS
    Generates an AppLocker FilePathRule XML fragment for a single path with optional exceptions.
    #>
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
    <#
    .SYNOPSIS
    Generates an AppLocker FilePublisherRule XML fragment for a publisher/product/binary triple.
    #>
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
    <#
    .SYNOPSIS
    Renders a complete AppLocker policy XML document from a policy specification object.
    #>
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
            # W-1(a): emit BlockedWindowsTools as explicit non-admin DENY rules too, not
            # only as exceptions to the %WINDIR%\* allow. Tools such as pwsh.exe live under
            # %PROGRAMFILES%\PowerShell\7\ -- covered by the %PROGRAMFILES%\* allow, which
            # does NOT receive the %WINDIR% exception list -- so without an explicit deny
            # they would still run. AppLocker evaluates Deny over Allow, so these denies
            # block the tools wherever their allow path lives.
            $denyPaths += @($Spec.BlockedWindowsTools)
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

    $appxRules = @()
    foreach ($productName in @($Spec.UnapprovedBrowserDenyAppxProducts)) {
        $productId = ($productName -replace '[^0-9A-Za-z]+', '-').Trim('-')
        $appxRules += New-OpenPathFilePublisherRuleXml -Name "$script:OpenPathAppControlRulePrefix Appx users deny $productId" -Sid $Spec.NonAdminSid -Action 'Deny' -PublisherName '*' -ProductName $productName -BinaryName '*'
    }
    # W-2: deny the parallel-network-stack Microsoft Appx packages (WSL, Windows
    # Terminal, OpenSSH/Telnet) ahead of the Microsoft-signed allow. AppLocker
    # evaluates Deny over Allow, so these stay blocked even though the broad
    # Microsoft-signed allow below keeps the rest of the inbox/Store surface usable.
    foreach ($productName in @($Spec.AlwaysDeniedAppxProducts)) {
        $productId = ($productName -replace '[^0-9A-Za-z]+', '-').Trim('-')
        $appxRules += New-OpenPathFilePublisherRuleXml -Name "$script:OpenPathAppControlRulePrefix Appx users deny parallel network stack $productId" -Sid $Spec.NonAdminSid -Action 'Deny' -PublisherName '*' -ProductName $productName -BinaryName '*'
    }
    # Allow only Microsoft-signed packaged apps (OS inbox and Store-distributed Microsoft apps).
    # A global ProductName='*' allow lets any publisher's Appx run, including sideloaded alternate
    # browsers with non-Edge ProductNames that would bypass the per-product Edge denies above.
    # Scoping to PublisherName='O=MICROSOFT CORPORATION*' covers all Microsoft-signed packages
    # (Windows inbox, Store-distributed Edge, Teams, etc.) without opening the door to third-party
    # sideloaded packages.  SID S-1-1-0 (Everyone) is kept so the rule applies to all users
    # including non-admins, matching the original intent.
    $appxRules += New-OpenPathFilePublisherRuleXml -Name "$script:OpenPathAppControlRulePrefix Appx users allow Microsoft signed packaged apps" -Sid 'S-1-1-0' -Action 'Allow' -PublisherName 'O=MICROSOFT CORPORATION*' -ProductName '*' -BinaryName '*'
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
    <#
    .SYNOPSIS
    Merges an OpenPath AppLocker policy into an existing policy, replacing any previously managed rules.
    .DESCRIPTION
    For each rule collection type present in the OpenPath policy, existing managed rules are removed
    from the current policy and replaced with the incoming rules. The enforcement mode is also updated.
    Unmanaged rules in the current policy are preserved unchanged.
    #>
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
        # A pristine local policy (Get-AppLockerPolicy -Local -Xml on a machine that has
        # never had AppLocker configured) is '<AppLockerPolicy Version="1" />' with no
        # RuleCollection children, so .RuleCollection is a scalar $null. Piping that $null
        # into Where-Object runs the filter once with $_ = $null; the $null -ne $_ guard
        # stops $null.GetAttribute(...) from throwing "You cannot call a method on a
        # null-valued expression" and aborting the installer's app-control phase.
        $targetCollection = @($CurrentPolicy.AppLockerPolicy.RuleCollection | Where-Object { $null -ne $_ -and $_.GetAttribute('Type') -eq $collectionType })[0]

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
    <#
    .SYNOPSIS
    Returns true when the required AppLocker management commands are present on this host.
    #>
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

function Get-OpenPathAppLockerCollection {
    <#
    .SYNOPSIS
    Returns the first rule collection of the specified type from a parsed AppLocker policy document.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [xml]$PolicyXml,

        [Parameter(Mandatory = $true)]
        [string]$Type
    )

    # Guard against a pristine policy whose .RuleCollection is a scalar $null (see
    # Merge-OpenPathAppLockerPolicyXml): the $null -ne $_ check prevents $null.GetAttribute().
    return @($PolicyXml.AppLockerPolicy.RuleCollection | Where-Object { $null -ne $_ -and $_.GetAttribute('Type') -eq $Type })[0]
}

function Test-OpenPathAppLockerCollectionMode {
    <#
    .SYNOPSIS
    Returns true when the given rule collection has the expected enforcement mode attribute value.
    #>
    param(
        [AllowNull()]
        [object]$Collection,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedMode
    )

    if (-not $Collection) {
        return $false
    }

    return ([string]$Collection.GetAttribute('EnforcementMode') -eq $ExpectedMode)
}

function Test-OpenPathFilePathRulePresent {
    <#
    .SYNOPSIS
    Returns true when a managed file-path rule with the given action, SID, and path exists in the collection.
    #>
    param(
        [AllowNull()]
        [object]$Collection,

        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Sid,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not $Collection) {
        return $false
    }

    return [bool](@($Collection.FilePathRule | Where-Object {
                $_.GetAttribute('Action') -eq $Action -and
                $_.GetAttribute('UserOrGroupSid') -eq $Sid -and
                $_.Conditions.FilePathCondition.GetAttribute('Path') -eq $Path -and
                (Test-OpenPathAppLockerRuleManaged -Rule $_)
            }).Count -gt 0)
}

function Test-OpenPathFilePublisherRulePresent {
    <#
    .SYNOPSIS
    Returns true when a managed publisher rule with the given action, SID, publisher name, and product name exists in the collection.
    #>
    param(
        [AllowNull()]
        [object]$Collection,

        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Sid,

        [Parameter(Mandatory = $true)]
        [string]$ProductName,

        [string]$PublisherName = $null
    )

    if (-not $Collection) {
        return $false
    }

    return [bool](@($Collection.FilePublisherRule | Where-Object {
                $_.GetAttribute('Action') -eq $Action -and
                $_.GetAttribute('UserOrGroupSid') -eq $Sid -and
                $_.Conditions.FilePublisherCondition.GetAttribute('ProductName') -eq $ProductName -and
                $_.Conditions.FilePublisherCondition.GetAttribute('BinaryName') -eq '*' -and
                (-not $PublisherName -or $_.Conditions.FilePublisherCondition.GetAttribute('PublisherName') -eq $PublisherName) -and
                (Test-OpenPathAppLockerRuleManaged -Rule $_)
            }).Count -gt 0)
}

function Test-OpenPathAppIdentityServiceRunning {
    <#
    .SYNOPSIS
    Returns true when the Application Identity service is present and currently running.
    #>
    [CmdletBinding()]
    param()

    if (-not (Get-Command -Name Get-Service -ErrorAction SilentlyContinue)) {
        return $false
    }

    try {
        $service = Get-Service -Name AppIDSvc -ErrorAction Stop
        return ([string]$service.Status -eq 'Running')
    }
    catch {
        return $false
    }
}

function Test-OpenPathAppLockerBoundaryPolicy {
    <#
    .SYNOPSIS
    Validates that a parsed AppLocker policy contains all required OpenPath boundary rules in the expected mode.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [xml]$PolicyXml,

        [ValidateSet('AuditOnly', 'Enforced')]
        [string]$Mode = 'Enforced',

        [string[]]$ApprovedBrowsers = @('Firefox')
    )

    $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot $script:OpenPathRoot -Mode $Mode -ApprovedBrowsers $ApprovedBrowsers
    $expectedMode = $spec.EnforcementMode
    $exeCollection = Get-OpenPathAppLockerCollection -PolicyXml $PolicyXml -Type 'Exe'
    $scriptCollection = Get-OpenPathAppLockerCollection -PolicyXml $PolicyXml -Type 'Script'
    $appxCollection = Get-OpenPathAppLockerCollection -PolicyXml $PolicyXml -Type 'Appx'

    foreach ($collection in @($exeCollection, $appxCollection)) {
        if (-not (Test-OpenPathAppLockerCollectionMode -Collection $collection -ExpectedMode $expectedMode)) {
            return $false
        }
    }

    foreach ($collection in @($exeCollection, $scriptCollection)) {
        foreach ($sid in @($spec.AdminSid, $spec.SystemSid)) {
            if (-not (Test-OpenPathFilePathRulePresent -Collection $collection -Action 'Allow' -Sid $sid -Path '*')) {
                return $false
            }
        }
    }

    if (-not (Test-OpenPathFilePublisherRulePresent -Collection $appxCollection -Action 'Allow' -Sid 'S-1-1-0' -ProductName '*' -PublisherName 'O=MICROSOFT CORPORATION*')) {
        return $false
    }

    foreach ($productName in @($spec.AlwaysDeniedAppxProducts)) {
        if (-not (Test-OpenPathFilePublisherRulePresent -Collection $appxCollection -Action 'Deny' -Sid $spec.NonAdminSid -ProductName $productName)) {
            return $false
        }
    }

    $approvedSet = Get-OpenPathApprovedBrowserSet -ApprovedBrowsers $ApprovedBrowsers
    if (-not $approvedSet.Edge) {
        foreach ($path in @($spec.UnapprovedBrowserDenyPaths | Where-Object { $_ -match '\\Microsoft\\Edge\\Application\\msedge\.exe$' })) {
            if (-not (Test-OpenPathFilePathRulePresent -Collection $exeCollection -Action 'Deny' -Sid $spec.NonAdminSid -Path $path)) {
                return $false
            }
        }
        foreach ($productName in @($spec.UnapprovedBrowserDenyAppxProducts)) {
            if (-not (Test-OpenPathFilePublisherRulePresent -Collection $appxCollection -Action 'Deny' -Sid $spec.NonAdminSid -ProductName $productName)) {
                return $false
            }
        }
    }

    return $true
}

function Set-OpenPathNonAdminAppControl {
    <#
    .SYNOPSIS
    Applies the OpenPath non-admin AppLocker policy, backing up the current policy first and restoring it on validation failure.
    .DESCRIPTION
    Requires administrator privileges. Backs up the current AppLocker policy to disk, builds the
    merged OpenPath policy, applies it, then validates the result. If validation fails the backup
    is restored. Also ensures the Application Identity service is running after a successful apply.
    #>
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

        if (-not (Test-OpenPathNonAdminAppControlActive -Mode $Mode -ApprovedBrowsers $ApprovedBrowsers)) {
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
    <#
    .SYNOPSIS
    Returns true when the live AppLocker policy matches the expected OpenPath boundary policy for the given mode.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('AuditOnly', 'Enforced')]
        [string]$Mode = 'Enforced',

        [string[]]$ApprovedBrowsers = @('Firefox')
    )

    if (-not (Test-OpenPathAppControlAvailable)) {
        return $false
    }
    if (-not (Test-OpenPathAppIdentityServiceRunning)) {
        return $false
    }

    try {
        $policyXml = [xml](Get-AppLockerPolicy -Local -Xml)
        return [bool](Test-OpenPathAppLockerBoundaryPolicy -PolicyXml $policyXml -Mode $Mode -ApprovedBrowsers $ApprovedBrowsers)
    }
    catch {
        return $false
    }
}

function Remove-OpenPathNonAdminAppControl {
    <#
    .SYNOPSIS
    Removes all OpenPath-managed AppLocker rules from the live policy and saves the cleaned policy.
    #>
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
    'Get-OpenPathAlwaysDeniedAppxProductNames',
    'New-OpenPathNonAdminAppLockerPolicySpec',
    'New-OpenPathAppLockerPolicyXml',
    'Merge-OpenPathAppLockerPolicyXml',
    'Test-OpenPathAppControlAvailable',
    'Set-OpenPathNonAdminAppControl',
    'Test-OpenPathNonAdminAppControlActive',
    'Remove-OpenPathNonAdminAppControl'
)
