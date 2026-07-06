# ContractScenarios.Helpers.psm1 - Windows-side loading, flag mapping, and PURE
# rule-set assertions for tests/contracts/scenarios/*.scenario.json.
#
# Consumed by BOTH Windows rungs over one rule-record shape (DisplayName,
# Direction, Protocol, RemoteAddress/RemotePort as space-joined strings,
# Action, Program):
#   - mocked:  windows/tests/Windows.ContractScenarios.Tests.ps1 feeds the
#              capture from Initialize-FirewallRuleCaptureMocks;
#   - live:    tests/e2e/Windows-ContractScenarios.Tests.ps1 feeds
#              Get-ContractLiveFirewallRules (real Get-NetFirewallRule state,
#              self-hosted lab runner only).
#
# Verdict semantics mirror Windows Filtering Platform: a matching Block rule
# wins over Allow; with no OpenPath rule matching, the profile default
# outbound action applies (Allow -- the transport floor is default-OFF, W-1b).

$script:contractsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'contracts')).Path
$script:scenariosRoot = Join-Path $script:contractsRoot 'scenarios'

function Get-ContractScenarios {
    [CmdletBinding()]
    param(
        [ValidateSet('linux', 'windows')]
        [string]$Platform
    )

    $scenarios = @(
        Get-ChildItem -Path $script:scenariosRoot -Filter '*.scenario.json' -File |
            Sort-Object Name |
            ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json -ErrorAction Stop }
    )
    if ($Platform) {
        $scenarios = @($scenarios | Where-Object { @($_.platforms) -contains $Platform })
    }
    return @($scenarios)
}

function Get-ContractScenario {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    $path = Join-Path $script:scenariosRoot "$Id.scenario.json"
    if (-not (Test-Path $path)) {
        throw "Scenario fixture not found: $path"
    }
    return (Get-Content $path -Raw | ConvertFrom-Json -ErrorAction Stop)
}

function ConvertTo-ContractWindowsFirewallConfig {
    <#
    .SYNOPSIS
        Maps fixture given.flags to the Get-OpenPathConfig shape consumed by
        Set-OpenPathFirewall. Throws when a windows-scoped scenario carries a
        flag value that has no Windows analogue (must stay linux-scoped).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Scenario
    )

    $configProperties = @{}
    $flags = $null
    if ($Scenario.PSObject.Properties['given'] -and $Scenario.given -and
        $Scenario.given.PSObject.Properties['flags']) {
        $flags = $Scenario.given.flags
    }

    if ($null -ne $flags) {
        foreach ($property in $flags.PSObject.Properties) {
            $name = [string]$property.Name
            $value = [string]$property.Value
            switch ($name) {
                'DOH_BLOCK_ENABLED' {
                    $configProperties['enableDohIpBlocking'] = ($value -eq '1')
                }
                'VPN_BLOCK_ENABLED' {
                    if ($value -ne '1') {
                        throw "Scenario '$($Scenario.id)': VPN_BLOCK_ENABLED=$value has no Windows analogue (the VPN catalog is always applied); scope the scenario to linux."
                    }
                }
                'TOR_BLOCK_ENABLED' {
                    if ($value -ne '1') {
                        throw "Scenario '$($Scenario.id)': TOR_BLOCK_ENABLED=$value has no Windows analogue (the Tor catalog is always applied); scope the scenario to linux."
                    }
                }
                'SINKHOLE_FAST_FAIL' {
                    if ($value -ne '1') {
                        throw "Scenario '$($Scenario.id)': SINKHOLE_FAST_FAIL=$value is a dnsmasq/iptables control with no Windows analogue; scope the scenario to linux."
                    }
                }
                'IPV6_FIREWALL_ENABLED' {
                    if ($value -ne '1') {
                        throw "Scenario '$($Scenario.id)': IPV6_FIREWALL_ENABLED=$value is an ip6tables control with no Windows analogue; scope the scenario to linux."
                    }
                }
                'ALLOW_SET_EGRESS_ENABLED' {
                    if ($value -ne '1') {
                        throw "Scenario '$($Scenario.id)': ALLOW_SET_EGRESS_ENABLED=$value is an ipset control with no Windows analogue; scope the scenario to linux."
                    }
                }
                default {
                    throw "Scenario '$($Scenario.id)': unknown flag '$name' (schema.json and both runners must move together)."
                }
            }
        }
    }

    return [PSCustomObject]$configProperties
}

