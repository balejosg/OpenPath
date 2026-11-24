function Test-OpenPathFirewallIpAddress {
    param(
        [AllowNull()]
        [string]$Address
    )

    if ([string]::IsNullOrWhiteSpace($Address)) {
        return $false
    }

    $parsedAddress = $null
    return [System.Net.IPAddress]::TryParse($Address.Trim(), [ref]$parsedAddress)
}

function ConvertTo-OpenPathIPv4UInt32 {
    # converts a dotted IPv4 string to its [int64] numeric value (0..4294967295);
    # returns $null for blank, non-IPv4, or unparseable input.
    param(
        [AllowNull()]
        [string]$Address
    )

    if ([string]::IsNullOrWhiteSpace($Address)) { return $null }

    $parsed = $null
    if (-not [System.Net.IPAddress]::TryParse($Address.Trim(), [ref]$parsed)) { return $null }
    if ($parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { return $null }

    $bytes = $parsed.GetAddressBytes()
    return ([int64]$bytes[0] -shl 24) -bor ([int64]$bytes[1] -shl 16) -bor ([int64]$bytes[2] -shl 8) -bor [int64]$bytes[3]
}

function ConvertFrom-OpenPathIPv4UInt32 {
    # converts an [int64] numeric IPv4 value (0..4294967295) back to dotted notation.
    param(
        [Parameter(Mandatory = $true)]
        [int64]$Value
    )

    $b0 = ($Value -shr 24) -band 0xFF
    $b1 = ($Value -shr 16) -band 0xFF
    $b2 = ($Value -shr 8) -band 0xFF
    $b3 = $Value -band 0xFF
    return "$b0.$b1.$b2.$b3"
}

function Get-OpenPathDnsEgressBlockRanges {
    <#
    .SYNOPSIS
        Returns the minimal set of IPv4 "start-end" ranges that cover the whole IPv4
        space EXCEPT loopback (127.0.0.0/8) and the supplied allow IPs.
    .DESCRIPTION
        Used to express a default-deny outbound DNS policy on a single port without
        also blocking the local Acrylic proxy or its configured upstreams. Windows
        Firewall evaluates Block over Allow, so a blanket "block all :53" would also
        kill Acrylic's upstream queries; instead we block everything except the
        loopback range and the explicit allow IPs (each a /32). IPv6 and non-IPv4
        entries in -AllowIps are ignored (IPv6 DNS is blocked wholesale elsewhere).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string[]]$AllowIps = @()
    )

    $min = [int64]0
    $max = [int64]4294967295

    $excluded = New-Object 'System.Collections.Generic.List[object]'
    # Loopback 127.0.0.0 - 127.255.255.255
    $excluded.Add([PSCustomObject]@{ Start = [int64]2130706432; End = [int64]2147483647 })

    foreach ($ip in @($AllowIps)) {
        $value = ConvertTo-OpenPathIPv4UInt32 -Address ([string]$ip)
        if ($null -ne $value) {
            $excluded.Add([PSCustomObject]@{ Start = [int64]$value; End = [int64]$value })
        }
    }

    $sorted = @($excluded | Sort-Object -Property Start)
    $merged = New-Object 'System.Collections.Generic.List[object]'
    foreach ($interval in $sorted) {
        if ($merged.Count -gt 0 -and $interval.Start -le ($merged[$merged.Count - 1].End + 1)) {
            if ($interval.End -gt $merged[$merged.Count - 1].End) {
                $merged[$merged.Count - 1].End = $interval.End
            }
        }
        else {
            $merged.Add([PSCustomObject]@{ Start = [int64]$interval.Start; End = [int64]$interval.End })
        }
    }

    $ranges = @()
    $cursor = $min
    foreach ($interval in $merged) {
        if ($interval.Start -gt $cursor) {
            $ranges += ('{0}-{1}' -f (ConvertFrom-OpenPathIPv4UInt32 -Value $cursor), (ConvertFrom-OpenPathIPv4UInt32 -Value ($interval.Start - 1)))
        }
        if (($interval.End + 1) -gt $cursor) {
            $cursor = $interval.End + 1
        }
    }
    if ($cursor -le $max) {
        $ranges += ('{0}-{1}' -f (ConvertFrom-OpenPathIPv4UInt32 -Value $cursor), (ConvertFrom-OpenPathIPv4UInt32 -Value $max))
    }

    return @($ranges)
}

function Get-OpenPathStudentEgressFloorRules {
    <#
    .SYNOPSIS
        Builds the rule descriptors of the user-scoped outbound egress floor.
    .DESCRIPTION
        PURE: returns descriptor objects only (no firewall cmdlets). The apply path sets
        each profile's DefaultOutboundAction to Block; these rules carve egress back out
        of it, scoped by the LocalUser security descriptor of the OpenPath-Restricted
        group (validated on a Windows 11 lab VM, 2026-11-03):

          * non-students (any token that is not in the group, including SYSTEM, services
            and kernel-attributed traffic) keep full egress;
          * students may only reach the network from the listed programs (approved
            browsers, the OpenPath native host, catalog apps marked network:true);
          * students' AppContainer (Store) apps are blocked explicitly, because the
            built-in "InternetClient Default Rule" would otherwise allow them. AppContainer
            tokens only match a LocalUser descriptor that also grants ALL APPLICATION
            PACKAGES (AC), hence the AC ACE;
          * ICMP, SMB and WebClient towards the Internet are blocked for everyone: that
            traffic is attributed to the kernel / a service and cannot be told apart by
            user, so it would otherwise tunnel student data.

        No rule allows Program 'System' (it would re-open ICMP for students).
    .OUTPUTS
        PSCustomObject[] rule descriptors.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$RestrictedSid,

        [AllowNull()]
        [string[]]$StudentPrograms = @(),

        [string]$RulePrefix = $script:RulePrefix
    )

    if ([string]$RestrictedSid -notmatch '^S-1-\d+(-\d+)+$') {
        throw "Student egress floor requires a SID for the restricted group (got '$RestrictedSid')"
    }

    $studentSddl = "D:(A;;CC;;;$RestrictedSid)"
    $nonStudentSddl = "D:(D;;CC;;;$RestrictedSid)(A;;CC;;;WD)"
    $rules = New-Object 'System.Collections.Generic.List[object]'

    $newRule = {
        param([hashtable]$Fields)
        $descriptor = [ordered]@{
            DisplayName   = $Fields.DisplayName
            Direction     = 'Outbound'
            Action        = $Fields.Action
            Protocol      = if ($Fields.Contains('Protocol')) { $Fields.Protocol } else { 'Any' }
            RemoteAddress = if ($Fields.Contains('RemoteAddress')) { $Fields.RemoteAddress } else { 'Any' }
            RemotePort    = if ($Fields.Contains('RemotePort')) { $Fields.RemotePort } else { 'Any' }
            Profile       = 'Any'
            Description   = $Fields.Description
        }
        foreach ($optional in @('Program', 'Package', 'Service', 'LocalUser')) {
            if ($Fields.Contains($optional)) { $descriptor[$optional] = $Fields[$optional] }
        }
        $rules.Add([PSCustomObject]$descriptor)
    }

    & $newRule @{ DisplayName = "$RulePrefix-Allow-EgressFloor-NonStudent"; Action = 'Allow'; LocalUser = $nonStudentSddl
        Description = 'Egress floor: users outside the restricted group keep full outbound access' }
    & $newRule @{ DisplayName = "$RulePrefix-Allow-EgressFloor-NonStudentAppContainers"; Action = 'Allow'; Package = '*'
        LocalUser = "$nonStudentSddl(A;;CC;;;AC)"
        Description = 'Egress floor: AppContainer apps of users outside the restricted group keep outbound access' }

    $seen = @{}
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        foreach ($program in @($StudentPrograms)) {
            $path = ([string]$program).Trim()
            if (-not $path -or $path -eq 'System') { continue }
            $key = $path.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($key))
            $hashPrefix = (($hash[0..3] | ForEach-Object { $_.ToString('x2') }) -join '')
            $stem = ([System.IO.Path]::GetFileNameWithoutExtension(($path -split '[\\/]')[-1])) -replace '[^0-9A-Za-z]', '-'
            & $newRule @{ DisplayName = "$RulePrefix-Allow-EgressFloor-Student-$stem-$hashPrefix"; Action = 'Allow'
                Program = $path; LocalUser = $studentSddl
                Description = "Egress floor: restricted users may reach the network from $path" }
        }
    }
    finally {
        $sha.Dispose()
    }

    & $newRule @{ DisplayName = "$RulePrefix-Allow-EgressFloor-Loopback"; Action = 'Allow'; RemoteAddress = '127.0.0.0/8'
        Description = 'Egress floor: IPv4 loopback stays allowed (IPv6 ::1 is WFP-exempt and rejected as a rule)' }
    & $newRule @{ DisplayName = "$RulePrefix-Block-EgressFloor-StudentAppContainers"; Action = 'Block'; Package = '*'
        LocalUser = "$studentSddl(A;;CC;;;AC)"
        Description = 'Egress floor: AppContainer apps of restricted users have no network' }
    & $newRule @{ DisplayName = "$RulePrefix-Block-EgressFloor-ICMPv4-Internet"; Action = 'Block'; Protocol = 'ICMPv4'; RemoteAddress = 'Internet'
        Description = 'Egress floor: ICMPv4 to the Internet is attributed to the kernel and cannot be scoped by user' }
    # Global unicast only: the Internet keyword also matches link-local multicast
    # (ff02::/16), which would cut MLD and neighbor discovery for every user.
    & $newRule @{ DisplayName = "$RulePrefix-Block-EgressFloor-ICMPv6-Internet"; Action = 'Block'; Protocol = 'ICMPv6'; RemoteAddress = '2000::/3'
        Description = 'Egress floor: ICMPv6 to global unicast is attributed to the kernel and cannot be scoped by user' }
    & $newRule @{ DisplayName = "$RulePrefix-Block-EgressFloor-SMB-Internet"; Action = 'Block'; Protocol = 'TCP'; RemotePort = @('139', '445'); RemoteAddress = 'Internet'
        Description = 'Egress floor: kernel SMB to the Internet cannot be scoped by user' }
    & $newRule @{ DisplayName = "$RulePrefix-Block-EgressFloor-WebClient-Internet"; Action = 'Block'; Service = 'WebClient'; RemoteAddress = 'Internet'
        Description = 'Egress floor: WebDAV (WebClient service) to the Internet would broker student egress' }

    return $rules.ToArray()
}

