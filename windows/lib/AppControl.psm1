# OpenPath App Control Module for Windows
# Applies AppLocker policy for non-admin users on managed endpoints.

if (Test-Path (Join-Path $PSScriptRoot 'internal\WindowsRoot.ps1')) {
    . (Join-Path $PSScriptRoot 'internal\WindowsRoot.ps1')
}
$script:OpenPathRoot = if (Get-Command -Name Resolve-OpenPathWindowsRoot -ErrorAction SilentlyContinue) { Resolve-OpenPathWindowsRoot } else { "C:\OpenPath" }
Import-Module "$PSScriptRoot\Common.psm1" -ErrorAction SilentlyContinue
Import-Module "$PSScriptRoot\Browser.Inventory.psm1" -Force -ErrorAction SilentlyContinue

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

function Get-OpenPathRestrictedGroupSid {
    <#
    .SYNOPSIS
    Returns the SID of the OpenPath-Restricted local group.
    .DESCRIPTION
    Fails closed when the dedicated group cannot be resolved. Widening the scope to
    BUILTIN\Users can restrict accounts outside the configured OpenPath boundary.
    #>
    [CmdletBinding()]
    param()

    if (-not (Get-Command -Name Get-LocalGroup -ErrorAction SilentlyContinue)) {
        throw 'OpenPath-Restricted group lookup capability is unavailable'
    }

    try {
        $group = Get-LocalGroup -Name 'OpenPath-Restricted' -ErrorAction Stop
        return [string]$group.SID.Value
    }
    catch {
        throw "OpenPath-Restricted group could not be resolved: $_"
    }
}

function Sync-OpenPathRestrictedGroup {
    <#
    .SYNOPSIS
    Ensures the OpenPath-Restricted local group contains every enabled non-administrator local user.
    .DESCRIPTION
    Idempotent membership reconciliation. It adds enabled non-administrators and
    removes administrators that were previously added to the restricted group. With
    -CreateIfMissing the group is created when absent. Without it a missing group is
    a no-op; callers that require the restricted-group model should opt into creation
    explicitly.
    Returns $true when the group is present after the call.
    #>
    [CmdletBinding()]
    param(
        [bool]$CreateIfMissing = $false,
        [string]$DiagnosticStatusPath = ''
    )

    if (-not (Get-Command -Name Get-LocalGroup -ErrorAction SilentlyContinue)) {
        Write-OpenPathAppControlDiagnosticFile -Path $DiagnosticStatusPath -Diagnostic (
            New-OpenPathAppControlPreconditionDiagnostic -Substep 'restricted-group-capability' -ReasonCode 'appcontrol_restricted_group_capability_unavailable')
        Write-OpenPathLog 'OpenPath-Restricted group sync unavailable; refusing to widen AppLocker scope to BUILTIN\Users' -Level WARN
        return $false
    }

    $group = $null
    try {
        $group = Get-LocalGroup -Name 'OpenPath-Restricted' -ErrorAction Stop
    }
    catch {
        if ($CreateIfMissing -and (Get-Command -Name New-LocalGroup -ErrorAction SilentlyContinue)) {
            try {
                $group = New-LocalGroup -Name 'OpenPath-Restricted' -Description 'Users restricted by OpenPath app control' -ErrorAction Stop
                Write-OpenPathLog 'Created local group OpenPath-Restricted'
            }
            catch {
                Write-OpenPathAppControlDiagnosticFile -Path $DiagnosticStatusPath -Diagnostic (
                    New-OpenPathAppControlPreconditionDiagnostic -Substep 'restricted-group-create' -ReasonCode 'appcontrol_restricted_group_create_failed')
                Write-OpenPathLog "Failed to create OpenPath-Restricted group: $_" -Level WARN
                return $false
            }
        }
        else {
            Write-OpenPathLog 'OpenPath-Restricted group absent; membership sync skipped without widening policy scope' -Level WARN
            return $false
        }
    }

    $adminGroupName = $null
    try {
        if (Get-Command Get-LocalGroup -ErrorAction SilentlyContinue) {
            $adminGroupObj = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue
            if ($adminGroupObj) {
                $adminGroupName = $adminGroupObj.Name
            }
        }
    }
    catch {}
    if (-not $adminGroupName) {
        $adminGroupName = 'Administrators'
    }

    $adminMembers = $null
    try {
        $adminMembers = @(Get-LocalGroupMember -Group $adminGroupName -ErrorAction Stop | ForEach-Object { [string]$_.SID.Value })
    }
    catch {
        Write-OpenPathAppControlDiagnosticFile -Path $DiagnosticStatusPath -Diagnostic (
            New-OpenPathAppControlPreconditionDiagnostic -Substep 'administrator-inventory' -ReasonCode 'appcontrol_administrator_inventory_failed')
        Write-OpenPathLog "Unable to reconcile OpenPath-Restricted because Administrators membership could not be enumerated: $_" -Level WARN
        return $false
    }
    if ($null -eq $adminMembers) {
        Write-OpenPathLog "Unable to reconcile OpenPath-Restricted because Administrators membership could not be enumerated" -Level WARN
        return $false
    }

    $existingMemberObjects = @()
    $existingMembers = @()
    try {
        $existingMemberObjects = @(Get-LocalGroupMember -Group 'OpenPath-Restricted' -ErrorAction Stop)
        $existingMembers = @($existingMemberObjects | ForEach-Object { [string]$_.SID.Value })
    }
    catch {
        Write-OpenPathAppControlDiagnosticFile -Path $DiagnosticStatusPath -Diagnostic (
            New-OpenPathAppControlPreconditionDiagnostic -Substep 'restricted-group-inventory' -ReasonCode 'appcontrol_restricted_group_inventory_failed')
        Write-OpenPathLog "Failed to enumerate OpenPath-Restricted members: $_" -Level WARN
        return $false
    }

    try {
        foreach ($adminSid in @($existingMembers | Where-Object { $_ -in $adminMembers })) {
            Remove-LocalGroupMember -Group 'OpenPath-Restricted' -Member $adminSid -ErrorAction Stop
            $existingMembers = @($existingMembers | Where-Object { $_ -ne $adminSid })
            Write-OpenPathLog "Removed administrator SID $adminSid from OpenPath-Restricted" -Level WARN
        }
        $added = 0
        $allUsers = @(Get-LocalUser -ErrorAction Stop)
        foreach ($user in $allUsers) {
            if (-not $user.PSObject.Properties['Enabled'] -or -not $user.Enabled) { continue }
            if (-not $user.PSObject.Properties['SID']) { continue }
            $sid = [string]$user.SID.Value
            if ($sid -in $adminMembers) { continue }
            if ($sid -in $existingMembers) { continue }
            Add-LocalGroupMember -Group 'OpenPath-Restricted' -Member $user.Name -ErrorAction Stop
            $added++
        }
        if ($added -gt 0) {
            Write-OpenPathLog "OpenPath-Restricted membership synced: added $added non-admin user(s)"
        }

        # Verify postcondition: ensure every enabled non-admin user is actually in OpenPath-Restricted
        $finalMembers = @(Get-LocalGroupMember -Group 'OpenPath-Restricted' -ErrorAction Stop | ForEach-Object { [string]$_.SID.Value })
        $restrictedAdministrators = @($finalMembers | Where-Object { $_ -in $adminMembers })
        if ($restrictedAdministrators.Count -gt 0) {
            Write-OpenPathLog 'Failed to sync OpenPath-Restricted membership: administrator remains in restricted group' -Level WARN
            return $false
        }
        $missingMembers = @()
        foreach ($user in $allUsers) {
            if (-not $user.PSObject.Properties['Enabled'] -or -not $user.Enabled) { continue }
            if (-not $user.PSObject.Properties['SID']) { continue }
            $sid = [string]$user.SID.Value
            if ($sid -in $adminMembers) { continue }
            if ($sid -notin $finalMembers) {
                $missingMembers += $user.Name
            }
        }

        if ($missingMembers.Count -gt 0) {
            Write-OpenPathLog "Failed to sync OpenPath-Restricted membership: users remain outside group: $($missingMembers -join ', ')" -Level WARN
            return $false
        }

        return $true
    }
    catch {
        Write-OpenPathAppControlDiagnosticFile -Path $DiagnosticStatusPath -Diagnostic (
            New-OpenPathAppControlPreconditionDiagnostic -Substep 'restricted-user-inventory' -ReasonCode 'appcontrol_restricted_user_inventory_failed')
        Write-OpenPathLog "Failed to sync OpenPath-Restricted membership: $_" -Level WARN
        return $false
    }
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

function Test-OpenPathApplicationApprovalCatalog {
    <#
    .SYNOPSIS
    Validates the versioned operator-managed application approval catalog.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('ManagedBrowserCompatibility', 'StrictApplicationAllowlist')]
        [string]$Profile = 'ManagedBrowserCompatibility',

        [AllowNull()]
        [object]$Catalog = $null
    )

    if ($Profile -eq 'ManagedBrowserCompatibility') {
        return $true
    }

    try {
        if (-not $Catalog -or -not $Catalog.PSObject.Properties['schemaVersion'] -or
            [int]$Catalog.schemaVersion -ne 1 -or -not $Catalog.PSObject.Properties['applications']) {
            return $false
        }

        $applicationsValue = $Catalog.PSObject.Properties['applications'].Value
        if ($null -eq $applicationsValue -or $applicationsValue -isnot [System.Array]) {
            return $false
        }

        $ids = @{}
        $knownExtensions = @('.exe', '.com', '.dll', '.ps1', '.bat', '.cmd', '.vbs', '.js', '.wsf', '.msi', '.msp', '.mst')
        foreach ($application in @($applicationsValue)) {
            if (-not $application -or -not $application.PSObject.Properties['id'] -or
                [string]::IsNullOrWhiteSpace([string]$application.id) -or
                [string]$application.id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or
                $ids.ContainsKey([string]$application.id) -or
                -not $application.PSObject.Properties['identity'] -or -not $application.identity) {
                return $false
            }
            $ids[[string]$application.id] = $true
            $identity = $application.identity
            $type = if ($identity.PSObject.Properties['type']) { [string]$identity.type } else { '' }
            switch ($type) {
                { $_ -in @('Publisher', 'AppxPublisher') } {
                    foreach ($property in @('publisherName', 'productName')) {
                        if (-not $identity.PSObject.Properties[$property] -or
                            [string]::IsNullOrWhiteSpace([string]$identity.$property) -or
                            [string]$identity.$property -match '[*?]' -or
                            [string]$identity.$property -match '[\\/\x00-\x1F]') {
                            return $false
                        }
                    }
                    $binaryWildcardAllowed = $type -eq 'AppxPublisher' -and [string]$identity.binaryName -eq '*'
                    if (-not $identity.PSObject.Properties['binaryName'] -or
                        [string]::IsNullOrWhiteSpace([string]$identity.binaryName) -or
                        ([string]$identity.binaryName -match '[*?]' -and -not $binaryWildcardAllowed) -or
                        [string]$identity.binaryName -match '[\\/:<>|\x00-\x1F]') {
                        return $false
                    }
                    if ($type -eq 'Publisher' -and $knownExtensions -notcontains ([IO.Path]::GetExtension([string]$identity.binaryName).ToLowerInvariant())) {
                        return $false
                    }
                }
                'Path' {
                    $path = if ($identity.PSObject.Properties['path']) { ([string]$identity.path).Trim() } else { '' }
                    $pathPattern = '^(?i)(?:[A-Z]:\\Program Files(?: \(x86\))?|%PROGRAMFILES%)\\[^*?\\/:<>|]+(?:\\[^*?\\/:<>|]+)*$'
                    if ($path -notmatch $pathPattern -or $path -match '(?i)\\Users\\|AppData|\.\.' -or
                        $knownExtensions -notcontains ([IO.Path]::GetExtension($path).ToLowerInvariant())) {
                        return $false
                    }
                }
                'Hash' {
                    $hash = if ($identity.PSObject.Properties['sha256']) { [string]$identity.sha256 } else { '' }
                    $fileName = if ($identity.PSObject.Properties['fileName']) { ([string]$identity.fileName).Trim() } else { '' }
                    if ($hash -notmatch '^[0-9a-fA-F]{64}$' -or
                        $fileName -notmatch '^[^\\/:*?"<>|\x00-\x1F]+$' -or
                        $knownExtensions -notcontains ([IO.Path]::GetExtension($fileName).ToLowerInvariant())) {
                        return $false
                    }
                }
                default { return $false }
            }
        }
        return $true
    }
    catch {
        return $false
    }
}

