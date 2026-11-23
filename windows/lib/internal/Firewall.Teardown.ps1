# Firewall teardown: the single owner of how OpenPath's firewall state is reverted
# (the egress-floor outbound default, the Filtering Platform Connection audit
# setting and the OpenPath-owned rules). Dependency-free leaf: it calls no OpenPath
# function it does not define and never logs. Failures are returned to the caller,
# which chooses an error policy and writes its own messages. Dot-sourced by
# Firewall.psm1, the installer cleanup helper and the standalone uninstaller.

function ConvertTo-OpenPathFirewallManifestRuleNames {
    param([object]$Value)

    $names = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Value)) {
        if ($null -eq $item) { continue }

        $text = [string]$item
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        foreach ($name in @($text -split '\s+' | Where-Object { $_ })) {
            [void]$names.Add([string]$name)
        }
    }

    return @($names | Sort-Object -Unique)
}

function Read-OpenPathFirewallManifestRuleNames {
    <#
    .SYNOPSIS
        Reads the firewall-rules.json manifest. Returns Names (string[]) and Error (empty when
        the file was read or is missing; the parse error text when it is unreadable).
    #>
    param([Parameter(Mandatory = $true)][string]$Path)

    $result = [PSCustomObject]@{
        Names = [string[]]@()
        Error = ''
    }
    if (-not (Test-Path $Path)) { return $result }

    try {
        $parsed = Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $result.Names = [string[]]@(ConvertTo-OpenPathFirewallManifestRuleNames -Value $parsed)
    }
    catch {
        $result.Error = [string]$_
    }

    return $result
}

function Get-OpenPathFirewallTeardownProfileNames {
    # The profiles the egress floor governs (outbound only).
    return @('Domain', 'Private', 'Public')
}

function Get-OpenPathFirewallOutboundRestorePlan {
    <#
    .SYNOPSIS
        Pure decision: which profiles get which DefaultOutboundAction on teardown.
    .DESCRIPTION
        With a usable state file every profile is planned: a recorded Allow or NotConfigured is
        honoured, anything else (missing, Block, garbage) becomes Allow. Without one,
        AllProfiles sets every profile to Allow and OnlyBlocked only the profiles whose current
        action is Block. The plan never contains Block.
    #>
    param(
        [hashtable]$RecordedActions = @{},
        [hashtable]$CurrentActions = @{},
        [bool]$HasState = $false,
        [ValidateSet('AllProfiles', 'OnlyBlocked')][string]$WhenNoState = 'AllProfiles'
    )

    if ($null -eq $RecordedActions) { $RecordedActions = @{} }
    if ($null -eq $CurrentActions) { $CurrentActions = @{} }

    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($profileName in @(Get-OpenPathFirewallTeardownProfileNames)) {
        if (-not $HasState -and $WhenNoState -eq 'OnlyBlocked') {
            if ([string]$CurrentActions[$profileName] -ne 'Block') { continue }
        }

        # Brick-guard: never restore Block, even when a damaged state file records it.
        $action = 'Allow'
        if ($HasState -and $RecordedActions.ContainsKey($profileName)) {
            $candidate = [string]$RecordedActions[$profileName]
            if ($candidate -in @('Allow', 'NotConfigured')) {
                $action = $candidate
            }
        }
        $plan.Add([PSCustomObject]@{ Profile = $profileName; Action = $action })
    }

    return @($plan)
}

