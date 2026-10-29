Import-Module (Join-Path $PSScriptRoot "TestHelpers.psm1") -Force

Describe 'PolicyStore.RegistryPol' {
    BeforeAll {
        $internalLib = Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'lib' 'internal')
        . (Join-Path $internalLib 'PolicyStore.RegistryPol.ps1')

        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-policystore-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        $script:RegistryCse = '[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F72-3407-48AE-BA88-E8213C6761F1}]'
        $script:HpJson = '{"firefoxhpsureclicksecurebrowsing@bromium.com":{"installation_mode":"blocked"},"firefoxhpwolfsecurityextension@bromium.com":{"installation_mode":"blocked"}}'
    }

    AfterAll {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $script:Case = Join-Path $script:TempRoot ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Case -Force | Out-Null
    }

    It 'Write golden single DWORD entry' {
        $path = Join-Path $script:Case 'Registry.pol'
        $dword = ConvertTo-OpenPathRegistryPolData -Type DWord -Value 1
        Write-OpenPathRegistryPolFile -Path $path -Entries @([pscustomobject]@{ Key = 'A'; ValueName = 'B'; Type = $dword.Type; Data = $dword.Data })

        $expected = [byte[]](0x50,0x52,0x65,0x67,0x01,0x00,0x00,0x00,
            0x5B,0x00,0x41,0x00,0x00,0x00,0x3B,0x00,0x42,0x00,0x00,0x00,0x3B,0x00,
            0x04,0x00,0x00,0x00,0x3B,0x00,0x04,0x00,0x00,0x00,0x3B,0x00,
            0x01,0x00,0x00,0x00,0x5D,0x00)
        $actual = [System.IO.File]::ReadAllBytes($path)
        ($actual -join ',') | Should -Be ($expected -join ',')
    }

    It 'Round-trips mixed entries' {
        $path = Join-Path $script:Case 'Registry.pol'
        $sz = ConvertTo-OpenPathRegistryPolData -Type String -Value $script:HpJson
        $multi = ConvertTo-OpenPathRegistryPolData -Type MultiString -Value @('line one', 'line two')
        $dword = ConvertTo-OpenPathRegistryPolData -Type DWord -Value 7
        $entries = @(
            [pscustomobject]@{ Key = 'Software\Policies\Mozilla\Firefox'; ValueName = 'ExtensionSettings'; Type = $sz.Type; Data = $sz.Data },
            [pscustomobject]@{ Key = 'Software\Policies\Test'; ValueName = 'Multi'; Type = $multi.Type; Data = $multi.Data },
            [pscustomobject]@{ Key = 'Software\Policies\Test'; ValueName = 'Flag'; Type = $dword.Type; Data = $dword.Data },
            [pscustomobject]@{ Key = 'Software\Policies\Test'; ValueName = '**delvals.'; Type = [uint32]1; Data = [byte[]]@() }
        )
        Write-OpenPathRegistryPolFile -Path $path -Entries $entries

        $read = @(Read-OpenPathRegistryPolFile -Path $path)
        $read.Count | Should -Be 4
        for ($i = 0; $i -lt 4; $i++) {
            $read[$i].Key | Should -Be $entries[$i].Key
            $read[$i].ValueName | Should -Be $entries[$i].ValueName
            [uint32]$read[$i].Type | Should -Be ([uint32]$entries[$i].Type)
            ($read[$i].Data -join ',') | Should -Be ($entries[$i].Data -join ',')
        }
        ConvertFrom-OpenPathRegistryPolData -Type $read[0].Type -Data $read[0].Data | Should -Be $script:HpJson
        $m = @(ConvertFrom-OpenPathRegistryPolData -Type $read[1].Type -Data $read[1].Data)
        $m.Count | Should -Be 2
        $m[1] | Should -Be 'line two'
        ConvertFrom-OpenPathRegistryPolData -Type $read[2].Type -Data $read[2].Data | Should -Be 7
        $read[3].Data.Length | Should -Be 0
    }

    It 'Missing file reads as empty' {
        $read = @(Read-OpenPathRegistryPolFile -Path (Join-Path $script:Case 'absent.pol'))
        $read.Count | Should -Be 0
    }

    It 'Truncated file throws local-gpo-unreadable and is left untouched' {
        $path = Join-Path $script:Case 'Registry.pol'
        $dword = ConvertTo-OpenPathRegistryPolData -Type DWord -Value 1
        Write-OpenPathRegistryPolFile -Path $path -Entries @([pscustomobject]@{ Key = 'A'; ValueName = 'B'; Type = $dword.Type; Data = $dword.Data })
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $truncated = New-Object byte[] ($bytes.Length - 6)
        [Array]::Copy($bytes, $truncated, $truncated.Length)
        [System.IO.File]::WriteAllBytes($path, $truncated)

        { Read-OpenPathRegistryPolFile -Path $path } | Should -Throw 'local-gpo-unreadable:*'
        (([System.IO.File]::ReadAllBytes($path)) -join ',') | Should -Be ($truncated -join ',')
    }

    It 'Bad header throws local-gpo-unreadable' {
        $path = Join-Path $script:Case 'Registry.pol'
        [System.IO.File]::WriteAllBytes($path, [byte[]](0x4E,0x4F,0x50,0x45,0x01,0x00,0x00,0x00))
        { Read-OpenPathRegistryPolFile -Path $path } | Should -Throw 'local-gpo-unreadable:*'
    }

    It 'Write keeps one-level backup' {
        $path = Join-Path (Join-Path $script:Case 'sub') 'Registry.pol'
        $one = ConvertTo-OpenPathRegistryPolData -Type DWord -Value 1
        $two = ConvertTo-OpenPathRegistryPolData -Type DWord -Value 2
        Write-OpenPathRegistryPolFile -Path $path -Entries @([pscustomobject]@{ Key = 'A'; ValueName = 'B'; Type = $one.Type; Data = $one.Data })
        $afterFirst = [System.IO.File]::ReadAllBytes($path)
        Write-OpenPathRegistryPolFile -Path $path -Entries @([pscustomobject]@{ Key = 'A'; ValueName = 'B'; Type = $two.Type; Data = $two.Data })

        (([System.IO.File]::ReadAllBytes("$path.openpath-bak")) -join ',') | Should -Be ($afterFirst -join ',')
        Test-Path -LiteralPath "$path.openpath-tmp" | Should -BeFalse
        (([System.IO.File]::ReadAllBytes($path)) -join ',') | Should -Not -Be ($afterFirst -join ',')
    }

    It 'Read maps I/O failures to local-gpo-unreadable' {
        $dirAsFile = Join-Path $script:Case 'Registry.pol'
        New-Item -ItemType Directory -Path $dirAsFile -Force | Out-Null
        Mock Test-Path { $true } -ParameterFilter { $PathType -eq 'Leaf' }
        { Read-OpenPathRegistryPolFile -Path $dirAsFile } | Should -Throw 'local-gpo-unreadable:*'
    }

    It 'Failed replace throws, keeps original bytes and leaves no tmp file' {
        $path = Join-Path $script:Case 'Registry.pol'
        $one = ConvertTo-OpenPathRegistryPolData -Type DWord -Value 1
        $two = ConvertTo-OpenPathRegistryPolData -Type DWord -Value 2
        Write-OpenPathRegistryPolFile -Path $path -Entries @([pscustomobject]@{ Key = 'A'; ValueName = 'B'; Type = $one.Type; Data = $one.Data })
        $original = [System.IO.File]::ReadAllBytes($path)
        Mock Move-Item { throw 'simulated lock' }
        { Write-OpenPathRegistryPolFile -Path $path -Entries @([pscustomobject]@{ Key = 'A'; ValueName = 'B'; Type = $two.Type; Data = $two.Data }) } | Should -Throw '*simulated lock*'
        (([System.IO.File]::ReadAllBytes($path)) -join ',') | Should -Be ($original -join ',')
        Test-Path -LiteralPath "$path.openpath-tmp" | Should -BeFalse
    }

    It 'Failed backup aborts before replacing' {
        $path = Join-Path $script:Case 'Registry.pol'
        $one = ConvertTo-OpenPathRegistryPolData -Type DWord -Value 1
        $two = ConvertTo-OpenPathRegistryPolData -Type DWord -Value 2
        Write-OpenPathRegistryPolFile -Path $path -Entries @([pscustomobject]@{ Key = 'A'; ValueName = 'B'; Type = $one.Type; Data = $one.Data })
        $original = [System.IO.File]::ReadAllBytes($path)
        Mock Copy-Item { throw 'simulated backup failure' }
        { Write-OpenPathRegistryPolFile -Path $path -Entries @([pscustomobject]@{ Key = 'A'; ValueName = 'B'; Type = $two.Type; Data = $two.Data }) } | Should -Throw '*simulated backup failure*'
        (([System.IO.File]::ReadAllBytes($path)) -join ',') | Should -Be ($original -join ',')
        Test-Path -LiteralPath "$path.openpath-tmp" | Should -BeFalse
    }

    It 'Gpt version bump preserves user half' {
        $gpt = Join-Path $script:Case 'gpt.ini'
        [System.IO.File]::WriteAllText($gpt, "[General]`r`ngPCMachineExtensionNames=[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F72-3407-48AE-BA88-E8213C6761F1}]`r`nVersion=65540`r`n")
        $result = Step-OpenPathLocalGpoMachineVersion -GptIniPath $gpt
        $result | Should -Be 65541
        [System.IO.File]::ReadAllText($gpt) | Should -Match 'Version=65541\r\n'
    }

    It 'Gpt version bump keeps a user half at or above 0x8000 and writes the unsigned value' {
        $gpt = Join-Path $script:Case 'gpt.ini'
        [System.IO.File]::WriteAllText($gpt, "[General]`r`nVersion=2147483649`r`n")
        Step-OpenPathLocalGpoMachineVersion -GptIniPath $gpt | Should -Be 2147483650
        [System.IO.File]::ReadAllText($gpt) | Should -Match 'Version=2147483650\r\n'
        [System.IO.File]::WriteAllText($gpt, "[General]`r`nVersion=4294901765`r`n")
        Step-OpenPathLocalGpoMachineVersion -GptIniPath $gpt | Should -Be 4294901766
        [System.IO.File]::ReadAllText($gpt) | Should -Match 'Version=4294901766\r\n'
    }

    It 'Gpt machine half wraps from 65535 to 1, never 0' {
        $gpt = Join-Path $script:Case 'gpt.ini'
        [System.IO.File]::WriteAllText($gpt, "[General]`r`nVersion=131071`r`n")
        Step-OpenPathLocalGpoMachineVersion -GptIniPath $gpt | Should -Be 65537
        [System.IO.File]::ReadAllText($gpt) | Should -Match 'Version=65537\r\n'
    }

    It 'Gpt bump clears a read-only attribute for the write and restores it' {
        $gpt = Join-Path $script:Case 'gpt.ini'
        [System.IO.File]::WriteAllText($gpt, "[General]`r`nVersion=3`r`n")
        [System.IO.File]::SetAttributes($gpt, [System.IO.FileAttributes]::ReadOnly)
        try {
            Step-OpenPathLocalGpoMachineVersion -GptIniPath $gpt | Should -Be 4
            [System.IO.File]::ReadAllText($gpt) | Should -Match 'Version=4'
            ([System.IO.File]::GetAttributes($gpt) -band [System.IO.FileAttributes]::ReadOnly) | Should -Be ([System.IO.FileAttributes]::ReadOnly)
        }
        finally { [System.IO.File]::SetAttributes($gpt, [System.IO.FileAttributes]::Normal) }
    }

    It 'Registry.pol replace keeps the protected attributes of the original file' {
        $path = Join-Path $script:Case 'Registry.pol'
        $one = ConvertTo-OpenPathRegistryPolData -Type DWord -Value 1
        $two = ConvertTo-OpenPathRegistryPolData -Type DWord -Value 2
        Write-OpenPathRegistryPolFile -Path $path -Entries @([pscustomobject]@{ Key = 'A'; ValueName = 'B'; Type = $one.Type; Data = $one.Data })
        [System.IO.File]::SetAttributes($path, [System.IO.FileAttributes]::ReadOnly)
        try {
            Write-OpenPathRegistryPolFile -Path $path -Entries @([pscustomobject]@{ Key = 'A'; ValueName = 'B'; Type = $two.Type; Data = $two.Data })
            $read = @(Read-OpenPathRegistryPolFile -Path $path)
            ConvertFrom-OpenPathRegistryPolData -Type $read[0].Type -Data $read[0].Data | Should -Be 2
            ([System.IO.File]::GetAttributes($path) -band [System.IO.FileAttributes]::ReadOnly) | Should -Be ([System.IO.FileAttributes]::ReadOnly)
        }
        finally {
            foreach ($f in @($path, "$path.openpath-bak")) {
                if ([System.IO.File]::Exists($f)) { [System.IO.File]::SetAttributes($f, [System.IO.FileAttributes]::Normal) }
            }
        }
    }

    It 'Protected attribute helpers clear Hidden, System and ReadOnly and restore them' {
        Mock Test-Path { $true }
        $script:attrSet = @()
        $attrs = [System.IO.FileAttributes]'Hidden, System, ReadOnly, Archive'
        Mock Get-OpenPathPolicyFileAttributes { $attrs }
        Mock Set-OpenPathPolicyFileAttributes { $script:attrSet += [System.IO.FileAttributes]$Attributes }
        $cleared = Clear-OpenPathPolicyFileProtection -Path 'x'
        $cleared | Should -Be ([System.IO.FileAttributes]'Hidden, System, ReadOnly')
        $script:attrSet[0] | Should -Be ([System.IO.FileAttributes]::Archive)
        Mock Get-OpenPathPolicyFileAttributes { [System.IO.FileAttributes]::Archive }
        Restore-OpenPathPolicyFileProtection -Path 'x' -Attributes $cleared
        $script:attrSet[1] | Should -Be ([System.IO.FileAttributes]'Hidden, System, ReadOnly, Archive')
    }

    It 'Gpt created when missing' {
        $gpt = Join-Path (Join-Path $script:Case 'gp') 'gpt.ini'
        $result = Step-OpenPathLocalGpoMachineVersion -GptIniPath $gpt
        $result | Should -Be 1
        $text = [System.IO.File]::ReadAllText($gpt)
        $text | Should -Match '\[General\]'
        $text | Should -Match 'Version=1'
        $text.Contains($script:RegistryCse) | Should -BeTrue
    }

    It 'Gpt keeps existing CSE brackets' {
        $gpt = Join-Path $script:Case 'gpt.ini'
        $line = 'gPCMachineExtensionNames=[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{62C1845D-C4A6-4ACB-BBB0-C895FD090385}]'
        [System.IO.File]::WriteAllText($gpt, "[General]`r`n$line`r`nVersion=3`r`n")
        Step-OpenPathLocalGpoMachineVersion -GptIniPath $gpt | Should -Be 4
        $text = [System.IO.File]::ReadAllText($gpt)
        $text.Contains($line + "`r`n") | Should -BeTrue
        $text.Contains('D02B1F72') | Should -BeFalse
    }

    It 'Gpt adds the Registry CSE in GUID order and keeps other brackets and lines' {
        $gpt = Join-Path $script:Case 'gpt.ini'
        $other = '[{0ACDD40C-75AC-47AB-BAA0-BF6DE7E7FE63}{D02B1F72-3407-48AE-BA88-E8213C6761F1}]'
        $late = '[{F312195E-3D9D-447A-A3F5-08DFFA24735E}{AAAA1111-0000-0000-0000-000000000000}]'
        [System.IO.File]::WriteAllText($gpt, "[General]`r`ngPCMachineExtensionNames=$other$late`r`nVersion=65540`r`nFoo=bar`r`n")
        Step-OpenPathLocalGpoMachineVersion -GptIniPath $gpt | Should -Be 65541
        $text = [System.IO.File]::ReadAllText($gpt)
        $text.Contains("gPCMachineExtensionNames=$other$($script:RegistryCse)$late`r`n") | Should -BeTrue
        $text.Contains("Foo=bar`r`n") | Should -BeTrue
    }
}

