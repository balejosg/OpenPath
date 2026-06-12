# OpenPath - Strict Internet Access Control
# Copyright (C) 2025 OpenPath Authors
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseBOMForUnicodeEncodedFile', '')]

#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Unified operational command for OpenPath Windows agent.
.DESCRIPTION
    Provides a Linux-like command entrypoint for common operations:
    status, update, health, doctor, enroll, rotate-token, restart.
#>

param(
    [string]$Command = 'status',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'

function Resolve-OpenPathRoot {
    . (Join-Path $PSScriptRoot 'lib\internal\WindowsRoot.ps1')
    $installedRoot = Resolve-OpenPathWindowsRoot
    if (Test-Path "$installedRoot\lib\Common.psm1") {
        return $installedRoot
    }

    if (Test-Path "$PSScriptRoot\lib\Common.psm1") {
        return $PSScriptRoot
    }

    throw 'OpenPath installation not found (missing lib/Common.psm1)'
}

function Show-OpenPathHelp {
    Write-Host 'OpenPath Windows command'
    Write-Host ''
    Write-Host 'Usage:'
    Write-Host '  .\OpenPath.ps1 [command] [args]'
    Write-Host ''
    Write-Host 'Commands:'
    Write-Host '  status           Show runtime status summary'
    Write-Host '  update           Trigger immediate whitelist update'
    Write-Host '  health           Run watchdog health check now'
    Write-Host '  doctor           Print focused diagnostics (for example: browser)'
    Write-Host '  domains [filter] List whitelisted domains (optional filter)'
    Write-Host '  check <domain>   Check whether a domain is allowed'
    Write-Host '  enable           Re-enable enforcement (DNS sinkhole + firewall)'
    Write-Host '  disable          Suspend enforcement until next enable'
    Write-Host '  self-update      Update Windows agent software from server'
    Write-Host '  enroll           Register machine in classroom mode'
    Write-Host '  rotate-token     Rotate tokenized whitelist URL'
    Write-Host '  restart          Restart Acrylic + trigger update'
    Write-Host '  help             Show this help'
    Write-Host ''
    Write-Host 'Examples:'
    Write-Host '  .\OpenPath.ps1 status'
    Write-Host '  .\OpenPath.ps1 update'
    Write-Host '  .\OpenPath.ps1 doctor browser'
    Write-Host '  .\OpenPath.ps1 domains edu'
    Write-Host '  .\OpenPath.ps1 check youtube.com'
    Write-Host '  .\OpenPath.ps1 enable'
    Write-Host '  .\OpenPath.ps1 disable'
    Write-Host '  .\OpenPath.ps1 self-update --check'
    Write-Host '  .\OpenPath.ps1 enroll -Classroom Aula1 -ApiUrl https://api.example.com -RegistrationToken <token>'
    Write-Host '  .\OpenPath.ps1 enroll -ApiUrl https://api.example.com -ClassroomId <id> -EnrollmentToken <token> -Unattended'
    Write-Host '  .\OpenPath.ps1 rotate-token -Secret <shared-secret>'
}

function ConvertTo-OpenPathInvocationSplat {
    param(
        [string[]]$ArgumentTokens = @()
    )

    $namedArguments = @{}
    $positionalArguments = New-Object System.Collections.Generic.List[string]
    $tokenCount = if ($null -eq $ArgumentTokens) { 0 } else { $ArgumentTokens.Count }

    # ValueFromRemainingArguments yields raw strings, so convert them back into
    # named/switch parameters before forwarding to child scripts.
    for ($index = 0; $index -lt $tokenCount; $index++) {
        $token = [string]$ArgumentTokens[$index]

        if ($token.StartsWith('-') -and $token.Length -gt 1) {
            $parameterName = $token.TrimStart('-')
            $nextIndex = $index + 1
            $nextTokenIsValue = $nextIndex -lt $tokenCount -and -not ([string]$ArgumentTokens[$nextIndex]).StartsWith('-')

            if ($nextTokenIsValue) {
                $namedArguments[$parameterName] = [string]$ArgumentTokens[$nextIndex]
                $index = $nextIndex
            }
            else {
                $namedArguments[$parameterName] = $true
            }

            continue
        }

        $positionalArguments.Add($token) | Out-Null
    }

    return [PSCustomObject]@{
        NamedArguments = $namedArguments
        PositionalArguments = $positionalArguments.ToArray()
    }
}

function Invoke-OpenPathScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [string[]]$ScriptArguments = @()
    )

    if (-not (Test-Path $ScriptPath)) {
        throw "Script not found: $ScriptPath"
    }

    $invocationSplat = ConvertTo-OpenPathInvocationSplat -ArgumentTokens $ScriptArguments
    $namedArguments = $invocationSplat.NamedArguments
    $positionalArguments = @($invocationSplat.PositionalArguments)

    & $ScriptPath @namedArguments @positionalArguments
}