function Read-OpenPathFirewallOutboundState {
    # Returns HasState, Unreadable, Recorded (profile -> action) and Error for the
    # pre-floor outbound state file. Empty, cut or zero-filled files are unreadable.
    param([Parameter(Mandatory = $true)][string]$StatePath)

    $state = [PSCustomObject]@{
        HasState = $false
        Unreadable = $false
        Recorded = @{}
        Error = ''
    }
    if (-not (Test-Path $StatePath)) { return $state }

    try {
        # Read line-wise and re-join rather than -Raw: equivalent for a small JSON file
        # and avoids a Pester mock-binding quirk around the -Raw parameter set in tests.
        $stateText = (Get-Content $StatePath -ErrorAction Stop) -join "`n"
        if ([string]::IsNullOrWhiteSpace(([string]$stateText).Replace([string][char]0, ''))) {
            throw "state file $StatePath is empty"
        }
        $parsed = $stateText | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $parsed) { throw "state file $StatePath holds no JSON value" }
        foreach ($property in $parsed.PSObject.Properties) {
            $state.Recorded[$property.Name] = [string]$property.Value
        }
        $state.HasState = $true
    }
    catch {
        $state.Unreadable = $true
        $state.Recorded = @{}
        $state.Error = [string]$_
    }

    return $state
}

function Invoke-OpenPathFirewallOutboundRestore {
    <#
    .SYNOPSIS
        Restores each profile's DefaultOutboundAction from the pre-floor state file (see
        Get-OpenPathFirewallOutboundRestorePlan for the rule).
    .DESCRIPTION
        Returns Applied (plan entries that were set), StateUnreadable, StateError and Errors (one
        per failing profile; the other profiles are still applied). With -RemoveState the state
        file is deleted afterwards. Returns at once, touching nothing, when
        Set-NetFirewallProfile is unavailable.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$StatePath,
        [ValidateSet('AllProfiles', 'OnlyBlocked')][string]$WhenNoState = 'AllProfiles',
        [switch]$RemoveState
    )

    $result = [PSCustomObject]@{
        Applied = @()
        StateUnreadable = $false
        StateError = ''
        Errors = [string[]]@()
    }
    if (-not (Get-Command -Name 'Set-NetFirewallProfile' -ErrorAction SilentlyContinue)) { return $result }

    $state = Read-OpenPathFirewallOutboundState -StatePath $StatePath
    $result.StateUnreadable = [bool]$state.Unreadable
    $result.StateError = [string]$state.Error

    $current = @{}
    if (-not $state.HasState -and $WhenNoState -eq 'OnlyBlocked' -and
        (Get-Command -Name 'Get-NetFirewallProfile' -ErrorAction SilentlyContinue)) {
        foreach ($profileName in @(Get-OpenPathFirewallTeardownProfileNames)) {
            $current[$profileName] = [string](Get-NetFirewallProfile -Profile $profileName -ErrorAction SilentlyContinue).DefaultOutboundAction
        }
    }

    $applied = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $plan = @(Get-OpenPathFirewallOutboundRestorePlan -RecordedActions $state.Recorded -CurrentActions $current -HasState ([bool]$state.HasState) -WhenNoState $WhenNoState)
    foreach ($step in $plan) {
        try {
            Set-NetFirewallProfile -Profile $step.Profile -DefaultOutboundAction $step.Action -ErrorAction Stop
            $applied.Add($step)
        }
        catch {
            $errors.Add("DefaultOutboundAction=$($step.Action) on profile $($step.Profile): $_")
        }
    }

    if ($RemoveState) {
        try {
            if (Test-Path $StatePath) {
                Remove-Item $StatePath -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
        }
    }

    $result.Applied = @($applied)
    $result.Errors = [string[]]@($errors)
    return $result
}

function Invoke-OpenPathAuditPol {
    <# Runs auditpol.exe; returns its output lines, or $null where auditpol is unavailable. #>
    param([string[]]$Arguments)

    if (-not (Get-Command -Name 'auditpol.exe' -ErrorAction SilentlyContinue)) { return $null }
    return @(& auditpol.exe @Arguments 2>$null)
}