function Get-OpenPathStudentNetworkPrograms {
    <#
    .SYNOPSIS
        Absolute program paths from which restricted (student) users may reach the
        network under the user-scoped egress floor.
    .DESCRIPTION
        Approved browser executables (inventory identities marked IsApproved whose family
        is in ApprovedBrowsers), the OpenPath Firefox native host, and approval-catalog
        entries with network = $true. Only catalog Path identities under Program Files
        are honored; network = $true on any other identity is ignored with a WARN, never
        granted.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string[]]$ApprovedBrowsers = @(),

        [AllowNull()]
        [object]$BrowserInventory = $null,

        [AllowNull()]
        [object]$ApplicationCatalog = $null,

        [AllowNull()]
        [string]$OpenPathRoot
    )

    $resolvedRoot = $OpenPathRoot
    if ([string]::IsNullOrWhiteSpace($resolvedRoot)) {
        $resolvedRoot = if (Get-Command -Name 'Resolve-OpenPathWindowsRoot' -ErrorAction SilentlyContinue) { Resolve-OpenPathWindowsRoot } else { 'C:\OpenPath' }
    }
    $resolvedRoot = ([string]$resolvedRoot).TrimEnd('\')
    $programFiles = if ($env:ProgramFiles) { [string]$env:ProgramFiles } else { 'C:\Program Files' }

    $programs = New-Object 'System.Collections.Generic.List[string]'
    $approvedFamilies = @($ApprovedBrowsers | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })

    if ($null -eq $BrowserInventory -and (Get-Command -Name 'Get-OpenPathBrowserInventory' -ErrorAction SilentlyContinue)) {
        try { $BrowserInventory = Get-OpenPathBrowserInventory } catch { Write-OpenPathLog "Egress floor: browser inventory failed: $_" -Level WARN }
    }
    $browserCount = 0
    if ($null -ne $BrowserInventory -and $BrowserInventory.PSObject.Properties['ExecutableIdentities']) {
        foreach ($identity in @($BrowserInventory.ExecutableIdentities)) {
            if (-not $identity -or -not $identity.ExecutablePath -or -not $identity.IsApproved) { continue }
            if ($approvedFamilies -notcontains [string]$identity.Family) { continue }
            $programs.Add([string]$identity.ExecutablePath)
            $browserCount++
        }
    }
    if ($browserCount -eq 0) {
        Write-OpenPathLog "Egress floor: no approved student browser executable found ($($approvedFamilies -join ',')); students will have no browser egress until one is installed" -Level WARN
    }

    $programs.Add("$resolvedRoot\browser-extension\firefox\native\OpenPath-NativeHost.exe")

    if ($null -ne $ApplicationCatalog -and $ApplicationCatalog.PSObject.Properties['applications']) {
        foreach ($application in @($ApplicationCatalog.applications)) {
            if (-not $application -or -not $application.PSObject.Properties['network'] -or $application.network -ne $true) { continue }
            $applicationId = [string]$application.id
            $identity = $application.identity
            $type = if ($identity -and $identity.PSObject.Properties['type']) { [string]$identity.type } else { '' }
            $path = if ($identity -and $identity.PSObject.Properties['path']) { ([string]$identity.path).Trim() } else { '' }
            if ($type -ne 'Path') {
                Write-OpenPathLog "Egress floor: catalog entry '$applicationId' has network=true on a $type identity; only Path identities can be granted network (ignored)" -Level WARN
                continue
            }
            if (-not (Test-OpenPathProgramFilesCatalogPath -Path $path)) {
                Write-OpenPathLog "Egress floor: catalog entry '$applicationId' path is not an exact Program Files path; network not granted" -Level WARN
                continue
            }
            $programs.Add(($path -ireplace '^%PROGRAMFILES%', $programFiles))
        }
    }

    return @($programs | Select-Object -Unique)
}

function Resolve-OpenPathEgressFloorRestrictedSid {
    <#
    .SYNOPSIS
        SID of the OpenPath-Restricted local group; throws when it cannot be resolved.
    .DESCRIPTION
        Uses the AppControl resolver when it is loaded, otherwise looks the group up by
        name. Never falls back to BUILTIN\Users: the floor must not restrict accounts
        outside the configured OpenPath boundary.
    #>
    [CmdletBinding()]
    param()

    if (Get-Command -Name 'Get-OpenPathRestrictedGroupSid' -ErrorAction SilentlyContinue) {
        return [string](Get-OpenPathRestrictedGroupSid)
    }
    if (-not (Get-Command -Name 'Get-LocalGroup' -ErrorAction SilentlyContinue)) {
        throw 'OpenPath-Restricted group lookup capability is unavailable'
    }
    $group = Get-LocalGroup -Name 'OpenPath-Restricted' -ErrorAction Stop
    return [string]$group.SID.Value
}

function Set-OpenPathStudentEgressFloor {
    <#
    .SYNOPSIS
        Applies the user-scoped egress floor: rules from
        Get-OpenPathStudentEgressFloorRules plus DefaultOutboundAction Block.
    .DESCRIPTION
        FAIL-OPEN: when the restricted group SID cannot be resolved, or any rule or the
        profile change fails, the floor is torn down and the persisted pre-floor outbound
        default restored, so the device is never left at Block without the non-student
        Allow. Before flipping any profile to Block the apply verifies that the active
        policy already exposes the expected non-student Allow; if not, nothing is blocked
        and the invariant latch records the reason. The pre-floor default is captured once
        (Save-... never overwrites an existing state file, which also covers upgrades from
        the IP-set floor), and the previous floor rules -- including legacy
        -EgressFloor-Whitelist-*/-System-* rules -- are removed only after the replacement
        set exists, so a swap never leaves a window without an Allow.
    .OUTPUTS
        int -- rules created (0 == not applied / fail-open).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [AllowNull()]
        [string[]]$StudentPrograms = @(),

        [string]$RulePrefix = $script:RulePrefix
    )

    if (-not $PSCmdlet.ShouldProcess('Windows Firewall', 'Apply OpenPath user-scoped egress floor')) {
        return 0
    }

    $latch = Read-OpenPathEgressFloorInvariantLatch
    if ($latch) {
        Write-OpenPathLog "Egress floor: invariant latch is active ($($latch.Reason)); NOT applying the floor until an operator clears it" -Level WARN
        return 0
    }

    try {
        $restrictedSid = Resolve-OpenPathEgressFloorRestrictedSid
        $rules = @(Get-OpenPathStudentEgressFloorRules -RestrictedSid $restrictedSid -StudentPrograms $StudentPrograms -RulePrefix $RulePrefix)
    }
    catch {
        Write-OpenPathLog "Egress floor: restricted group unavailable ($_); NOT applying the floor (fail-open) and restoring the pre-floor outbound default" -Level WARN
        Remove-OpenPathEgressFloorRules -RulePrefix $RulePrefix -RestoreDefaultOutbound $true
        return 0
    }

    Save-OpenPathEgressFloorPreviousOutbound
    # Capture the existing floor rules instead of deleting them up front: the new
    # set is created first, so there is never a moment without a non-student Allow.
    $previousRules = @()
    if (Get-Command -Name 'Get-NetFirewallRule' -ErrorAction SilentlyContinue) {
        $previousRules = @(Get-NetFirewallRule -DisplayName "$RulePrefix-*-EgressFloor-*" -ErrorAction SilentlyContinue)
    }

    try {
        foreach ($rule in $rules) {
            $parameters = @{}
            foreach ($property in $rule.PSObject.Properties) {
                if ($null -ne $property.Value -and [string]$property.Value -ne '') { $parameters[$property.Name] = $property.Value }
            }
            New-OpenPathFirewallRule @parameters -ErrorAction Stop | Out-Null
        }

        # Precondition 5.5: never flip a profile to Block unless the active policy
        # already exposes an effective non-student Allow. Step 2 of the plan showed
        # that AllowLocalFirewallRules=False does not suppress local rules on a
        # workgroup Windows VM, so effectiveness is read from the active store.
        $precondition = Test-OpenPathStudentEgressFloorEffectiveNonStudentAllow -RestrictedSid $restrictedSid -RulePrefix $RulePrefix
        if (-not $precondition.Holds) {
            Write-OpenPathLog "Egress floor: effective non-student Allow precondition failed ($($precondition.Reason)); NOT applying Block (fail-open)" -Level WARN
            Set-OpenPathEgressFloorInvariantLatch -Reason ([string]$precondition.Reason)
            Remove-OpenPathEgressFloorRules -RulePrefix $RulePrefix -RestoreDefaultOutbound $true -ClearInvariantLatch:$false
            return 0
        }

        if (Get-Command -Name 'Set-NetFirewallProfile' -ErrorAction SilentlyContinue) {
            Set-NetFirewallProfile -Profile @(Get-OpenPathEgressFloorProfileNames) -DefaultOutboundAction Block -ErrorAction Stop
        }
    }
    catch {
        Write-OpenPathLog "Egress floor: apply failed ($_); tearing down and restoring the pre-floor outbound default" -Level ERROR
        Remove-OpenPathEgressFloorRules -RulePrefix $RulePrefix -RestoreDefaultOutbound $true
        return 0
    }

    if ($previousRules.Count -gt 0) {
        Remove-OpenPathFirewallRuleObjects -Rules $previousRules
    }

    try { Enable-OpenPathEgressFloorAudit } catch { Write-OpenPathLog "Egress floor: blocked-connection auditing not enabled: $_" -Level WARN }
    Write-OpenPathLog "Egress floor active: $($rules.Count) rules, $(@($StudentPrograms).Count) student network program(s), default outbound = Block" -Level WARN
    return $rules.Count
}