function Get-OpenPathApplicationCatalogCollection {
    <#
    .SYNOPSIS
    Maps a validated catalog identity to the AppLocker collection it can affect.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$Identity
    )

    $type = if ($Identity.PSObject.Properties['type']) { [string]$Identity.type } else { '' }
    if ($type -eq 'AppxPublisher') {
        return 'Appx'
    }

    $fileName = switch ($type) {
        'Publisher' { [string]$Identity.binaryName }
        'Path' { [string]$Identity.path }
        'Hash' { [string]$Identity.fileName }
        default { '' }
    }
    $extension = [IO.Path]::GetExtension($fileName).ToLowerInvariant()
    switch ($extension) {
        { $_ -in @('.exe', '.com') } { return 'Exe' }
        { $_ -in @('.ps1', '.bat', '.cmd', '.vbs', '.js', '.wsf') } { return 'Script' }
        { $_ -in @('.msi', '.msp', '.mst') } { return 'Msi' }
        '.dll' { return 'Dll' }
        default { return '' }
    }
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

        [string[]]$ApprovedBrowsers = @('Firefox'),

        [ValidateSet('ManagedBrowserCompatibility', 'StrictApplicationAllowlist')]
        [string]$Profile = 'ManagedBrowserCompatibility',

        [AllowNull()]
        [object]$ApplicationCatalog = $null,

        [AllowNull()]
        [object]$BrowserInventory = $null
    )

    $openPathRuntimePath = "$($OpenPathRoot.TrimEnd('\'))\*"
    $approvedBrowserSet = Get-OpenPathApprovedBrowserSet -ApprovedBrowsers $ApprovedBrowsers
    if (-not (Test-OpenPathApplicationApprovalCatalog -Profile $Profile -Catalog $ApplicationCatalog)) {
        throw 'strict-catalog-invalid'
    }

    $firefoxPaths = @(
        '%PROGRAMFILES%\Mozilla Firefox\firefox.exe',
        '%PROGRAMFILES%\Mozilla Firefox\firefox.exe',
        'C:\Program Files\Mozilla Firefox\firefox.exe',
        'C:\Program Files (x86)\Mozilla Firefox\firefox.exe'
    )
    $firefoxUserWritablePaths = @(
        '%OSDRIVE%\Users\*\AppData\Local\Mozilla Firefox\firefox.exe'
    )
    $edgePaths = @(
        '%PROGRAMFILES%\Microsoft\Edge\Application\msedge.exe',
        '%PROGRAMFILES%\Microsoft\Edge\Application\msedge.exe',
        'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
        'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
    )
    $edgeUserWritablePaths = @(
        '%OSDRIVE%\Users\*\AppData\Local\Microsoft\Edge\Application\msedge.exe'
    )
    $chromePaths = @(
        '%PROGRAMFILES%\Google\Chrome\Application\chrome.exe',
        '%PROGRAMFILES%\Google\Chrome\Application\chrome.exe',
        'C:\Program Files\Google\Chrome\Application\chrome.exe',
        'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe'
    )
    $chromeUserWritablePaths = @(
        '%OSDRIVE%\Users\*\AppData\Local\Google\Chrome\Application\chrome.exe'
    )
    $alwaysDeniedBrowserPaths = @(
        '%PROGRAMFILES%\BraveSoftware\Brave-Browser\Application\brave.exe',
        '%PROGRAMFILES%\BraveSoftware\Brave-Browser\Application\brave.exe',
        'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe',
        'C:\Program Files (x86)\BraveSoftware\Brave-Browser\Application\brave.exe',
        '%OSDRIVE%\Users\*\AppData\Local\BraveSoftware\Brave-Browser\Application\brave.exe',
        '%PROGRAMFILES%\Opera\launcher.exe',
        '%PROGRAMFILES%\Opera\launcher.exe',
        'C:\Program Files\Opera\launcher.exe',
        'C:\Program Files (x86)\Opera\launcher.exe',
        '%OSDRIVE%\Users\*\AppData\Local\Programs\Opera\launcher.exe',
        '%PROGRAMFILES%\Opera\opera.exe',
        '%PROGRAMFILES%\Opera\opera.exe',
        'C:\Program Files\Opera\opera.exe',
        'C:\Program Files (x86)\Opera\opera.exe',
        '%OSDRIVE%\Users\*\AppData\Local\Programs\Opera\opera.exe',
        '%PROGRAMFILES%\Opera GX\launcher.exe',
        '%PROGRAMFILES%\Opera GX\launcher.exe',
        'C:\Program Files\Opera GX\launcher.exe',
        'C:\Program Files (x86)\Opera GX\launcher.exe',
        '%OSDRIVE%\Users\*\AppData\Local\Programs\Opera GX\launcher.exe',
        '%PROGRAMFILES%\Vivaldi\Application\vivaldi.exe',
        '%PROGRAMFILES%\Vivaldi\Application\vivaldi.exe',
        'C:\Program Files\Vivaldi\Application\vivaldi.exe',
        'C:\Program Files (x86)\Vivaldi\Application\vivaldi.exe',
        '%OSDRIVE%\Users\*\AppData\Local\Vivaldi\Application\vivaldi.exe',
        '%PROGRAMFILES%\Tor Browser\Browser\firefox.exe',
        '%PROGRAMFILES%\Tor Browser\Browser\firefox.exe',
        'C:\Program Files\Tor Browser\Browser\firefox.exe',
        'C:\Program Files (x86)\Tor Browser\Browser\firefox.exe',
        '%PROGRAMFILES%\Chromium\Application\chrome.exe',
        '%PROGRAMFILES%\Chromium\Application\chrome.exe',
        'C:\Program Files\Chromium\Application\chrome.exe',
        'C:\Program Files (x86)\Chromium\Application\chrome.exe',
        '%OSDRIVE%\Users\*\AppData\Local\Chromium\Application\chrome.exe',
        '%PROGRAMFILES%\Chromium\Application\chromium.exe',
        '%PROGRAMFILES%\Chromium\Application\chromium.exe',
        'C:\Program Files\Chromium\Application\chromium.exe',
        'C:\Program Files (x86)\Chromium\Application\chromium.exe',
        '%OSDRIVE%\Users\*\AppData\Local\Chromium\Application\chromium.exe',
        '%PROGRAMFILES%\Ungoogled Chromium\Application\chrome.exe',
        '%PROGRAMFILES%\Ungoogled Chromium\Application\chrome.exe',
        'C:\Program Files\Ungoogled Chromium\Application\chrome.exe',
        'C:\Program Files (x86)\Ungoogled Chromium\Application\chrome.exe',
        '%OSDRIVE%\Users\*\AppData\Local\Ungoogled Chromium\Application\chrome.exe',
        '%PROGRAMFILES%\Ungoogled Chromium\Application\chromium.exe',
        '%PROGRAMFILES%\Ungoogled Chromium\Application\chromium.exe',
        'C:\Program Files\Ungoogled Chromium\Application\chromium.exe',
        'C:\Program Files (x86)\Ungoogled Chromium\Application\chromium.exe',
        '%OSDRIVE%\Users\*\AppData\Local\Ungoogled Chromium\Application\chromium.exe',
        '%PROGRAMFILES%\Floorp\floorp.exe',
        '%PROGRAMFILES%\Floorp\floorp.exe',
        'C:\Program Files\Floorp\floorp.exe',
        'C:\Program Files (x86)\Floorp\floorp.exe',
        '%OSDRIVE%\Users\*\AppData\Local\Floorp\floorp.exe',
        '%PROGRAMFILES%\Internet Explorer\iexplore.exe',
        '%PROGRAMFILES%\Internet Explorer\iexplore.exe',
        'C:\Program Files\Internet Explorer\iexplore.exe',
        'C:\Program Files (x86)\Internet Explorer\iexplore.exe'
    )
    $windowsAppsPaths = @(
        '%PROGRAMFILES%\WindowsApps\Microsoft.*\*',
        '%PROGRAMFILES%\WindowsApps\MicrosoftWindows.*\*',
        'C:\Program Files\WindowsApps\Microsoft.*\*',
        'C:\Program Files\WindowsApps\MicrosoftWindows.*\*'
    )

    $allowPaths = @('%WINDIR%\*', $openPathRuntimePath)
    if ($Profile -eq 'ManagedBrowserCompatibility') {
        $allowPaths += '%PROGRAMFILES%\*'
        $allowPaths += $windowsAppsPaths
        if ($approvedBrowserSet.Firefox) { $allowPaths += $firefoxPaths }
        if ($approvedBrowserSet.Edge) { $allowPaths += $edgePaths }
        if ($approvedBrowserSet.Chrome) { $allowPaths += $chromePaths }
    }
    $allowPaths = @($allowPaths | ForEach-Object {
            ([string]$_).Replace('%PROGRAMFILES%', '%PROGRAMFILES%').Replace('%OSDRIVE%\Users\*\AppData\Local', '%OSDRIVE%\Users\*\AppData\Local')
        } | Sort-Object -Unique)

    # Keep collection-specific baselines separate.  A path that is safe for an
    # executable is not automatically safe for scripts, installers, or DLLs.
    # Compatibility retains the historical broad executable/script contract;
    # strict mode only gives restricted users the protected OpenPath runtime
    # script root and catalog entries in their matching collection.
    $allowPathsByCollection = @{
        Exe = @('%WINDIR%\*', $openPathRuntimePath)
        Script = @($openPathRuntimePath)
        Msi = @()
        # OpenPath ships native dependencies alongside its protected runtime.
        # Keep that allowance scoped to the exact install root; never widen DLL
        # approval to all of Program Files.
        # Enabling DLL enforcement must still permit the administrator-owned
        # Windows runtime that every approved process loads.  The student
        # cannot write this root; executable/script escape surfaces remain
        # governed by their own collections and explicit denies.
        Dll = @('%WINDIR%\*', $openPathRuntimePath)
        Appx = @()
    }
    if ($Profile -eq 'ManagedBrowserCompatibility') {
        $allowPathsByCollection.Exe = @($allowPaths)
        $allowPathsByCollection.Script = @($allowPaths)
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
    if ($null -eq $BrowserInventory) {
        $BrowserInventory = Get-OpenPathBrowserInventory
    }
    if ($Profile -eq 'StrictApplicationAllowlist') {
        foreach ($identity in @($BrowserInventory.ExecutableIdentities)) {
            if (-not $identity -or -not $identity.ExecutablePath -or -not $identity.IsApproved) { continue }
            if ($approvedBrowserSet.ContainsKey([string]$identity.Family)) {
                $allowPaths += [string]$identity.ExecutablePath
                $allowPathsByCollection.Exe += [string]$identity.ExecutablePath
                # An approved browser is a process plus its administrator-owned
                # native DLL directory.  Keep the DLL allowance scoped to the
                # exact discovered installation root; never widen it to all of
                # Program Files.
                # Avoid provider normalization here: inventory paths are
                # Windows AppLocker paths even when the policy is unit-tested
                # under PowerShell Core on a non-Windows host.
                $browserDirectory = ([string]$identity.ExecutablePath) -replace '[\\/][^\\/]+$', ''
                if ($browserDirectory) {
                    $allowPathsByCollection.Dll += "$($browserDirectory -replace '[\\/]+$', '')\*"
                }
            }
        }
    }
    foreach ($identity in @($BrowserInventory.ExecutableIdentities)) {
        if (-not $identity -or -not $identity.ExecutablePath) { continue }
        $familyApproved = $approvedBrowserSet.ContainsKey([string]$identity.Family)
        if (-not $familyApproved) {
            $denyPath = [string]$identity.ExecutablePath
            $denyPath = $denyPath -replace '\\\d+(?:\.\d+)+\\([^\\]+\.exe)$', '\*\$1'
            $unapprovedBrowserDenyPaths += $denyPath
        }
    }
    $unapprovedBrowserDenyPaths = @($unapprovedBrowserDenyPaths |
        ForEach-Object {
            ([string]$_).Replace('%PROGRAMFILES%', '%PROGRAMFILES%').Replace('%OSDRIVE%\Users\*\AppData\Local', '%OSDRIVE%\Users\*\AppData\Local')
        } | Sort-Object -Unique)
    $unapprovedBrowserDenyAppxProducts = @()
    if (-not $approvedBrowserSet.Edge) {
        $unapprovedBrowserDenyAppxProducts = @(Get-OpenPathEdgeAppxProductNames)
    }

    $approvedApplicationPublishers = @()
    $approvedApplicationHashes = @()
    $approvedApplicationPublishersByCollection = @{
        Exe = @(); Script = @(); Msi = @(); Dll = @(); Appx = @()
    }
    $approvedApplicationHashesByCollection = @{
        Exe = @(); Script = @(); Msi = @(); Dll = @(); Appx = @()
    }
    if ($Profile -eq 'StrictApplicationAllowlist') {
        foreach ($application in @($ApplicationCatalog.applications)) {
            $collection = Get-OpenPathApplicationCatalogCollection -Identity $application.identity
            if (-not $collection) {
                throw 'strict-catalog-invalid'
            }
            switch ([string]$application.identity.type) {
                'Path' {
                    $allowPaths += [string]$application.identity.path
                    $allowPathsByCollection[$collection] += [string]$application.identity.path
                }
                'Publisher' {
                    $publisher = [pscustomobject]@{
                        Id = [string]$application.id
                        PublisherName = [string]$application.identity.publisherName
                        ProductName = [string]$application.identity.productName
                        BinaryName = [string]$application.identity.binaryName
                    }
                    $approvedApplicationPublishers += $publisher
                    $approvedApplicationPublishersByCollection[$collection] += $publisher
                }
                'AppxPublisher' {
                    $publisher = [pscustomobject]@{
                        Id = [string]$application.id
                        PublisherName = [string]$application.identity.publisherName
                        ProductName = [string]$application.identity.productName
                        BinaryName = [string]$application.identity.binaryName
                    }
                    $approvedApplicationPublishersByCollection.Appx += $publisher
                }
                'Hash' {
                    $hash = [pscustomobject]@{
                        Id = [string]$application.id
                        Sha256 = ([string]$application.identity.sha256).ToUpperInvariant()
                        FileName = [string]$application.identity.fileName
                    }
                    $approvedApplicationHashes += $hash
                    $approvedApplicationHashesByCollection[$collection] += $hash
                }
            }
        }
        $allowPaths = @($allowPaths | Sort-Object -Unique)
        foreach ($collection in @('Exe', 'Script', 'Msi', 'Dll', 'Appx')) {
            $allowPathsByCollection[$collection] = @($allowPathsByCollection[$collection] | Sort-Object -Unique)
            $approvedApplicationPublishersByCollection[$collection] = @($approvedApplicationPublishersByCollection[$collection])
            $approvedApplicationHashesByCollection[$collection] = @($approvedApplicationHashesByCollection[$collection])
        }
    }

    $approvedAppxBrowserProducts = if ($Profile -eq 'StrictApplicationAllowlist' -and $approvedBrowserSet.Edge) {
        @(Get-OpenPathEdgeAppxProductNames)
    }
    else {
        @()
    }

    return [PSCustomObject]@{
        Profile = $Profile
        Mode = $Mode
        EnforcementMode = if ($Mode -eq 'AuditOnly') { 'AuditOnly' } else { 'Enabled' }
        EnforcedCollections = if ($Profile -eq 'StrictApplicationAllowlist') { @('Exe', 'Script', 'Msi', 'Appx', 'Dll') } else { @('Exe', 'Script', 'Appx') }
        RestrictedSid = Get-OpenPathRestrictedGroupSid
        AdminSid = 'S-1-5-32-544'
        SystemSid = 'S-1-5-18'
        ApprovedBrowsers = @($approvedBrowserSet.Keys | Sort-Object)
        AllowPaths = @($allowPaths)
        AllowPathsByCollection = $allowPathsByCollection
        ApprovedApplicationPublishers = @($approvedApplicationPublishers)
        ApprovedApplicationHashes = @($approvedApplicationHashes)
        ApprovedApplicationPublishersByCollection = $approvedApplicationPublishersByCollection
        ApprovedApplicationHashesByCollection = $approvedApplicationHashesByCollection
        ApprovedAppxBrowserProducts = @($approvedAppxBrowserProducts)
        BrowserInventory = $BrowserInventory
        UnapprovedBrowserDenyPaths = @($unapprovedBrowserDenyPaths)
        UnapprovedBrowserDenyAppxProducts = @($unapprovedBrowserDenyAppxProducts)
        AlwaysDeniedAppxProducts = @(Get-OpenPathAlwaysDeniedAppxProductNames)
        BlockedWindowsTools = @(@(
            '%WINDIR%\System32\curl.exe',
            '%WINDIR%\SysWOW64\curl.exe',
            '%WINDIR%\System32\nslookup.exe',
            '%WINDIR%\SysWOW64\nslookup.exe',
            '%WINDIR%\System32\ssh.exe',
            '%WINDIR%\SysWOW64\ssh.exe',
            '%OSDRIVE%\Users\*\AppData\Local\Microsoft\WindowsApps\winget.exe',
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
            '%PROGRAMFILES%\PowerShell\7\pwsh.exe',
            '%WINDIR%\System32\ftp.exe',
            '%WINDIR%\SysWOW64\ftp.exe',
            '%WINDIR%\System32\tftp.exe',
            '%WINDIR%\SysWOW64\tftp.exe'
        ) | ForEach-Object { ([string]$_).Replace('%PROGRAMFILES%', '%PROGRAMFILES%').Replace('%OSDRIVE%\Users\*\AppData\Local', '%OSDRIVE%\Users\*\AppData\Local') } | Sort-Object -Unique)
        UserWritableDenyPaths = @(
            '%OSDRIVE%\Users\*\Downloads\*',
            '%OSDRIVE%\Users\*\Desktop\*',
            '%OSDRIVE%\Users\*\AppData\Local\Temp\*',
            # Windows Temp is writable by standard users on supported images;
            # keep the broad system-root baseline from turning it into an
            # execution escape hatch.
            '%WINDIR%\Temp\*',
            '%REMOVABLE%\*',
            '%HOT%\*'
        )
        BrowserInventoryStatus = if ($BrowserInventory.PSObject.Properties['DiscoveryStatus']) { [string]$BrowserInventory.DiscoveryStatus } else { 'Degraded' }
        BrowserInventoryErrors = if ($BrowserInventory.PSObject.Properties['DiscoveryErrors']) { @($BrowserInventory.DiscoveryErrors) } else { @('browser inventory diagnostics unavailable') }
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

function New-OpenPathFileHashRuleXml {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Sid,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    $id = [guid]::NewGuid().ToString()
    $escapedName = ConvertTo-OpenPathXmlAttribute -Value $Name
    $escapedSid = ConvertTo-OpenPathXmlAttribute -Value $Sid
    $escapedAction = ConvertTo-OpenPathXmlAttribute -Value $Action
    $escapedFileName = ConvertTo-OpenPathXmlAttribute -Value $FileName
    $hashData = '0x' + $Sha256.ToUpperInvariant()
    return "      <FileHashRule Id=`"$id`" Name=`"$escapedName`" Description=`"Managed by OpenPath`" UserOrGroupSid=`"$escapedSid`" Action=`"$escapedAction`">`n        <Conditions>`n          <FileHashCondition>`n            <FileHash Type=`"SHA256`" Data=`"$hashData`" SourceFileName=`"$escapedFileName`" SourceFileLength=`"0`" />`n          </FileHashCondition>`n        </Conditions>`n      </FileHashRule>"
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
    $strictProfile = $Spec.PSObject.Properties['Profile'] -and $Spec.Profile -eq 'StrictApplicationAllowlist'
    $fileCollectionTypes = if ($strictProfile) { @('Exe', 'Script', 'Msi', 'Dll') } else { @('Exe', 'Script') }
    foreach ($collectionType in $fileCollectionTypes) {
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
            $rules += New-OpenPathFilePathRuleXml -CollectionType $collectionType -Name "$script:OpenPathAppControlRulePrefix $collectionType users deny $pathId" -Sid $Spec.RestrictedSid -Action 'Deny' -Path $path
        }

        $rules += New-OpenPathFilePathRuleXml -CollectionType $collectionType -Name "$script:OpenPathAppControlRulePrefix $collectionType administrators allow all" -Sid $Spec.AdminSid -Action 'Allow' -Path '*'
        $rules += New-OpenPathFilePathRuleXml -CollectionType $collectionType -Name "$script:OpenPathAppControlRulePrefix $collectionType system allow all" -Sid $Spec.SystemSid -Action 'Allow' -Path '*'

        $collectionAllowPaths = @($Spec.AllowPaths)
        if ($Spec.PSObject.Properties['AllowPathsByCollection'] -and $Spec.AllowPathsByCollection.ContainsKey($collectionType)) {
            $collectionAllowPaths = @($Spec.AllowPathsByCollection[$collectionType])
        }
        foreach ($path in $collectionAllowPaths) {
            $exceptions = @()
            if ($collectionType -eq 'Exe' -and $path -eq '%WINDIR%\*') {
                $exceptions = @($Spec.BlockedWindowsTools)
            }

            $pathId = ($path -replace '[^0-9A-Za-z]+', '-').Trim('-')
            $rules += New-OpenPathFilePathRuleXml -CollectionType $collectionType -Name "$script:OpenPathAppControlRulePrefix $collectionType users allow $pathId" -Sid $Spec.RestrictedSid -Action 'Allow' -Path $path -Exceptions $exceptions
        }

        if ($Spec.PSObject.Properties['ApprovedApplicationPublishersByCollection'] -and $Spec.ApprovedApplicationPublishersByCollection.ContainsKey($collectionType)) {
            foreach ($publisher in @($Spec.ApprovedApplicationPublishersByCollection[$collectionType])) {
                $rules += New-OpenPathFilePublisherRuleXml -Name "$script:OpenPathAppControlRulePrefix $collectionType users allow approved app $($publisher.Id)" `
                    -Sid $Spec.RestrictedSid -Action 'Allow' -PublisherName $publisher.PublisherName `
                    -ProductName $publisher.ProductName -BinaryName $publisher.BinaryName
            }
        }
        if ($Spec.PSObject.Properties['ApprovedApplicationHashesByCollection'] -and $Spec.ApprovedApplicationHashesByCollection.ContainsKey($collectionType)) {
            foreach ($hash in @($Spec.ApprovedApplicationHashesByCollection[$collectionType])) {
                $rules += New-OpenPathFileHashRuleXml -Name "$script:OpenPathAppControlRulePrefix $collectionType users allow approved app $($hash.Id)" `
                    -Sid $Spec.RestrictedSid -Action 'Allow' -Sha256 $hash.Sha256 -FileName $hash.FileName
            }
        }

        $ruleCollections += "    <RuleCollection Type=`"$collectionType`" EnforcementMode=`"$($Spec.EnforcementMode)`">`n$($rules -join "`n")`n    </RuleCollection>"
    }

    $appxRules = @()
    foreach ($productName in @($Spec.UnapprovedBrowserDenyAppxProducts)) {
        $productId = ($productName -replace '[^0-9A-Za-z]+', '-').Trim('-')
        $appxRules += New-OpenPathFilePublisherRuleXml -Name "$script:OpenPathAppControlRulePrefix Appx users deny $productId" -Sid $Spec.RestrictedSid -Action 'Deny' -PublisherName '*' -ProductName $productName -BinaryName '*'
    }
    # W-2: deny the parallel-network-stack Microsoft Appx packages (WSL, Windows
    # Terminal, OpenSSH/Telnet) ahead of the Microsoft-signed allow. AppLocker
    # evaluates Deny over Allow, so these stay blocked even though the broad
    # Microsoft-signed allow below keeps the rest of the inbox/Store surface usable.
    foreach ($productName in @($Spec.AlwaysDeniedAppxProducts)) {
        $productId = ($productName -replace '[^0-9A-Za-z]+', '-').Trim('-')
        $appxRules += New-OpenPathFilePublisherRuleXml -Name "$script:OpenPathAppControlRulePrefix Appx users deny parallel network stack $productId" -Sid $Spec.RestrictedSid -Action 'Deny' -PublisherName '*' -ProductName $productName -BinaryName '*'
    }
    if ($strictProfile) {
        # Appx has no useful path rule. Keep recovery scoped to administrators
        # and SYSTEM, while restricted users receive only catalog publishers.
        $appxRules += New-OpenPathFilePublisherRuleXml -Name "$script:OpenPathAppControlRulePrefix Appx administrators allow all" -Sid $Spec.AdminSid -Action 'Allow' -PublisherName '*' -ProductName '*' -BinaryName '*'
        $appxRules += New-OpenPathFilePublisherRuleXml -Name "$script:OpenPathAppControlRulePrefix Appx system allow all" -Sid $Spec.SystemSid -Action 'Allow' -PublisherName '*' -ProductName '*' -BinaryName '*'
        foreach ($productName in @($Spec.ApprovedAppxBrowserProducts)) {
            $productId = ($productName -replace '[^0-9A-Za-z]+', '-').Trim('-')
            $appxRules += New-OpenPathFilePublisherRuleXml -Name "$script:OpenPathAppControlRulePrefix Appx users allow approved Edge $productId" -Sid $Spec.RestrictedSid -Action 'Allow' -PublisherName 'O=MICROSOFT CORPORATION*' -ProductName $productName -BinaryName '*'
        }
        if ($Spec.PSObject.Properties['ApprovedApplicationPublishersByCollection'] -and $Spec.ApprovedApplicationPublishersByCollection.ContainsKey('Appx')) {
            foreach ($publisher in @($Spec.ApprovedApplicationPublishersByCollection.Appx)) {
                $appxRules += New-OpenPathFilePublisherRuleXml -Name "$script:OpenPathAppControlRulePrefix Appx users allow approved app $($publisher.Id)" -Sid $Spec.RestrictedSid -Action 'Allow' -PublisherName $publisher.PublisherName -ProductName $publisher.ProductName -BinaryName $publisher.BinaryName
            }
        }
    }
    # Allow only Microsoft-signed packaged apps (OS inbox and Store-distributed Microsoft apps).
    # A global ProductName='*' allow lets any publisher's Appx run, including sideloaded alternate
    # browsers with non-Edge ProductNames that would bypass the per-product Edge denies above.
    # Scoping to PublisherName='O=MICROSOFT CORPORATION*' covers all Microsoft-signed packages
    # (Windows inbox, Store-distributed Edge, Teams, etc.) without opening the door to third-party
    # sideloaded packages.  SID S-1-1-0 (Everyone) is kept so the rule applies to all users
    # including non-admins, matching the original intent.
    if (-not $strictProfile) {
        $appxRules += New-OpenPathFilePublisherRuleXml -Name "$script:OpenPathAppControlRulePrefix Appx users allow Microsoft signed packaged apps" -Sid 'S-1-1-0' -Action 'Allow' -PublisherName 'O=MICROSOFT CORPORATION*' -ProductName '*' -BinaryName '*'
    }
    $ruleCollections += "    <RuleCollection Type=`"Appx`" EnforcementMode=`"$($Spec.EnforcementMode)`">`n$($appxRules -join "`n")`n    </RuleCollection>"

    $emptyCollections = if (-not $strictProfile) {
        "    <RuleCollection Type=`"Dll`" EnforcementMode=`"NotConfigured`" />`n    <RuleCollection Type=`"Msi`" EnforcementMode=`"NotConfigured`" />"
    }
    else {
        ''
    }
    return @"