function Get-ContractWindowsEgressExpectations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Scenario
    )

    $entries = @()
    if ($Scenario.PSObject.Properties['expect'] -and $Scenario.expect -and
        $Scenario.expect.PSObject.Properties['egress'] -and $Scenario.expect.egress) {
        $entries = @($Scenario.expect.egress)
    }
    return @($entries | Where-Object {
            (-not $_.PSObject.Properties['platforms']) -or (@($_.platforms) -contains 'windows')
        })
}

function Test-ContractRulePortMatch {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()]
        [string]$RemotePort,
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    if ([string]::IsNullOrWhiteSpace($RemotePort) -or $RemotePort -eq 'Any') {
        return $true
    }
    foreach ($token in @($RemotePort -split '[\s,]+' | Where-Object { $_ })) {
        if ($token -match '^(\d+)-(\d+)$') {
            if ($Port -ge [int]$Matches[1] -and $Port -le [int]$Matches[2]) { return $true }
        }
        elseif ($token -match '^\d+$' -and [int]$token -eq $Port) {
            return $true
        }
    }
    return $false
}

function Test-ContractRuleAddressMatch {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()]
        [string]$RemoteAddress,
        [AllowEmptyCollection()]
        [string[]]$RequiredTokens = @(),
        [switch]$RequireUnscoped
    )

    $tokens = @($RemoteAddress -split '[\s,]+' | Where-Object { $_ })
    if ($RequireUnscoped) {
        return ($tokens.Count -eq 0) -or ($tokens -contains 'Any')
    }
    foreach ($required in @($RequiredTokens)) {
        $found = $false
        foreach ($token in $tokens) {
            # The live API reports a /32 as x.x.x.x/255.255.255.255; normalize.
            if ($token -eq $required -or $token -eq "$required/255.255.255.255" -or $token -eq "$required/32") {
                $found = $true
                break
            }
        }
        if (-not $found) { return $false }
    }
    return $true
}