function Test-OpenPathStudentEgressFloorDrift {
    <#
    .SYNOPSIS
        Reports whether the installed user-scoped egress floor differs from the expected
        one (profile default, rule names, non-student scope).
    .OUTPUTS
        PSCustomObject -- Drifted (bool), Reason (string).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string[]]$StudentPrograms = @(),

        [string]$RulePrefix = $script:RulePrefix
    )

    $installedNames = @(Get-NetFirewallRule -DisplayName "$RulePrefix-*-EgressFloor-*" -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.DisplayName } | Sort-Object -Unique)
    $defaultsBlocked = @(foreach ($profileName in @(Get-OpenPathEgressFloorProfileNames)) {
            $profileObject = Get-NetFirewallProfile -Profile $profileName -ErrorAction SilentlyContinue
            [bool]($profileObject -and [string]$profileObject.DefaultOutboundAction -eq 'Block')
        })

    try {
        $restrictedSid = Resolve-OpenPathEgressFloorRestrictedSid
    }
    catch {
        $floorPresent = ($installedNames.Count -gt 0) -or ($defaultsBlocked -contains $true)
        return [PSCustomObject]@{ Drifted = $floorPresent; Reason = 'restricted-group-unresolved' }
    }

    if ($defaultsBlocked -contains $false) {
        return [PSCustomObject]@{ Drifted = $true; Reason = 'default-outbound-not-block' }
    }

    $expected = @(Get-OpenPathStudentEgressFloorRules -RestrictedSid $restrictedSid -StudentPrograms $StudentPrograms -RulePrefix $RulePrefix)
    $expectedNames = @($expected | ForEach-Object { [string]$_.DisplayName } | Sort-Object -Unique)
    if (($expectedNames -join '|') -ne ($installedNames -join '|')) {
        return [PSCustomObject]@{ Drifted = $true; Reason = 'rule-set-mismatch' }
    }

    $nonStudent = @($expected | Where-Object { $_.DisplayName -eq "$RulePrefix-Allow-EgressFloor-NonStudent" })[0]
    $installedRule = @(Get-NetFirewallRule -DisplayName $nonStudent.DisplayName -ErrorAction SilentlyContinue)[0]
    $installedScope = if ($installedRule) { @($installedRule | Get-NetFirewallSecurityFilter -ErrorAction SilentlyContinue)[0] } else { $null }
    if (-not $installedScope -or [string]$installedScope.LocalUser -ne [string]$nonStudent.LocalUser) {
        return [PSCustomObject]@{ Drifted = $true; Reason = 'nonstudent-scope-mismatch' }
    }

    return [PSCustomObject]@{ Drifted = $false; Reason = 'in-sync' }
}

function Get-OpenPathEgressFloorEffectiveProfileStates {
    <#
    .SYNOPSIS
        Effective DefaultOutboundAction of each governed firewall profile.
    .DESCRIPTION
        Reads the active policy store when the NetSecurity cmdlets expose it, and
        falls back to the cmdlet default otherwise. On Windows the active store is
        what the firewall enforces; the local store may still say something else.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string[]]$ProfileNames = @()
    )

    if ($null -eq $ProfileNames -or $ProfileNames.Count -eq 0) {
        $ProfileNames = @(Get-OpenPathEgressFloorProfileNames)
    }

    $command = Get-Command -Name 'Get-NetFirewallProfile' -ErrorAction SilentlyContinue
    $supportsPolicyStore = [bool]($command -and $command.Parameters.ContainsKey('PolicyStore'))

    $states = foreach ($profileName in @($ProfileNames)) {
        $profileObject = $null
        $source = 'default'
        if ($command) {
            try {
                $parameters = @{ Profile = $profileName; ErrorAction = 'Stop' }
                if ($supportsPolicyStore) { $parameters['PolicyStore'] = 'ActiveStore' }
                $profileObject = Get-NetFirewallProfile @parameters
                $source = if ($supportsPolicyStore) { 'active-store' } else { 'local-store' }
            }
            catch {
                $profileObject = $null
                try {
                    $profileObject = Get-NetFirewallProfile -Profile $profileName -ErrorAction Stop
                    $source = 'local-store'
                }
                catch {
                    $profileObject = $null
                    $source = 'unavailable'
                }
            }
        }
        else {
            $source = 'unavailable'
        }

        $action = 'Unknown'
        if ($profileObject -and $profileObject.PSObject.Properties['DefaultOutboundAction'] -and $profileObject.DefaultOutboundAction) {
            $action = [string]$profileObject.DefaultOutboundAction
        }
        [PSCustomObject]@{
            Name = [string]$profileName
            DefaultOutboundAction = $action
            Source = $source
        }
    }

    return @($states)
}