function Show-OpenPathStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OpenPathRoot
    )

    $configPath = "$OpenPathRoot\data\config.json"
    $staleStatePath = "$OpenPathRoot\data\stale-failsafe-state.json"
    $watchdogFailPath = "$OpenPathRoot\data\watchdog-fails.txt"

    $config = $null
    if (Test-Path $configPath) {
        try {
            $config = Get-OpenPathConfig
        }
        catch {
            Write-OpenPathLog "Unable to read config for status command: $_" -Level WARN
        }
    }

    $acrylicService = Get-Service -DisplayName '*Acrylic*' -ErrorAction SilentlyContinue | Select-Object -First 1
    $acrylicState = if ($acrylicService) { [string]$acrylicService.Status } else { 'NotInstalled' }

    $dnsResolving = $false
    $sinkholeWorking = $false
    $firewallActive = $false

    try {
        $dnsResolving = [bool](Test-DNSResolution)
    }
    catch {
        $dnsResolving = $false
    }

    try {
        $sinkholeWorking = [bool](Test-DNSSinkhole -Domain 'this-should-be-blocked-test-12345.com')
    }
    catch {
        $sinkholeWorking = $false
    }

    try {
        $firewallActive = [bool](Test-FirewallActive)
    }
    catch {
        $firewallActive = $false
    }

    $tasks = @()
    try {
        $tasks = @(Get-OpenPathTaskStatus)
    }
    catch {
        $tasks = @()
    }

    $watchdogFails = 0
    if (Test-Path $watchdogFailPath) {
        try {
            $watchdogFails = [int](Get-Content $watchdogFailPath -Raw)
        }
        catch {
            $watchdogFails = 0
        }
    }

    $staleFailsafe = Test-Path $staleStatePath

    $overallStatus = if ($acrylicState -eq 'Running' -and $dnsResolving -and $sinkholeWorking) {
        'HEALTHY'
    }
    elseif ($acrylicState -eq 'Running' -and $dnsResolving) {
        'DEGRADED'
    }
    else {
        'CRITICAL'
    }

    if ($staleFailsafe) {
        $overallStatus = 'STALE_FAILSAFE'
    }

    Write-Host '==========================================' -ForegroundColor Cyan
    Write-Host '  OpenPath Windows Status' -ForegroundColor Cyan
    Write-Host '==========================================' -ForegroundColor Cyan
    Write-Host "Overall: $overallStatus"
    Write-Host "Acrylic service: $acrylicState"
    Write-Host "DNS resolving: $dnsResolving"
    Write-Host "Sinkhole active: $sinkholeWorking"
    Write-Host "Firewall active: $firewallActive"
    Write-Host "Stale failsafe: $staleFailsafe"
    Write-Host "Watchdog fail count: $watchdogFails"

    if ($config) {
        Write-Host "Agent version: $($config.version)"
        if ($config.PSObject.Properties['lastAgentUpdateAt'] -and $config.lastAgentUpdateAt) {
            Write-Host "Last agent update: $($config.lastAgentUpdateAt)"
        }
        Write-Host "Classroom: $($config.classroom)"
        Write-Host "API URL: $($config.apiUrl)"
        $redactedWhitelistUrl = ConvertTo-OpenPathRedactedValue -Value $config.whitelistUrl
        Write-Host "Whitelist URL: $redactedWhitelistUrl"
    }

    if ($tasks.Count -gt 0) {
        Write-Host ''
        Write-Host 'Scheduled tasks:'
        foreach ($task in $tasks | Sort-Object Name) {
            Write-Host "  - $($task.Name): $($task.State) (last result: $($task.LastResult))"
        }
    }
}