function Get-ContractWindowsEgressVerdict {
    <#
    .SYNOPSIS
        Classifies one fixture egress expectation against a rule set:
        matching Block -> dropped; else matching Allow -> allowed; else the
        default outbound action -> allowed (transport floor default-OFF).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Rules,
        [Parameter(Mandatory = $true)]
        [string]$Dest,
        [Parameter(Mandatory = $true)]
        [string]$Protocol,
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $protocolUpper = $Protocol.ToUpperInvariant()
    $requiredAddressTokens = @()
    $requireUnscopedAddress = $false

    if ($Dest -eq 'dot-any' -or $Dest.StartsWith('vpn:') -or $Dest.StartsWith('tor:')) {
        $requireUnscopedAddress = $true
    }
    elseif ($Dest.StartsWith('doh-resolver:')) {
        $requiredAddressTokens = @($Dest.Substring('doh-resolver:'.Length))
    }
    elseif ($Dest -eq 'v6-dns-any') {
        # New-NetFirewallRule rejects ::/0; "all IPv6" is the two /1 halves
        # (Firewall.Policy.ps1:1308-1320, regression 33d67ea4).
        $requiredAddressTokens = @('::/1', '8000::/1')
    }
    else {
        throw "Egress dest class '$Dest' is not assertable from Windows rule state; scope the fixture entry to linux."
    }

    $matching = @($Rules | Where-Object {
            ([string]$_.Direction) -eq 'Outbound' -and
            ([string]$_.Protocol).ToUpperInvariant() -eq $protocolUpper -and
            (Test-ContractRulePortMatch -RemotePort ([string]$_.RemotePort) -Port $Port) -and
            (Test-ContractRuleAddressMatch -RemoteAddress ([string]$_.RemoteAddress) `
                -RequiredTokens $requiredAddressTokens -RequireUnscoped:$requireUnscopedAddress)
        })

    if (@($matching | Where-Object { ([string]$_.Action) -eq 'Block' }).Count -gt 0) { return 'dropped' }
    if (@($matching | Where-Object { ([string]$_.Action) -eq 'Allow' }).Count -gt 0) { return 'allowed' }
    return 'allowed'
}

function Get-ContractCatalogLines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $path = Join-Path $script:contractsRoot $FileName
    if (-not (Test-Path $path)) {
        throw "Contract catalog fixture not found: $path"
    }
    return @(
        Get-Content $path -ErrorAction Stop |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') }
    )
}

function Get-ContractCatalogVpnRules {
    [CmdletBinding()]
    param()
    return @(Get-ContractCatalogLines -FileName 'vpn-block-rules.txt' | ForEach-Object {
            $parts = @($_ -split ':', 3)
            [PSCustomObject]@{
                Protocol = ([string]$parts[0]).ToUpperInvariant()
                Port     = [int]$parts[1]
                Name     = [string]$parts[2]
            }
        })
}

function Get-ContractCatalogTorPorts {
    [CmdletBinding()]
    param()
    return @(Get-ContractCatalogLines -FileName 'tor-block-ports.txt' | ForEach-Object { [int]$_ })
}

function Test-ContractRuleSetInvariant {
    <#
    .SYNOPSIS
        Evaluates one named fixture invariant against a rule set. Returns
        'pass' or 'skipped' (linux-only encodings); throws with detail on
        violation or on an UNKNOWN invariant name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Invariant,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Rules
    )

    switch ($Invariant) {
        { $_ -in @('sinkhole-order', 'resolv-conf-no-search-domain', 'allow-set-populated-when-scoped', 'upstream-consistency') } {
            # dnsmasq/resolv.conf/ipset encodings -- linux runner territory.
            return 'skipped'
        }
        'no-slash-zero-prefix' {
            foreach ($rule in $Rules) {
                foreach ($token in @(([string]$rule.RemoteAddress) -split '[\s,]+' | Where-Object { $_ })) {
                    if ($token -match '/0$') {
                        throw "Rule '$($rule.DisplayName)' carries invalid /0 prefix token '$token' (New-NetFirewallRule rejects it; regression 33d67ea4)."
                    }
                }
            }
            return 'pass'
        }
        'no-ipv6-loopback-rule' {
            foreach ($rule in $Rules) {
                foreach ($token in @(([string]$rule.RemoteAddress) -split '[\s,]+' | Where-Object { $_ })) {
                    if ($token -eq '::1') {
                        throw "Rule '$($rule.DisplayName)' targets ::1 (New-NetFirewallRule rejects IPv6 loopback; Firewall.Policy.ps1:458-472)."
                    }
                }
            }
            return 'pass'
        }
        'v6-dns-block-split-halves' {
            foreach ($protocol in @('UDP', 'TCP')) {
                $halves = @($Rules | Where-Object {
                        ([string]$_.Action) -eq 'Block' -and
                        ([string]$_.Protocol).ToUpperInvariant() -eq $protocol -and
                        (Test-ContractRulePortMatch -RemotePort ([string]$_.RemotePort) -Port 53) -and
                        (Test-ContractRuleAddressMatch -RemoteAddress ([string]$_.RemoteAddress) `
                            -RequiredTokens @('::/1', '8000::/1'))
                    })
                if ($halves.Count -eq 0) {
                    throw "Missing all-IPv6 DNS block ($protocol/53) expressed as the ::/1 + 8000::/1 halves."
                }
            }
            return 'pass'
        }
        'bypass-blocks-applied' {
            if (@($Rules | Where-Object {
                        ([string]$_.Action) -eq 'Block' -and
                        ([string]$_.Protocol).ToUpperInvariant() -eq 'TCP' -and
                        (Test-ContractRulePortMatch -RemotePort ([string]$_.RemotePort) -Port 853)
                    }).Count -eq 0) {
                throw 'Missing DoT :853 block rule.'
            }
            if (@($Rules | Where-Object { ([string]$_.DisplayName) -like '*-Block-DoH-*' }).Count -eq 0) {
                throw 'Missing DoH resolver block rules.'
            }
            foreach ($vpnRule in @(Get-ContractCatalogVpnRules)) {
                if (@($Rules | Where-Object {
                            ([string]$_.Action) -eq 'Block' -and
                            ([string]$_.Protocol).ToUpperInvariant() -eq $vpnRule.Protocol -and
                            (Test-ContractRulePortMatch -RemotePort ([string]$_.RemotePort) -Port $vpnRule.Port)
                        }).Count -eq 0) {
                    throw "Missing VPN block $($vpnRule.Protocol)/$($vpnRule.Port) ($($vpnRule.Name))."
                }
            }
            foreach ($torPort in @(Get-ContractCatalogTorPorts)) {
                if (@($Rules | Where-Object {
                            ([string]$_.Action) -eq 'Block' -and
                            ([string]$_.Protocol).ToUpperInvariant() -eq 'TCP' -and
                            (Test-ContractRulePortMatch -RemotePort ([string]$_.RemotePort) -Port $torPort)
                        }).Count -eq 0) {
                    throw "Missing Tor block :$torPort."
                }
            }
            return 'pass'
        }
        default {
            throw "Unknown invariant '$Invariant' (schema.json and both runners must move together)."
        }
    }
}