function Test-OpenPathStudentEgressFloorEffectiveNonStudentAllow {
    <#
    .SYNOPSIS
        True when the active policy contains an effective non-student Allow rule.
    .DESCRIPTION
        "Effective" means a rule with the expected display name that is visible in
        the active store, enabled, Action=Allow, Direction=Outbound, Profile=Any,
        and scoped to the expected LocalUser descriptor for the restricted SID.
        Any matching rule that satisfies all of those is enough (a reapply can
        briefly leave a stale duplicate next to the new rule).
    .OUTPUTS
        PSCustomObject -- Holds (bool), Reason (string).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RestrictedSid,

        [string]$RulePrefix = $script:RulePrefix
    )

    $expectedLocalUser = "D:(D;;CC;;;$RestrictedSid)(A;;CC;;;WD)"
    $ruleName = "$RulePrefix-Allow-EgressFloor-NonStudent"
    $ruleCommand = Get-Command -Name 'Get-NetFirewallRule' -ErrorAction SilentlyContinue
    if (-not $ruleCommand) {
        return [PSCustomObject]@{ Holds = $false; Reason = 'firewall-rule-query-unavailable' }
    }

    $supportsPolicyStore = [bool]$ruleCommand.Parameters.ContainsKey('PolicyStore')
    $parameters = @{ DisplayName = $ruleName; ErrorAction = 'SilentlyContinue' }
    if ($supportsPolicyStore) { $parameters['PolicyStore'] = 'ActiveStore' }
    $installedRules = @(Get-NetFirewallRule @parameters)
    if ($installedRules.Count -eq 0) {
        return [PSCustomObject]@{ Holds = $false; Reason = 'nonstudent-allow-missing' }
    }

    $scopeCommand = Get-Command -Name 'Get-NetFirewallSecurityFilter' -ErrorAction SilentlyContinue
    $reasons = New-Object 'System.Collections.Generic.List[string]'
    foreach ($installedRule in $installedRules) {
        if ($null -eq $installedRule) { continue }

        $enabled = if ($installedRule.PSObject.Properties['Enabled']) { [string]$installedRule.Enabled -eq 'True' } else { $false }
        if (-not $enabled) {
            if (-not $reasons.Contains('nonstudent-allow-disabled')) { $reasons.Add('nonstudent-allow-disabled') }
            continue
        }
        if ($installedRule.PSObject.Properties['Action'] -and [string]$installedRule.Action -ne 'Allow') {
            if (-not $reasons.Contains('nonstudent-allow-action-not-allow')) { $reasons.Add('nonstudent-allow-action-not-allow') }
            continue
        }
        if ($installedRule.PSObject.Properties['Direction'] -and [string]$installedRule.Direction -ne 'Outbound') {
            if (-not $reasons.Contains('nonstudent-allow-direction-not-outbound')) { $reasons.Add('nonstudent-allow-direction-not-outbound') }
            continue
        }
        if ($installedRule.PSObject.Properties['Profile'] -and $installedRule.Profile) {
            $profileText = [string]$installedRule.Profile
            if ($profileText -and $profileText -notin @('Any', 'NotConfigured')) {
                if (-not $reasons.Contains('nonstudent-allow-profile-not-any')) { $reasons.Add('nonstudent-allow-profile-not-any') }
                continue
            }
        }

        $scope = $null
        if ($scopeCommand) {
            $scopeParameters = @{ ErrorAction = 'SilentlyContinue' }
            if ($supportsPolicyStore -and $scopeCommand.Parameters.ContainsKey('PolicyStore')) {
                $scopeParameters['PolicyStore'] = 'ActiveStore'
            }
            $scope = @($installedRule | Get-NetFirewallSecurityFilter @scopeParameters)[0]
        }
        if (-not $scope) {
            if (-not $reasons.Contains('nonstudent-scope-unavailable')) { $reasons.Add('nonstudent-scope-unavailable') }
            continue
        }
        if ([string]$scope.LocalUser -ne $expectedLocalUser) {
            if (-not $reasons.Contains('nonstudent-scope-mismatch')) { $reasons.Add('nonstudent-scope-mismatch') }
            continue
        }

        return [PSCustomObject]@{ Holds = $true; Reason = 'effective-nonstudent-allow' }
    }

    $reason = if ($reasons.Count -gt 0) { $reasons[0] } else { 'nonstudent-allow-missing' }
    return [PSCustomObject]@{ Holds = $false; Reason = $reason }
}

function Test-OpenPathStudentEgressFloorInvariant {
    <#
    .SYNOPSIS
        Safety invariant: Block must never be active without an effective non-student Allow.
    .DESCRIPTION
        Reads the effective DefaultOutboundAction of Domain, Private and Public. When
        none is Block the invariant holds trivially. Otherwise the active policy must
        contain the expected non-student Allow (enabled, Allow, Outbound, expected
        LocalUser). Returns a stable reason string.
    .OUTPUTS
        PSCustomObject -- Holds (bool), Reason (string), BlockProfiles (string[]).
    #>
    [CmdletBinding()]
    param(
        [string]$RulePrefix = $script:RulePrefix
    )

    $profileStates = @(Get-OpenPathEgressFloorEffectiveProfileStates)
    $blockProfiles = @($profileStates | Where-Object { [string]$_.DefaultOutboundAction -eq 'Block' } | ForEach-Object { [string]$_.Name })
    if ($blockProfiles.Count -eq 0) {
        return [PSCustomObject]@{ Holds = $true; Reason = 'no-governed-profile-blocked'; BlockProfiles = @() }
    }

    try {
        $restrictedSid = Resolve-OpenPathEgressFloorRestrictedSid
    }
    catch {
        return [PSCustomObject]@{ Holds = $false; Reason = 'restricted-group-unresolved'; BlockProfiles = @($blockProfiles) }
    }

    $allow = Test-OpenPathStudentEgressFloorEffectiveNonStudentAllow -RestrictedSid $restrictedSid -RulePrefix $RulePrefix
    return [PSCustomObject]@{
        Holds = [bool]$allow.Holds
        Reason = [string]$allow.Reason
        BlockProfiles = @($blockProfiles)
    }
}

function Get-OpenPathEgressFloorInvariantLatchPath {
    <#
    .SYNOPSIS
        Path of the marker that stops the watchdog from reapplying a floor whose
        invariant already failed twice.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$OpenPathRoot
    )

    $resolvedRoot = $OpenPathRoot
    if ([string]::IsNullOrWhiteSpace($resolvedRoot)) {
        if ($script:OpenPathRoot) {
            $resolvedRoot = [string]$script:OpenPathRoot
        }
        elseif (Get-Command -Name 'Resolve-OpenPathWindowsRoot' -ErrorAction SilentlyContinue) {
            $resolvedRoot = Resolve-OpenPathWindowsRoot
        }
        else {
            $resolvedRoot = 'C:\OpenPath'
        }
    }
    $resolvedRoot = ([string]$resolvedRoot).TrimEnd('\', '/')
    return [System.IO.Path]::Combine($resolvedRoot, 'data', 'egress-floor-invariant-latch.json')
}

function Read-OpenPathEgressFloorInvariantLatch {
    <#
    .SYNOPSIS
        Reads the invariant latch, or $null when absent/invalid.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$OpenPathRoot
    )

    $path = Get-OpenPathEgressFloorInvariantLatchPath -OpenPathRoot $OpenPathRoot
    if (-not (Test-Path -LiteralPath $path)) { return $null }

    try {
        $parsed = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $parsed.PSObject.Properties['reason'] -or [string]::IsNullOrWhiteSpace([string]$parsed.reason)) {
            return $null
        }
        $createdAt = $null
        if ($parsed.PSObject.Properties['createdAtUtc'] -and $parsed.createdAtUtc) {
            if ($parsed.createdAtUtc -is [DateTimeOffset]) {
                $createdAt = [DateTimeOffset]$parsed.createdAtUtc
            }
            elseif ($parsed.createdAtUtc -is [DateTime]) {
                $createdAt = [DateTimeOffset]$parsed.createdAtUtc
            }
            else {
                $parsedTimestamp = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse(
                        [string]$parsed.createdAtUtc,
                        [System.Globalization.CultureInfo]::InvariantCulture,
                        [System.Globalization.DateTimeStyles]::RoundtripKind,
                        [ref]$parsedTimestamp)) {
                    $createdAt = $parsedTimestamp
                }
            }
        }
        return [PSCustomObject]@{
            Reason = [string]$parsed.reason
            CreatedAtUtc = $createdAt
            Path = $path
        }
    }
    catch {
        Write-OpenPathLog "Egress floor: ignoring unreadable invariant latch at ${path}: $_" -Level WARN
        return $null
    }
}

function Set-OpenPathEgressFloorInvariantLatch {
    <#
    .SYNOPSIS
        Persists the invariant latch (reason + culture-invariant UTC timestamp).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reason,

        [AllowNull()]
        [string]$OpenPathRoot
    )

    $path = Get-OpenPathEgressFloorInvariantLatchPath -OpenPathRoot $OpenPathRoot
    $payload = [ordered]@{
        reason = [string]$Reason
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }

    try {
        $directory = Split-Path -Parent $path
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        if (Get-Command -Name 'Write-OpenPathAtomicJsonFile' -ErrorAction SilentlyContinue) {
            Write-OpenPathAtomicJsonFile -Path $path -Data $payload -Depth 3
        }
        else {
            $payload | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $path -Encoding UTF8 -Force
        }
        Write-OpenPathLog "Egress floor: invariant latch written to ${path} (reason: $Reason)" -Level WARN
    }
    catch {
        Write-OpenPathLog "Egress floor: failed to write the invariant latch at ${path}: $_" -Level WARN
    }
}

function Clear-OpenPathEgressFloorInvariantLatch {
    <#
    .SYNOPSIS
        Removes the invariant latch (operator enable/update, flag off, or recovered precondition).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$OpenPathRoot
    )

    $path = Get-OpenPathEgressFloorInvariantLatchPath -OpenPathRoot $OpenPathRoot
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Get-OpenPathEgressFloorStudentProgramsFromConfig {
    <#
    .SYNOPSIS
        Student network programs for the egress floor, from an OpenPath config object
        (approvedStudentBrowsers, default Firefox; approvedApplicationCatalog).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Config,

        [AllowNull()]
        [string]$OpenPathRoot
    )

    $approvedBrowsers = @('Firefox')
    $catalog = $null
    if ($null -ne $Config) {
        if ($Config.PSObject.Properties['approvedStudentBrowsers'] -and @($Config.approvedStudentBrowsers).Count -gt 0) {
            $approvedBrowsers = @($Config.approvedStudentBrowsers | ForEach-Object { [string]$_ })
        }
        if ($Config.PSObject.Properties['approvedApplicationCatalog']) {
            $catalog = $Config.approvedApplicationCatalog
        }
    }

    return @(Get-OpenPathStudentNetworkPrograms -ApprovedBrowsers $approvedBrowsers -ApplicationCatalog $catalog -OpenPathRoot $OpenPathRoot)
}