function Invoke-OpenPathFirewallAuditRestore {
    <#
    .SYNOPSIS
        Puts back the "Filtering Platform Connection" audit setting recorded by the egress floor.
    .DESCRIPTION
        No-op when the state file is missing. Otherwise restores the recorded numeric setting
        (bit 1 success, bit 2 failure) and removes the state file, also when it was unreadable.
        Invoke-OpenPathAuditPol is the platform gate: without auditpol.exe it does nothing.
        Returns Restored (bool) and Error (string).
    #>
    param([Parameter(Mandatory = $true)][string]$StatePath)

    $subcategoryGuid = '{0CCE9226-69AE-11D9-BED3-505054503030}'
    $result = [PSCustomObject]@{
        Restored = $false
        Error = ''
    }
    if (-not (Test-Path -LiteralPath $StatePath)) { return $result }

    try {
        $stateText = (Get-Content -LiteralPath $StatePath -ErrorAction Stop) -join "`n"
        $previous = [int](($stateText | ConvertFrom-Json -ErrorAction Stop).settingValue)
        $success = if ($previous -band 1) { 'enable' } else { 'disable' }
        $failure = if ($previous -band 2) { 'enable' } else { 'disable' }
        Invoke-OpenPathAuditPol -Arguments @('/set', "/subcategory:$subcategoryGuid", "/success:$success", "/failure:$failure") | Out-Null
        $result.Restored = $true
    }
    catch {
        $result.Error = [string]$_
    }
    Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue

    return $result
}

function Remove-OpenPathFirewallRuleSelection {
    <#
    .SYNOPSIS
        Deletes every rule matched by one selector in a single Remove-NetFirewallRule call.
    .DESCRIPTION
        Each Get-NetFirewallRule call scans the whole firewall store, so a Get + Remove per rule
        costs roughly a second per rule. The NetSecurity cmdlets accept an array of names (and
        wildcards) on -DisplayName and a group on -Group, so one bulk call removes the whole
        selection. Returns the error text, or '' when the selection was removed.
    #>
    param(
        [string[]]$DisplayName,
        [string]$Group
    )

    $parameters = @{ ErrorAction = 'Stop' }
    if ($PSBoundParameters.ContainsKey('DisplayName') -and @($DisplayName).Count -gt 0) {
        $parameters['DisplayName'] = [string[]]$DisplayName
    }
    elseif (-not [string]::IsNullOrWhiteSpace($Group)) {
        $parameters['Group'] = $Group
    }
    else {
        return ''
    }

    try {
        Remove-NetFirewallRule @parameters
        return ''
    }
    catch {
        return [string]$_
    }
}