function Test-ContractDnsAnswerBlocked {
    <#
    .SYNOPSIS
        True when every answer is sinkhole/unspecified (or there are none) --
        the fixture "blocked" DNS class, mirroring dns_probe_result_is_blocked.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()]
        [string[]]$Addresses
    )

    foreach ($address in @($Addresses | Where-Object { $_ })) {
        if ($address -notin @('0.0.0.0', '::', '192.0.2.1', '100::')) {
            return $false
        }
    }
    return $true
}

function Get-ContractLiveFirewallRules {
    <#
    .SYNOPSIS
        Live rung only (Windows with the NetSecurity module): snapshots the
        installed OpenPath rules into the shared record shape.
    #>
    [CmdletBinding()]
    param(
        [string]$DisplayNamePrefix = 'OpenPath-DNS'
    )

    $records = @()
    foreach ($rule in @(Get-NetFirewallRule -DisplayName "$DisplayNamePrefix-*" -ErrorAction SilentlyContinue)) {
        $portFilter = $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
        $addressFilter = $rule | Get-NetFirewallAddressFilter -ErrorAction SilentlyContinue
        $applicationFilter = $rule | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
        $records += [PSCustomObject]@{
            DisplayName   = [string]$rule.DisplayName
            Direction     = [string]$rule.Direction
            Protocol      = [string]$portFilter.Protocol
            RemoteAddress = ([string](@($addressFilter.RemoteAddress) -join ' '))
            RemotePort    = ([string](@($portFilter.RemotePort) -join ' '))
            LocalAddress  = ([string](@($addressFilter.LocalAddress) -join ' '))
            LocalPort     = ([string](@($portFilter.LocalPort) -join ' '))
            Action        = [string]$rule.Action
            Program       = [string]$applicationFilter.Program
        }
    }
    return @($records)
}

Export-ModuleMember -Function @(
    'Get-ContractScenarios',
    'Get-ContractScenario',
    'ConvertTo-ContractWindowsFirewallConfig',
    'Get-ContractWindowsEgressExpectations',
    'Test-ContractRulePortMatch',
    'Test-ContractRuleAddressMatch',
    'Get-ContractWindowsEgressVerdict',
    'Get-ContractCatalogVpnRules',
    'Get-ContractCatalogTorPorts',
    'Test-ContractRuleSetInvariant',
    'Test-ContractDnsAnswerBlocked',
    'Get-ContractLiveFirewallRules'
)