$script:OpenPathFilteringPlatformConnectionAuditGuid = '{0CCE9226-69AE-11D9-BED3-505054503030}'

# Invoke-OpenPathAuditPol lives in Firewall.Teardown.ps1 (loaded before this file).

function Get-OpenPathAuditPolBackupLines {
    <#
    .SYNOPSIS
        Lines of `auditpol /backup` CSV (read from a temporary file that is then deleted).
    .DESCRIPTION
        `/backup` is the only auditpol output with the numeric "Setting Value" column;
        `/get /r` carries only the localized inclusion text.
    #>
    param()

    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-auditpol-" + [guid]::NewGuid().ToString('N') + '.csv')
    try {
        Invoke-OpenPathAuditPol -Arguments @('/backup', "/file:$path") | Out-Null
        if (-not (Test-Path -LiteralPath $path)) { return $null }
        return @(Get-Content -LiteralPath $path -ErrorAction Stop)
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function ConvertFrom-OpenPathAuditPolCsv {
    <#
    .SYNOPSIS
        Numeric "Setting Value" (0 none, 1 success, 2 failure, 3 both) of one
        subcategory from `auditpol /backup` CSV lines.
    .DESCRIPTION
        Selects the row by subcategory GUID and reads the LAST field (Setting Value),
        never header or setting text: auditpol localizes both (es-ES fleet), and a
        localized subcategory name may itself contain commas.
    #>
    param(
        [AllowNull()][string[]]$Lines,
        [Parameter(Mandatory = $true)][string]$SubcategoryGuid
    )

    foreach ($line in @($Lines | Select-Object -Skip 1)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $fields = @(([string]$line).Split(','))
        if (@($fields | Where-Object { $_.Trim() -eq $SubcategoryGuid }).Count -eq 0) { continue }
        $value = 0
        if ($fields.Count -ge 7 -and [int]::TryParse($fields[-1].Trim(), [ref]$value)) { return $value }
    }
    return $null
}

function Get-OpenPathEgressFloorAuditStatePath {
    param()
    $root = if ($script:OpenPathRoot) { [string]$script:OpenPathRoot } elseif (Get-Command -Name 'Resolve-OpenPathWindowsRoot' -ErrorAction SilentlyContinue) { Resolve-OpenPathWindowsRoot } else { 'C:\OpenPath' }
    return "$(([string]$root).TrimEnd('\'))\data\egress-floor-audit-prev.json"
}

function Set-OpenPathFilteringPlatformConnectionAudit {
    param([int]$SettingValue)
    $success = if ($SettingValue -band 1) { 'enable' } else { 'disable' }
    $failure = if ($SettingValue -band 2) { 'enable' } else { 'disable' }
    Invoke-OpenPathAuditPol -Arguments @('/set', "/subcategory:$script:OpenPathFilteringPlatformConnectionAuditGuid", "/success:$success", "/failure:$failure") | Out-Null
}

function Enable-OpenPathEgressFloorAudit {
    <#
    .SYNOPSIS
        Turns on failure auditing for "Filtering Platform Connection" (Security 5157 =
        blocked connection) so blocked student egress can be reported, recording the
        previous setting once so Disable-OpenPathEgressFloorAudit can restore it.
    #>
    [CmdletBinding()]
    param()

    $statePath = Get-OpenPathEgressFloorAuditStatePath
    $previous = $null
    if (Test-Path -LiteralPath $statePath) {
        try { $previous = [int]((Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json).settingValue) } catch { $previous = $null }
    }
    if ($null -eq $previous) {
        $previous = ConvertFrom-OpenPathAuditPolCsv -Lines (Get-OpenPathAuditPolBackupLines) -SubcategoryGuid $script:OpenPathFilteringPlatformConnectionAuditGuid
        if ($null -eq $previous) {
            Write-OpenPathLog 'Egress floor: could not read the Filtering Platform Connection audit setting; blocked-connection reporting unavailable' -Level WARN
            return
        }
        $directory = Split-Path -Parent $statePath
        if ($directory -and -not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
        Set-Content -LiteralPath $statePath -Value (ConvertTo-Json -InputObject ([ordered]@{ settingValue = $previous })) -Encoding UTF8 -Force
    }
    Set-OpenPathFilteringPlatformConnectionAudit -SettingValue ([int]$previous -bor 2)
}

function Disable-OpenPathEgressFloorAudit {
    <# Restores the audit setting recorded by Enable-OpenPathEgressFloorAudit (no-op when none). #>
    [CmdletBinding()]
    param()

    # The restore rule lives in Invoke-OpenPathFirewallAuditRestore (Firewall.Teardown.ps1).
    $restore = Invoke-OpenPathFirewallAuditRestore -StatePath (Get-OpenPathEgressFloorAuditStatePath)
    if ($restore.Error) {
        Write-OpenPathLog "Egress floor: could not restore the Filtering Platform Connection audit setting: $($restore.Error)" -Level WARN
    }
}

function Get-OpenPathEgressFloorBlockedConnections {
    <#
    .SYNOPSIS
        Blocked outbound connections (Security event 5157) since a point in time,
        grouped by application and destination; loopback excluded.
    .DESCRIPTION
        5157 carries no user SID. Under the floor, non-students are allowed everything,
        so an outbound block is student (or kernel) traffic.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][datetime]$Since)

    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Security'; Id = 5157; StartTime = $Since } -ErrorAction SilentlyContinue)
    $groups = @{}
    foreach ($event in $events) {
        $data = @{}
        foreach ($item in @(([xml]$event.ToXml()).Event.EventData.Data)) { $data[[string]$item.Name] = [string]$item.'#text' }
        if ($data['Direction'] -ne '%%14593') { continue }
        $destination = [string]$data['DestAddress']
        if ($destination -match '^(127\.|::1$)') { continue }
        $key = '{0}|{1}|{2}|{3}' -f $data['Application'], $destination, $data['DestPort'], $data['Protocol']
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [pscustomobject]@{ Application = $data['Application']; DestAddress = $destination; DestPort = $data['DestPort']; Protocol = $data['Protocol']; Count = 0; LastSeen = $event.TimeCreated }
        }
        $groups[$key].Count++
        if ($event.TimeCreated -gt $groups[$key].LastSeen) { $groups[$key].LastSeen = $event.TimeCreated }
    }
    return @($groups.Values | Sort-Object -Property Count -Descending)
}

function Format-OpenPathEgressFloorReport {
    <# One line per application: "<app>: <n> blocked (dest:port, ...)", busiest first. #>
    param([AllowNull()][object[]]$Connections = @())

    $byApplication = @($Connections | Where-Object { $_ } | Group-Object -Property Application)
    if ($byApplication.Count -eq 0) { return @('No blocked outbound connections recorded.') }
    $lines = foreach ($group in $byApplication) {
        $total = ($group.Group | Measure-Object -Property Count -Sum).Sum
        $destinations = @($group.Group | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'DestAddress'; Descending = $false } |
                Select-Object -First 5 | ForEach-Object { "$($_.DestAddress):$($_.DestPort)" })
        [pscustomobject]@{ Total = $total; Line = "$($group.Name): $total blocked ($($destinations -join ', '))" }
    }
    return @($lines | Sort-Object -Property Total -Descending | ForEach-Object Line)
}

function Get-OpenPathEgressFloorProfileNames {
    <#
    .SYNOPSIS
        W-1(b): the firewall profiles the egress floor governs. Outbound only --
        inbound (management/RDP/guest-agent) is never touched.
    #>
    [CmdletBinding()]
    param()
    return @('Domain', 'Private', 'Public')
}

function Get-OpenPathEgressFloorPreviousOutboundStatePath {
    <#
    .SYNOPSIS
        W-1(b): path of the JSON state file that records each profile's
        DefaultOutboundAction BEFORE the floor flipped it to Block, so disable/remove
        can restore the machine to exactly its pre-floor outbound default.
    .DESCRIPTION
        Lives next to the other OpenPath data-dir state files (<root>\data). The root is
        resolved the same way the rest of this module resolves it.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$OpenPathRoot
    )

    $resolvedRoot = $OpenPathRoot
    if ([string]::IsNullOrWhiteSpace($resolvedRoot)) {
        if ($script:OpenPathRoot) {
            $resolvedRoot = [string]$script:OpenPathRoot
        }
        elseif (Get-Command -Name 'Resolve-OpenPathWindowsRoot' -ErrorAction SilentlyContinue) {
            $resolvedRoot = Resolve-OpenPathWindowsRoot
        }
        else {
            $resolvedRoot = 'C:\OpenPath'
        }
    }
    $resolvedRoot = ([string]$resolvedRoot).TrimEnd('\')
    return "$resolvedRoot\data\egress-floor-prev-outbound.json"
}

