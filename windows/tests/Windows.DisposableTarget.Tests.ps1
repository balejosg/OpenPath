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
        Mock Get-LocalUser { [pscustomobject]@{ Name = 'op-e2e-test'; Enabled = $true; SID = $script:testSid } } -ModuleName DisposableWindowsTarget
        Mock Get-LocalGroup { [pscustomobject]@{ Name = 'Administrators' } } -ModuleName DisposableWindowsTarget
        Mock Get-LocalGroupMember { @([pscustomobject]@{ SID = 'S-1-5-21-1-2-3-500' }) } -ModuleName DisposableWindowsTarget
        Mock Get-CimInstance {
            [pscustomobject]@{ SID = $script:testSid; LocalPath = $script:testPath; Special = $false; Loaded = $false }
        } -ModuleName DisposableWindowsTarget
        Mock New-LocalUser { [pscustomobject]@{ Name = 'op-e2e-test'; SID = $script:testSid } } -ModuleName DisposableWindowsTarget
        Mock Enable-LocalUser {} -ModuleName DisposableWindowsTarget
        Mock Invoke-OpenPathCreateDisposableProfile { $script:testPath } -ModuleName DisposableWindowsTarget
        Mock Remove-CimInstance {} -ModuleName DisposableWindowsTarget
        Mock Remove-LocalUser {} -ModuleName DisposableWindowsTarget
        Mock Add-LocalGroupMember {} -ModuleName DisposableWindowsTarget
    }

    It 'creates an enabled non-admin account with a materialized non-special profile without pre-populating the restricted group' {
        $target = New-OpenPathDisposableStandardTarget
        $target.Sid | Should -Be $script:testSid
        $target.ProfilePath | Should -Be $script:testPath
        [string]::IsNullOrWhiteSpace($target.Password) | Should -BeFalse
        Should -Invoke New-LocalUser -ModuleName DisposableWindowsTarget -Times 1
        Should -Invoke Enable-LocalUser -ModuleName DisposableWindowsTarget -Times 1
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
                return [pscustomobject]@{ SID = $script:testSid; LocalPath = $script:testPath; Special = $false; Loaded = $false }
            }
            return @()
        } -ModuleName DisposableWindowsTarget
        Mock Get-LocalUser { $null } -ModuleName DisposableWindowsTarget
        $target = [pscustomobject]@{ UserName = 'op-e2e-test'; Sid = $script:testSid; ProfilePath = $script:testPath; Password = 'not-serialized' }
        $cleanup = Remove-OpenPathDisposableStandardTarget -Target $target
        $cleanup.profileRemoved | Should -BeTrue
        $cleanup.userRemoved | Should -BeTrue
        $cleanup.credentialDestroyed | Should -BeTrue
        $target.Password | Should -BeNullOrEmpty
        Should -Invoke Remove-CimInstance -ModuleName DisposableWindowsTarget -Times 1
        Should -Invoke Remove-LocalUser -ModuleName DisposableWindowsTarget -Times 1
    }
}