<AppLockerPolicy Version="1">
$($ruleCollections -join "`n")
$emptyCollections
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
        if ($null -eq $sourceCollection) {
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

        foreach ($rule in @($targetCollection.ChildNodes)) {
            if (Test-OpenPathAppLockerRuleManaged -Rule $rule) {
                [void]$targetCollection.RemoveChild($rule)
            }
        }

        if (@($sourceCollection.ChildNodes).Count -eq 0) {
            # An empty managed collection clears stale OpenPath rules.  Preserve
            # an administrator-owned collection's enforcement mode when it still
            # contains unrelated rules; otherwise apply the source mode (for
            # example NotConfigured when leaving strict mode).
            $unmanagedRuleCount = @($targetCollection.ChildNodes | Where-Object {
                    $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and
                    -not (Test-OpenPathAppLockerRuleManaged -Rule $_)
                }).Count
            if ($unmanagedRuleCount -eq 0 -and $sourceCollection.HasAttribute('EnforcementMode')) {
                $targetCollection.SetAttribute('EnforcementMode', $sourceCollection.GetAttribute('EnforcementMode'))
            }
            continue
        }
        if ($sourceCollection.HasAttribute('EnforcementMode')) {
            $targetCollection.SetAttribute('EnforcementMode', $sourceCollection.GetAttribute('EnforcementMode'))
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

        [string]$PublisherName = $null,

        [string]$BinaryName = '*'
    )

    if (-not $Collection) {
        return $false
    }

    return [bool](@($Collection.FilePublisherRule | Where-Object {
                $_.GetAttribute('Action') -eq $Action -and
                $_.GetAttribute('UserOrGroupSid') -eq $Sid -and
                $_.Conditions.FilePublisherCondition.GetAttribute('ProductName') -eq $ProductName -and
                $_.Conditions.FilePublisherCondition.GetAttribute('BinaryName') -eq $BinaryName -and
                (-not $PublisherName -or $_.Conditions.FilePublisherCondition.GetAttribute('PublisherName') -eq $PublisherName) -and
                (Test-OpenPathAppLockerRuleManaged -Rule $_)
            }).Count -gt 0)
}