try {
    $openPathRoot = Resolve-OpenPathRoot

    # Import dependent modules first, then re-import Common globally so its
    # exported helpers remain visible across standalone CLI command execution.
    Import-Module "$openPathRoot\lib\DNS.psm1" -Force
    Import-Module "$openPathRoot\lib\Firewall.psm1" -Force
    Import-Module "$openPathRoot\lib\Services.psm1" -Force
    Import-Module "$openPathRoot\lib\Browser.psm1" -Force -Global
    Import-Module "$openPathRoot\lib\Common.psm1" -Force -Global
    . "$openPathRoot\lib\internal\Common.Redaction.ps1"

    $requiredCommonCommands = @(
        'Get-OpenPathConfig',
        'Get-OpenPathMachineTokenFromWhitelistUrl',
        'Invoke-OpenPathAgentSelfUpdate'
    )
    $missingCommonCommands = @(
        $requiredCommonCommands | Where-Object {
            -not (Get-Command -Name $_ -ErrorAction SilentlyContinue)
        }
    )
    if ($missingCommonCommands.Count -gt 0) {
        throw "OpenPath.ps1 failed to import required common commands: $($missingCommonCommands -join ', ')"
    }

    $scriptsPath = "$openPathRoot\scripts"
    $commandName = $Command.ToLowerInvariant()

    # Dot-source the whitelist parser helper used by 'domains' and 'check'.
    . "$openPathRoot\lib\internal\Common.Whitelist.ps1"

    switch ($commandName) {
        'status' {
            Show-OpenPathStatus -OpenPathRoot $openPathRoot
        }
        'update' {
            Invoke-OpenPathScript -ScriptPath "$scriptsPath\Update-OpenPath.ps1" -ScriptArguments $Arguments
        }
        'health' {
            Invoke-OpenPathScript -ScriptPath "$scriptsPath\Test-DNSHealth.ps1" -ScriptArguments $Arguments
        }
        'doctor' {
            $doctorTarget = if ($Arguments.Count -gt 0) { [string]$Arguments[0] } else { '' }

            switch ($doctorTarget.ToLowerInvariant()) {
                'browser' {
                    Write-Host (Get-OpenPathBrowserDoctorReport)
                }
                default {
                    throw "Unknown doctor target: $doctorTarget. Supported targets: browser"
                }
            }
        }
        'self-update' {
            $checkOnly = $Arguments -contains '--check' -or $Arguments -contains '-check'
            $silent = $Arguments -contains '--silent' -or $Arguments -contains '-silent'
            $result = Invoke-OpenPathAgentSelfUpdate -CheckOnly:$checkOnly -Silent:$silent
            if (-not $result.Success) {
                throw $result.Message
            }
        }
        'enroll' {
            Invoke-OpenPathScript -ScriptPath "$scriptsPath\Enroll-Machine.ps1" -ScriptArguments $Arguments
        }
        'rotate-token' {
            Invoke-OpenPathScript -ScriptPath "$openPathRoot\Rotate-Token.ps1" -ScriptArguments $Arguments
        }
        'restart' {
            Restart-AcrylicService | Out-Null
            Start-OpenPathTask -TaskType SSE | Out-Null
            Invoke-OpenPathScript -ScriptPath "$scriptsPath\Update-OpenPath.ps1"
        }
        'domains' {
            $domainFilter = if ($Arguments.Count -gt 0) { [string]$Arguments[0] } else { '' }
            $whitelistPath = "$openPathRoot\data\whitelist.txt"

            if (-not (Test-Path $whitelistPath)) {
                Write-Host 'Whitelist not found' -ForegroundColor Red
                exit 1
            }

            $sections = Get-OpenPathWhitelistSectionsFromFile -Path $whitelistPath
            $domains = @($sections.Whitelist | Where-Object { $_ })

            if ($domainFilter) {
                $domains = @($domains | Where-Object { $_ -like "*$domainFilter*" })
            }

            $domains | Sort-Object | ForEach-Object { Write-Host $_ }
        }
        'check' {
            $checkDomain = if ($Arguments.Count -gt 0) { [string]$Arguments[0] } else { '' }

            if (-not $checkDomain) {
                Write-Host 'Usage: .\OpenPath.ps1 check <domain>' -ForegroundColor Red
                exit 1
            }

            # Normalize: strip scheme, query, fragment, path — keep host only
            $normalizedDomain = $checkDomain -replace '^https?://', ''
            $normalizedDomain = $normalizedDomain -replace '[?#].*$', ''
            $normalizedDomain = $normalizedDomain -replace '/.*$', ''
            $normalizedDomain = $normalizedDomain.Trim('.').ToLowerInvariant()

            Write-Host "Checking: $checkDomain" -ForegroundColor Cyan
            Write-Host ''

            $whitelistPath = "$openPathRoot\data\whitelist.txt"
            $inWhitelist = $false
            $blockedSubdomain = $false

            if (Test-Path $whitelistPath) {
                $sections = Get-OpenPathWhitelistSectionsFromFile -Path $whitelistPath
                $inWhitelist = @($sections.Whitelist | Where-Object { $_.ToLowerInvariant() -eq $normalizedDomain }).Count -gt 0
                $blockedSubdomain = @($sections.BlockedSubdomains | Where-Object { $_.ToLowerInvariant() -eq $normalizedDomain }).Count -gt 0
            }

            if ($inWhitelist) {
                Write-Host '  In whitelist: YES' -ForegroundColor Green
            }
            else {
                Write-Host '  In whitelist: NO' -ForegroundColor Yellow
            }

            if ($blockedSubdomain) {
                Write-Host '  Blocked by subdomain: YES' -ForegroundColor Green
            }
            else {
                Write-Host '  Blocked by subdomain: NO' -ForegroundColor Yellow
            }

            Write-Host -NoNewline '  Resolves: '
            $sinkholeBlocked = $false
            try {
                $sinkholeBlocked = [bool](Test-DNSSinkhole -Domain $normalizedDomain)
            }
            catch {
                $sinkholeBlocked = $false
            }

            if (-not $sinkholeBlocked) {
                $dnsResult = $false
                try {
                    $dnsResult = [bool](Test-DNSResolution -Domain $normalizedDomain -MaxAttempts 1)
                }
                catch {
                    $dnsResult = $false
                }

                if ($dnsResult) {
                    Write-Host 'YES' -ForegroundColor Green
                }
                else {
                    Write-Host 'NO' -ForegroundColor Red
                }
            }
            else {
                Write-Host 'NO (sinkholed)' -ForegroundColor Red
            }

            Write-Host ''
        }
        'enable' {
            Write-Host 'Enabling OpenPath enforcement...' -ForegroundColor Cyan

            $enabledFirewall = Enable-OpenPathFirewall
            if (-not $enabledFirewall) {
                Write-Host 'WARNING: Could not re-enable firewall rules' -ForegroundColor Yellow
            }

            $enabledAcrylic = Start-AcrylicService
            if (-not $enabledAcrylic) {
                Write-Host 'WARNING: Could not start Acrylic DNS service' -ForegroundColor Yellow
            }

            Invoke-OpenPathScript -ScriptPath "$scriptsPath\Update-OpenPath.ps1"

            Write-Host 'OpenPath enforcement enabled' -ForegroundColor Green
        }
        'disable' {
            Write-Host 'Suspending OpenPath enforcement...' -ForegroundColor Yellow

            $disabledFirewall = Disable-OpenPathFirewall
            if (-not $disabledFirewall) {
                Write-Host 'WARNING: Could not disable firewall rules' -ForegroundColor Yellow
            }

            $stoppedAcrylic = Stop-AcrylicService
            if (-not $stoppedAcrylic) {
                Write-Host 'WARNING: Could not stop Acrylic DNS service' -ForegroundColor Yellow
            }

            Restore-OriginalDNS | Out-Null

            Write-Host 'OpenPath enforcement suspended' -ForegroundColor Green
        }
        'help' {
            Show-OpenPathHelp
        }
        default {
            Write-Host "Unknown command: $Command" -ForegroundColor Red
            Show-OpenPathHelp
            exit 1
        }
    }
}
catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    exit 1
}
