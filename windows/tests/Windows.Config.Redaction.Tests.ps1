# OpenPath Windows config model and redaction tests

Describe "Common Redaction" {
    BeforeAll {
        . (Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Redaction.ps1")
    }

    It "Redacts tokenized whitelist URLs while preserving the route shape" {
        $value = ConvertTo-OpenPathRedactedValue -Value "https://school.example/w/machine-token-123/whitelist.txt?etag=abc"

        $value | Should -Be "https://school.example/w/[redacted]/whitelist.txt?etag=abc"
        $value | Should -Not -Match "machine-token-123"
    }

    It "Leaves nonsensitive scalar values unchanged" {
        ConvertTo-OpenPathRedactedValue -Value "https://school.example/api" | Should -Be "https://school.example/api"
        ConvertTo-OpenPathRedactedValue -Value "classroom-123" | Should -Be "classroom-123"
        ConvertTo-OpenPathRedactedValue -Value 42 | Should -Be 42
    }

    It "Redacts nested object values without changing nonsensitive fields" {
        $redacted = ConvertTo-OpenPathRedactedObject -InputObject ([PSCustomObject]@{
                whitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
                apiUrl = "https://school.example"
                nested = [PSCustomObject]@{
                    callback = "https://school.example/w/other-token/whitelist.txt"
                    classroom = "group-a"
                }
            })

        $redacted.whitelistUrl | Should -Be "https://school.example/w/[redacted]/whitelist.txt"
        $redacted.apiUrl | Should -Be "https://school.example"
        $redacted.nested.callback | Should -Be "https://school.example/w/[redacted]/whitelist.txt"
        $redacted.nested.classroom | Should -Be "group-a"
    }
}

Describe "OpenPath Config Model" {
    BeforeAll {
        . (Join-Path $PSScriptRoot ".." "lib" "internal" "OpenPathConfig.Model.ps1")
    }

    It "Normalizes existing request setup config shapes without losing compatibility" {
        $config = ConvertTo-OpenPathNormalizedConfig -Config ([PSCustomObject]@{
                requestApiUrl = "https://school.example/"
                whitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
                classroom = "group-a"
                machineName = "lab-pc-01"
            })

        Get-OpenPathConfigValue -Config $config -Name "apiUrl" | Should -Be "https://school.example"
        Get-OpenPathConfigValue -Config $config -Name "requestApiUrl" | Should -Be "https://school.example"
        Get-OpenPathConfigValue -Config $config -Name "classroom" | Should -Be "group-a"
        Get-OpenPathConfigValue -Config $config -Name "classroomId" | Should -Be ""
        $config.PSObject.Properties["whitelistUrl"] | Should -Not -BeNullOrEmpty
    }

    It "Accepts existing classroomId request setup configs as valid" {
        $config = ConvertTo-OpenPathNormalizedConfig -Config ([PSCustomObject]@{
                apiUrl = "https://school.example"
                whitelistUrl = "https://school.example/w/machine-token-123/whitelist.txt"
                classroomId = "classroom-123"
            })

        $result = Test-OpenPathConfig -Config $config

        $result.Valid | Should -BeTrue
        @($result.MissingFields).Count | Should -Be 0
    }

    It "Accepts legacy non-tokenized http whitelist URLs as valid config" {
        $config = ConvertTo-OpenPathNormalizedConfig -Config ([PSCustomObject]@{
                apiUrl = "https://school.example"
                whitelistUrl = "https://school.example/export/group.txt"
                classroomId = "classroom-123"
            })

        $result = Test-OpenPathConfig -Config $config

        $result.Valid | Should -BeTrue
        @($result.MissingFields) | Should -Not -Contain "whitelistUrl"
    }

    It "Normalizes hashtable config input using config keys" {
        $config = ConvertTo-OpenPathNormalizedConfig -Config @{
            requestApiUrl = "https://school.example/"
            whitelistUrl = "https://school.example/export/group.txt"
            classroomId = "classroom-123"
        }

        Get-OpenPathConfigValue -Config $config -Name "apiUrl" | Should -Be "https://school.example"
        Get-OpenPathConfigValue -Config $config -Name "requestApiUrl" | Should -Be "https://school.example"
        Get-OpenPathConfigValue -Config $config -Name "whitelistUrl" | Should -Be "https://school.example/export/group.txt"
        Get-OpenPathConfigValue -Config $config -Name "classroomId" | Should -Be "classroom-123"
    }

    It "Keeps Set-OpenPathConfigValue semantics for existing and new properties" {
        $config = [PSCustomObject]@{ apiUrl = "https://old.example" }

        Set-OpenPathConfigValue -Config $config -Name "apiUrl" -Value "https://new.example"
        Set-OpenPathConfigValue -Config $config -Name "classroomId" -Value "classroom-123"

        $config.apiUrl | Should -Be "https://new.example"
        $config.classroomId | Should -Be "classroom-123"
    }
}
