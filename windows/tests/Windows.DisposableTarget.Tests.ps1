BeforeAll {
    foreach ($commandName in @(
        'Get-LocalUser', 'New-LocalUser', 'Enable-LocalUser', 'Remove-LocalUser',
        'Get-LocalGroup', 'Get-LocalGroupMember', 'Add-LocalGroupMember',
        'Get-CimInstance', 'Remove-CimInstance'
    )) {
        if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
            Set-Item -Path "Function:global:$commandName" -Value { param() }
        }
    }
    Import-Module (Join-Path $PSScriptRoot '..\..\tests\e2e\ci\DisposableWindowsTarget.psm1') -Force
}

Describe 'Canonical offline installer disposable target' {
    BeforeEach {
        $script:testSid = 'S-1-5-21-100-200-300-400'
        $script:testPath = Join-Path $TestDrive 'op-e2e-test'
        New-Item -ItemType Directory -Path $script:testPath -Force | Out-Null
        $script:testProfile = if (Get-Command New-CimInstance -ErrorAction SilentlyContinue) {
            New-CimInstance -ClassName Win32_UserProfile -Namespace root/cimv2 -ClientOnly -Property @{
                SID = $script:testSid
                LocalPath = $script:testPath
                Special = $false
                Loaded = $false
            }
        }
        else {
            [pscustomobject]@{ SID = $script:testSid; LocalPath = $script:testPath; Special = $false; Loaded = $false }
        }
        Mock Get-LocalUser { [pscustomobject]@{ Name = 'op-e2e-test'; Enabled = $true; SID = $script:testSid } } -ModuleName DisposableWindowsTarget
        Mock Get-LocalGroup { [pscustomobject]@{ Name = 'Administrators' } } -ModuleName DisposableWindowsTarget
        Mock Get-LocalGroupMember { @([pscustomobject]@{ SID = 'S-1-5-21-1-2-3-500' }) } -ModuleName DisposableWindowsTarget
        Mock Get-CimInstance {
            $script:testProfile
        } -ModuleName DisposableWindowsTarget
        Mock New-LocalUser { [pscustomobject]@{ Name = 'op-e2e-test'; SID = $script:testSid } } -ModuleName DisposableWindowsTarget
        Mock Enable-LocalUser {} -ModuleName DisposableWindowsTarget
        Mock Invoke-OpenPathCreateDisposableProfile { $script:testPath } -ModuleName DisposableWindowsTarget
        Mock Grant-OpenPathDisposableTargetUserRight {} -ModuleName DisposableWindowsTarget
        Mock Revoke-OpenPathDisposableTargetUserRight {} -ModuleName DisposableWindowsTarget
        Mock Remove-CimInstance {} -ModuleName DisposableWindowsTarget
        Mock Remove-LocalUser {} -ModuleName DisposableWindowsTarget
        Mock Add-LocalGroupMember {} -ModuleName DisposableWindowsTarget
        Mock Start-Sleep {} -ModuleName DisposableWindowsTarget
    }

    It 'creates an enabled non-admin account with a materialized non-special profile without pre-populating the restricted group' {
        $target = New-OpenPathDisposableStandardTarget
        $target.Sid | Should -Be $script:testSid
        $target.ProfilePath | Should -Be $script:testPath
        [string]::IsNullOrWhiteSpace($target.Password) | Should -BeFalse
        Should -Invoke New-LocalUser -ModuleName DisposableWindowsTarget -Times 1
        Should -Invoke Enable-LocalUser -ModuleName DisposableWindowsTarget -Times 1
        Should -Invoke Grant-OpenPathDisposableTargetUserRight -ModuleName DisposableWindowsTarget -Times 1 -ParameterFilter {
            $Sid -eq $script:testSid -and $Right -eq 'SeBatchLogonRight'
        }
        Should -Invoke Add-LocalGroupMember -ModuleName DisposableWindowsTarget -Times 0
    }

    It 'rejects a target whose profile was not materialized' {
        Mock Get-CimInstance { @() } -ModuleName DisposableWindowsTarget
        $target = [pscustomobject]@{ UserName = 'op-e2e-test'; Sid = $script:testSid; ProfilePath = $script:testPath }
        { Assert-OpenPathDisposableTarget -Target $target } | Should -Throw '*disposable-target-profile-not-materialized*'
    }

    It 'rejects an administrator target' {
        Mock Get-LocalGroupMember { @([pscustomobject]@{ SID = $script:testSid }) } -ModuleName DisposableWindowsTarget
        $target = [pscustomobject]@{ UserName = 'op-e2e-test'; Sid = $script:testSid; ProfilePath = $script:testPath }
        { Assert-OpenPathDisposableTarget -Target $target } | Should -Throw '*disposable-target-is-administrator*'
    }

    It 'removes the profile and account and clears the ephemeral credential' {
        $script:profileQueryCount = 0
        Mock Get-CimInstance {
            $script:profileQueryCount++
            if ($script:profileQueryCount -eq 1) {
                return $script:testProfile
            }
            return @()
        } -ModuleName DisposableWindowsTarget
        Mock Get-LocalUser { $null } -ModuleName DisposableWindowsTarget
        $target = [pscustomobject]@{ UserName = 'op-e2e-test'; Sid = $script:testSid; ProfilePath = $script:testPath; Password = 'not-serialized'; BatchLogonRightGranted = $true }
        $cleanup = Remove-OpenPathDisposableStandardTarget -Target $target
        $cleanup.profileRemoved | Should -BeTrue
        $cleanup.userRemoved | Should -BeTrue
        $cleanup.credentialDestroyed | Should -BeTrue
        $target.Password | Should -BeNullOrEmpty
        Should -Invoke Remove-CimInstance -ModuleName DisposableWindowsTarget -Times 1
        Should -Invoke Revoke-OpenPathDisposableTargetUserRight -ModuleName DisposableWindowsTarget -Times 1 -ParameterFilter {
            $Sid -eq $script:testSid -and $Right -eq 'SeBatchLogonRight'
        }
        Should -Invoke Remove-LocalUser -ModuleName DisposableWindowsTarget -Times 1
    }

    It 'waits for a task-loaded disposable profile to unload before removing it' {
        $loadedProfile = if (Get-Command New-CimInstance -ErrorAction SilentlyContinue) {
            New-CimInstance -ClassName Win32_UserProfile -Namespace root/cimv2 -ClientOnly -Property @{
                SID = $script:testSid
                LocalPath = $script:testPath
                Special = $false
                Loaded = $true
            }
        }
        else {
            [pscustomobject]@{ SID = $script:testSid; LocalPath = $script:testPath; Special = $false; Loaded = $true }
        }
        $script:profileQueryCount = 0
        Mock Get-CimInstance {
            $script:profileQueryCount++
            if ($script:profileQueryCount -eq 1) { return $loadedProfile }
            if ($script:profileQueryCount -eq 2) { return $script:testProfile }
            return @()
        } -ModuleName DisposableWindowsTarget
        Mock Get-LocalUser { $null } -ModuleName DisposableWindowsTarget
        $target = [pscustomobject]@{ UserName = 'op-e2e-test'; Sid = $script:testSid; ProfilePath = $script:testPath; Password = 'not-serialized'; BatchLogonRightGranted = $true }

        $cleanup = Remove-OpenPathDisposableStandardTarget -Target $target

        $cleanup.profileRemoved | Should -BeTrue
        Should -Invoke Start-Sleep -ModuleName DisposableWindowsTarget -Times 1
        Should -Invoke Remove-CimInstance -ModuleName DisposableWindowsTarget -Times 1
    }

    It 'transports sanitized Edge failure evidence across the nested Browser module boundary' {
        if (-not (Get-Command icacls.exe -ErrorAction SilentlyContinue)) {
            Set-Item -Path Function:global:icacls.exe -Value { $global:LASTEXITCODE = 0 }
        }
        if (-not (Get-Command New-OpenPathProbePayloadBinary -ErrorAction SilentlyContinue)) {
            Set-Item -Path Function:global:New-OpenPathProbePayloadBinary -Value { }
        }
        foreach ($commandName in @('Get-OpenPathLastBoundaryProbeFailureEvidence', 'Invoke-StudentExecutableTaskProbe', 'Invoke-OpenPathEdgeBoundaryDiagnostic')) {
            if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
                Set-Item -Path "Function:global:$commandName" -Value { param() }
            }
        }
        $target = [pscustomobject]@{
            UserName = 'op-e2e-test'
            Password = 'not-serialized'
            Sid = $script:testSid
            ProfilePath = $script:testPath
        }
        $edgeEvidence = [pscustomobject][ordered]@{
            probeName = 'Canonical Edge deny'
            executablePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
            studentSid = $script:testSid
            processes = @([pscustomobject]@{ processId = 5436; tokenUserSid = $script:testSid; restrictedGroupPresent = $true })
        }
        Mock Test-Path {
            param($LiteralPath, $PathType)
            if ([string]$LiteralPath -match '(?i)(firefox|msedge)\.exe$') { return $true }
            return $false
        } -ModuleName DisposableWindowsTarget
        Mock Import-Module {} -ModuleName DisposableWindowsTarget -ParameterFilter {
            [string]$Name -like '*BrowserBoundaryProbe.psm1'
        }
        Mock New-OpenPathProbePayloadBinary {} -ModuleName DisposableWindowsTarget
        Mock Invoke-OpenPathNativePolicyProbe { [pscustomobject]@{ status = 'ok' } } -ModuleName DisposableWindowsTarget
        Mock Get-OpenPathLastBoundaryProbeFailureEvidence { $edgeEvidence } -ModuleName DisposableWindowsTarget
        $script:boundaryProbeCallCount = 0
        Mock Invoke-StudentExecutableTaskProbe {
            $script:boundaryProbeCallCount++
            if ($script:boundaryProbeCallCount -eq 2) { throw 'simulated-edge-boundary-failure' }
            [pscustomobject]@{ status = 'pass'; evidence = [pscustomobject]@{} }
        } -ModuleName DisposableWindowsTarget

        $capturedException = $null
        try {
            Invoke-OpenPathInstalledBoundaryProbes -Target $target -OpenPathRoot 'C:\OpenPath'
        }
        catch {
            $capturedException = $_.Exception
        }

        $capturedException | Should -Not -BeNullOrEmpty
        $capturedException.Message | Should -Be 'boundary-edge-execution-failed'
        $capturedException.Data.Contains('OpenPathEdgeBoundaryEvidence') | Should -BeTrue
        $transportedEvidence = $capturedException.Data['OpenPathEdgeBoundaryEvidence']
        $transportedEvidence.probeName | Should -Be 'Canonical Edge deny'
        $transportedEvidence.processes[0].processId | Should -Be 5436
        ($transportedEvidence | ConvertTo-Json -Depth 8) | Should -Not -Match 'not-serialized|Password'

        Mock Invoke-OpenPathEdgeBoundaryDiagnostic { [pscustomobject]@{ status = 'pass'; attempts = @() } } -ModuleName DisposableWindowsTarget
        $repeat = Invoke-OpenPathDisposableEdgeBoundaryDiagnostic -UserName $target.UserName -Password $target.Password -ExecutablePath $edgeEvidence.executablePath -StudentSid $target.Sid
        $repeat.status | Should -Be 'pass'
    }
}