function Save-OpenPathEgressFloorPreviousOutbound {
    <#
    .SYNOPSIS
        W-1(b): captures and PERSISTS each profile's current DefaultOutboundAction before
        the floor flips it to Block, so the original can be restored exactly on disable.
    .DESCRIPTION
        Reads Get-NetFirewallProfile for Domain/Private/Public and writes a JSON map of
        profile -> DefaultOutboundAction to the state file. Idempotent: if the state file
        already exists (a prior apply captured the genuine pre-floor default) it is NOT
        overwritten, so a re-apply or refresh that runs while the default is already Block
        cannot poison the saved baseline with "Block". Best-effort: a read/write failure
        is logged and swallowed (the apply still proceeds; restore then falls back to Allow).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [AllowNull()]
        [string]$StatePath
    )

    if ([string]::IsNullOrWhiteSpace($StatePath)) {
        $StatePath = Get-OpenPathEgressFloorPreviousOutboundStatePath
    }

    if (-not $PSCmdlet.ShouldProcess($StatePath, 'Persist pre-floor DefaultOutboundAction')) {
        return
    }

    try {
        if (Test-Path $StatePath) {
            # A genuine pre-floor baseline is already recorded; do not clobber it.
            return
        }
    }
    catch {
    }

    if (-not (Get-Command -Name 'Get-NetFirewallProfile' -ErrorAction SilentlyContinue)) {
        return
    }

    $previous = [ordered]@{}
    foreach ($profileName in @(Get-OpenPathEgressFloorProfileNames)) {
        $action = 'Allow'
        try {
            $profileObject = Get-NetFirewallProfile -Profile $profileName -ErrorAction Stop
            if ($null -ne $profileObject -and $profileObject.PSObject.Properties['DefaultOutboundAction'] -and $profileObject.DefaultOutboundAction) {
                $action = [string]$profileObject.DefaultOutboundAction
            }
        }
        catch {
            $action = 'Allow'
        }
        $previous[$profileName] = $action
    }

    try {
        $directory = Split-Path $StatePath -Parent
        if ($directory -match '^([A-Za-z]):[\\/]' -and -not (Get-PSDrive -Name $Matches[1] -ErrorAction SilentlyContinue)) {
            return
        }
        if ($directory -and -not (Test-Path $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $json = ConvertTo-Json -InputObject $previous -Depth 3
        Set-Content -Path $StatePath -Value $json -Encoding UTF8 -Force
        Write-OpenPathLog "Egress floor: saved pre-floor DefaultOutboundAction state to $StatePath"
    }
    catch {
        Write-OpenPathLog "Egress floor: failed to persist pre-floor DefaultOutboundAction state: $_" -Level WARN
    }
}

function Restore-OpenPathEgressFloorPreviousOutbound {
    <#
    .SYNOPSIS
        W-1(b): restores each profile's DefaultOutboundAction from the persisted pre-floor
        state (fallback Allow when no state is recorded) and deletes the state file.
    .DESCRIPTION
        The mirror of Save-OpenPathEgressFloorPreviousOutbound. Used on disable/remove and
        on the fail-open path. NEVER restores to Block: if the recorded value is missing,
        unreadable, or anything other than a recognized non-Block action, the profile is
        restored to Allow so an empty allow-set can never leave egress bricked. After a
        successful restore the state file is removed so the next apply re-captures a fresh
        genuine baseline.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [AllowNull()]
        [string]$StatePath
    )

    if ([string]::IsNullOrWhiteSpace($StatePath)) {
        $StatePath = Get-OpenPathEgressFloorPreviousOutboundStatePath
    }

    if (-not $PSCmdlet.ShouldProcess($StatePath, 'Restore pre-floor DefaultOutboundAction')) {
        return
    }

    # The restore rule (never Block; recorded Allow/NotConfigured honoured; no usable state
    # means every profile to Allow) lives in Invoke-OpenPathFirewallOutboundRestore
    # (Firewall.Teardown.ps1).
    $restore = Invoke-OpenPathFirewallOutboundRestore -StatePath $StatePath -WhenNoState AllProfiles -RemoveState
    if ($restore.StateUnreadable) {
        Write-OpenPathLog "Egress floor: pre-floor DefaultOutboundAction state unreadable; restoring profiles to Allow. $($restore.StateError)" -Level WARN
    }
    foreach ($restoreError in @($restore.Errors)) {
        Write-OpenPathLog "Egress floor: failed restoring $restoreError" -Level WARN
    }
    if (Get-Command -Name 'Set-NetFirewallProfile' -ErrorAction SilentlyContinue) {
        Write-OpenPathLog 'Egress floor: restored DefaultOutboundAction from pre-floor state (fallback Allow)'
    }
}

function Remove-OpenPathEgressFloorRules {
    <#
    .SYNOPSIS
        W-1(b): the disable/teardown path for the egress floor -- restores each profile's
        DefaultOutboundAction from the persisted pre-floor state (fallback Allow) and
        removes the "$RulePrefix-*-EgressFloor-*" Allow rules.
    .DESCRIPTION
        Under the DefaultOutboundAction-Block model, removing the Allow rules WITHOUT
        first restoring the default would brick every outbound connection (the default is
        still Block, and nothing carves egress out of it). So the full teardown
        FIRST restores the default outbound action via
        Restore-OpenPathEgressFloorPreviousOutbound (which also deletes the state file),
        THEN removes the floor Allow rules. Every floor rule carries the
        "$RulePrefix-*-EgressFloor-*" display-name shape, so we target exactly those.

        -RestoreDefaultOutbound (default $true) restores the profile default. The
        idempotent rule-swap inside Set-OpenPathStudentEgressFloor (which is about to set
        the default to Block and re-create the Allow rules) calls this with
        -RestoreDefaultOutbound:$false so it does NOT churn the profile default or delete
        the still-valid pre-floor baseline mid-apply.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$RulePrefix = $script:RulePrefix,
        [bool]$RestoreDefaultOutbound = $true,
        [bool]$ClearInvariantLatch = $true
    )

    if (-not $PSCmdlet.ShouldProcess('Windows Firewall', 'Remove OpenPath egress-floor rules')) {
        return
    }

    if ($RestoreDefaultOutbound) {
        Restore-OpenPathEgressFloorPreviousOutbound
        Disable-OpenPathEgressFloorAudit
    }

    if (-not (Get-Command -Name 'Get-NetFirewallRule' -ErrorAction SilentlyContinue)) {
        if ($ClearInvariantLatch) { Clear-OpenPathEgressFloorInvariantLatch }
        return
    }

    Remove-OpenPathFirewallRuleObjects -Rules @(Get-NetFirewallRule -DisplayName "$RulePrefix-*-EgressFloor-*" -ErrorAction SilentlyContinue)
    if ($ClearInvariantLatch) { Clear-OpenPathEgressFloorInvariantLatch }
}

function Add-OpenPathCaptivePortalUpstreamFirewallAllow {
    <#
    .SYNOPSIS
        Allows Acrylic to reach the captive-portal upstream DNS (the network's DHCP
        resolver) through the anti-bypass firewall.
    .DESCRIPTION
        OpenPath's outbound DNS firewall only permits Acrylic to talk to the
        configured primary/secondary upstream. When a captive portal requires
        forwarding the admin-declared portal domains to the network's own resolver,
        Acrylic's queries to that resolver are otherwise dropped, so the portal never
        resolves. This adds an additive allow rule (port 53, scoped to Acrylic) for
        the portal upstream. Rules use the OpenPath-DNS prefix, so the firewall
        rebuild on protected-mode restore removes them automatically -- the allow is
        only in effect during the captive-portal window. The adapter stays on
        127.0.0.1 and unmatched domains are denied by the upstream policy (no fail-open).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)][string]$Address,
        [string]$AcrylicPath = "${env:ProgramFiles(x86)}\Acrylic DNS Proxy"
    )

    if (-not (Test-OpenPathFirewallIpAddress -Address $Address)) {
        Write-OpenPathLog "Captive portal upstream firewall allow skipped: invalid address '$Address'" -Level WARN
        return $false
    }
    if (-not (Test-AdminPrivileges)) {
        Write-OpenPathLog 'Administrator privileges required for captive portal upstream firewall allow' -Level WARN
        return $false
    }
    if (-not $PSCmdlet.ShouldProcess('Windows Firewall', "Allow Acrylic to reach captive portal upstream $Address")) {
        return $false
    }

    $acrylicExe = "$AcrylicPath\AcrylicService.exe"
    foreach ($protocol in @('UDP', 'TCP')) {
        $name = "$script:RulePrefix-Allow-PortalUpstream-$protocol"
        Remove-OpenPathFirewallRuleObjects -Rules @(Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)

        $ruleParameters = @{
            DisplayName   = $name
            Direction     = 'Outbound'
            Protocol      = $protocol
            RemoteAddress = $Address
            RemotePort    = 53
            Action        = 'Allow'
            Profile       = 'Any'
            Description   = "Allow Acrylic to reach captive portal upstream $Address over $protocol"
        }
        if (Test-Path $acrylicExe) { $ruleParameters['Program'] = $acrylicExe }
        New-OpenPathFirewallRule @ruleParameters | Out-Null
    }
    Write-OpenPathLog "Captive portal upstream firewall allow set for $Address"
    return $true
}