function Remove-OpenPathFirewallOwnedRules {
    <#
    .SYNOPSIS
        Removes the OpenPath-owned firewall rules in bulk: group OpenPath, then the manifest
        names, then a display-name <RulePrefix>-* sweep for legacy ungrouped rules.
    .DESCRIPTION
        Every rule New-OpenPathFirewallRule creates carries Group = OpenPath, so one
        Remove-NetFirewallRule -Group call removes the current set without the per-rule
        Get-NetFirewallRule store scans that made teardown take about a second per rule. The
        manifest names and the prefix sweep are bulk backups for rules created before the
        group existed; each backup only runs when one Get still finds matching leftover rules.
        An unreadable manifest sets ManifestError and the group and prefix removal still run.
        Removal failures are collected in Errors, never thrown; PrefixErrors holds the ones of
        the final prefix sweep. With -RemoveManifest the manifest is deleted after the rule
        removal. Returns at once when the firewall rule cmdlets are unavailable.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [string]$RulePrefix = 'OpenPath-DNS',
        [switch]$RemoveManifest
    )

    $result = [PSCustomObject]@{
        ManifestError = ''
        Errors = [string[]]@()
        PrefixErrors = [string[]]@()
    }
    if (-not (Get-Command -Name 'Get-NetFirewallRule' -ErrorAction SilentlyContinue)) { return $result }
    if (-not (Get-Command -Name 'Remove-NetFirewallRule' -ErrorAction SilentlyContinue)) { return $result }

    $errors = [System.Collections.Generic.List[string]]::new()
    $manifest = Read-OpenPathFirewallManifestRuleNames -Path $ManifestPath
    $result.ManifestError = [string]$manifest.Error

    # Fast path: one bulk delete for the rules the agent owns today.
    $message = Remove-OpenPathFirewallRuleSelection -Group 'OpenPath'
    if ($message) { $errors.Add($message) }

    # Backup for rules created before Group=OpenPath existed: the manifest records their
    # exact display names. One Get decides whether anything is left; the whole name array is
    # removed in one call, not a Get + Remove per name.
    if (@($manifest.Names).Count -gt 0) {
        $manifestRules = @(Get-NetFirewallRule -DisplayName $manifest.Names -ErrorAction SilentlyContinue)
        if ($manifestRules.Count -gt 0) {
            $message = Remove-OpenPathFirewallRuleSelection -DisplayName $manifest.Names
            if ($message) { $errors.Add($message) }
        }
    }

    # Last sweep: one Get finds ungrouped rules that are neither in the manifest nor grouped
    # (legacy or mangled state); one wildcard delete removes them in a single call.
    $prefixErrors = [System.Collections.Generic.List[string]]::new()
    $remainingRules = @(Get-NetFirewallRule -DisplayName "$RulePrefix-*" -ErrorAction SilentlyContinue)
    if ($remainingRules.Count -gt 0) {
        $message = Remove-OpenPathFirewallRuleSelection -DisplayName "$RulePrefix-*"
        if ($message) { $prefixErrors.Add($message) }
    }
    foreach ($message in $prefixErrors) {
        $errors.Add($message)
    }

    if ($RemoveManifest -and (Test-Path $ManifestPath)) {
        Remove-Item $ManifestPath -Force -ErrorAction SilentlyContinue
    }

    $result.Errors = [string[]]@($errors)
    $result.PrefixErrors = [string[]]@($prefixErrors)
    return $result
}

function Invoke-OpenPathFirewallTeardown {
    <#
    .SYNOPSIS
        Reverts OpenPath's firewall state in a fixed order: outbound default, then the audit
        setting, then the rules, so the default never stays at Block once the rules are gone.
    .DESCRIPTION
        Returns Outbound, Audit and Rules: the results of Invoke-OpenPathFirewallOutboundRestore,
        Invoke-OpenPathFirewallAuditRestore and Remove-OpenPathFirewallOwnedRules, plus RulesKept.
        With -KeepRulesWhenOutboundFails a failed profile restore skips the rule removal
        (RulesKept): a profile left at Block without OpenPath's non-student Allow would cut every
        account off the network, while the kept rules still let non-student accounts out.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$OutboundStatePath,
        [Parameter(Mandatory = $true)][string]$AuditStatePath,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [string]$RulePrefix = 'OpenPath-DNS',
        [ValidateSet('AllProfiles', 'OnlyBlocked')][string]$WhenNoState = 'OnlyBlocked',
        [switch]$RemoveOutboundState,
        [switch]$RemoveManifest,
        [switch]$KeepRulesWhenOutboundFails
    )

    $outbound = Invoke-OpenPathFirewallOutboundRestore -StatePath $OutboundStatePath -WhenNoState $WhenNoState -RemoveState:$RemoveOutboundState
    $audit = Invoke-OpenPathFirewallAuditRestore -StatePath $AuditStatePath
    $rulesKept = [bool]($KeepRulesWhenOutboundFails -and @($outbound.Errors).Count -gt 0)
    if ($rulesKept) {
        $rules = [PSCustomObject]@{
            ManifestError = ''
            Errors = [string[]]@()
            PrefixErrors = [string[]]@()
        }
    }
    else {
        $rules = Remove-OpenPathFirewallOwnedRules -ManifestPath $ManifestPath -RulePrefix $RulePrefix -RemoveManifest:$RemoveManifest
    }

    return [PSCustomObject]@{
        Outbound = $outbound
        Audit = $audit
        Rules = $rules
        RulesKept = $rulesKept
    }
}
