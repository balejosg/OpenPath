Describe "Whitelist Validation" {
    Context "Content validation" {
        It "Common module validates minimum domain count" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.Http.Whitelist.ps1"
            $content = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'minRequiredDomains',
                'Invalid whitelist content'
            )
        }
    }
}

Describe "Log Rotation" {
    Context "Automatic rotation" {
        It "Common module implements log rotation" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "internal" "Common.System.ps1"
            $content = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Invoke-OpenPathLogRotation',
                'logMaxSizeMb',
                'Move-Item $LogPath "$LogPath.1"'
            )
        }
    }
}