function Test-OpenPathFileHashRulePresent {
    <#
    .SYNOPSIS
    Returns true when a managed SHA-256 file-hash rule is present in a collection.
    #>
    param(
        [AllowNull()]
        [object]$Collection,

        [Parameter(Mandatory = $true)]
        [string]$Action,

        [Parameter(Mandatory = $true)]
        [string]$Sid,

        [Parameter(Mandatory = $true)]
        [string]$Sha256,

        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    if (-not $Collection) {
        return $false
    }

    $expectedData = '0x' + $Sha256.ToUpperInvariant()
    return [bool](@($Collection.FileHashRule | Where-Object {
                $_.GetAttribute('Action') -eq $Action -and
                $_.GetAttribute('UserOrGroupSid') -eq $Sid -and
                $_.Conditions.FileHashCondition.FileHash.GetAttribute('Data') -eq $expectedData -and
                $_.Conditions.FileHashCondition.FileHash.GetAttribute('SourceFileName') -eq $FileName -and
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

function Invoke-OpenPathAppLockerPolicyEvaluation {
    param(
        [Parameter(Mandatory = $true)][string]$PolicyXml,
        [Parameter(Mandatory = $true)][string[]]$Path,
        [Parameter(Mandatory = $true)][string]$UserSid
    )

    $policyPath = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-applocker-evaluation-$([guid]::NewGuid()).xml"
    try {
        Set-Content -LiteralPath $policyPath -Value $PolicyXml -Encoding UTF8 -ErrorAction Stop
        $decisions = [System.Collections.Generic.List[object]]::new()
        foreach ($candidatePath in @($Path)) {
            foreach ($decision in @(Test-AppLockerPolicy -XmlPolicy $policyPath -Path ([string]$candidatePath) -User $UserSid -ErrorAction Stop)) {
                $decisions.Add($decision)
            }
        }
        return @($decisions)
    }
    finally {
        Remove-Item -LiteralPath $policyPath -Force -ErrorAction SilentlyContinue
    }
}

function Set-OpenPathAppIdentityServiceAutomatic {
    <#
    .SYNOPSIS
    Configures protected AppIDSvc for automatic start using the Windows-supported sc.exe path.
    #>
    [CmdletBinding()]
    param()

    $scCommand = Get-Command -Name 'sc.exe' -ErrorAction Stop
    $scOutput = @(& $scCommand.Source config AppIDSvc start= auto 2>&1)
    if ($LASTEXITCODE -ne 0) {
        $boundedOutput = (@($scOutput | ForEach-Object { [string]$_ }) -join ' ').Trim()
        if ($boundedOutput.Length -gt 240) {
            $boundedOutput = $boundedOutput.Substring(0, 240)
        }
        throw "sc.exe could not configure AppIDSvc for automatic start (exit $LASTEXITCODE): $boundedOutput"
    }
}

function Get-OpenPathSidString {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }
    if ($Value.PSObject.Properties['Value']) {
        return [string]$Value.Value
    }
    return [string]$Value
}

function New-OpenPathAppControlTargetException {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [ValidateSet('group-missing', 'group-sid-unresolvable', 'group-empty', 'member-sid-unresolvable', 'member-profile-unavailable', 'target-sid-not-member')]
        [string]$Detail,

        [string]$GroupSid = '',

        [string]$TargetSid = ''
    )

    $exception = [System.InvalidOperationException]::new($Message)
    $exception.Data['OpenPathDetail'] = $Detail
    $exception.Data['OpenPathGroupSid'] = $GroupSid
    $exception.Data['OpenPathTargetSid'] = $TargetSid
    return $exception
}

function Get-OpenPathRestrictedIdentity {
    <#
    .SYNOPSIS
    Resolves a real OpenPath-Restricted group member independently of profile state.

    The AppLocker policy is scoped to the restricted group and Test-AppLockerPolicy
    needs a representative user SID. A Windows profile is deliberately not part of
    this identity contract because installation must work before first login.
    .PARAMETER TargetSid
    Selects one known restricted member when acceptance must be bound to a specific
    profileless identity; an empty value preserves representative-member discovery.
    #>
    [CmdletBinding()]
    param([string]$TargetSid = '')

    foreach ($requiredCommand in @('Get-LocalGroup', 'Get-LocalGroupMember')) {
        if (-not (Get-Command -Name $requiredCommand -ErrorAction SilentlyContinue)) {
            throw "Required AppControl target capability is unavailable: $requiredCommand"
        }
    }

    try {
        $group = Get-LocalGroup -Name 'OpenPath-Restricted' -ErrorAction Stop
    }
    catch {
        throw (New-OpenPathAppControlTargetException -Message 'OpenPath-Restricted group is unavailable for AppControl validation' -Detail 'group-missing')
    }
    $groupSid = Get-OpenPathSidString -Value $group.SID
    if ([string]::IsNullOrWhiteSpace($groupSid)) {
        throw (New-OpenPathAppControlTargetException -Message 'OpenPath-Restricted has no resolvable SID' -Detail 'group-sid-unresolvable')
    }

    $members = @(Get-LocalGroupMember -Group 'OpenPath-Restricted' -ErrorAction Stop)
    if ($members.Count -eq 0) {
        throw (New-OpenPathAppControlTargetException -Message 'OpenPath-Restricted has no members available for AppControl validation' -Detail 'group-empty' -GroupSid $groupSid)
    }

    foreach ($member in $members) {
        $memberSid = Get-OpenPathSidString -Value $member.SID
        if ([string]::IsNullOrWhiteSpace($memberSid)) {
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace($TargetSid) -and $memberSid -ne $TargetSid) {
            continue
        }
        return [PSCustomObject]@{
            GroupSid = $groupSid
            UserSid = $memberSid
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($TargetSid)) {
        throw (New-OpenPathAppControlTargetException -Message 'Requested restricted SID is not a member of OpenPath-Restricted' -Detail 'target-sid-not-member' -GroupSid $groupSid -TargetSid $TargetSid)
    }

    throw (New-OpenPathAppControlTargetException -Message 'OpenPath-Restricted members have no resolvable SID' -Detail 'member-sid-unresolvable' -GroupSid $groupSid)
}

function Get-OpenPathAppControlProfileProbeTarget {
    <#
    .SYNOPSIS
    Resolves the optional materialized, non-special profile for a restricted identity.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Identity
    )

    if (-not (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue)) {
        throw 'Required AppControl profile capability is unavailable: Get-CimInstance'
    }

    $profiles = @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop)
    foreach ($profile in $profiles) {
        $profilePath = [string]$profile.LocalPath
        if ([string]$profile.SID -ne [string]$Identity.UserSid -or [string]::IsNullOrWhiteSpace($profilePath)) {
            continue
        }
        if ($profile.PSObject.Properties['Special'] -and [bool]$profile.Special) {
            return $null
        }
        if (-not [System.IO.Directory]::Exists($profilePath)) {
            return $null
        }

        return [PSCustomObject]@{
            UserSid = [string]$Identity.UserSid
            ProfilePath = $profilePath
        }
    }

    return $null
}

function Get-OpenPathAppControlProbeTarget {
    <#
    .SYNOPSIS
    Combines a required restricted identity with an optional profile-backed probe target.
    #>
    [CmdletBinding()]
    param([string]$TargetSid = '')

    $identity = Get-OpenPathRestrictedIdentity -TargetSid $TargetSid
    $profileTarget = Get-OpenPathAppControlProfileProbeTarget -Identity $identity
    $profileAvailable = ($null -ne $profileTarget)

    return [PSCustomObject]@{
        GroupSid = [string]$identity.GroupSid
        UserSid = [string]$identity.UserSid
        ProfilePath = if ($profileAvailable) { [string]$profileTarget.ProfilePath } else { '' }
        IdentityResolved = $true
        ProfileAvailable = $profileAvailable
        ValidationMode = if ($profileAvailable) { 'profile-backed' } else { 'profileless' }
    }
}

function Get-OpenPathAppControlProbeSourcePath {
    <#
    .SYNOPSIS
    Finds a stable Windows PE that can be copied into a user-writable probe path.
    #>
    [CmdletBinding()]
    param()

    $systemRoots = @()
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $systemRoots += $env:SystemRoot
    }
    try {
        $systemDirectory = [Environment]::SystemDirectory
        if (-not [string]::IsNullOrWhiteSpace($systemDirectory)) {
            $systemRoots += (Split-Path -Path $systemDirectory -Parent)
        }
    }
    catch {
    }

    foreach ($systemRoot in @($systemRoots | Select-Object -Unique)) {
        foreach ($fileName in @('cmd.exe', 'where.exe')) {
            $candidate = Join-Path (Join-Path $systemRoot 'System32') $fileName
            if ([System.IO.File]::Exists($candidate)) {
                return $candidate
            }
        }
    }

    throw 'Unable to locate a stable Windows PE for AppControl validation'
}

function Get-OpenPathAppControlExistingSamplePaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Paths,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $existingPaths = @(
        foreach ($path in @($Paths)) {
            $candidate = [string]$path
            if ([System.IO.File]::Exists($candidate) -and $seenPaths.Add($candidate)) {
                $candidate
            }
        }
    )
    if ($existingPaths.Count -eq 0) {
        throw "Unable to locate an existing $Label executable for AppControl validation"
    }

    return $existingPaths
}

function Remove-OpenPathAppControlEvaluationProbeSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$ProbeSet
    )

    $cleanupSucceeded = $true
    foreach ($probePath in @($ProbeSet.Paths)) {
        if (-not [System.IO.File]::Exists([string]$probePath)) {
            continue
        }
        try {
            [System.IO.File]::Delete([string]$probePath)
        }
        catch {
            $cleanupSucceeded = $false
            Write-OpenPathLog "Failed to remove temporary AppControl probe $probePath`: $_" -Level WARN
        }
    }

    foreach ($directoryPath in @($ProbeSet.CreatedDirectories | Sort-Object Length -Descending)) {
        if (-not [System.IO.Directory]::Exists([string]$directoryPath)) {
            continue
        }
        try {
            if (@([System.IO.Directory]::GetFileSystemEntries([string]$directoryPath)).Count -eq 0) {
                [System.IO.Directory]::Delete([string]$directoryPath)
            }
        }
        catch {
            $cleanupSucceeded = $false
            Write-OpenPathLog "Failed to remove temporary AppControl probe directory $directoryPath`: $_" -Level WARN
        }
    }

    return $cleanupSucceeded
}

function New-OpenPathAppControlEvaluationProbeSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Target,

        [ValidateSet('ManagedBrowserCompatibility', 'StrictApplicationAllowlist')]
        [string]$Profile = 'ManagedBrowserCompatibility',

        [ref]$CleanupSucceeded
    )

    $sourcePath = Get-OpenPathAppControlProbeSourcePath
    if (-not [System.IO.File]::Exists($sourcePath)) {
        throw "AppControl probe source does not exist: $sourcePath"
    }

    $probePaths = [System.Collections.Generic.List[string]]::new()
    $createdDirectories = [System.Collections.Generic.List[string]]::new()
    $probeSet = [PSCustomObject]@{
        Paths = $probePaths
        CreatedDirectories = $createdDirectories
        StrictUnknownPath = ''
    }

    try {
        $probeRoot = if ($Target.ProfileAvailable) {
            [string]$Target.ProfilePath
        }
        else {
            $machineDataRoot = if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) { $env:ProgramData } else { [System.IO.Path]::GetTempPath() }
            Join-Path $machineDataRoot "OpenPath\AppControlValidation\$([guid]::NewGuid().ToString('N'))"
        }
        $relativeDirectories = if ($Target.ProfileAvailable) {
            @('Downloads', 'Desktop', 'AppData\Local\Temp')
        }
        else {
            @('Downloads', 'Desktop', 'LocalAppDataTemp', 'ArbitraryWritable')
        }

        foreach ($relativeDirectory in $relativeDirectories) {
            $directoryPath = Join-Path $probeRoot $relativeDirectory
            $missingDirectories = [System.Collections.Generic.List[string]]::new()
            $currentPath = $directoryPath
            while (-not [System.IO.Directory]::Exists($currentPath)) {
                $parentPath = Split-Path -Path $currentPath -Parent
                if ([string]::IsNullOrWhiteSpace($parentPath) -or $parentPath -eq $currentPath) {
                    throw "Unable to resolve parent directory for AppControl probe: $currentPath"
                }
                $missingDirectories.Add($currentPath)
                $currentPath = $parentPath
            }

            if ($missingDirectories.Count -gt 0) {
                [System.IO.Directory]::CreateDirectory($directoryPath) | Out-Null
                foreach ($missingDirectory in $missingDirectories) {
                    $createdDirectories.Add($missingDirectory)
                }
            }

            $probePath = Join-Path $directoryPath "openpath-appcontrol-probe-$([guid]::NewGuid().ToString('N')).exe"
            [System.IO.File]::Copy($sourcePath, $probePath, $false)
            $probePaths.Add($probePath)
        }

        if ($Profile -eq 'StrictApplicationAllowlist') {
            $programFilesRoot = [string]$env:ProgramFiles
            if ([string]::IsNullOrWhiteSpace($programFilesRoot) -or -not [System.IO.Directory]::Exists($programFilesRoot)) {
                throw 'Program Files is unavailable for strict AppControl validation'
            }
            $strictDirectory = Join-Path $programFilesRoot "OpenPathUnknownProbe-$([guid]::NewGuid().ToString('N'))"
            [System.IO.Directory]::CreateDirectory($strictDirectory) | Out-Null
            $createdDirectories.Add($strictDirectory)
            $strictUnknownPath = Join-Path $strictDirectory 'future.exe'
            [System.IO.File]::Copy($sourcePath, $strictUnknownPath, $false)
            $probePaths.Add($strictUnknownPath)
            $probeSet.StrictUnknownPath = $strictUnknownPath
        }

        return $probeSet
    }
    catch {
        $cleanupResult = $true
        try {
            $cleanupResult = [bool](Remove-OpenPathAppControlEvaluationProbeSet -ProbeSet $probeSet)
        }
        catch {
            $cleanupResult = $false
        }
        if ($PSBoundParameters.ContainsKey('CleanupSucceeded')) {
            $CleanupSucceeded.Value = $cleanupResult
        }
        throw
    }
}

function Test-OpenPathAppControlEvaluationDecisionCoverage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$RequestedPaths,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Decisions
    )

    $requested = @($RequestedPaths | ForEach-Object { [string]$_ })
    if ($requested.Count -eq 0 -or $Decisions.Count -ne $requested.Count) {
        return $false
    }

    $requestedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($requestedPath in $requested) {
        if ([string]::IsNullOrWhiteSpace($requestedPath) -or -not $requestedSet.Add($requestedPath)) {
            return $false
        }
    }

    $observedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($decision in @($Decisions)) {
        if ($null -eq $decision -or $null -eq $decision.PSObject.Properties['FilePath']) {
            return $false
        }
        $observedPath = [string]$decision.FilePath
        if ([string]::IsNullOrWhiteSpace($observedPath) -or
            -not $requestedSet.Contains($observedPath) -or
            -not $observedSet.Add($observedPath)) {
            return $false
        }
    }

    return ($observedSet.Count -eq $requestedSet.Count)
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

        [string[]]$ApprovedBrowsers = @('Firefox'),

        [ValidateSet('ManagedBrowserCompatibility', 'StrictApplicationAllowlist')]
        [string]$Profile = 'ManagedBrowserCompatibility',

        [AllowNull()]
        [object]$ApplicationCatalog = $null,

        [AllowNull()]
        [object]$BrowserInventory = $null,

        [string]$OpenPathRoot = $script:OpenPathRoot
    )

    $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot $OpenPathRoot -Mode $Mode -ApprovedBrowsers $ApprovedBrowsers -Profile $Profile -ApplicationCatalog $ApplicationCatalog -BrowserInventory $BrowserInventory
    $expectedMode = $spec.EnforcementMode
    $exeCollection = Get-OpenPathAppLockerCollection -PolicyXml $PolicyXml -Type 'Exe'
    $scriptCollection = Get-OpenPathAppLockerCollection -PolicyXml $PolicyXml -Type 'Script'
    $msiCollection = Get-OpenPathAppLockerCollection -PolicyXml $PolicyXml -Type 'Msi'
    $dllCollection = Get-OpenPathAppLockerCollection -PolicyXml $PolicyXml -Type 'Dll'
    $appxCollection = Get-OpenPathAppLockerCollection -PolicyXml $PolicyXml -Type 'Appx'

    $requiredCollections = if ($Profile -eq 'StrictApplicationAllowlist') {
        @($exeCollection, $scriptCollection, $msiCollection, $dllCollection, $appxCollection)
    }
    else {
        @($exeCollection, $scriptCollection, $appxCollection)
    }
    foreach ($collection in $requiredCollections) {
        if (-not (Test-OpenPathAppLockerCollectionMode -Collection $collection -ExpectedMode $expectedMode)) {
            return $false
        }
    }

    $adminFileCollections = if ($Profile -eq 'StrictApplicationAllowlist') {
        @($exeCollection, $scriptCollection, $msiCollection, $dllCollection)
    }
    else {
        @($exeCollection, $scriptCollection)
    }
    foreach ($collection in $adminFileCollections) {
        foreach ($sid in @($spec.AdminSid, $spec.SystemSid)) {
            if (-not (Test-OpenPathFilePathRulePresent -Collection $collection -Action 'Allow' -Sid $sid -Path '*')) {
                return $false
            }
        }
    }

    if ($Profile -eq 'StrictApplicationAllowlist') {
        foreach ($sid in @($spec.AdminSid, $spec.SystemSid)) {
            if (-not (Test-OpenPathFilePublisherRulePresent -Collection $appxCollection -Action 'Allow' -Sid $sid -ProductName '*' -PublisherName '*' -BinaryName '*')) {
                return $false
            }
        }
        foreach ($productName in @($spec.ApprovedAppxBrowserProducts)) {
            if (-not (Test-OpenPathFilePublisherRulePresent -Collection $appxCollection -Action 'Allow' -Sid $spec.RestrictedSid -ProductName $productName -PublisherName 'O=MICROSOFT CORPORATION*' -BinaryName '*')) {
                return $false
            }
        }

        # Strict mode must be default-deny for arbitrary managed locations and
        # packaged apps.  A brand-specific deny would not prove the invariant.
        if (@($exeCollection.FilePathRule | Where-Object {
                    $_.GetAttribute('Action') -eq 'Allow' -and
                    $_.GetAttribute('UserOrGroupSid') -eq $spec.RestrictedSid -and
                    $_.Conditions.FilePathCondition.GetAttribute('Path') -eq '%PROGRAMFILES%\*'
                }).Count -gt 0) {
            return $false
        }
        if (@($appxCollection.FilePublisherRule | Where-Object {
                    $_.GetAttribute('Action') -eq 'Allow' -and
                    $_.GetAttribute('UserOrGroupSid') -in @('S-1-1-0', $spec.RestrictedSid) -and
                    $_.Conditions.FilePublisherCondition.GetAttribute('PublisherName') -eq 'O=MICROSOFT CORPORATION*' -and
                    $_.Conditions.FilePublisherCondition.GetAttribute('ProductName') -eq '*'
                }).Count -gt 0) {
            return $false
        }

        foreach ($application in @($ApplicationCatalog.applications)) {
            $collection = Get-OpenPathApplicationCatalogCollection -Identity $application.identity
            $targetCollection = switch ($collection) {
                'Exe' { $exeCollection }
                'Script' { $scriptCollection }
                'Msi' { $msiCollection }
                'Dll' { $dllCollection }
                'Appx' { $appxCollection }
                default { $null }
            }
            if (-not $targetCollection) {
                return $false
            }
            switch ([string]$application.identity.type) {
                'Path' {
                    if (-not (Test-OpenPathFilePathRulePresent -Collection $targetCollection -Action 'Allow' -Sid $spec.RestrictedSid -Path ([string]$application.identity.path))) {
                        return $false
                    }
                }
                'Publisher' {
                    if (-not (Test-OpenPathFilePublisherRulePresent -Collection $targetCollection -Action 'Allow' -Sid $spec.RestrictedSid -ProductName ([string]$application.identity.productName) -PublisherName ([string]$application.identity.publisherName) -BinaryName ([string]$application.identity.binaryName))) {
                        return $false
                    }
                }
                'AppxPublisher' {
                    if (-not (Test-OpenPathFilePublisherRulePresent -Collection $targetCollection -Action 'Allow' -Sid $spec.RestrictedSid -ProductName ([string]$application.identity.productName) -PublisherName ([string]$application.identity.publisherName) -BinaryName ([string]$application.identity.binaryName))) {
                        return $false
                    }
                }
                'Hash' {
                    if (-not (Test-OpenPathFileHashRulePresent -Collection $targetCollection -Action 'Allow' -Sid $spec.RestrictedSid -Sha256 ([string]$application.identity.sha256) -FileName ([string]$application.identity.fileName))) {
                        return $false
                    }
                }
            }
        }
    }

    if ($Profile -eq 'ManagedBrowserCompatibility' -and -not (Test-OpenPathFilePublisherRulePresent -Collection $appxCollection -Action 'Allow' -Sid 'S-1-1-0' -ProductName '*' -PublisherName 'O=MICROSOFT CORPORATION*')) {
        return $false
    }

    foreach ($productName in @($spec.AlwaysDeniedAppxProducts)) {
        if (-not (Test-OpenPathFilePublisherRulePresent -Collection $appxCollection -Action 'Deny' -Sid $spec.RestrictedSid -ProductName $productName)) {
            return $false
        }
    }

    $approvedSet = Get-OpenPathApprovedBrowserSet -ApprovedBrowsers $ApprovedBrowsers
    if (-not $approvedSet.Edge) {
        foreach ($path in @($spec.UnapprovedBrowserDenyPaths | Where-Object { $_ -match '\\Microsoft\\Edge\\Application\\msedge\.exe$' })) {
            if (-not (Test-OpenPathFilePathRulePresent -Collection $exeCollection -Action 'Deny' -Sid $spec.RestrictedSid -Path $path)) {
                return $false
            }
        }
        foreach ($productName in @($spec.UnapprovedBrowserDenyAppxProducts)) {
            if (-not (Test-OpenPathFilePublisherRulePresent -Collection $appxCollection -Action 'Deny' -Sid $spec.RestrictedSid -ProductName $productName)) {
                return $false
            }
        }
    }

    return $true
}