function Split-OpenPathResolverIpsByUpstream {
    <#
    .SYNOPSIS
        Validates resolver IPs and splits them into upstream resolvers and the rest.
    .DESCRIPTION
        Upstream resolvers stay reachable for Acrylic, so they are blocked per bypass
        client program; every other resolver is blocked for everyone. Invalid entries
        are logged and dropped so one bad value cannot fail a whole grouped rule.
    #>
    param(
        [object[]]$ResolverIps = @(),
        [object[]]$UpstreamIps = @()
    )

    $upstreamSet = @($UpstreamIps | Where-Object { $_ } | ForEach-Object { ([string]$_).Trim() })
    $upstream = [System.Collections.Generic.List[string]]::new()
    $other = [System.Collections.Generic.List[string]]::new()
    foreach ($resolverIp in (@($ResolverIps) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Sort-Object -Unique)) {
        if (-not (Test-OpenPathFirewallIpAddress -Address $resolverIp)) {
            Write-OpenPathLog "Skipping invalid DNS resolver IP: $resolverIp" -Level WARN
            continue
        }
        if ($upstreamSet -contains $resolverIp) { $upstream.Add($resolverIp) } else { $other.Add($resolverIp) }
    }
    return [PSCustomObject]@{
        Upstream = [string[]]$upstream.ToArray()
        Other = [string[]]$other.ToArray()
    }
}