Describe 'PolicyStore.Owner' {
    BeforeAll {
        $internalLib = Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'lib' 'internal')
        . (Join-Path $internalLib 'PolicyStore.RegistryPol.ps1')
        . (Join-Path $internalLib 'PolicyStore.Owner.ps1')

        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-policyowner-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        $script:FfKey = 'Software\Policies\Mozilla\Firefox'
        $script:DomainGuid = '{31B2F340-016D-11D2-945F-00C04FB984F9}'

        function script:New-PolFile {
            param([object[]]$Entries)
            $path = Join-Path $script:Case 'Registry.pol'
            Write-OpenPathRegistryPolFile -Path $path -Entries $Entries
            return $path
        }
        function script:New-Rsop {
            param([string]$Key, [string]$ValueName, [string]$GpoId, [object]$Precedence)
            [pscustomobject]@{ registryKey = $Key; valueName = $ValueName; GPOID = $GpoId; precedence = $Precedence }
        }
    }

    AfterAll {
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $script:Case = Join-Path $script:TempRoot ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Case -Force | Out-Null
        $script:Missing = Join-Path $script:Case 'absent.pol'
        Mock Get-OpenPathRsopRegistryPolicySetting { @() }
        Mock Get-OpenPathRsopGpo { @() }
        Mock Get-ChildItem { @() } -ParameterFilter { $Path -like '*PolicyManager*' }
        Mock Get-OpenPathPolicyMdmAreaValueNames { @() }
        Mock Test-Path { $false } -ParameterFilter { "$LiteralPath$Path" -like "HKLM:*" }
        Mock Get-ItemProperty { $null }
    }

    It 'LocalGPO rsop record -> LocalGpo' {
        Mock Get-OpenPathRsopRegistryPolicySetting { @(New-Rsop 'software\policies\mozilla\firefox' 'ExtensionSettings' 'LocalGPO' 1) }
        $r = Get-OpenPathPolicyValueOwner -Key $script:FfKey -ValueName 'ExtensionSettings' -LocalPolPath $script:Missing
        $r.Owner | Should -Be 'LocalGpo'
    }

    It 'Domain GPO wins over local by precedence' {
        Mock Get-OpenPathRsopRegistryPolicySetting {
            @((New-Rsop $script:FfKey 'ExtensionSettings' 'LocalGPO' 2), (New-Rsop $script:FfKey 'ExtensionSettings' $script:DomainGuid 1))
        }
        Mock Get-OpenPathRsopGpo { @([pscustomobject]@{ id = $script:DomainGuid; name = 'Default Domain Policy' }) }
        $r = Get-OpenPathPolicyValueOwner -Key $script:FfKey -ValueName 'ExtensionSettings' -LocalPolPath $script:Missing
        $r.Owner | Should -Be 'DomainGpo'
        $r.GpoName | Should -Be 'Default Domain Policy'
    }

    It 'No rsop but present in Registry.pol -> LocalGpo' {
        $sz = ConvertTo-OpenPathRegistryPolData -Type String -Value '{}'
        $pol = New-PolFile @([pscustomobject]@{ Key = $script:FfKey; ValueName = 'ExtensionSettings'; Type = $sz.Type; Data = $sz.Data })
        $r = Get-OpenPathPolicyValueOwner -Key $script:FfKey -ValueName 'extensionsettings' -LocalPolPath $pol
        $r.Owner | Should -Be 'LocalGpo'
    }

    It 'Chromium list key matches **delvals. record' {
        $key = 'Software\Policies\Google\Chrome\ExtensionInstallBlocklist'
        $pol = New-PolFile @([pscustomobject]@{ Key = $key; ValueName = '**delvals.'; Type = [uint32]1; Data = [byte[]]@() })
        $r = Get-OpenPathPolicyValueOwner -Key $key -ValueName '' -LocalPolPath $pol
        $r.Owner | Should -Be 'LocalGpo'
    }

    It 'MDM area Firefox~Policy~firefox~Extensions with the value -> Mdm' {
        Mock Get-ChildItem { @([pscustomobject]@{ PSChildName = 'Firefox~Policy~firefox~Extensions'; Name = 'HKEY_LOCAL_MACHINE\x\Firefox~Policy~firefox~Extensions' }) } -ParameterFilter { $Path -like '*PolicyManager*' }
        Mock Get-OpenPathPolicyMdmAreaValueNames { @('ExtensionSettings') } -ParameterFilter { $AreaName -eq 'Firefox~Policy~firefox~Extensions' }
        $r = Get-OpenPathPolicyValueOwner -Key $script:FfKey -ValueName 'ExtensionSettings' -LocalPolPath $script:Missing
        $r.Owner | Should -Be 'Mdm'
        @($r.Evidence) | Should -Contain 'mdm:Firefox~Policy~firefox~Extensions'
    }

    It 'MDM value names match exactly or as a ~ValueName suffix, case-insensitively' {
        Mock Get-ChildItem { @([pscustomobject]@{ PSChildName = 'Edge~Policy~microsoft_edge' }) } -ParameterFilter { $Path -like '*PolicyManager*' }
        Mock Get-OpenPathPolicyMdmAreaValueNames { @('microsoft_edge~Policy~microsoft_edge~DnsOverHttpsMode', 'urlblocklist') }
        (Get-OpenPathPolicyValueOwner -Key 'Software\Policies\Microsoft\Edge' -ValueName 'DnsOverHttpsMode' -LocalPolPath $script:Missing).Owner | Should -Be 'Mdm'
        (Get-OpenPathPolicyValueOwner -Key 'Software\Policies\Microsoft\Edge\URLBlocklist' -ValueName '' -LocalPolPath $script:Missing).Owner | Should -Be 'Mdm'
    }

    It 'An MDM-managed browser area without the requested value does not block it' {
        Mock Get-ChildItem { @([pscustomobject]@{ PSChildName = 'Edge~Policy~microsoft_edge' }) } -ParameterFilter { $Path -like '*PolicyManager*' }
        Mock Get-OpenPathPolicyMdmAreaValueNames { @('HomepageLocation', 'microsoft_edge~Policy~microsoft_edge~DnsOverHttpsModeExtra', 'URLBlocklist_ProviderSet') }
        (Get-OpenPathPolicyValueOwner -Key 'Software\Policies\Microsoft\Edge' -ValueName 'DnsOverHttpsMode' -LocalPolPath $script:Missing).Owner | Should -Be 'None'
        (Get-OpenPathPolicyValueOwner -Key 'Software\Policies\Microsoft\Edge\URLBlocklist' -ValueName '' -LocalPolPath $script:Missing).Owner | Should -Be 'None'
        (Get-OpenPathPolicyValueOwner -Key 'Software\Policies\Microsoft\Edge\ExtensionInstallForcelist' -ValueName '' -LocalPolPath $script:Missing).Owner | Should -Be 'None'
    }

    It 'MDM area value names are read from the PolicyManager area key' {
        Mock Test-Path { $true } -ParameterFilter { "$LiteralPath$Path" -like '*PolicyManager*' }
        Mock Get-ItemProperty { [pscustomobject]@{ URLBlocklist = 'x'; PSPath = 'p'; PSChildName = 'c' } } -ParameterFilter { "$LiteralPath$Path" -like '*PolicyManager\current\device\Chrome~Policy~googlechrome' }
        $names = @(& (Get-Command Get-OpenPathPolicyMdmAreaValueNames -CommandType Function).ScriptBlock -AreaName 'Chrome~Policy~googlechrome')
        $names | Should -Be @('URLBlocklist')
    }

    It 'RSoP is queried with a WQL filter on the registry key, with backslashes and quotes escaped' {
        Get-OpenPathRsopRegistryPolicyFilter -Key "Software\Policies\Vendor's\Chrome" |
            Should -BeExactly "registryKey = 'Software\\Policies\\Vendor\'s\\Chrome' OR registryKey = '\\Software\\Policies\\Vendor\'s\\Chrome'"
    }

    It 'The RSoP CIM query passes the filter' {
        $script:cimFilter = $null
        $stubbed = -not (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue)
        # Get-CimInstance does not exist on non-Windows PowerShell; give Pester something to mock.
        if ($stubbed) { function global:Get-CimInstance { param($Namespace, $ClassName, $Filter) } }
        try {
            Mock Get-CimInstance { $script:cimFilter = $Filter; @() }
            & (Get-Command Get-OpenPathRsopRegistryPolicySetting -CommandType Function).ScriptBlock -Key 'Software\Policies\Google\Chrome'
        }
        finally { if ($stubbed) { Remove-Item Function:\Get-CimInstance -ErrorAction SilentlyContinue } }
        $script:cimFilter | Should -BeExactly "registryKey = 'Software\\Policies\\Google\\Chrome' OR registryKey = '\\Software\\Policies\\Google\\Chrome'"
    }

    It 'Owner lookup asks RSoP only for the requested key' {
        Mock Get-OpenPathRsopRegistryPolicySetting { @(New-Rsop $script:FfKey 'ExtensionSettings' 'LocalGPO' 1) }
        Get-OpenPathPolicyValueOwner -Key $script:FfKey -ValueName 'ExtensionSettings' -LocalPolPath $script:Missing | Out-Null
        Should -Invoke Get-OpenPathRsopRegistryPolicySetting -Times 1 -Exactly -ParameterFilter { $Key -eq $script:FfKey }
    }

    It 'Registry-only value -> Unknown' {
        Mock Test-Path { $true } -ParameterFilter { "$LiteralPath$Path" -like "HKLM:*" }
        Mock Get-ItemProperty { [pscustomobject]@{ ExtensionSettings = '{}' } }
        $r = Get-OpenPathPolicyValueOwner -Key $script:FfKey -ValueName 'ExtensionSettings' -LocalPolPath $script:Missing
        $r.Owner | Should -Be 'Unknown'
    }

    It 'Nothing anywhere -> None' {
        $r = Get-OpenPathPolicyValueOwner -Key $script:FfKey -ValueName 'ExtensionSettings' -LocalPolPath $script:Missing
        $r.Owner | Should -Be 'None'
        @($r.Evidence).Count | Should -Be 0
    }

    It 'RSoP throws -> falls back, Evidence contains rsop-unavailable' {
        Mock Get-OpenPathRsopRegistryPolicySetting { throw 'cim down' }
        $sz = ConvertTo-OpenPathRegistryPolData -Type String -Value '{}'
        $pol = New-PolFile @([pscustomobject]@{ Key = $script:FfKey; ValueName = 'ExtensionSettings'; Type = $sz.Type; Data = $sz.Data })
        $r = Get-OpenPathPolicyValueOwner -Key $script:FfKey -ValueName 'ExtensionSettings' -LocalPolPath $pol
        $r.Owner | Should -Be 'LocalGpo'
        @($r.Evidence) -contains 'rsop-unavailable' | Should -BeTrue
    }

    It 'Record for a different valueName in the same key does not match' {
        Mock Get-OpenPathRsopRegistryPolicySetting { @(New-Rsop $script:FfKey 'Other' $script:DomainGuid 1) }
        (Get-OpenPathPolicyValueOwner -Key $script:FfKey -ValueName 'ExtensionSettings' -LocalPolPath $script:Missing).Owner | Should -Be 'None'
    }

    It 'Local record wins when it has precedence 1 and domain has 2' {
        Mock Get-OpenPathRsopRegistryPolicySetting {
            @((New-Rsop $script:FfKey 'ExtensionSettings' $script:DomainGuid 2), (New-Rsop $script:FfKey 'ExtensionSettings' 'LocalGPO' 1))
        }
        (Get-OpenPathPolicyValueOwner -Key $script:FfKey -ValueName 'ExtensionSettings' -LocalPolPath $script:Missing).Owner | Should -Be 'LocalGpo'
    }

    It 'Handles uint32 precedence' {
        Mock Get-OpenPathRsopRegistryPolicySetting {
            @([pscustomobject]@{ registryKey = $script:FfKey; valueName = 'ExtensionSettings'; GPOID = 'LocalGPO'; precedence = [uint32]2 },
              [pscustomobject]@{ registryKey = $script:FfKey; valueName = 'ExtensionSettings'; GPOID = $script:DomainGuid; precedence = [uint32]1 })
        }
        (Get-OpenPathPolicyValueOwner -Key $script:FfKey -ValueName 'ExtensionSettings' -LocalPolPath $script:Missing).Owner | Should -Be 'DomainGpo'
    }

    It 'No RSOP_GPO match gives empty GpoName without throwing' {
        Mock Get-OpenPathRsopRegistryPolicySetting { @(New-Rsop $script:FfKey 'ExtensionSettings' $script:DomainGuid 1) }
        $r = Get-OpenPathPolicyValueOwner -Key $script:FfKey -ValueName 'ExtensionSettings' -LocalPolPath $script:Missing
        $r.Owner | Should -Be 'DomainGpo'
        $r.GpoName | Should -Be ''
    }

    It 'RSOP_GPO query failure adds rsop-gpo-name-unavailable' {
        Mock Get-OpenPathRsopRegistryPolicySetting { @(New-Rsop $script:FfKey 'ExtensionSettings' $script:DomainGuid 1) }
        Mock Get-OpenPathRsopGpo { throw 'gpo down' }
        $r = Get-OpenPathPolicyValueOwner -Key $script:FfKey -ValueName 'ExtensionSettings' -LocalPolPath $script:Missing
        $r.Owner | Should -Be 'DomainGpo'
        @($r.Evidence) -contains 'rsop-gpo-name-unavailable' | Should -BeTrue
    }

    It 'Whole-key lookup through RSoP matches any value' {
        $key = 'Software\Policies\Google\Chrome\ExtensionInstallBlocklist'
        Mock Get-OpenPathRsopRegistryPolicySetting { @(New-Rsop 'Software\Policies\Google\Chrome\ExtensionInstallBlocklist' '1' $script:DomainGuid 1) }
        (Get-OpenPathPolicyValueOwner -Key $key -ValueName '' -LocalPolPath $script:Missing).Owner | Should -Be 'DomainGpo'
    }

    It 'Whole-key tie at precedence 1 prefers the domain record regardless of order' {
        $key = 'Software\Policies\Google\Chrome\ExtensionInstallBlocklist'
        Mock Get-OpenPathRsopRegistryPolicySetting {
            @((New-Rsop $key '1' 'LocalGPO' 1), (New-Rsop $key '2' $script:DomainGuid 1))
        }
        (Get-OpenPathPolicyValueOwner -Key $key -ValueName '' -LocalPolPath $script:Missing).Owner | Should -Be 'DomainGpo'
        Mock Get-OpenPathRsopRegistryPolicySetting {
            @((New-Rsop $key '2' $script:DomainGuid 1), (New-Rsop $key '1' 'LocalGPO' 1))
        }
        (Get-OpenPathPolicyValueOwner -Key $key -ValueName '' -LocalPolPath $script:Missing).Owner | Should -Be 'DomainGpo'
    }

    It 'Missing GPOID is skipped with rsop-gpoid-missing evidence' {
        Mock Get-OpenPathRsopRegistryPolicySetting { @(New-Rsop $script:FfKey 'ExtensionSettings' '' 1) }
        $r = Get-OpenPathPolicyValueOwner -Key $script:FfKey -ValueName 'ExtensionSettings' -LocalPolPath $script:Missing
        $r.Owner | Should -Be 'None'
        @($r.Evidence) -contains 'rsop-gpoid-missing' | Should -BeTrue
    }

    It 'Null precedence sorts last' {
        Mock Get-OpenPathRsopRegistryPolicySetting {
            @((New-Rsop $script:FfKey 'ExtensionSettings' $script:DomainGuid $null), (New-Rsop $script:FfKey 'ExtensionSettings' 'LocalGPO' 3))
        }
        (Get-OpenPathPolicyValueOwner -Key $script:FfKey -ValueName 'ExtensionSettings' -LocalPolPath $script:Missing).Owner | Should -Be 'LocalGpo'
    }

    It 'Chrome and Edge MDM markers resolve to Mdm' {
        Mock Get-OpenPathPolicyMdmAreaValueNames { @('X') }
        Mock Get-ChildItem { @([pscustomobject]@{ PSChildName = 'Chrome~Policy~googlechrome' }) } -ParameterFilter { $Path -like '*PolicyManager*' }
        (Get-OpenPathPolicyValueOwner -Key 'Software\Policies\Google\Chrome' -ValueName 'X' -LocalPolPath $script:Missing).Owner | Should -Be 'Mdm'
        Mock Get-ChildItem { @([pscustomobject]@{ PSChildName = 'Edge~Policy~microsoft_edge' }) } -ParameterFilter { $Path -like '*PolicyManager*' }
        (Get-OpenPathPolicyValueOwner -Key 'Software\Policies\Microsoft\Edge' -ValueName 'X' -LocalPolPath $script:Missing).Owner | Should -Be 'Mdm'
    }

    It 'A Firefox MDM area does not make a Chrome key Mdm' {
        Mock Get-OpenPathPolicyMdmAreaValueNames { @('X') }
        Mock Get-ChildItem { @([pscustomobject]@{ PSChildName = 'Firefox~Policy~firefox~Extensions' }) } -ParameterFilter { $Path -like '*PolicyManager*' }
        (Get-OpenPathPolicyValueOwner -Key 'Software\Policies\Google\Chrome' -ValueName 'X' -LocalPolPath $script:Missing).Owner | Should -Be 'None'
    }

    It 'Unreadable local Registry.pol propagates local-gpo-unreadable' {
        $bad = Join-Path $script:Case 'Registry.pol'
        [System.IO.File]::WriteAllBytes($bad, [byte[]](1,2,3,4,5,6,7,8,9))
        { Get-OpenPathPolicyValueOwner -Key $script:FfKey -ValueName 'X' -LocalPolPath $bad } | Should -Throw 'local-gpo-unreadable*'
    }
}