function Get-OpenPathNonAdminAppControlHealth {
    <#
    .SYNOPSIS
    Returns a structured health snapshot for the OpenPath non-admin AppLocker boundary.
    .DESCRIPTION
    Observes capability, restricted-target, service, local-policy, effective-policy, and
    runtime-evaluation state independently. Reason codes are stable contract values; the
    detailed paths and exceptions remain in the existing operational log messages.
    The appcontrol_runtime_evaluation_failed code identifies an available runtime evaluator
    that could not complete a trustworthy observation.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('AuditOnly', 'Enforced')]
        [string]$Mode = 'Enforced',

        [string[]]$ApprovedBrowsers = @('Firefox'),

        [ValidateSet('ManagedBrowserCompatibility', 'StrictApplicationAllowlist')]
        [string]$Profile = 'ManagedBrowserCompatibility',

        [AllowNull()]
        [object]$ApplicationCatalog = $null,

        [string]$TargetSid = ''
    )

    if (-not (Test-OpenPathApplicationApprovalCatalog -Profile $Profile -Catalog $ApplicationCatalog)) {
        return [pscustomobject][ordered]@{
            Healthy = $false
            Mode = $Mode
            Profile = $Profile
            ReasonCodes = @('strict-catalog-invalid')
            CapabilityAvailable = $false
            RestrictedTargetValid = $false
            AppIdentityServiceRunning = $false
            LocalPolicyPresent = $false
            LocalPolicyValid = $false
            EffectivePolicyPresent = $false
            EffectivePolicyValid = $false
            RuntimeEvaluationAvailable = $false
            RuntimeBoundaryValid = $false
            ExpectedProfile = $Profile
            RestrictedTargetDetail = 'not-observed'
            GroupSid = ''; TargetSid = ''; ProfilePath = ''
            Expected = [pscustomobject]@{}
            Observed = [pscustomobject]@{}
            CleanupAttempted = 'not-observed'; CleanupSucceeded = 'not-observed'
        }
    }

    $reasonCodes = [System.Collections.Generic.List[string]]::new()
    $addReasonCode = {
        param([string]$Code)
        if (-not $reasonCodes.Contains($Code)) {
            [void]$reasonCodes.Add($Code)
        }
    }

    $browserInventory = Get-OpenPathBrowserInventory
    if ($Profile -eq 'StrictApplicationAllowlist' -and
        (-not $browserInventory -or $browserInventory.DiscoveryStatus -ne 'Complete')) {
        & $addReasonCode 'appcontrol_browser_inventory_degraded'
    }

    $capabilityAvailable = $false
    $restrictedTargetValid = $false
    $appIdentityServiceRunning = $false
    $localPolicyPresent = $false
    $localPolicyValid = $false
    $effectivePolicyPresent = $false
    $effectivePolicyValid = $false
    $runtimeEvaluationAvailable = $false
    $runtimeBoundaryValid = $false
    $probeCleanupSucceeded = $true
    $probeCleanupAttempted = $false
    $probeTarget = $null
    $probeTargetError = $null
    $restrictedTargetDetail = 'not-observed'
    $identityResolved = $false
    $profileAvailable = $false
    $validationMode = 'not-observed'
    $groupSid = ''
    $resolvedTargetSid = ''
    $profilePath = ''
    $runtimeDecisions = [System.Collections.Generic.List[object]]::new()

    $capabilityAvailable = [bool](Test-OpenPathAppControlAvailable)
    if (-not $capabilityAvailable) {
        & $addReasonCode 'appcontrol_capability_unavailable'
    }
    else {
        try {
            $probeTarget = Get-OpenPathAppControlProbeTarget -TargetSid $TargetSid
            $restrictedTargetValid = $true
            $identityResolved = $true
            $profileAvailable = [bool]$probeTarget.ProfileAvailable
            $validationMode = [string]$probeTarget.ValidationMode
            $restrictedTargetDetail = if ($profileAvailable) { 'resolved' } else { 'member-profile-unavailable' }
            $groupSid = [string]$probeTarget.GroupSid
            $resolvedTargetSid = [string]$probeTarget.UserSid
            $profilePath = [string]$probeTarget.ProfilePath
        }
        catch {
            $probeTargetError = $_
            $exceptionData = $_.Exception.Data
            $restrictedTargetDetail = if ($exceptionData -and $exceptionData['OpenPathDetail']) { [string]$exceptionData['OpenPathDetail'] } else { 'not-observed' }
            $groupSid = if ($exceptionData -and $exceptionData['OpenPathGroupSid']) { [string]$exceptionData['OpenPathGroupSid'] } else { '' }
            $resolvedTargetSid = if ($exceptionData -and $exceptionData['OpenPathTargetSid']) { [string]$exceptionData['OpenPathTargetSid'] } else { '' }
            & $addReasonCode 'appcontrol_restricted_target_missing'
        }

        $appIdentityServiceRunning = [bool](Test-OpenPathAppIdentityServiceRunning)
        if (-not $appIdentityServiceRunning) {
            & $addReasonCode 'appcontrol_appidsvc_not_running'
        }

        $localPolicyText = $null
        try {
            $localPolicyText = Get-AppLockerPolicy -Local -Xml -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace([string]$localPolicyText)) {
                & $addReasonCode 'appcontrol_local_policy_absent'
            }
            else {
                $localPolicyPresent = $true
                try {
                    $localPolicyXml = [xml]$localPolicyText
                        $localPolicyValid = [bool](Test-OpenPathAppLockerBoundaryPolicy -PolicyXml $localPolicyXml -Mode $Mode -ApprovedBrowsers $ApprovedBrowsers -Profile $Profile -ApplicationCatalog $ApplicationCatalog -BrowserInventory $browserInventory)
                }
                catch {
                    $localPolicyValid = $false
                }
                if (-not $localPolicyValid) {
                    & $addReasonCode 'appcontrol_local_policy_invalid'
                    if ($Profile -eq 'StrictApplicationAllowlist') {
                        & $addReasonCode 'strict-required-rule-missing'
                    }
                }
            }
        }
        catch {
            & $addReasonCode 'appcontrol_local_policy_invalid'
            if ($Profile -eq 'StrictApplicationAllowlist') {
                & $addReasonCode 'strict-required-rule-missing'
            }
        }

        $effectivePolicyText = $null
        try {
            $effectivePolicyText = Get-AppLockerPolicy -Effective -Xml -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace([string]$effectivePolicyText)) {
                & $addReasonCode 'appcontrol_effective_policy_absent'
            }
            else {
                $effectivePolicyPresent = $true
                try {
                    $effectivePolicyXml = [xml]$effectivePolicyText
                        $effectivePolicyValid = [bool](Test-OpenPathAppLockerBoundaryPolicy -PolicyXml $effectivePolicyXml -Mode $Mode -ApprovedBrowsers $ApprovedBrowsers -Profile $Profile -ApplicationCatalog $ApplicationCatalog -BrowserInventory $browserInventory)
                }
                catch {
                    $effectivePolicyValid = $false
                }
                if (-not $effectivePolicyValid) {
                    & $addReasonCode 'appcontrol_effective_policy_invalid'
                    if ($Profile -eq 'StrictApplicationAllowlist') {
                        & $addReasonCode 'strict-effective-policy-mismatch'
                    }
                }
            }
        }
        catch {
            & $addReasonCode 'appcontrol_effective_policy_invalid'
            if ($Profile -eq 'StrictApplicationAllowlist') {
                & $addReasonCode 'strict-effective-policy-mismatch'
            }
        }

        $runtimeEvaluationAvailable = [bool](Get-Command -Name 'Test-AppLockerPolicy' -ErrorAction SilentlyContinue)
        if (-not $runtimeEvaluationAvailable) {
            Write-OpenPathLog 'AppLocker effective runtime policy test unavailable; refusing structural-only validation' -Level WARN
            & $addReasonCode 'appcontrol_runtime_evaluation_unavailable'
            if ($Profile -eq 'StrictApplicationAllowlist') {
                & $addReasonCode 'strict-runtime-probe-failed'
            }
        }
        elseif ($restrictedTargetValid -and $effectivePolicyValid) {
            $probeSet = $null
            try {
                if ([string]::IsNullOrWhiteSpace([string]$effectivePolicyText)) {
                    throw 'Effective AppLocker policy is unavailable'
                }
                $evaluationPolicyXml = [xml]$effectivePolicyText
                if (@($evaluationPolicyXml.AppLockerPolicy.RuleCollection).Count -eq 0) {
                    throw 'Effective AppLocker policy has no rule collections'
                }

                $probeCleanupAttempted = $true
                $probeSet = New-OpenPathAppControlEvaluationProbeSet -Target $probeTarget -Profile $Profile -CleanupSucceeded ([ref]$probeCleanupSucceeded)
                $probePaths = @($probeSet.Paths | ForEach-Object { [string]$_ })
                $testDecisions = @(Invoke-OpenPathAppLockerPolicyEvaluation -PolicyXml $effectivePolicyText -Path $probePaths -UserSid $probeTarget.UserSid)
                if (-not (Test-OpenPathAppControlEvaluationDecisionCoverage -RequestedPaths $probePaths -Decisions $testDecisions)) {
                    throw 'Test-AppLockerPolicy did not return one decision for every controlled AppControl probe'
                }

                $runtimeBoundaryValid = $true
                foreach ($decision in $testDecisions) {
                    [void]$runtimeDecisions.Add([pscustomobject][ordered]@{
                            Kind = 'arbitrary-executable'
                            FilePath = [string]$decision.FilePath
                            Expected = 'DeniedOrDeniedByDefault'
                            Observed = [string]$decision.PolicyDecision
                        })
                    if ($decision.PolicyDecision -in @('Denied', 'DeniedByDefault')) {
                        continue
                    }
                    $runtimeBoundaryValid = $false
                    & $addReasonCode 'appcontrol_runtime_arbitrary_exe_allowed'
                    if ($Profile -eq 'StrictApplicationAllowlist') {
                        & $addReasonCode 'strict-runtime-probe-failed'
                    }
                    Write-OpenPathLog "AppLocker effective evaluation failed for $($decision.FilePath): expected Denied/DeniedByDefault, observed $($decision.PolicyDecision)" -Level WARN
                    Write-OpenPathLog "AppLocker effective runtime policy test failed: Controlled AppControl probe was not denied: $($decision.PolicyDecision)" -Level WARN
                }

                if ($Profile -eq 'StrictApplicationAllowlist') {
                    $futureBrowserPath = [string]$probeSet.StrictUnknownPath
                    if ([string]::IsNullOrWhiteSpace($futureBrowserPath) -or -not [System.IO.File]::Exists($futureBrowserPath)) {
                        throw 'Strict unknown executable probe was not created'
                    }
                    $futureDecisions = @(Invoke-OpenPathAppLockerPolicyEvaluation -PolicyXml $effectivePolicyText -Path @($futureBrowserPath) -UserSid $probeTarget.UserSid)
                    if (-not (Test-OpenPathAppControlEvaluationDecisionCoverage -RequestedPaths @($futureBrowserPath) -Decisions $futureDecisions)) {
                        throw 'Test-AppLockerPolicy did not return a decision for the strict FutureBrowser probe'
                    }
                    foreach ($decision in $futureDecisions) {
                        [void]$runtimeDecisions.Add([pscustomobject][ordered]@{
                                Kind = 'strict-unknown-program-files-executable'
                                FilePath = [string]$decision.FilePath
                                Expected = 'DeniedOrDeniedByDefault'
                                Observed = [string]$decision.PolicyDecision
                            })
                        if ($decision.PolicyDecision -notin @('Denied', 'DeniedByDefault')) {
                            $runtimeBoundaryValid = $false
                            & $addReasonCode 'strict-runtime-probe-failed'
                            Write-OpenPathLog "Strict AppLocker evaluation failed for unknown FutureBrowser path: observed $($decision.PolicyDecision)" -Level WARN
                        }
                    }
                }

                $approvedSet = Get-OpenPathApprovedBrowserSet -ApprovedBrowsers $ApprovedBrowsers
                $programFilesRoots = @(
                    $env:ProgramFiles
                    ${env:ProgramFiles(x86)}
                ) |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                    Select-Object -Unique

                if (-not $approvedSet.Edge) {
                    $edgeSampleCandidates = @(
                        foreach ($programFilesRoot in $programFilesRoots) {
                            Join-Path $programFilesRoot 'Microsoft\Edge\Application\msedge.exe'
                        }
                        'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
                        'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
                    )
                    $edgeSamplePaths = Get-OpenPathAppControlExistingSamplePaths -Label 'Edge' -Paths $edgeSampleCandidates
                    $edgeDecisions = @(Invoke-OpenPathAppLockerPolicyEvaluation -PolicyXml $effectivePolicyText -Path $edgeSamplePaths -UserSid $probeTarget.UserSid)
                    if (-not (Test-OpenPathAppControlEvaluationDecisionCoverage -RequestedPaths $edgeSamplePaths -Decisions $edgeDecisions)) {
                        throw 'Test-AppLockerPolicy did not return one decision for every Edge probe'
                    }
                    $edgeAllowedDecisions = @($edgeDecisions | Where-Object { $_.PolicyDecision -notin @('Denied', 'DeniedByDefault') })
                    foreach ($decision in $edgeDecisions) {
                        [void]$runtimeDecisions.Add([pscustomobject][ordered]@{
                                Kind = 'edge'
                                FilePath = [string]$decision.FilePath
                                Expected = 'DeniedOrDeniedByDefault'
                                Observed = [string]$decision.PolicyDecision
                            })
                    }
                    if ($edgeAllowedDecisions.Count -gt 0) {
                        $runtimeBoundaryValid = $false
                        & $addReasonCode 'appcontrol_runtime_edge_allowed'
                        if ($Profile -eq 'StrictApplicationAllowlist') {
                            & $addReasonCode 'strict-runtime-probe-failed'
                        }
                        Write-OpenPathLog 'AppLocker effective evaluation failed: Edge executable was not evaluated as Denied' -Level WARN
                        Write-OpenPathLog 'AppLocker effective runtime policy test failed: Edge executable was not evaluated as Denied' -Level WARN
                    }
                }

                if ($approvedSet.Firefox) {
                    $firefoxSampleCandidates = @(
                        foreach ($programFilesRoot in $programFilesRoots) {
                            Join-Path $programFilesRoot 'Mozilla Firefox\firefox.exe'
                        }
                        'C:\Program Files\Mozilla Firefox\firefox.exe',
                        'C:\Program Files (x86)\Mozilla Firefox\firefox.exe'
                    )
                    $firefoxSamplePaths = Get-OpenPathAppControlExistingSamplePaths -Label 'Firefox' -Paths $firefoxSampleCandidates
                    $firefoxDecisions = @(Invoke-OpenPathAppLockerPolicyEvaluation -PolicyXml $effectivePolicyText -Path $firefoxSamplePaths -UserSid $probeTarget.UserSid)
                    if (-not (Test-OpenPathAppControlEvaluationDecisionCoverage -RequestedPaths $firefoxSamplePaths -Decisions $firefoxDecisions)) {
                        throw 'Test-AppLockerPolicy did not return one decision for every Firefox probe'
                    }
                    $firefoxNotAllowedDecisions = @($firefoxDecisions | Where-Object { $_.PolicyDecision -ne 'Allowed' })
                    foreach ($decision in $firefoxDecisions) {
                        [void]$runtimeDecisions.Add([pscustomobject][ordered]@{
                                Kind = 'firefox'
                                FilePath = [string]$decision.FilePath
                                Expected = 'Allowed'
                                Observed = [string]$decision.PolicyDecision
                            })
                    }
                    if ($firefoxNotAllowedDecisions.Count -gt 0) {
                        $runtimeBoundaryValid = $false
                        & $addReasonCode 'appcontrol_runtime_firefox_not_allowed'
                        if ($Profile -eq 'StrictApplicationAllowlist') {
                            & $addReasonCode 'strict-runtime-probe-failed'
                        }
                        Write-OpenPathLog 'AppLocker effective evaluation failed: Firefox executable was not evaluated as Allowed' -Level WARN
                        Write-OpenPathLog 'AppLocker effective runtime policy test failed: Firefox executable was not evaluated as Allowed' -Level WARN
                    }
                }
            }
            catch {
                $runtimeBoundaryValid = $false
                & $addReasonCode 'appcontrol_runtime_evaluation_failed'
                if ($Profile -eq 'StrictApplicationAllowlist') {
                    & $addReasonCode 'strict-runtime-probe-failed'
                }
                Write-OpenPathLog "AppLocker effective runtime policy test failed: $_" -Level WARN
            }
            finally {
                if ($null -ne $probeSet) {
                    try {
                        $probeCleanupSucceeded = [bool](Remove-OpenPathAppControlEvaluationProbeSet -ProbeSet $probeSet)
                    }
                    catch {
                        $probeCleanupSucceeded = $false
                        Write-OpenPathLog "Failed to remove temporary AppControl probes: $_" -Level WARN
                    }
                }
                if (-not $probeCleanupSucceeded) {
                    & $addReasonCode 'appcontrol_probe_cleanup_failed'
                }
            }
        }
        elseif ($null -ne $probeTargetError) {
            Write-OpenPathLog "AppLocker effective runtime policy test failed: $probeTargetError" -Level WARN
        }
    }

    $healthy = [bool]($capabilityAvailable -and
        $restrictedTargetValid -and
        $appIdentityServiceRunning -and
        $localPolicyPresent -and
        $localPolicyValid -and
        $effectivePolicyPresent -and
        $effectivePolicyValid -and
        $runtimeEvaluationAvailable -and
        $runtimeBoundaryValid -and
        $probeCleanupSucceeded)

    return [PSCustomObject][ordered]@{
        Healthy = $healthy
        Mode = $Mode
        Profile = $Profile
        ReasonCodes = @($reasonCodes.ToArray())
        CapabilityAvailable = $capabilityAvailable
        RestrictedTargetValid = $restrictedTargetValid
        AppIdentityServiceRunning = $appIdentityServiceRunning
        LocalPolicyPresent = $localPolicyPresent
        LocalPolicyValid = $localPolicyValid
        EffectivePolicyPresent = $effectivePolicyPresent
        EffectivePolicyValid = $effectivePolicyValid
        RuntimeEvaluationAvailable = $runtimeEvaluationAvailable
        RuntimeBoundaryValid = $runtimeBoundaryValid
        IdentityResolved = $identityResolved
        ProfileAvailable = $profileAvailable
        ValidationMode = $validationMode
        ExpectedProfile = $Profile
        RestrictedTargetDetail = $restrictedTargetDetail
        GroupSid = $groupSid
        TargetSid = $resolvedTargetSid
        ProfilePath = $profilePath
        Expected = [pscustomobject][ordered]@{
            RestrictedTarget = 'group-member-with-optional-materialized-profile'
            AppIdentityService = 'Running'
            LocalPolicy = 'present-valid'
            EffectivePolicy = 'present-valid'
            RuntimeBoundary = 'valid'
        }
        Observed = [pscustomobject][ordered]@{
            RestrictedTarget = $restrictedTargetDetail
            IdentityResolved = $identityResolved
            ProfileAvailable = $profileAvailable
            ValidationMode = $validationMode
            AppIdentityService = if (-not $capabilityAvailable) { 'not-observed' } elseif ($appIdentityServiceRunning) { 'Running' } else { 'not-running-or-unavailable' }
            LocalPolicyPresent = if ($capabilityAvailable) { $localPolicyPresent } else { 'not-observed' }
            LocalPolicyValid = if ($capabilityAvailable) { $localPolicyValid } else { 'not-observed' }
            EffectivePolicyPresent = if ($capabilityAvailable) { $effectivePolicyPresent } else { 'not-observed' }
            EffectivePolicyValid = if ($capabilityAvailable) { $effectivePolicyValid } else { 'not-observed' }
            RuntimeDecisions = @($runtimeDecisions.ToArray())
            Profile = $Profile
        }
        CleanupAttempted = if ($probeCleanupAttempted) { $true } else { 'not-observed' }
        CleanupSucceeded = if ($probeCleanupAttempted) { $probeCleanupSucceeded } else { 'not-observed' }
    }
}

