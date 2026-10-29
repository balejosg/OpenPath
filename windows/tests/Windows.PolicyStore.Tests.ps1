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
            param([string]$Key, [string]$ValueName, [string]$GpoId, [int]$Precedence)
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

    It 'MDM area Firefox~Policy~firefox~Extensions -> Mdm' {
        Mock Get-ChildItem { @([pscustomobject]@{ PSChildName = 'Firefox~Policy~firefox~Extensions'; Name = 'HKEY_LOCAL_MACHINE\x\Firefox~Policy~firefox~Extensions' }) } -ParameterFilter { $Path -like '*PolicyManager*' }
        $r = Get-OpenPathPolicyValueOwner -Key $script:FfKey -ValueName 'ExtensionSettings' -LocalPolPath $script:Missing
        $r.Owner | Should -Be 'Mdm'
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

    It 'Unreadable local Registry.pol propagates local-gpo-unreadable' {
        $bad = Join-Path $script:Case 'Registry.pol'
        [System.IO.File]::WriteAllBytes($bad, [byte[]](1,2,3,4,5,6,7,8,9))
        { Get-OpenPathPolicyValueOwner -Key $script:FfKey -ValueName 'X' -LocalPolPath $bad } | Should -Throw 'local-gpo-unreadable*'
    }
}