Describe 'PolicyStore module' {
    BeforeAll {
        $script:StoreModule = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'lib') 'PolicyStore.psm1'
        . (Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'lib') 'internal') 'PolicyStore.RegistryPol.ps1')
        Import-Module $script:StoreModule -Force -ErrorAction Stop

        $script:TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("openpath-policystore-mod-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TempRoot -Force | Out-Null
        $script:FfKey = 'Software\Policies\Mozilla\Firefox'
        $script:ChromeListKey = 'Software\Policies\Google\Chrome\ExtensionInstallBlocklist'
        $script:SrpKey = 'Software\Policies\Microsoft\Windows\SrpV2\Exe'
        $script:HpJson = '{"firefoxhpsureclicksecurebrowsing@bromium.com":{"installation_mode":"blocked"}}'
        $script:OpenPathJson = '{"*":{"installation_mode":"blocked"}}'

        function script:New-PolEntry {
            param([string]$Key, [string]$ValueName, [string]$Type, $Value)
            $d = ConvertTo-OpenPathRegistryPolData -Type $Type -Value $Value
            [pscustomobject]@{ Key = $Key; ValueName = $ValueName; Type = $d.Type; Data = $d.Data }
        }
        function script:Get-GptVersion {
            $text = [System.IO.File]::ReadAllText($global:PSTPaths.GptIni)
            [int][regex]::Match($text, 'Version=(\d+)').Groups[1].Value
        }
    }

    AfterAll {
        Remove-Variable -Name PSTPaths, PSTReg, PSTKeys, PSTLedger, PSTWrites -Scope Global -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $case = Join-Path $script:TempRoot ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $case 'Machine') -Force | Out-Null
        $global:PSTPaths = [pscustomobject]@{
            RegistryPol = Join-Path (Join-Path $case 'Machine') 'Registry.pol'
            GptIni = Join-Path $case 'gpt.ini'
            Ledger = Join-Path $case 'policy-store-ledger.json'
            LegacyLedger = Join-Path $case 'legacy-policy-store-ledger.json'
        }
        $global:PSTReg = @{}
        $global:PSTKeys = @{}

        Mock Get-OpenPathLocalGpoPaths { [pscustomobject]@{ RegistryPol = $global:PSTPaths.RegistryPol; GptIni = $global:PSTPaths.GptIni } } -ModuleName PolicyStore
        # The ledger lives in the registry; these tests back its raw text with a file.
        Mock Read-OpenPathPolicyStoreLedgerText {
            if ([System.IO.File]::Exists($global:PSTPaths.Ledger)) { return [System.IO.File]::ReadAllText($global:PSTPaths.Ledger) }
            return $null
        } -ModuleName PolicyStore
        Mock Write-OpenPathPolicyStoreLedgerText { param([string]$Text) [System.IO.File]::WriteAllText($global:PSTPaths.Ledger, $Text) } -ModuleName PolicyStore
        Mock Get-OpenPathPolicyStoreLegacyLedgerPath { $global:PSTPaths.LegacyLedger } -ModuleName PolicyStore
        Mock Write-OpenPathLog { } -ModuleName PolicyStore
        Mock Get-OpenPathPolicyValueOwner { [pscustomobject]@{ Owner = 'None'; GpoName = ''; Evidence = @() } } -ModuleName PolicyStore

        Mock Test-Path { $global:PSTKeys.ContainsKey(("$LiteralPath$Path").ToLowerInvariant()) } -ModuleName PolicyStore -ParameterFilter { "$LiteralPath$Path" -like 'HKLM:*' }
        Mock New-Item { $global:PSTKeys[([string]$Path).ToLowerInvariant()] = $true } -ModuleName PolicyStore -ParameterFilter { "$Path" -like 'HKLM:*' }
        Mock New-ItemProperty {
            $global:PSTReg[(([string]$Path).ToLowerInvariant() + '|' + $Name)] = [pscustomobject]@{ Type = [string]$PropertyType; Value = $Value }
        } -ModuleName PolicyStore
        Mock Remove-ItemProperty {
            $global:PSTReg.Remove((([string]$Path).ToLowerInvariant() + '|' + $Name))
        } -ModuleName PolicyStore
        Mock Get-ItemProperty {
            $p = ("$LiteralPath$Path").ToLowerInvariant()
            $o = [ordered]@{}
            foreach ($k in $global:PSTReg.Keys) {
                $parts = $k.Split('|', 2)
                if ($parts[0] -eq $p) { $o[$parts[1]] = $global:PSTReg[$k].Value }
            }
            [pscustomobject]$o
        } -ModuleName PolicyStore
    }

    It 'Exports the public surface' {
        $names = @((Get-Module PolicyStore).ExportedFunctions.Keys)
        foreach ($n in 'Get-OpenPathManagedPolicyValue', 'Set-OpenPathManagedPolicyValue', 'Remove-OpenPathManagedPolicyValue',
            'Sync-OpenPathManagedPolicyList', 'Remove-OpenPathManagedPolicyList', 'Invoke-OpenPathPolicyRefresh',
            'Get-OpenPathLocalGpoPaths', 'Get-OpenPathPolicyValueOwner',
            'Get-OpenPathPolicyStoreLastOwner', 'Set-OpenPathPolicyStoreLastOwner', 'Remove-OpenPathPolicyStoreLedger',
            'Get-OpenPathPolicyStoreOriginal') {
            $names -contains $n | Should -BeTrue -Because $n
        }
    }

    It 'Last owner defaults to empty, round-trips and preserves managed lists' {
        Get-OpenPathPolicyStoreLastOwner -Key $script:FfKey -ValueName 'ExtensionSettings' | Should -Be ''
        $json = '{"lists":{"k":["a","b"]},"lastOwners":{}}'
        [System.IO.File]::WriteAllText($global:PSTPaths.Ledger, $json)
        Set-OpenPathPolicyStoreLastOwner -Key $script:FfKey -ValueName 'ExtensionSettings' -Owner 'DomainGpo' | Should -BeTrue
        Get-OpenPathPolicyStoreLastOwner -Key $script:FfKey -ValueName 'ExtensionSettings' | Should -Be 'DomainGpo'
        $ledger = Get-Content -LiteralPath $global:PSTPaths.Ledger -Raw | ConvertFrom-Json
        @($ledger.lists.k) -join ',' | Should -Be 'a,b'
        Test-Path -LiteralPath "$($global:PSTPaths.Ledger).openpath-tmp" | Should -BeFalse
    }

    It 'Last owner helpers never throw on an unwritable or corrupt ledger' {
        [System.IO.File]::WriteAllText($global:PSTPaths.Ledger, '{not json')
        { Get-OpenPathPolicyStoreLastOwner -Key $script:FfKey -ValueName 'ExtensionSettings' } | Should -Not -Throw
        [System.IO.File]::WriteAllText((Join-Path $script:TempRoot 'blocker'), 'x')
        $global:PSTPaths.Ledger = Join-Path (Join-Path $script:TempRoot 'blocker') 'x.json'
        { Set-OpenPathPolicyStoreLastOwner -Key $script:FfKey -ValueName 'ExtensionSettings' -Owner 'Mdm' } | Should -Not -Throw
        Set-OpenPathPolicyStoreLastOwner -Key $script:FfKey -ValueName 'ExtensionSettings' -Owner 'Mdm' | Should -BeFalse
    }

    It 'Unchanged value does not touch Registry.pol or gpt.ini' {
        $first = Set-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings' -Type String -Value $script:OpenPathJson
        $first.Applied | Should -BeTrue
        $first.Changed | Should -BeTrue
        $version = Get-GptVersion
        $bytes = [System.IO.File]::ReadAllBytes($global:PSTPaths.RegistryPol)
        $old = (Get-Item -LiteralPath $global:PSTPaths.RegistryPol).LastWriteTimeUtc.AddHours(-2)
        (Get-Item -LiteralPath $global:PSTPaths.RegistryPol).LastWriteTimeUtc = $old
        (Get-Item -LiteralPath $global:PSTPaths.GptIni).LastWriteTimeUtc = $old

        $second = Set-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings' -Type String -Value $script:OpenPathJson
        $second.Applied | Should -BeTrue
        $second.Changed | Should -BeFalse
        Get-GptVersion | Should -Be $version
        (Get-Item -LiteralPath $global:PSTPaths.RegistryPol).LastWriteTimeUtc | Should -Be $old
        (Get-Item -LiteralPath $global:PSTPaths.GptIni).LastWriteTimeUtc | Should -Be $old
        (([System.IO.File]::ReadAllBytes($global:PSTPaths.RegistryPol)) -join ',') | Should -Be ($bytes -join ',')
        $version | Should -Be 1
    }

    It 'Still mirrors the registry when Registry.pol is unchanged' {
        Set-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings' -Type String -Value $script:OpenPathJson | Out-Null
        $global:PSTReg.Clear()
        $r = Set-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings' -Type String -Value $script:OpenPathJson
        $r.Changed | Should -BeFalse
        $global:PSTReg["hklm:\$($script:FfKey.ToLowerInvariant())|ExtensionSettings"].Value | Should -Be $script:OpenPathJson
        $global:PSTReg["hklm:\$($script:FfKey.ToLowerInvariant())|ExtensionSettings"].Type | Should -Be 'String'
    }

    It 'Mirrors DWord and MultiString with matching registry types' {
        Set-OpenPathManagedPolicyValue -Key 'Software\Policies\Test' -ValueName 'Flag' -Type DWord -Value 1 | Out-Null
        Set-OpenPathManagedPolicyValue -Key 'Software\Policies\Test' -ValueName 'Multi' -Type MultiString -Value @('a', 'b') | Out-Null
        $global:PSTReg['hklm:\software\policies\test|Flag'].Type | Should -Be 'DWord'
        $global:PSTReg['hklm:\software\policies\test|Multi'].Type | Should -Be 'MultiString'
        @($global:PSTReg['hklm:\software\policies\test|Multi'].Value).Count | Should -Be 2
        $global:PSTKeys.ContainsKey('hklm:\software\policies\test') | Should -BeTrue
    }

    It 'HP local GPO value is replaced with caller value keeping other entries' {
        $srp = @(
            (New-PolEntry $script:SrpKey 'Enabled' DWord 1),
            (New-PolEntry "$($script:SrpKey)\0\Paths\{a}" 'ItemData' String 'C:\Windows\*'),
            (New-PolEntry "$($script:SrpKey)\0\Paths\{b}" 'SaferFlags' DWord 0)
        )
        $hp = New-PolEntry $script:FfKey 'ExtensionSettings' String $script:HpJson
        Write-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol -Entries (@($hp) + $srp)
        Mock Get-OpenPathPolicyValueOwner { [pscustomobject]@{ Owner = 'LocalGpo'; GpoName = ''; Evidence = @('registry-pol') } } -ModuleName PolicyStore

        $r = Set-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings' -Type String -Value $script:OpenPathJson
        $r.Applied | Should -BeTrue
        $r.Changed | Should -BeTrue
        $r.Owner | Should -Be 'LocalGpo'

        $read = @(Read-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol)
        $read.Count | Should -Be 4
        $ff = @($read | Where-Object { $_.Key -eq $script:FfKey })
        $ff.Count | Should -Be 1
        ConvertFrom-OpenPathRegistryPolData -Type $ff[0].Type -Data $ff[0].Data | Should -Be $script:OpenPathJson
        $others = @($read | Where-Object { $_.Key -ne $script:FfKey })
        $others.Count | Should -Be 3
        for ($i = 0; $i -lt 3; $i++) {
            $others[$i].Key | Should -Be $srp[$i].Key
            $others[$i].ValueName | Should -Be $srp[$i].ValueName
            ($others[$i].Data -join ',') | Should -Be ($srp[$i].Data -join ',')
        }
        Get-GptVersion | Should -Be 1
    }

    It 'DomainGpo owner blocks all writes' {
        Write-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol -Entries @((New-PolEntry $script:SrpKey 'Enabled' DWord 1))
        $before = [System.IO.File]::ReadAllBytes($global:PSTPaths.RegistryPol)
        Mock Get-OpenPathPolicyValueOwner { [pscustomobject]@{ Owner = 'DomainGpo'; GpoName = 'School Policy'; Evidence = @('rsop:{x}') } } -ModuleName PolicyStore

        $r = Set-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings' -Type String -Value $script:OpenPathJson
        $r.Applied | Should -BeFalse
        $r.Changed | Should -BeFalse
        $r.FailureCode | Should -Be 'policy-externally-managed'
        $r.Owner | Should -Be 'DomainGpo'
        $r.GpoName | Should -Be 'School Policy'
        (([System.IO.File]::ReadAllBytes($global:PSTPaths.RegistryPol)) -join ',') | Should -Be ($before -join ',')
        Test-Path -LiteralPath $global:PSTPaths.GptIni | Should -BeFalse
        $global:PSTReg.Count | Should -Be 0
        Should -Invoke New-ItemProperty -ModuleName PolicyStore -Times 0 -Exactly
    }

    It 'Mdm owner blocks all writes' {
        Mock Get-OpenPathPolicyValueOwner { [pscustomobject]@{ Owner = 'Mdm'; GpoName = ''; Evidence = @('mdm:x') } } -ModuleName PolicyStore
        $r = Set-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings' -Type String -Value $script:OpenPathJson
        $r.FailureCode | Should -Be 'policy-externally-managed'
        $r.Owner | Should -Be 'Mdm'
        Test-Path -LiteralPath $global:PSTPaths.RegistryPol | Should -BeFalse
        $global:PSTReg.Count | Should -Be 0
    }

    It 'Unreadable Registry.pol returns local-gpo-unreadable and leaves bytes intact' {
        $junk = [byte[]](1, 2, 3, 4, 5, 6, 7, 8, 9)
        [System.IO.File]::WriteAllBytes($global:PSTPaths.RegistryPol, $junk)
        Mock Get-OpenPathPolicyValueOwner { throw 'local-gpo-unreadable: bad header' } -ModuleName PolicyStore

        $r = Set-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings' -Type String -Value $script:OpenPathJson
        $r.Applied | Should -BeFalse
        $r.FailureCode | Should -Be 'local-gpo-unreadable'
        (([System.IO.File]::ReadAllBytes($global:PSTPaths.RegistryPol)) -join ',') | Should -Be ($junk -join ',')
        Test-Path -LiteralPath $global:PSTPaths.GptIni | Should -BeFalse
        $global:PSTReg.Count | Should -Be 0
    }

    It 'Unreadable Registry.pol is also caught when the owner probe does not read it' {
        $junk = [byte[]](1, 2, 3, 4, 5, 6, 7, 8, 9)
        [System.IO.File]::WriteAllBytes($global:PSTPaths.RegistryPol, $junk)
        $r = Set-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings' -Type String -Value $script:OpenPathJson
        $r.FailureCode | Should -Be 'local-gpo-unreadable'
        (([System.IO.File]::ReadAllBytes($global:PSTPaths.RegistryPol)) -join ',') | Should -Be ($junk -join ',')
        $global:PSTReg.Count | Should -Be 0
    }

    It 'WhatIf performs no writes' {
        $r = Set-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings' -Type String -Value $script:OpenPathJson -WhatIf
        $r.Applied | Should -BeFalse
        Test-Path -LiteralPath $global:PSTPaths.RegistryPol | Should -BeFalse
        $global:PSTReg.Count | Should -Be 0
    }

    It 'Get reads Registry.pol first, then the registry, then reports None' {
        (Get-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings').Source | Should -Be 'None'

        $global:PSTKeys["hklm:\$($script:FfKey.ToLowerInvariant())"] = $true
        $global:PSTReg["hklm:\$($script:FfKey.ToLowerInvariant())|ExtensionSettings"] = [pscustomobject]@{ Type = 'String'; Value = 'from-registry' }
        $reg = Get-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings'
        $reg.Source | Should -Be 'Registry'
        $reg.Type | Should -Be 'String'
        $reg.Value | Should -Be 'from-registry'

        Write-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol -Entries @((New-PolEntry $script:FfKey 'ExtensionSettings' String 'from-pol'))
        $pol = Get-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings'
        $pol.Source | Should -Be 'LocalGpo'
        $pol.Value | Should -Be 'from-pol'

        Write-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol -Entries @((New-PolEntry $script:FfKey 'Flag' DWord 1))
        $dw = Get-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'Flag'
        $dw.Type | Should -Be 'DWord'
        $dw.Value | Should -Be 1
    }

    It 'Remove deletes the Registry.pol entry, bumps the version and keeps other entries' {
        Write-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol -Entries @(
            (New-PolEntry $script:SrpKey 'Enabled' DWord 1),
            (New-PolEntry $script:FfKey 'ExtensionSettings' String $script:OpenPathJson))
        Set-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings' -Type String -Value $script:OpenPathJson | Out-Null
        $r = Remove-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings'
        $r.Removed | Should -BeTrue
        @($r.FailureCode) -join '' | Should -Be ''
        $read = @(Read-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol)
        $read.Count | Should -Be 1
        $read[0].Key | Should -Be $script:SrpKey
        $global:PSTReg.ContainsKey("hklm:\$($script:FfKey.ToLowerInvariant())|ExtensionSettings") | Should -BeFalse
    }

    It 'Set records the original vendor pol value once and Remove restores it' {
        $chrome = 'Software\Policies\Google\Chrome'
        Write-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol -Entries @(
            (New-PolEntry $script:SrpKey 'Enabled' DWord 1),
            (New-PolEntry $chrome 'DnsOverHttpsMode' String 'secure'))
        $vendorBytes = (New-PolEntry $chrome 'DnsOverHttpsMode' String 'secure').Data

        (Set-OpenPathManagedPolicyValue -Key $chrome -ValueName 'DnsOverHttpsMode' -Type String -Value 'off').Applied | Should -BeTrue
        (Set-OpenPathManagedPolicyValue -Key $chrome -ValueName 'DnsOverHttpsMode' -Type String -Value 'automatic').Applied | Should -BeTrue
        $original = Get-OpenPathPolicyStoreOriginal -Key $chrome -ValueName 'DnsOverHttpsMode'
        $original.InPol | Should -BeTrue
        [int]$original.Type | Should -Be 1
        ($original.Data -join ',') | Should -Be ($vendorBytes -join ',')

        $r = Remove-OpenPathManagedPolicyValue -Key $chrome -ValueName 'DnsOverHttpsMode'
        $r.Removed | Should -BeTrue
        $r.Restored | Should -BeTrue
        @($r.FailureCode) -join '' | Should -Be ''
        $read = @(Read-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol)
        $read.Count | Should -Be 2
        $doh = @($read | Where-Object { $_.ValueName -eq 'DnsOverHttpsMode' })
        ConvertFrom-OpenPathRegistryPolData -Type $doh[0].Type -Data $doh[0].Data | Should -Be 'secure'
        $global:PSTReg["hklm:\$($chrome.ToLowerInvariant())|DnsOverHttpsMode"].Value | Should -Be 'secure'
        Get-OpenPathPolicyStoreOriginal -Key $chrome -ValueName 'DnsOverHttpsMode' | Should -BeNullOrEmpty
    }

    It 'Remove deletes the pol entry when the value was absent before the first OpenPath write' {
        $chrome = 'Software\Policies\Google\Chrome'
        Write-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol -Entries @((New-PolEntry $script:SrpKey 'Enabled' DWord 1))
        Set-OpenPathManagedPolicyValue -Key $chrome -ValueName 'DnsOverHttpsMode' -Type String -Value 'off' | Out-Null
        (Get-OpenPathPolicyStoreOriginal -Key $chrome -ValueName 'DnsOverHttpsMode').InPol | Should -BeFalse

        $r = Remove-OpenPathManagedPolicyValue -Key $chrome -ValueName 'DnsOverHttpsMode'
        $r.Removed | Should -BeTrue
        $r.Restored | Should -BeFalse
        @(Read-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol | Where-Object { $_.ValueName -eq 'DnsOverHttpsMode' }).Count | Should -Be 0
        $global:PSTReg.ContainsKey("hklm:\$($chrome.ToLowerInvariant())|DnsOverHttpsMode") | Should -BeFalse
        Get-OpenPathPolicyStoreOriginal -Key $chrome -ValueName 'DnsOverHttpsMode' | Should -BeNullOrEmpty
    }

    It 'An unchanged Set records no original, so a lost or legacy ledger keeps the delete behavior' {
        Write-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol -Entries @((New-PolEntry $script:FfKey 'ExtensionSettings' String $script:OpenPathJson))
        (Set-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings' -Type String -Value $script:OpenPathJson).Changed | Should -BeFalse
        Get-OpenPathPolicyStoreOriginal -Key $script:FfKey -ValueName 'ExtensionSettings' | Should -BeNullOrEmpty
        (Remove-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings').Restored | Should -BeFalse
        @(Read-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol).Count | Should -Be 0
    }

    It 'Recording the original fails closed when the ledger cannot be written' {
        Write-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol -Entries @((New-PolEntry $script:FfKey 'ExtensionSettings' String $script:HpJson))
        $before = [System.IO.File]::ReadAllBytes($global:PSTPaths.RegistryPol)
        Mock Write-OpenPathPolicyStoreLedger { throw 'disk full' } -ModuleName PolicyStore
        $r = Set-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings' -Type String -Value $script:OpenPathJson
        $r.Applied | Should -BeFalse
        $r.FailureCode | Should -Be 'ledger-write-failed'
        (([System.IO.File]::ReadAllBytes($global:PSTPaths.RegistryPol)) -join ',') | Should -Be ($before -join ',')
        $global:PSTReg.Count | Should -Be 0
    }

    It 'ReleaseOriginal writes without recording and clears an existing original' {
        Write-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol -Entries @((New-PolEntry $script:FfKey 'ExtensionSettings' String $script:HpJson))
        Set-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings' -Type String -Value $script:OpenPathJson | Out-Null
        (Get-OpenPathPolicyStoreOriginal -Key $script:FfKey -ValueName 'ExtensionSettings').InPol | Should -BeTrue
        (Set-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings' -Type String -Value $script:HpJson -ReleaseOriginal).Applied | Should -BeTrue
        Get-OpenPathPolicyStoreOriginal -Key $script:FfKey -ValueName 'ExtensionSettings' | Should -BeNullOrEmpty
        (Set-OpenPathManagedPolicyValue -Key 'Software\Policies\Test' -ValueName 'Flag' -Type DWord -Value 1 -ReleaseOriginal).Applied | Should -BeTrue
        Get-OpenPathPolicyStoreOriginal -Key 'Software\Policies\Test' -ValueName 'Flag' | Should -BeNullOrEmpty
    }

    It 'DiscardOriginal deletes instead of restoring and clears the original' {
        Write-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol -Entries @((New-PolEntry $script:FfKey 'ExtensionSettings' String $script:HpJson))
        Set-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings' -Type String -Value $script:OpenPathJson | Out-Null
        $r = Remove-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings' -DiscardOriginal
        $r.Removed | Should -BeTrue
        $r.Restored | Should -BeFalse
        @(Read-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol).Count | Should -Be 0
        Get-OpenPathPolicyStoreOriginal -Key $script:FfKey -ValueName 'ExtensionSettings' | Should -BeNullOrEmpty
    }

    It 'Originals survive list syncs and owner updates in the ledger' {
        Set-OpenPathManagedPolicyValue -Key 'Software\Policies\Test' -ValueName 'Flag' -Type DWord -Value 1 | Out-Null
        Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('x') | Out-Null
        Set-OpenPathPolicyStoreLastOwner -Key $script:FfKey -ValueName 'ExtensionSettings' -Owner 'LocalGpo' | Out-Null
        (Get-OpenPathPolicyStoreOriginal -Key 'Software\Policies\Test' -ValueName 'Flag').InPol | Should -BeFalse
        $ledger = Get-Content -LiteralPath $global:PSTPaths.Ledger -Raw | ConvertFrom-Json
        $ledger.originals.'Software\Policies\Test|Flag'.inPol | Should -BeFalse
    }

    It 'Remove of a missing value is a silent no-op' {
        Write-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol -Entries @((New-PolEntry $script:SrpKey 'Enabled' DWord 1))
        $before = [System.IO.File]::ReadAllBytes($global:PSTPaths.RegistryPol)
        $r = Remove-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings'
        $r.Removed | Should -BeFalse
        @($r.FailureCode) -join '' | Should -Be ''
        (([System.IO.File]::ReadAllBytes($global:PSTPaths.RegistryPol)) -join ',') | Should -Be ($before -join ',')
        Test-Path -LiteralPath $global:PSTPaths.GptIni | Should -BeFalse
    }

    It 'Remove on an externally managed value writes nothing' {
        Mock Get-OpenPathPolicyValueOwner { [pscustomobject]@{ Owner = 'DomainGpo'; GpoName = 'School Policy'; Evidence = @() } } -ModuleName PolicyStore
        $r = Remove-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings'
        $r.Removed | Should -BeFalse
        $r.FailureCode | Should -Be 'policy-externally-managed'
        Should -Invoke Remove-ItemProperty -ModuleName PolicyStore -Times 0 -Exactly
    }

    It 'List merge keeps foreign numbered entries' {
        Write-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol -Entries @(
            (New-PolEntry $script:ChromeListKey '**delvals.' String ''),
            (New-PolEntry $script:ChromeListKey '1' String 'vendor-a'),
            (New-PolEntry $script:ChromeListKey '2' String 'vendor-b'))
        $r = Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('x', 'y')
        $r.Applied | Should -BeTrue
        $r.Changed | Should -BeTrue

        $read = @(Read-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol | Where-Object { $_.Key -eq $script:ChromeListKey })
        $byName = @{}
        foreach ($e in $read) { $byName[$e.ValueName] = ConvertFrom-OpenPathRegistryPolData -Type $e.Type -Data $e.Data }
        $byName.ContainsKey('**delvals.') | Should -BeTrue
        $byName['1'] | Should -Be 'vendor-a'
        $byName['2'] | Should -Be 'vendor-b'
        $byName['3'] | Should -Be 'x'
        $byName['4'] | Should -Be 'y'
        $read.Count | Should -Be 5

        $ledger = Get-Content -LiteralPath $global:PSTPaths.Ledger -Raw | ConvertFrom-Json
        @($ledger.lists.$($script:ChromeListKey)) -join ',' | Should -Be 'x,y'
        $global:PSTReg["hklm:\$($script:ChromeListKey.ToLowerInvariant())|3"].Value | Should -Be 'x'
        $global:PSTReg["hklm:\$($script:ChromeListKey.ToLowerInvariant())|1"].Value | Should -Be 'vendor-a'
    }

    It 'Identical list sync does not touch Registry.pol or gpt.ini' {
        Write-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol -Entries @(
            (New-PolEntry $script:ChromeListKey '1' String 'vendor-a'),
            (New-PolEntry $script:ChromeListKey '**delvals.' String ''),
            (New-PolEntry $script:ChromeListKey '2' String 'vendor-b'))
        Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('x', 'y') | Out-Null
        $version = Get-GptVersion
        $old = (Get-Item -LiteralPath $global:PSTPaths.RegistryPol).LastWriteTimeUtc.AddHours(-2)
        (Get-Item -LiteralPath $global:PSTPaths.RegistryPol).LastWriteTimeUtc = $old

        $r = Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('x', 'y')
        $r.Applied | Should -BeTrue
        $r.Changed | Should -BeFalse
        Get-GptVersion | Should -Be $version
        (Get-Item -LiteralPath $global:PSTPaths.RegistryPol).LastWriteTimeUtc | Should -Be $old
    }

    It 'List resync replaces only owned entries' {
        Write-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol -Entries @(
            (New-PolEntry $script:ChromeListKey '**delvals.' String ''),
            (New-PolEntry $script:ChromeListKey '1' String 'vendor-a'),
            (New-PolEntry $script:ChromeListKey '2' String 'vendor-b'))
        Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('x', 'y') | Out-Null
        $r = Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('z')
        $r.Changed | Should -BeTrue

        $read = @(Read-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol | Where-Object { $_.Key -eq $script:ChromeListKey })
        $values = @($read | Where-Object { $_.ValueName -match '^\d+$' } | ForEach-Object { '{0}={1}' -f $_.ValueName, (ConvertFrom-OpenPathRegistryPolData -Type $_.Type -Data $_.Data) })
        ($values | Sort-Object) -join ',' | Should -Be '1=vendor-a,2=vendor-b,3=z'
        @($read | Where-Object { $_.ValueName -eq '**delvals.' }).Count | Should -Be 1
        $ledger = Get-Content -LiteralPath $global:PSTPaths.Ledger -Raw | ConvertFrom-Json
        @($ledger.lists.$($script:ChromeListKey)) -join ',' | Should -Be 'z'
        $global:PSTReg.ContainsKey("hklm:\$($script:ChromeListKey.ToLowerInvariant())|4") | Should -BeFalse
        $global:PSTReg["hklm:\$($script:ChromeListKey.ToLowerInvariant())|3"].Value | Should -Be 'z'
    }

    It 'List sync preserves lastOwners in the ledger' {
        $json = '{"lists":{},"lastOwners":{"Software\\Policies\\Mozilla\\Firefox|ExtensionSettings":"LocalGpo"}}'
        [System.IO.File]::WriteAllText($global:PSTPaths.Ledger, $json)
        Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('only-one') | Out-Null
        $ledger = Get-Content -LiteralPath $global:PSTPaths.Ledger -Raw | ConvertFrom-Json
        @($ledger.lists.$($script:ChromeListKey)) -join ',' | Should -Be 'only-one'
        $ledger.lastOwners.'Software\Policies\Mozilla\Firefox|ExtensionSettings' | Should -Be 'LocalGpo'
    }

    It 'Corrupt ledger is treated as empty without throwing' {
        [System.IO.File]::WriteAllText($global:PSTPaths.Ledger, '{not json')
        { Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('a') } | Should -Not -Throw
        $ledger = Get-Content -LiteralPath $global:PSTPaths.Ledger -Raw | ConvertFrom-Json
        @($ledger.lists.$($script:ChromeListKey)) -join ',' | Should -Be 'a'
    }

    It 'List sync honors DomainGpo ownership' {
        Mock Get-OpenPathPolicyValueOwner { [pscustomobject]@{ Owner = 'DomainGpo'; GpoName = 'School Policy'; Evidence = @() } } -ModuleName PolicyStore
        $r = Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('a')
        $r.FailureCode | Should -Be 'policy-externally-managed'
        Test-Path -LiteralPath $global:PSTPaths.RegistryPol | Should -BeFalse
        Test-Path -LiteralPath $global:PSTPaths.Ledger | Should -BeFalse
    }

    It 'Remove list removes only ledger entries' {
        Write-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol -Entries @(
            (New-PolEntry $script:SrpKey 'Enabled' DWord 1),
            (New-PolEntry $script:ChromeListKey '**delvals.' String ''),
            (New-PolEntry $script:ChromeListKey '1' String 'vendor-a'))
        Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('x', 'y') | Out-Null
        $version = Get-GptVersion

        $r = Remove-OpenPathManagedPolicyList -Key $script:ChromeListKey
        $r.Removed | Should -BeTrue
        @($r.FailureCode) -join '' | Should -Be ''
        Get-GptVersion | Should -Be ($version + 1)

        $read = @(Read-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol)
        $read.Count | Should -Be 3
        $names = @($read | Where-Object { $_.Key -eq $script:ChromeListKey } | ForEach-Object { $_.ValueName })
        ($names | Sort-Object) -join ',' | Should -Be '**delvals.,1'
        @($read | Where-Object { $_.Key -eq $script:SrpKey }).Count | Should -Be 1
        $ledger = Get-Content -LiteralPath $global:PSTPaths.Ledger -Raw | ConvertFrom-Json
        @($ledger.lists.PSObject.Properties | Where-Object { $_.Name -eq $script:ChromeListKey }).Count | Should -Be 0
        $global:PSTReg.ContainsKey("hklm:\$($script:ChromeListKey.ToLowerInvariant())|3") | Should -BeFalse
        $global:PSTReg.ContainsKey("hklm:\$($script:ChromeListKey.ToLowerInvariant())|4") | Should -BeFalse
    }

    It 'Remove list with no ledger entries is a no-op' {
        Write-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol -Entries @((New-PolEntry $script:ChromeListKey '1' String 'vendor-a'))
        $before = [System.IO.File]::ReadAllBytes($global:PSTPaths.RegistryPol)
        $r = Remove-OpenPathManagedPolicyList -Key $script:ChromeListKey
        $r.Removed | Should -BeFalse
        (([System.IO.File]::ReadAllBytes($global:PSTPaths.RegistryPol)) -join ',') | Should -Be ($before -join ',')
        Test-Path -LiteralPath $global:PSTPaths.GptIni | Should -BeFalse
    }

    It 'Foreign entry equal to a caller value stays foreign through sync, resync and remove' {
        Write-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol -Entries @((New-PolEntry $script:ChromeListKey '1' String 'vendor-a'))
        $regKey = "hklm:\$($script:ChromeListKey.ToLowerInvariant())"
        $global:PSTKeys[$regKey] = $true
        $global:PSTReg["$regKey|1"] = [pscustomobject]@{ Type = 'String'; Value = 'vendor-a' }

        Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('vendor-a', 'x') | Out-Null
        $ledger = Get-Content -LiteralPath $global:PSTPaths.Ledger -Raw | ConvertFrom-Json
        @($ledger.lists.$($script:ChromeListKey)) -join ',' | Should -Be 'x'
        $r2 = Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('vendor-a', 'x')
        $r2.Changed | Should -BeFalse
        Remove-OpenPathManagedPolicyList -Key $script:ChromeListKey | Out-Null

        $read = @(Read-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol)
        $read.Count | Should -Be 1
        $read[0].ValueName | Should -Be '1'
        ConvertFrom-OpenPathRegistryPolData -Type $read[0].Type -Data $read[0].Data | Should -Be 'vendor-a'
        $global:PSTReg["$regKey|1"].Value | Should -Be 'vendor-a'
        $global:PSTReg.ContainsKey("$regKey|2") | Should -BeFalse
    }

    It 'List registry mirror keeps foreign registry-only numbered values and non-numbered values' {
        $regKey = "hklm:\$($script:ChromeListKey.ToLowerInvariant())"
        $global:PSTKeys[$regKey] = $true
        $global:PSTReg["$regKey|9"] = [pscustomobject]@{ Type = 'String'; Value = 'ghost-foreign' }
        $global:PSTReg["$regKey|Other"] = [pscustomobject]@{ Type = 'String'; Value = 'keep-me' }
        Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('x', 'y') | Out-Null
        Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('z') | Out-Null
        $global:PSTReg["$regKey|9"].Value | Should -Be 'ghost-foreign'
        $global:PSTReg["$regKey|Other"].Value | Should -Be 'keep-me'
        $global:PSTReg["$regKey|1"].Value | Should -Be 'z'
        $global:PSTReg.ContainsKey("$regKey|2") | Should -BeFalse
    }

    It 'List sync with a precomputed owner skips the owner lookup and still honors it' {
        $r = Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('x') -PrecomputedOwner ([pscustomobject]@{ Owner = 'Unknown'; GpoName = ''; Evidence = @() })
        $r.Applied | Should -BeTrue
        $r.Owner | Should -Be 'Unknown'
        Should -Invoke Get-OpenPathPolicyValueOwner -ModuleName PolicyStore -Times 0 -Exactly
        $blocked = Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('y') -PrecomputedOwner ([pscustomobject]@{ Owner = 'Mdm'; GpoName = ''; Evidence = @() })
        $blocked.FailureCode | Should -Be 'policy-externally-managed'
        @(Read-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol | ForEach-Object { ConvertFrom-OpenPathRegistryPolData -Type $_.Type -Data $_.Data }) | Should -Be @('x')
    }

    It 'Pruning replaces registry-only legacy numbered values once Registry.pol holds the list' {
        $regKey = "hklm:\$($script:ChromeListKey.ToLowerInvariant())"
        $global:PSTKeys[$regKey] = $true
        foreach ($i in 1..3) { $global:PSTReg["$regKey|$i"] = [pscustomobject]@{ Type = 'String'; Value = "legacy-$i" } }
        $global:PSTReg["$regKey|Note"] = [pscustomobject]@{ Type = 'String'; Value = 'keep' }

        $r = Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('x') -PruneUnownedRegistryValues
        $r.Applied | Should -BeTrue
        $global:PSTReg["$regKey|1"].Value | Should -Be 'x'
        $global:PSTReg.ContainsKey("$regKey|2") | Should -BeFalse
        $global:PSTReg.ContainsKey("$regKey|3") | Should -BeFalse
        $global:PSTReg["$regKey|Note"].Value | Should -Be 'keep'
    }

    It 'Pruning leaves the registry list untouched when Registry.pol could not be written' {
        $regKey = "hklm:\$($script:ChromeListKey.ToLowerInvariant())"
        $global:PSTKeys[$regKey] = $true
        foreach ($i in 1..3) { $global:PSTReg["$regKey|$i"] = [pscustomobject]@{ Type = 'String'; Value = "legacy-$i" } }
        Mock Write-OpenPathRegistryPolFile { throw 'disk full' } -ModuleName PolicyStore

        $r = Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('x') -PruneUnownedRegistryValues
        $r.FailureCode | Should -Be 'local-gpo-write-failed'
        foreach ($i in 1..3) { $global:PSTReg["$regKey|$i"].Value | Should -Be "legacy-$i" }
    }

    It 'Unchanged second list sync does not write or delete registry values' {
        Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('x', 'y') | Out-Null
        $global:PSTWrites = 0
        Mock New-ItemProperty { $global:PSTWrites++ } -ModuleName PolicyStore
        Mock Remove-ItemProperty { $global:PSTWrites++ } -ModuleName PolicyStore
        $r = Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('x', 'y')
        $r.Applied | Should -BeTrue
        $r.Changed | Should -BeFalse
        $global:PSTWrites | Should -Be 0
        Remove-Variable -Name PSTWrites -Scope Global -ErrorAction SilentlyContinue
    }

    It 'Ledger write failure fails closed without touching Registry.pol, gpt.ini or the registry' {
        Mock Write-OpenPathPolicyStoreLedger { throw 'disk full' } -ModuleName PolicyStore
        $r = Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('x')
        $r.Applied | Should -BeFalse
        $r.Changed | Should -BeFalse
        $r.FailureCode | Should -Be 'ledger-write-failed'
        Test-Path -LiteralPath $global:PSTPaths.RegistryPol | Should -BeFalse
        Test-Path -LiteralPath $global:PSTPaths.GptIni | Should -BeFalse
        $global:PSTReg.Count | Should -Be 0
    }

    It 'Migrates a legacy data\ ledger file into the registry once and deletes the file' {
        [System.IO.File]::WriteAllText($global:PSTPaths.LegacyLedger, '{"lists":{"Software\\Policies\\Google\\Chrome\\ExtensionInstallBlocklist":["x"]},"lastOwners":{}}')
        Write-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol -Entries @(
            (New-PolEntry $script:ChromeListKey '1' String 'vendor-a'),
            (New-PolEntry $script:ChromeListKey '2' String 'x'))

        Remove-OpenPathManagedPolicyList -Key $script:ChromeListKey | Out-Null

        $read = @(Read-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol)
        $read.Count | Should -Be 1
        ConvertFrom-OpenPathRegistryPolData -Type $read[0].Type -Data $read[0].Data | Should -Be 'vendor-a'
        Test-Path -LiteralPath $global:PSTPaths.LegacyLedger | Should -BeFalse
        Test-Path -LiteralPath $global:PSTPaths.Ledger | Should -BeTrue
    }

    It 'Keeps the legacy ledger file and still uses it when the registry migration fails' {
        [System.IO.File]::WriteAllText($global:PSTPaths.LegacyLedger, '{"lists":{"Software\\Policies\\Google\\Chrome\\ExtensionInstallBlocklist":["x"]},"lastOwners":{}}')
        Write-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol -Entries @((New-PolEntry $script:ChromeListKey '1' String 'x'))
        Mock Write-OpenPathPolicyStoreLedgerText { throw 'registry denied' } -ModuleName PolicyStore

        $r = Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('x')
        $r.Changed | Should -BeFalse
        @(Read-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol).Count | Should -Be 1
        Test-Path -LiteralPath $global:PSTPaths.LegacyLedger | Should -BeTrue
    }

    It 'Every mutator returns local-gpo-busy and writes nothing when the store lock is not acquired' {
        Mock Enter-OpenPathLocalGpoLock { $null } -ModuleName PolicyStore
        (Set-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings' -Type String -Value $script:OpenPathJson).FailureCode | Should -Be 'local-gpo-busy'
        (Remove-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings').FailureCode | Should -Be 'local-gpo-busy'
        (Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('x')).FailureCode | Should -Be 'local-gpo-busy'
        (Remove-OpenPathManagedPolicyList -Key $script:ChromeListKey).FailureCode | Should -Be 'local-gpo-busy'
        Set-OpenPathPolicyStoreLastOwner -Key $script:FfKey -ValueName 'ExtensionSettings' -Owner 'LocalGpo' | Should -BeFalse
        Test-Path -LiteralPath $global:PSTPaths.RegistryPol | Should -BeFalse
        Test-Path -LiteralPath $global:PSTPaths.Ledger | Should -BeFalse
        $global:PSTReg.Count | Should -Be 0
        Should -Invoke Get-OpenPathPolicyValueOwner -ModuleName PolicyStore -Times 0 -Exactly
    }

    It 'Releases the store lock after each call, also on failure' {
        Set-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings' -Type String -Value $script:OpenPathJson | Out-Null
        Mock Get-OpenPathPolicyValueOwner { throw 'unexpected owner failure' } -ModuleName PolicyStore
        { Set-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'Other' -Type String -Value 'x' } | Should -Throw
        $ps = [powershell]::Create()
        try {
            [void]$ps.AddScript('$m = New-Object System.Threading.Mutex($false, ''Global\OpenPath-LocalGpo-v1''); $ok = $m.WaitOne(0); if ($ok) { $m.ReleaseMutex() }; $m.Dispose(); $ok')
            # BeginInvoke runs on another thread; the same thread would re-enter a leaked mutex.
            @($ps.EndInvoke($ps.BeginInvoke()))[0] | Should -BeTrue
        }
        finally { $ps.Dispose() }
    }

    It 'Recomputes the merge from fresh bytes when Registry.pol changed before the replace' {
        $global:PSTConflicts = 1
        Mock Read-OpenPathPolicyStoreBytes {
            if ($global:PSTConflicts -gt 0) {
                $global:PSTConflicts--
                $d = ConvertTo-OpenPathRegistryPolData -Type DWord -Value 1
                Write-OpenPathRegistryPolFile -Path $PolPath -Entries @([pscustomobject]@{ Key = 'Software\Policies\Microsoft\Windows\SrpV2\Exe'; ValueName = 'EnforcementMode'; Type = $d.Type; Data = $d.Data })
            }
            if (-not [System.IO.File]::Exists($PolPath)) { return $null }
            return ,([System.IO.File]::ReadAllBytes($PolPath))
        } -ModuleName PolicyStore -ParameterFilter { $BeforeReplace }

        $r = Set-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings' -Type String -Value $script:OpenPathJson
        $r.Applied | Should -BeTrue
        $read = @(Read-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol)
        @($read | ForEach-Object { $_.ValueName }) -join ',' | Should -Be 'EnforcementMode,ExtensionSettings'
        Remove-Variable -Name PSTConflicts -Scope Global -ErrorAction SilentlyContinue
    }

    It 'Gives up with local-gpo-busy after three conflicting attempts' {
        $global:PSTConflicts = 0
        Mock Read-OpenPathPolicyStoreBytes {
            $global:PSTConflicts++
            $d = ConvertTo-OpenPathRegistryPolData -Type DWord -Value $global:PSTConflicts
            Write-OpenPathRegistryPolFile -Path $PolPath -Entries @([pscustomobject]@{ Key = 'Software\Policies\Other'; ValueName = 'Counter'; Type = $d.Type; Data = $d.Data })
            return ,([System.IO.File]::ReadAllBytes($PolPath))
        } -ModuleName PolicyStore -ParameterFilter { $BeforeReplace }

        $r = Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('x')
        $r.FailureCode | Should -Be 'local-gpo-busy'
        $r.Applied | Should -BeFalse
        $global:PSTConflicts | Should -Be 3
        @(Read-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol | Where-Object { $_.Key -eq $script:ChromeListKey }).Count | Should -Be 0
        Test-Path -LiteralPath $global:PSTPaths.GptIni | Should -BeFalse
        Remove-Variable -Name PSTConflicts -Scope Global -ErrorAction SilentlyContinue
    }

    It 'gpt.ini bump failure still reports Changed with a failure code' {
        Mock Step-OpenPathLocalGpoMachineVersion { throw 'gpt locked' } -ModuleName PolicyStore
        $r = Set-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'ExtensionSettings' -Type String -Value $script:OpenPathJson
        $r.Changed | Should -BeTrue
        $r.Applied | Should -BeFalse
        $r.FailureCode | Should -Be 'gpt-ini-bump-failed'
        $s = Sync-OpenPathManagedPolicyList -Key $script:ChromeListKey -Values @('x')
        $s.Changed | Should -BeTrue
        $s.FailureCode | Should -Be 'gpt-ini-bump-failed'
    }

    It 'Get returns MultiString as string[] even with a single element' {
        Write-OpenPathRegistryPolFile -Path $global:PSTPaths.RegistryPol -Entries @((New-PolEntry $script:FfKey 'Lines' MultiString @('{"a":1}')))
        $r = Get-OpenPathManagedPolicyValue -Key $script:FfKey -ValueName 'Lines'
        $r.Type | Should -Be 'MultiString'
        $r.Value.GetType().Name | Should -Be 'String[]'
        $r.Value.Count | Should -Be 1
        $r.Value[0] | Should -Be '{"a":1}'
    }

    It 'Refresh builds gpupdate arguments' {
        Mock Start-OpenPathGpUpdateProcess { 0 } -ModuleName PolicyStore
        $r = Invoke-OpenPathPolicyRefresh -Force -TimeoutSeconds 60
        $r.ExitCode | Should -Be 0
        Should -Invoke Start-OpenPathGpUpdateProcess -ModuleName PolicyStore -Times 1 -Exactly -ParameterFilter { $Arguments -eq '/target:computer /force /wait:60' }
        Invoke-OpenPathPolicyRefresh | Out-Null
        Should -Invoke Start-OpenPathGpUpdateProcess -ModuleName PolicyStore -Times 1 -Exactly -ParameterFilter { $Arguments -eq '/target:computer /wait:120' }
    }

    It 'Refresh answers N on stdin so a restart prompt cannot hang the process' {
        $pwshPath = (Get-Process -Id $PID).Path
        $exit = & (Get-Module PolicyStore) {
            param($exe)
            Start-OpenPathGpUpdateProcess -FilePath $exe -Arguments '-NoProfile -NonInteractive -Command "$l = [Console]::In.ReadLine(); exit ([int][char]$l[0])"' -TimeoutSeconds 30
        } $pwshPath
        $exit | Should -Be ([int][char]'N')
    }

    It 'Refresh warns that a restart may be required when gpupdate does not exit cleanly' {
        Mock Start-OpenPathGpUpdateProcess { 1 } -ModuleName PolicyStore
        (Invoke-OpenPathPolicyRefresh -Force).ExitCode | Should -Be 1
        Should -Invoke Write-OpenPathLog -ModuleName PolicyStore -ParameterFilter { $Level -eq 'WARN' -and $Message -match 'restart' }
    }

    It 'Refresh never throws when gpupdate cannot start' {
        Mock Start-OpenPathGpUpdateProcess { throw 'cannot start' } -ModuleName PolicyStore
        { $script:r = Invoke-OpenPathPolicyRefresh -Force } | Should -Not -Throw
        $script:r.ExitCode | Should -Be -1
        Should -Invoke Write-OpenPathLog -ModuleName PolicyStore -ParameterFilter { $Level -eq 'WARN' }
    }

    It 'Default local GPO paths point at System32\GroupPolicy' {
        Remove-Module PolicyStore -Force
        Import-Module $script:StoreModule -Force -ErrorAction Stop
        $old = $env:SystemRoot
        try {
            $env:SystemRoot = (Join-Path $script:TempRoot 'win')
            $p = Get-OpenPathLocalGpoPaths
            $p.RegistryPol | Should -Be (Join-Path (Join-Path (Join-Path (Join-Path $env:SystemRoot 'System32') 'GroupPolicy') 'Machine') 'Registry.pol')
            $p.GptIni | Should -Be (Join-Path (Join-Path (Join-Path $env:SystemRoot 'System32') 'GroupPolicy') 'gpt.ini')
        }
        finally { $env:SystemRoot = $old }
    }
}

Describe 'PolicyStore ledger storage' {
    BeforeAll {
        $script:StoreModule = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'lib') 'PolicyStore.psm1'
        Import-Module $script:StoreModule -Force -ErrorAction Stop
        $script:LedgerKey = 'HKLM:\SOFTWARE\OpenPath\PolicyStore'
    }

    AfterAll {
        Remove-Variable -Name PSLReg, PSLKeys, PSLLegacy -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $global:PSLReg = @{}
        $global:PSLKeys = @{}
        $global:PSLLegacy = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.json')
        Mock Write-OpenPathLog { } -ModuleName PolicyStore
        Mock Get-OpenPathPolicyStoreLegacyLedgerPath { $global:PSLLegacy } -ModuleName PolicyStore
        Mock Test-Path { $global:PSLKeys.ContainsKey([string]"$LiteralPath$Path") } -ModuleName PolicyStore -ParameterFilter { "$LiteralPath$Path" -like 'HKLM:*' }
        Mock New-Item { $global:PSLKeys[[string]$Path] = $true } -ModuleName PolicyStore -ParameterFilter { "$Path" -like 'HKLM:*' }
        Mock New-ItemProperty { $global:PSLReg[([string]$Path + '|' + $Name)] = [pscustomobject]@{ Type = [string]$PropertyType; Value = $Value } } -ModuleName PolicyStore
        Mock Get-ItemProperty {
            $o = [ordered]@{}
            foreach ($k in $global:PSLReg.Keys) {
                $parts = $k.Split('|', 2)
                if ($parts[0] -eq "$LiteralPath$Path") { $o[$parts[1]] = $global:PSLReg[$k].Value }
            }
            [pscustomobject]$o
        } -ModuleName PolicyStore
        Mock Remove-Item { $global:PSLKeys.Remove([string]$LiteralPath); $global:PSLReg.Clear() } -ModuleName PolicyStore -ParameterFilter { "$LiteralPath" -like 'HKLM:*' }
    }

    It 'Writes the ledger as a REG_SZ value under HKLM:\SOFTWARE\OpenPath\PolicyStore' {
        Set-OpenPathPolicyStoreLastOwner -Key 'Software\Policies\Mozilla\Firefox' -ValueName 'ExtensionSettings' -Owner 'LocalGpo' | Should -BeTrue
        $global:PSLKeys.ContainsKey($script:LedgerKey) | Should -BeTrue
        $global:PSLReg["$($script:LedgerKey)|Ledger"].Type | Should -Be 'String'
        $ledger = $global:PSLReg["$($script:LedgerKey)|Ledger"].Value | ConvertFrom-Json
        $ledger.lastOwners.'Software\Policies\Mozilla\Firefox|ExtensionSettings' | Should -Be 'LocalGpo'
        Get-OpenPathPolicyStoreLastOwner -Key 'Software\Policies\Mozilla\Firefox' -ValueName 'ExtensionSettings' | Should -Be 'LocalGpo'
    }

    It 'Survives the loss of the install root data folder' {
        Set-OpenPathPolicyStoreLastOwner -Key 'Software\Policies\Mozilla\Firefox' -ValueName 'ExtensionSettings' -Owner 'DomainGpo' | Out-Null
        Test-Path -LiteralPath $global:PSLLegacy | Should -BeFalse
        Get-OpenPathPolicyStoreLastOwner -Key 'Software\Policies\Mozilla\Firefox' -ValueName 'ExtensionSettings' | Should -Be 'DomainGpo'
    }

    It 'Migrates the legacy file into the registry and deletes it' {
        [System.IO.File]::WriteAllText($global:PSLLegacy, '{"lists":{},"lastOwners":{"K|V":"Mdm"}}')
        Get-OpenPathPolicyStoreLastOwner -Key 'K' -ValueName 'V' | Should -Be 'Mdm'
        Test-Path -LiteralPath $global:PSLLegacy | Should -BeFalse
        ($global:PSLReg["$($script:LedgerKey)|Ledger"].Value | ConvertFrom-Json).lastOwners.'K|V' | Should -Be 'Mdm'
    }

    It 'Prefers the registry ledger over a stale legacy file' {
        $global:PSLKeys[$script:LedgerKey] = $true
        $global:PSLReg["$($script:LedgerKey)|Ledger"] = [pscustomobject]@{ Type = 'String'; Value = '{"lists":{},"lastOwners":{"K|V":"LocalGpo"}}' }
        [System.IO.File]::WriteAllText($global:PSLLegacy, '{"lists":{},"lastOwners":{"K|V":"Mdm"}}')
        Get-OpenPathPolicyStoreLastOwner -Key 'K' -ValueName 'V' | Should -Be 'LocalGpo'
    }

    It 'Remove-OpenPathPolicyStoreLedger deletes the registry key and any legacy file' {
        Set-OpenPathPolicyStoreLastOwner -Key 'K' -ValueName 'V' -Owner 'LocalGpo' | Out-Null
        [System.IO.File]::WriteAllText($global:PSLLegacy, '{}')
        Remove-OpenPathPolicyStoreLedger | Should -BeTrue
        $global:PSLKeys.ContainsKey($script:LedgerKey) | Should -BeFalse
        Test-Path -LiteralPath $global:PSLLegacy | Should -BeFalse
        Get-OpenPathPolicyStoreLastOwner -Key 'K' -ValueName 'V' | Should -Be ''
    }

    It 'Remove-OpenPathPolicyStoreLedger never throws' {
        $global:PSLKeys[$script:LedgerKey] = $true
        Mock Remove-Item { throw 'access denied' } -ModuleName PolicyStore -ParameterFilter { "$LiteralPath" -like 'HKLM:*' }
        { Remove-OpenPathPolicyStoreLedger } | Should -Not -Throw
        Remove-OpenPathPolicyStoreLedger | Should -BeFalse
    }
}

Describe 'PolicyStore local GPO lock' {
    BeforeAll {
        $script:StoreModule = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'lib') 'PolicyStore.psm1'
        Import-Module $script:StoreModule -Force -ErrorAction Stop
    }

    It 'Times out while another thread holds the mutex and acquires it once released' {
        $release = New-Object System.Threading.ManualResetEvent($false)
        $held = New-Object System.Threading.ManualResetEvent($false)
        $ps = [powershell]::Create()
        [void]$ps.AddScript({
                param($Held, $Release)
                $m = New-Object System.Threading.Mutex($false, 'Global\OpenPath-LocalGpo-v1')
                [void]$m.WaitOne()
                [void]$Held.Set()
                [void]$Release.WaitOne(10000)
                $m.ReleaseMutex()
                $m.Dispose()
            }).AddArgument($held).AddArgument($release)
        $async = $ps.BeginInvoke()
        try {
            $held.WaitOne(10000) | Should -BeTrue
            $busy = & (Get-Module PolicyStore) { Enter-OpenPathLocalGpoLock -TimeoutMs 200 }
            $busy | Should -BeNullOrEmpty
            [void]$release.Set()
            [void]$ps.EndInvoke($async)
            $lock = & (Get-Module PolicyStore) { Enter-OpenPathLocalGpoLock -TimeoutMs 2000 }
            $lock | Should -Not -BeNullOrEmpty
            & (Get-Module PolicyStore) { param($l) Exit-OpenPathLocalGpoLock -Lock $l } $lock
        }
        finally {
            [void]$release.Set()
            $ps.Dispose()
        }
    }
}
