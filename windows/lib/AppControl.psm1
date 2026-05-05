# OpenPath App Control Module for Windows
# Applies AppLocker policy for non-admin users on managed endpoints.

$script:OpenPathRoot = "C:\OpenPath"
Import-Module "$PSScriptRoot\Common.psm1" -ErrorAction SilentlyContinue

$script:OpenPathAppControlRulePrefix = 'OpenPath non-admin app control'

function ConvertTo-OpenPathXmlAttribute {
    param(
        [AllowNull()]
        [string]$Value
    )

    return [System.Security.SecurityElement]::Escape([string]$Value)
}

function New-OpenPathNonAdminAppLockerPolicySpec {
    [CmdletBinding()]
    param(
        [string]$OpenPathRoot = $script:OpenPathRoot,

        [ValidateSet('AuditOnly', 'Enforced')]
        [string]$Mode = 'Enforced'
    )

    $openPathRuntimePath = "$($OpenPathRoot.TrimEnd('\'))\*"
    return [PSCustomObject]@{
        Mode = $Mode
        EnforcementMode = if ($Mode -eq 'AuditOnly') { 'AuditOnly' } else { 'Enabled' }
        NonAdminSid = 'S-1-5-32-545'
        AdminSid = 'S-1-5-32-544'
        SystemSid = 'S-1-5-18'
        AllowPaths = @(
            '%WINDIR%\*',
            $openPathRuntimePath,
            '%PROGRAMFILES%\Mozilla Firefox\firefox.exe',
            '%PROGRAMFILES(X86)%\Mozilla Firefox\firefox.exe',
            '%PROGRAMFILES%\Microsoft\Edge\Application\msedge.exe',
            '%PROGRAMFILES(X86)%\Microsoft\Edge\Application\msedge.exe',
            '%PROGRAMFILES%\Google\Chrome\Application\chrome.exe',
            '%PROGRAMFILES(X86)%\Google\Chrome\Application\chrome.exe'
        )
        BlockedWindowsTools = @(
            '%WINDIR%\System32\curl.exe',
            '%WINDIR%\SysWOW64\curl.exe',
            '%WINDIR%\System32\nslookup.exe',
            '%WINDIR%\SysWOW64\nslookup.exe',
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
            '%USERPROFILE%\AppData\Local\*',
            '%APPDATA%\*',
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

function New-OpenPathAppLockerPolicyXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Spec
    )

    $ruleCollections = @()
    foreach ($collectionType in @('Exe', 'Script')) {
        $rules = @()
        foreach ($path in @($Spec.UserWritableDenyPaths)) {
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

    return @"
<AppLockerPolicy Version="1">
$($ruleCollections -join "`n")
    <RuleCollection Type="Dll" EnforcementMode="NotConfigured" />
    <RuleCollection Type="Msi" EnforcementMode="NotConfigured" />
    <RuleCollection Type="Appx" EnforcementMode="NotConfigured" />
</AppLockerPolicy>
"@
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
        [string]$Mode = 'Enforced'
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
        $spec = New-OpenPathNonAdminAppLockerPolicySpec -OpenPathRoot $OpenPathRoot -Mode $Mode
        $policyXml = New-OpenPathAppLockerPolicyXml -Spec $spec
        $policyPath = Join-Path ([System.IO.Path]::GetTempPath()) "openpath-applocker-$([guid]::NewGuid()).xml"
        Set-Content -Path $policyPath -Value $policyXml -Encoding UTF8
        Set-AppLockerPolicy -XMLPolicy $policyPath
        Remove-Item $policyPath -Force -ErrorAction SilentlyContinue

        try {
            Set-Service -Name AppIDSvc -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name AppIDSvc -ErrorAction SilentlyContinue
        }
        catch {
            Write-OpenPathLog "AppLocker policy applied but AppIDSvc could not be started: $_" -Level WARN
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
        return [bool](@($rules | Where-Object { $_.Name -like "$script:OpenPathAppControlRulePrefix*" }).Count -gt 0)
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
                if ($rule.Name -like "$script:OpenPathAppControlRulePrefix*") {
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
    'Test-OpenPathAppControlAvailable',
    'Set-OpenPathNonAdminAppControl',
    'Test-OpenPathNonAdminAppControlActive',
    'Remove-OpenPathNonAdminAppControl'
)