function Set-OpenPathFirewall {
    <#
    .SYNOPSIS
        Configures Windows Firewall to block external DNS and VPNs
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$UpstreamDNS = '8.8.8.8',
        [string]$AcrylicPath = "${env:ProgramFiles(x86)}\Acrylic DNS Proxy"
    )

    if (-not (Test-AdminPrivileges)) {
        Write-OpenPathLog 'Administrator privileges required for firewall configuration' -Level ERROR
        return $false
    }

    if (-not $PSCmdlet.ShouldProcess('Windows Firewall', 'Configure OpenPath firewall rules')) {
        return $false
    }

    Write-OpenPathLog 'Configuring Windows Firewall...'
    Remove-OpenPathFirewall

    # One manifest write for the whole apply instead of one per rule: Add-... only buffers
    # while this batch is active, and the finally writes the sorted names once.
    $ownsFirewallManifestBatch = Start-OpenPathFirewallManifestBatch
    try {
        $secondaryDns = '8.8.4.4'
        $declaredPortalDomains = @()
        $enableKnownDnsIpBlocking = $true
        $enableDohIpBlocking = $true
        $dnsEgressDefaultDeny = $true
        $blockInboundDns = $true
        # User-scoped outbound egress floor (docs/windows-egress-floor.md). DEFAULT OFF.
        $outboundEgressFloorEnabled = $false
        $egressFloorConfig = $null
        $dohResolvers = Get-DefaultDohResolverIps
        $resolverBypassClients = Get-DefaultResolverBypassClientPrograms
        $vpnPorts = Get-DefaultVpnBlockRules
        $torPorts = Get-DefaultTorBlockPorts

        try {
            $config = Get-OpenPathConfig
            if ($config.PSObject.Properties['enableKnownDnsIpBlocking']) {
                $enableKnownDnsIpBlocking = [bool]$config.enableKnownDnsIpBlocking
            }
            if ($config.PSObject.Properties['enableDohIpBlocking']) {
                $enableDohIpBlocking = [bool]$config.enableDohIpBlocking
            }
            if ($config.PSObject.Properties['dnsEgressDefaultDeny']) {
                $dnsEgressDefaultDeny = [bool]$config.dnsEgressDefaultDeny
            }
            if ($config.PSObject.Properties['blockInboundDns']) {
                $blockInboundDns = [bool]$config.blockInboundDns
            }
            if ($config.PSObject.Properties['outboundEgressFloorEnabled']) {
                $outboundEgressFloorEnabled = [bool]$config.outboundEgressFloorEnabled
            }
            $egressFloorConfig = $config
            foreach ($obsoleteKey in @('outboundEgressFloorAllowIps', 'outboundEgressFloorSystemPrograms')) {
                if ($config.PSObject.Properties[$obsoleteKey]) {
                    Write-OpenPathLog "obsolete egress floor key $obsoleteKey ignored (the egress floor is user-scoped and no longer uses IP or system-program lists)" -Level WARN
                }
            }
            if ($config.PSObject.Properties['dohResolverIps'] -and $config.dohResolverIps) {
                $configuredResolvers = @($config.dohResolverIps | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() })
                if ($configuredResolvers.Count -gt 0) {
                    $dohResolvers = $configuredResolvers
                }
            }
            if ($config.PSObject.Properties['vpnBlockRules'] -and $config.vpnBlockRules) {
                $configuredVpnRules = @()
                foreach ($rule in @($config.vpnBlockRules)) {
                    try {
                        $protocol = ''
                        $port = 0
                        $name = ''

                        if ($rule -is [string]) {
                            $parts = @($rule -split ':', 3)
                            if ($parts.Count -lt 2) { continue }
                            $protocol = [string]$parts[0]
                            $port = [int]$parts[1]
                            if ($parts.Count -ge 3) { $name = [string]$parts[2] }
                        }
                        else {
                            $protocol = if ($rule.PSObject.Properties['Protocol']) { [string]$rule.Protocol } else { '' }
                            $port = if ($rule.PSObject.Properties['Port']) { [int]$rule.Port } else { 0 }
                            $name = if ($rule.PSObject.Properties['Name']) { [string]$rule.Name } else { '' }
                        }

                        $protocolUpper = $protocol.Trim().ToUpperInvariant()
                        if ($protocolUpper -notin @('TCP', 'UDP')) { continue }
                        if ($port -lt 1 -or $port -gt 65535) { continue }
                        if (-not $name) { $name = "VPN-$protocolUpper-$port" }

                        $configuredVpnRules += [PSCustomObject]@{
                            Protocol = $protocolUpper
                            Port     = $port
                            Name     = $name
                        }
                    }
                    catch {
                        continue
                    }
                }

                if ($configuredVpnRules.Count -gt 0) {
                    $vpnPorts = $configuredVpnRules
                }
            }

            if ($config.PSObject.Properties['torBlockPorts'] -and $config.torBlockPorts) {
                $configuredTorPorts = @()
                foreach ($torPort in @($config.torBlockPorts)) {
                    try {
                        $candidatePort = [int]$torPort
                        if ($candidatePort -ge 1 -and $candidatePort -le 65535) {
                            $configuredTorPorts += $candidatePort
                        }
                    }
                    catch {
                        continue
                    }
                }

                if ($configuredTorPorts.Count -gt 0) {
                    $torPorts = @($configuredTorPorts | Sort-Object -Unique)
                }
            }

            if ($config.PSObject.Properties['captivePortalDomains'] -and $config.captivePortalDomains) {
                $declaredPortalDomains = @($config.captivePortalDomains | Where-Object { $_ })
            }
        }
        catch {
        }

        # Permanent split DNS: Acrylic must be able to reach the network's DHCP
        # resolvers for the declared captive-portal domains in normal protected
        # mode, not only during the legacy limited-mode window.
        $portalUpstreams = @()
        if ($declaredPortalDomains.Count -gt 0 -and (Get-Command -Name 'Get-OpenPathSplitDnsPortalUpstreams' -ErrorAction SilentlyContinue)) {
            try {
                $portalUpstreams = @(Get-OpenPathSplitDnsPortalUpstreams -ExcludeAddresses @($UpstreamDNS, $secondaryDns))
            }
            catch {
                $portalUpstreams = @()
            }
        }

        New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Allow-Loopback-UDP" `
            -Direction Outbound -Protocol UDP -RemoteAddress 127.0.0.1 -RemotePort 53 `
            -Action Allow -Profile Any -Description 'Allow DNS to local Acrylic DNS Proxy' | Out-Null

        New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Allow-Loopback-TCP" `
            -Direction Outbound -Protocol TCP -RemoteAddress 127.0.0.1 -RemotePort 53 `
            -Action Allow -Profile Any -Description 'Allow DNS to local Acrylic DNS Proxy (TCP)' | Out-Null

        $acrylicExe = "$AcrylicPath\AcrylicService.exe"
        if (Test-Path $acrylicExe) {
            $allowTargets = @(
                [PSCustomObject]@{ Name = 'Upstream'; Address = $UpstreamDNS },
                [PSCustomObject]@{ Name = 'Secondary'; Address = $secondaryDns }
            )
            $portalUpstreamIndex = 0
            foreach ($portalUpstream in @($portalUpstreams)) {
                $portalUpstreamIndex++
                $allowTargets += [PSCustomObject]@{ Name = "PortalUpstream$portalUpstreamIndex"; Address = [string]$portalUpstream }
            }

            foreach ($target in $allowTargets) {
                if (-not (Test-OpenPathFirewallIpAddress -Address $target.Address)) { continue }

                foreach ($protocol in @('UDP', 'TCP')) {
                    New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Allow-$($target.Name)-$protocol" `
                        -Direction Outbound -Protocol $protocol -RemoteAddress $target.Address -RemotePort 53 `
                        -Action Allow -Program $acrylicExe -Profile Any `
                        -Description "Allow Acrylic to reach $($target.Name.ToLowerInvariant()) DNS over $protocol" | Out-Null
                }
            }
        }

        # One rule per protocol for all resolver IPs (plus one per bypass client for the
        # resolvers that are also our upstream) instead of one rule per IP: each
        # New-NetFirewallRule costs ~0.5 s on classroom laptops, and ~140 single-IP
        # rules held the update cycle (and every queued unblock) for over a minute.
        $resolverSplit = Split-OpenPathResolverIpsByUpstream -ResolverIps $dohResolvers -UpstreamIps @($UpstreamDNS, $secondaryDns)

        if ($enableKnownDnsIpBlocking) {
            $dns53RuleCount = 0
            foreach ($protocol in @('TCP', 'UDP')) {
                if ($resolverSplit.Other.Count -gt 0) {
                    New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-Known-DNS-$protocol-53" `
                        -Direction Outbound -Protocol $protocol -RemoteAddress $resolverSplit.Other -RemotePort 53 `
                        -Action Block -Profile Any `
                        -Description "Block direct DNS bypass to $($resolverSplit.Other.Count) known resolvers over $protocol/53" | Out-Null
                    $dns53RuleCount++
                }
                if ($resolverSplit.Upstream.Count -gt 0) {
                    foreach ($clientProgram in @($resolverBypassClients)) {
                        $clientId = ([System.IO.Path]::GetFileNameWithoutExtension($clientProgram)) -replace '[^0-9A-Za-z]', '-'
                        New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-Known-DNS-Upstream-$clientId-$protocol-53" `
                            -Direction Outbound -Protocol $protocol -RemoteAddress $resolverSplit.Upstream -RemotePort 53 `
                            -Action Block -Program $clientProgram -Profile Any `
                            -Description "Block direct DNS bypass from $clientProgram to the upstream resolvers over $protocol/53" | Out-Null
                        $dns53RuleCount++
                    }
                }
            }

            Write-OpenPathLog "Added $dns53RuleCount direct DNS bypass block rules"
        }
        else {
            Write-OpenPathLog 'Known DNS IP blocking disabled by configuration' -Level WARN
        }

        if ($dnsEgressDefaultDeny) {
            $egressAllowIps = @('127.0.0.1', $UpstreamDNS, $secondaryDns)
            foreach ($portalUpstream in @($portalUpstreams)) { $egressAllowIps += [string]$portalUpstream }
            $egressAllowIps = @($egressAllowIps | Where-Object { Test-OpenPathFirewallIpAddress -Address $_ } | Sort-Object -Unique)
            $egressBlockRanges = @(Get-OpenPathDnsEgressBlockRanges -AllowIps $egressAllowIps)

            if ($egressBlockRanges.Count -gt 0) {
                foreach ($protocol in @('UDP', 'TCP')) {
                    New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-DefaultDeny-DNS-$protocol-53" `
                        -Direction Outbound -Protocol $protocol -RemoteAddress $egressBlockRanges -RemotePort 53 `
                        -Action Block -Profile Any `
                        -Description "Default-deny outbound DNS over $protocol/53 except local Acrylic and configured upstreams" | Out-Null
                }
            }

            # IPv6 DNS has no local Acrylic listener (IPv6 binding disabled), so block it
            # wholesale. New-NetFirewallRule REJECTS the '::/0' all-IPv6 prefix with "One
            # or more of the address prefixes is invalid" (prefix length 0 is not allowed
            # -- confirmed on the real Windows box), which previously aborted the entire
            # firewall configuration mid-apply. Express all-IPv6 as the two valid /1
            # halves (the standard /0 workaround). A wildcard "Any" would also match IPv4
            # and override the upstream-DNS carve-out above, so this must stay IPv6-scoped.
            foreach ($protocol in @('UDP', 'TCP')) {
                New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-DefaultDeny-DNS6-$protocol-53" `
                    -Direction Outbound -Protocol $protocol -RemoteAddress @('::/1', '8000::/1') -RemotePort 53 `
                    -Action Block -Profile Any `
                    -Description "Default-deny outbound IPv6 DNS over $protocol/53" | Out-Null
            }

            Write-OpenPathLog "Default-deny DNS egress active ($($egressBlockRanges.Count) IPv4 block ranges)"
        }
        else {
            Write-OpenPathLog 'Default-deny DNS egress disabled by configuration' -Level WARN
        }

        if ($blockInboundDns) {
            foreach ($protocol in @('UDP', 'TCP')) {
                New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-Inbound-DNS-$protocol-53" `
                    -Direction Inbound -Protocol $protocol -LocalPort 53 -Action Block -Profile Any `
                    -Description "Block inbound DNS over $protocol/53 so the host never answers LAN or guest-VM queries" | Out-Null
            }
        }

        if ($outboundEgressFloorEnabled) {
            # Students (OpenPath-Restricted) reach the network only from approved
            # browsers, the native host and catalog apps marked network:true; everyone
            # else keeps full egress. Fails open when the group cannot be resolved.
            $studentNetworkPrograms = @(Get-OpenPathEgressFloorStudentProgramsFromConfig -Config $egressFloorConfig)
            $egressFloorRuleCount = Set-OpenPathStudentEgressFloor -StudentPrograms $studentNetworkPrograms
            Write-OpenPathLog "Outbound egress floor configured ($egressFloorRuleCount rules applied; 0 == fail-open)" -Level WARN
        }
        else {
            # Remove-OpenPathFirewall above already restored the pre-floor default and
            # removed any floor rules recorded in the manifest.
            Write-OpenPathLog 'Outbound egress floor disabled by configuration (default)'
        }

        New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-DoT" `
            -Direction Outbound -Protocol TCP -RemotePort 853 -Action Block -Profile Any `
            -Description 'Block DNS-over-TLS to prevent bypass' | Out-Null

        if ($enableDohIpBlocking) {
            $dohRuleCount = 0
            foreach ($protocol in @('TCP', 'UDP')) {
                if ($resolverSplit.Other.Count -gt 0) {
                    New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-DoH-$($protocol)443" `
                        -Direction Outbound -Protocol $protocol -RemoteAddress $resolverSplit.Other -RemotePort 443 `
                        -Action Block -Profile Any -Description "Block $($resolverSplit.Other.Count) DoH resolvers over $protocol/443" | Out-Null
                    $dohRuleCount++
                }
                if ($resolverSplit.Upstream.Count -gt 0) {
                    foreach ($clientProgram in @($resolverBypassClients)) {
                        $clientId = ([System.IO.Path]::GetFileNameWithoutExtension($clientProgram)) -replace '[^0-9A-Za-z]', '-'
                        New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-DoH-Upstream-$clientId-$($protocol)443" `
                            -Direction Outbound -Protocol $protocol -RemoteAddress $resolverSplit.Upstream -RemotePort 443 `
                            -Action Block -Program $clientProgram -Profile Any -Description "Block the upstream DoH resolvers from $clientProgram over $protocol/443" | Out-Null
                        $dohRuleCount++
                    }
                }
            }

            Write-OpenPathLog "Added $dohRuleCount DoH egress block rules"
        }
        else {
            Write-OpenPathLog 'DoH IP blocking disabled by configuration' -Level WARN
        }

        foreach ($vpn in @($vpnPorts)) {
            $vpnProtocol = ([string]$vpn.Protocol).Trim().ToUpperInvariant()
            $vpnPort = [int]$vpn.Port
            $vpnName = [string]$vpn.Name

            if ($vpnProtocol -notin @('TCP', 'UDP')) {
                Write-OpenPathLog "Skipping invalid VPN protocol in rule: $vpnProtocol" -Level WARN
                continue
            }
            if ($vpnPort -lt 1 -or $vpnPort -gt 65535) {
                Write-OpenPathLog "Skipping invalid VPN port in rule: $vpnPort" -Level WARN
                continue
            }
            if (-not $vpnName) { $vpnName = "VPN-$vpnProtocol-$vpnPort" }

            New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-VPN-$vpnName" `
                -Direction Outbound -Protocol $vpnProtocol -RemotePort $vpnPort -Action Block `
                -Profile Any -Description "Block $vpnName VPN traffic" | Out-Null
        }

        foreach ($port in @($torPorts)) {
            New-OpenPathFirewallRule -DisplayName "$script:RulePrefix-Block-Tor-$port" `
                -Direction Outbound -Protocol TCP -RemotePort $port -Action Block -Profile Any `
                -Description "Block Tor traffic on port $port" | Out-Null
        }

        Write-OpenPathLog 'Windows Firewall configured successfully'
        return $true
    }
    catch {
        Write-OpenPathLog "Failed to configure firewall: $_" -Level ERROR
        return $false
    }
    finally {
        if ($ownsFirewallManifestBatch) {
            Complete-OpenPathFirewallManifestBatch
        }
    }
}