function Write-OpenPathAppControlDiagnosticFile {
    param(
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$Diagnostic
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    try {
        if (-not (Get-Command -Name Write-OpenPathAtomicJsonFile -ErrorAction SilentlyContinue)) {
            throw 'shared atomic JSON writer unavailable'
        }
        Write-OpenPathAtomicJsonFile -Path $Path -Data $Diagnostic -Depth 12
        return
    }
    catch {
        # Diagnostic transport must survive a failed Common.psm1 import without
        # changing the AppControl decision. Keep this fallback self-contained,
        # atomic, bounded by the caller's schema, and private to SYSTEM,
        # Administrators, and the current principal.
        $tempPath = "$Path.tmp-$([guid]::NewGuid().ToString('N'))"
        try {
            $parent = Split-Path -Parent $Path -ErrorAction SilentlyContinue
            if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            $json = $Diagnostic | ConvertTo-Json -Depth 12
            [IO.File]::WriteAllText($tempPath, $json, [Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $tempPath -Destination $Path -Force
            $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            & icacls.exe $Path /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' "*$currentSid`:F" | Out-Null
        }
        catch {
            if (Get-Command -Name Write-OpenPathLog -ErrorAction SilentlyContinue) {
                Write-OpenPathLog 'Unable to persist bounded AppControl diagnostic status' -Level WARN
            }
        }
        finally {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function New-OpenPathAppControlFailureDiagnostic {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Health,

        [string]$Substep = 'validation'
    )

    return [pscustomobject][ordered]@{
        Stage = 'app-control'
        Substep = $Substep
        ReasonCodes = @($Health.ReasonCodes)
        Detail = [string]$Health.RestrictedTargetDetail
        TargetSid = [string]$Health.TargetSid
        GroupSid = [string]$Health.GroupSid
        ProfilePath = [string]$Health.ProfilePath
        IdentityResolved = if ($Health.PSObject.Properties['IdentityResolved']) { [bool]$Health.IdentityResolved } else { $false }
        ProfileAvailable = if ($Health.PSObject.Properties['ProfileAvailable']) { [bool]$Health.ProfileAvailable } else { $false }
        ValidationMode = if ($Health.PSObject.Properties['ValidationMode']) { [string]$Health.ValidationMode } else { 'not-observed' }
        Expected = $Health.Expected
        Observed = $Health.Observed
        AppControlCommitState = 'not-committed'
        InternalRollbackAttempted = $false
        InternalRollbackSucceeded = 'not-observed'
        CleanupAttempted = $Health.CleanupAttempted
        CleanupSucceeded = $Health.CleanupSucceeded
        PowerShellProcessArchitecture = "$(8 * [IntPtr]::Size)-bit"
    }
}

function New-OpenPathAppControlPreconditionDiagnostic {
    param(
        [Parameter(Mandatory = $true)][string]$Substep,
        [Parameter(Mandatory = $true)][string]$ReasonCode
    )

    $health = [pscustomobject][ordered]@{
        ReasonCodes = @($ReasonCode)
        RestrictedTargetDetail = 'not-observed'
        TargetSid = ''
        GroupSid = ''
        ProfilePath = ''
        Expected = [pscustomobject][ordered]@{
            RestrictedTarget = 'group-member-with-optional-materialized-profile'
            AppIdentityService = 'Running'
            LocalPolicy = 'present-valid'
            EffectivePolicy = 'present-valid'
            RuntimeBoundary = 'valid'
        }
        Observed = [pscustomobject][ordered]@{
            RestrictedTarget = 'not-observed'
            IdentityResolved = $false
            ProfileAvailable = $false
            ValidationMode = 'not-observed'
            AppIdentityService = 'not-observed'
            LocalPolicyPresent = 'not-observed'
            LocalPolicyValid = 'not-observed'
            EffectivePolicyPresent = 'not-observed'
            EffectivePolicyValid = 'not-observed'
            RuntimeDecisions = @()
        }
        CleanupAttempted = 'not-observed'
        CleanupSucceeded = 'not-observed'
    }
    return New-OpenPathAppControlFailureDiagnostic -Health $health -Substep $Substep
}

function Invoke-OpenPathAppControlPolicyConverterActivation {
    $taskPath = '\Microsoft\Windows\AppID\'
    $taskName = 'PolicyConverter'
    $result = [ordered]@{
        status = 'inconclusive'
        code = 'task-query-failed'
        initialEnabled = $null
        finalEnabled = $null
        restoreStatus = 'not-required'
        startRunObserved = $false
    }

    try {
        $initialTask = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
        $initialInfo = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
    }
    catch {
        return [pscustomobject]$result
    }

    $initialEnabled = if ($initialTask.Settings.PSObject.Properties['Enabled']) {
        $initialTask.Settings.Enabled
    }
    else {
        $null
    }
    $result.initialEnabled = $initialEnabled
    if ($null -eq $initialEnabled -or
        $null -eq $initialTask.State -or
        $null -eq $initialInfo.LastRunTime -or
        $null -eq $initialInfo.LastTaskResult) {
        $result.code = 'task-snapshot-unknown'
        return [pscustomobject]$result
    }
    if ([string]$initialTask.State -eq 'Running') {
        $result.code = 'task-already-running'
        return [pscustomobject]$result
    }

    $restoreRequired = -not [bool]$initialEnabled
    $activationObserved = $false
    try {
        if ($restoreRequired) {
            try {
                Enable-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop | Out-Null
            }
            catch {
                $result.code = 'task-enable-failed'
                return [pscustomobject]$result
            }
        }

        try {
            Start-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop | Out-Null
        }
        catch {
            $result.code = 'task-start-failed'
            return [pscustomobject]$result
        }

        $deadline = (Get-Date).AddSeconds(20)
        do {
            Start-Sleep -Milliseconds 250
            try {
                $currentTask = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
                $currentInfo = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
            }
            catch {
                $result.code = 'task-query-failed'
                return [pscustomobject]$result
            }

            $newRun = $currentInfo.LastRunTime -gt $initialInfo.LastRunTime
            $ready = [string]$currentTask.State -eq 'Ready'
            if ($newRun -and $ready -and $currentInfo.LastTaskResult -eq 0) {
                $activationObserved = $true
                $result.startRunObserved = $true
                $result.code = 'task-run-observed'
                break
            }
        } while ((Get-Date) -lt $deadline)

        if (-not $activationObserved) {
            $result.code = 'task-run-not-confirmed'
        }
    }
    finally {
        if ($restoreRequired) {
            $result.restoreStatus = 'not-observed'
            try {
                Disable-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop | Out-Null
            }
            catch {
                if ($activationObserved) {
                    $result.code = 'task-restore-failed'
                }
                $activationObserved = $false
            }

            if ($result.code -ne 'task-restore-failed') {
                try {
                    $finalTask = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction Stop
                    $finalEnabled = if ($finalTask.Settings.PSObject.Properties['Enabled']) {
                        $finalTask.Settings.Enabled
                    }
                    else {
                        $null
                    }
                    $result.finalEnabled = $finalEnabled
                    if ($null -ne $finalEnabled -and -not [bool]$finalEnabled) {
                        $result.restoreStatus = 'observed'
                    }
                    elseif ($activationObserved) {
                        $result.code = 'task-restore-not-confirmed'
                        $activationObserved = $false
                    }
                }
                catch {
                    if ($activationObserved) {
                        $result.code = 'task-restore-not-confirmed'
                        $activationObserved = $false
                    }
                }
            }
        }
    }

    if ($activationObserved) {
        $result.status = 'observed'
    }
    return [pscustomobject]$result
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

        [string[]]$ApprovedBrowsers = @('Firefox'),

        [ValidateSet('ManagedBrowserCompatibility', 'StrictApplicationAllowlist')]
        [string]$Profile = 'ManagedBrowserCompatibility',

        [AllowNull()]
        [object]$ApplicationCatalog = $null,

        [string]$DiagnosticStatusPath = ''
    )

    if (-not (Test-OpenPathApplicationApprovalCatalog -Profile $Profile -Catalog $ApplicationCatalog)) {
        Write-OpenPathAppControlDiagnosticFile -Path $DiagnosticStatusPath -Diagnostic (
            New-OpenPathAppControlPreconditionDiagnostic -Substep 'catalog-validation' -ReasonCode 'strict-catalog-invalid')
        return $false
    }

    if (-not (Get-Command -Name Test-AdminPrivileges -ErrorAction SilentlyContinue)) {
        Write-OpenPathAppControlDiagnosticFile -Path $DiagnosticStatusPath -Diagnostic (
            New-OpenPathAppControlPreconditionDiagnostic -Substep 'dependency-check' -ReasonCode 'appcontrol_capability_unavailable')
        return $false
    }
    if (-not (Test-AdminPrivileges)) {
        Write-OpenPathAppControlDiagnosticFile -Path $DiagnosticStatusPath -Diagnostic (
            New-OpenPathAppControlPreconditionDiagnostic -Substep 'privilege-check' -ReasonCode 'appcontrol_admin_required')
        Write-OpenPathLog 'Administrator privileges required for AppLocker configuration' -Level ERROR
        return $false
    }
    if (-not (Test-OpenPathAppControlAvailable)) {
        Write-OpenPathAppControlDiagnosticFile -Path $DiagnosticStatusPath -Diagnostic (
            New-OpenPathAppControlPreconditionDiagnostic -Substep 'capability-check' -ReasonCode 'appcontrol_capability_unavailable')
        Write-OpenPathLog 'AppLocker cmdlets unavailable; non-admin app control not applied' -Level WARN
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess('Windows AppLocker', "Configure OpenPath non-admin app control in $Mode mode")) {
        Write-OpenPathAppControlDiagnosticFile -Path $DiagnosticStatusPath -Diagnostic (
            New-OpenPathAppControlPreconditionDiagnostic -Substep 'should-process' -ReasonCode 'appcontrol_apply_not_authorized')
        return $false
    }

    $diagnosticSubstep = 'policy-backup'
    $failureDiagnostic = $null
    $policyApplied = $false
    try {
        $appLockerBackupPath = Join-Path (Join-Path $OpenPathRoot 'data') 'applocker-backup.xml'
        $backupDir = Split-Path $appLockerBackupPath -Parent
        if (-not (Test-Path $backupDir)) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        }

        $currentPolicyText = Get-AppLockerPolicy -Local -Xml
        Set-Content -Path $appLockerBackupPath -Value $currentPolicyText -Encoding UTF8

        $diagnosticSubstep = 'policy-generation'
        $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot $OpenPathRoot -Mode $Mode -ApprovedBrowsers $ApprovedBrowsers -Profile $Profile -ApplicationCatalog $ApplicationCatalog
        $policyXml = New-OpenPathAppLockerPolicyXml -Spec $spec
        $mergedPolicyXml = Merge-OpenPathAppLockerPolicyXml -CurrentPolicy ([xml]$currentPolicyText) -OpenPathPolicy ([xml]$policyXml)
        # Validate the candidate in memory before crossing the AppLocker
        # mutation boundary.  The backup remains available for failures after
        # apply, but malformed strict candidates must never be applied first.
        $diagnosticSubstep = 'policy-preflight'
        if ($Profile -eq 'StrictApplicationAllowlist' -and
            -not (Test-OpenPathAppLockerBoundaryPolicy -PolicyXml ([xml]$mergedPolicyXml) -Mode $Mode -ApprovedBrowsers $ApprovedBrowsers -Profile $Profile -ApplicationCatalog $ApplicationCatalog -BrowserInventory $spec.BrowserInventory -OpenPathRoot $OpenPathRoot)) {
            throw 'strict-required-rule-missing'
        }
        $policyPath = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-applocker-$([guid]::NewGuid()).xml"
        $mergedPolicyXml.Save($policyPath)
        $diagnosticSubstep = 'policy-apply'
        Set-AppLockerPolicy -XMLPolicy $policyPath
        $policyApplied = $true
        Remove-Item $policyPath -Force -ErrorAction SilentlyContinue

        $diagnosticSubstep = 'service-config'
        Set-OpenPathAppIdentityServiceAutomatic
        $diagnosticSubstep = 'service-start'
        Start-Service -Name AppIDSvc -ErrorAction Stop
        if (-not (Test-OpenPathAppIdentityServiceRunning)) {
            throw 'AppIDSvc did not reach Running after Start-Service'
        }

        $diagnosticSubstep = 'policy-activation'
        $activation = Invoke-OpenPathAppControlPolicyConverterActivation
        if ($activation.status -ne 'observed') {
            Write-OpenPathLog 'AppLocker policy activation was inconclusive; continuing with validation' -Level WARN
        }

        $diagnosticSubstep = 'validation'
        if (-not (Test-OpenPathNonAdminAppControlActive -Mode $Mode -ApprovedBrowsers $ApprovedBrowsers -Profile $Profile -ApplicationCatalog $ApplicationCatalog)) {
            $health = $script:OpenPathLastAppControlHealth
            if ($null -eq $health) {
                $health = [pscustomobject]@{
                    ReasonCodes = @('appcontrol_health_evaluation_failed')
                    RestrictedTargetDetail = 'not-observed'
                    TargetSid = ''
                    GroupSid = ''
                    ProfilePath = ''
                    Expected = [pscustomobject]@{}
                    Observed = [pscustomobject]@{}
                    CleanupAttempted = 'not-observed'
                    CleanupSucceeded = 'not-observed'
                }
            }
            $failureDiagnostic = New-OpenPathAppControlFailureDiagnostic -Health $health
            if ($Profile -eq 'StrictApplicationAllowlist' -and
                @($failureDiagnostic.ReasonCodes) -notcontains 'strict-transition-failed') {
                $failureDiagnostic.ReasonCodes = @($failureDiagnostic.ReasonCodes) + 'strict-transition-failed'
            }
            Write-OpenPathAppControlDiagnosticFile -Path $DiagnosticStatusPath -Diagnostic $failureDiagnostic

            $failureDiagnostic.InternalRollbackAttempted = $true
            try {
                Set-AppLockerPolicy -XMLPolicy $appLockerBackupPath -ErrorAction Stop
                $failureDiagnostic.InternalRollbackSucceeded = $true
                Write-OpenPathLog 'AppLocker validation failed after OpenPath policy apply; restored previous policy backup' -Level WARN
            }
            catch {
                $failureDiagnostic.InternalRollbackSucceeded = $false
                Write-OpenPathLog 'AppLocker validation failed and the previous policy backup could not be restored' -Level WARN
            }
            Write-OpenPathAppControlDiagnosticFile -Path $DiagnosticStatusPath -Diagnostic $failureDiagnostic
            return $false
        }

        Write-OpenPathLog "OpenPath non-admin app control applied in $Mode mode"
        return $true
    }
    catch {
        if ($null -eq $failureDiagnostic) {
            $reasonCode = switch ($diagnosticSubstep) {
                'policy-backup' { 'appcontrol_policy_backup_failed' }
                'policy-generation' { 'appcontrol_policy_generation_failed' }
                'policy-preflight' { if ($Profile -eq 'StrictApplicationAllowlist') { 'strict-required-rule-missing' } else { 'appcontrol_policy_generation_failed' } }
                'policy-apply' { 'appcontrol_policy_apply_failed' }
                'service-config' { 'appcontrol_appidsvc_configuration_failed' }
                'service-start' { 'appcontrol_appidsvc_start_failed' }
                'policy-activation' { 'appcontrol_policy_activation_failed' }
                default { 'appcontrol_health_evaluation_failed' }
            }
            $failureDiagnostic = [pscustomobject][ordered]@{
                Stage = 'app-control'
                Substep = $diagnosticSubstep
                ReasonCodes = @($reasonCode)
                Detail = 'not-observed'
                TargetSid = ''
                GroupSid = ''
                ProfilePath = ''
                Expected = [pscustomobject][ordered]@{
                    RestrictedTarget = 'group-member-with-optional-materialized-profile'
                    AppIdentityService = 'Running'
                    LocalPolicy = 'present-valid'
                    EffectivePolicy = 'present-valid'
                    RuntimeBoundary = 'valid'
                }
                Observed = [pscustomobject][ordered]@{
                    RestrictedTarget = 'not-observed'
                    AppIdentityService = 'not-observed'
                    LocalPolicyPresent = 'not-observed'
                    LocalPolicyValid = 'not-observed'
                    EffectivePolicyPresent = 'not-observed'
                    EffectivePolicyValid = 'not-observed'
                    RuntimeDecisions = @()
                }
                AppControlCommitState = 'not-committed'
                InternalRollbackAttempted = 'not-observed'
                InternalRollbackSucceeded = 'not-observed'
                CleanupAttempted = 'not-observed'
                CleanupSucceeded = 'not-observed'
                PowerShellProcessArchitecture = "$(8 * [IntPtr]::Size)-bit"
            }
            if ($Profile -eq 'StrictApplicationAllowlist') {
                $failureDiagnostic.ReasonCodes = @($failureDiagnostic.ReasonCodes) + 'strict-transition-failed'
            }
            if ($policyApplied) {
                $failureDiagnostic.InternalRollbackAttempted = $true
                try {
                    Set-AppLockerPolicy -XMLPolicy $appLockerBackupPath -ErrorAction Stop
                    $failureDiagnostic.InternalRollbackSucceeded = $true
                    Write-OpenPathLog 'AppLocker activation failed after policy apply; restored previous policy backup' -Level WARN
                }
                catch {
                    $failureDiagnostic.InternalRollbackSucceeded = $false
                    Write-OpenPathLog 'AppLocker activation failed and the previous policy backup could not be restored' -Level WARN
                }
            }
            Write-OpenPathAppControlDiagnosticFile -Path $DiagnosticStatusPath -Diagnostic $failureDiagnostic
        }
        Write-OpenPathLog "Failed to configure OpenPath non-admin app control: $_" -Level WARN
        return $false
    }
}

function Test-OpenPathNonAdminAppControlActive {
    <#
    .SYNOPSIS
    Returns true when the structured OpenPath non-admin AppControl health is healthy.
    .DESCRIPTION
    Compatibility adapter for callers that only need the historical boolean contract.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('AuditOnly', 'Enforced')]
        [string]$Mode = 'Enforced',

        [string[]]$ApprovedBrowsers = @('Firefox'),

        [ValidateSet('ManagedBrowserCompatibility', 'StrictApplicationAllowlist')]
        [string]$Profile = 'ManagedBrowserCompatibility',

        [AllowNull()]
        [object]$ApplicationCatalog = $null
    )

    $health = Get-OpenPathNonAdminAppControlHealth -Mode $Mode -ApprovedBrowsers $ApprovedBrowsers -Profile $Profile -ApplicationCatalog $ApplicationCatalog
    $script:OpenPathLastAppControlHealth = $health
    return [bool]$health.Healthy
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

function Remove-OpenPathRestrictedGroup {
    <#
    .SYNOPSIS
    Removes the OpenPath-Restricted local group when it exists. No-op when absent or unavailable.
    #>
    [CmdletBinding()]
    param()

    if (-not (Get-Command -Name Get-LocalGroup -ErrorAction SilentlyContinue)) {
        return
    }
    try {
        if (Get-LocalGroup -Name 'OpenPath-Restricted' -ErrorAction SilentlyContinue) {
            Remove-LocalGroup -Name 'OpenPath-Restricted' -ErrorAction Stop
            Write-OpenPathLog 'Removed OpenPath-Restricted group'
        }
    }
    catch {
        Write-OpenPathLog "Failed to remove OpenPath-Restricted group: $_" -Level WARN
    }
}

Export-ModuleMember -Function @(
    'Get-OpenPathAlwaysDeniedAppxProductNames',
    'Test-OpenPathApplicationApprovalCatalog',
    'New-OpenPathNonAdminAppLockerPolicySpec',
    'New-OpenPathAppLockerPolicyXml',
    'Merge-OpenPathAppLockerPolicyXml',
    'Test-OpenPathAppControlAvailable',
    'Set-OpenPathNonAdminAppControl',
    'Get-OpenPathNonAdminAppControlHealth',
    'Test-OpenPathNonAdminAppControlActive',
    'Remove-OpenPathNonAdminAppControl',
    'Get-OpenPathRestrictedGroupSid',
    'Sync-OpenPathRestrictedGroup',
    'Remove-OpenPathRestrictedGroup'
)
