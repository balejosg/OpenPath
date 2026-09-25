# Keeps the lab resolver reachable for the staged DNS chain.
#
# The OpenPath Windows client applies a DNS default-deny firewall policy: port
# 53 is blocked to every destination except loopback and the configured
# upstreams (its range builder always excludes 127.0.0.0/8 plus each allow IP).
# In this lab the client's upstream is the sslip resolver fixture on 127.0.0.2,
# which forwards every non-fixture name to the lab resolver on the LAN. That
# fixture egress is invisible to the client policy, so those queries are
# blocked and every real-domain lookup (runner telemetry, DNS readiness
# probes) times out.
#
# Rebuild the default-deny remote ranges with the lab resolver carved out so
# the staged chain keeps resolving between policy applications. The client
# re-applies its policy on domain changes, so this script is idempotent and
# meant to be re-run (the lane runs it from a periodic guard job as well).
[CmdletBinding()]
param(
    [string]$LabResolverAddress = '192.168.1.133'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-IpValue {
    param([string]$Address)

    $octets = @($Address.Split('.'))
    if ($octets.Count -ne 4) {
        return $null
    }

    $value = [int64]0
    foreach ($octetText in $octets) {
        $octet = 0
        if (-not [int]::TryParse($octetText, [ref]$octet) -or $octet -lt 0 -or $octet -gt 255) {
            return $null
        }
        $value = ($value * 256) + $octet
    }

    return $value
}

function ConvertFrom-IpValue {
    param([int64]$Value)

    return ('{0}.{1}.{2}.{3}' -f (($Value -shr 24) -band 255), (($Value -shr 16) -band 255), (($Value -shr 8) -band 255), ($Value -band 255))
}

$resolverValue = ConvertTo-IpValue -Address $LabResolverAddress
if ($null -eq $resolverValue) {
    throw "Invalid lab resolver address: $LabResolverAddress"
}

foreach ($rule in @(Get-NetFirewallRule -DisplayName '*DefaultDeny-DNS-*-53' -ErrorAction SilentlyContinue |
        Where-Object { $_.Enabled -eq 'True' -and $_.Action -eq 'Block' -and $_.DisplayName -notlike '*DNS6*' })) {
    $addresses = @(($rule | Get-NetFirewallAddressFilter).RemoteAddress)
    if ($addresses.Count -eq 0) {
        continue
    }

    $updated = [System.Collections.Generic.List[string]]::new()
    $changed = $false
    foreach ($entry in $addresses) {
        $text = [string]$entry

        if ($text.Contains('-')) {
            $bounds = @($text.Split('-', 2))
            $startValue = ConvertTo-IpValue -Address $bounds[0]
            $endValue = ConvertTo-IpValue -Address $bounds[1]
            if ($null -eq $startValue -or $null -eq $endValue) {
                $updated.Add($text) | Out-Null
                continue
            }

            if ($resolverValue -lt $startValue -or $resolverValue -gt $endValue) {
                $updated.Add($text) | Out-Null
                continue
            }

            $changed = $true
            if ($resolverValue -gt $startValue) {
                $updated.Add(('{0}-{1}' -f (ConvertFrom-IpValue -Value $startValue), (ConvertFrom-IpValue -Value ($resolverValue - 1)))) | Out-Null
            }
            if ($resolverValue -lt $endValue) {
                $updated.Add(('{0}-{1}' -f (ConvertFrom-IpValue -Value ($resolverValue + 1)), (ConvertFrom-IpValue -Value $endValue))) | Out-Null
            }
            continue
        }

        if ($text -eq $LabResolverAddress) {
            $changed = $true
            continue
        }

        $updated.Add($text) | Out-Null
    }

    if ($changed -and $updated.Count -gt 0) {
        Set-NetFirewallRule -DisplayName $rule.DisplayName -RemoteAddress $updated.ToArray() -ErrorAction Stop
    }
}
