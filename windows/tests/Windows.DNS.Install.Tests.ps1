Describe "DNS Module - Install Contracts" {
    BeforeAll {
        $modulePath = Join-Path $PSScriptRoot ".." "lib"
        Import-Module "$modulePath\DNS.psm1" -Force -ErrorAction SilentlyContinue
    }

    Context "Max domains limit" {
        It "Truncates generated whitelist domains to the configured limit" {
            InModuleScope DNS {
                $definition = New-AcrylicHostsDefinition `
                    -WhitelistedDomains @('one.example.com', 'two.example.com', 'three.example.com') `
                    -DnsSettings ([PSCustomObject]@{
                        PrimaryDNS = '8.8.8.8'
                        SecondaryDNS = '8.8.4.4'
                        MaxDomains = 2
                    })

                $definition.WasTruncated | Should -BeTrue
                $definition.OriginalWhitelistedDomainCount | Should -Be 3
                @($definition.EffectiveWhitelistedDomains).Count | Should -Be 2
                @($definition.EffectiveWhitelistedDomains) | Should -Be @('one.example.com', 'two.example.com')
            }
        }
    }

    Context "Acrylic installation fallback" {
        It "Pins the Acrylic portable installer to a release with modern hosts-cache fixes" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.Acrylic.Install.ps1"
            $content = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                '$installerVersion = "2.2.1"',
                'https://github.com/balejosg/openpath/releases/download/acrylic-mirror-v$installerVersion/Acrylic-Portable.zip',
                'https://downloads.sourceforge.net/project/acrylic/Acrylic/$installerVersion/Acrylic-Portable.zip',
                'https://sourceforge.net/projects/acrylic/files/Acrylic/$installerVersion/Acrylic-Portable.zip/download',
                'https://master.dl.sourceforge.net/project/acrylic/Acrylic/$installerVersion/Acrylic-Portable.zip?viasf=1',
                'https://sourceforge.net/projects/acrylic/files/Acrylic/$installerVersion/Acrylic.exe/download'
            )
        }

        It "Validates SourceForge portable downloads before accepting them" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.Acrylic.Install.ps1"
            $content = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'function Test-AcrylicPortableArchive',
                '[System.IO.Compression.ZipFile]::OpenRead($Path)',
                'AcrylicService\.exe$',
                'Downloaded Acrylic archive from ${candidateUrl} was not a valid portable release'
            )
        }

        It "Pins Acrylic 2.2.1 downloads by SHA256 before extraction or execution" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.Acrylic.Install.ps1"
            $content = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'function Assert-AcrylicDownloadHash',
                '$portableZipSha256 = ''26a5601c813257c186cd69da617ee1fff254b84f3ecb542483af8f4a5cc520cd''',
                '$executableInstallerSha256 = ''be60bde686766a889a8878c8b27446ea3584e425583070eeef85b0b31c60adbc''',
                'Assert-AcrylicDownloadHash -Path $zipPath -ExpectedSha256 $portableZipSha256 -ArtifactName ''Acrylic-Portable.zip''',
                'Assert-AcrylicDownloadHash -Path $exePath -ExpectedSha256 $executableInstallerSha256 -ArtifactName ''Acrylic.exe'''
            )
        }

        It "Falls back to Chocolatey when the direct Acrylic download fails" {
            $modulePath = Join-Path $PSScriptRoot ".." "lib" "internal" "DNS.Acrylic.Install.ps1"
            $content = Get-Content $modulePath -Raw

            Assert-ContentContainsAll -Content $content -Needles @(
                'Direct Acrylic install failed',
                'Get-Command choco',
                'install acrylic-dns-proxy -y --no-progress',
                'ProgramData\chocolatey\lib\acrylic-dns-proxy',
                'Get-ChildItem -Path $searchRoot -Filter ''AcrylicService.exe'' -Recurse',
                'Register-AcrylicServiceFromPath -AcrylicPath $acrylicPath',
                'Acrylic DNS Proxy installed successfully via executable installer',
                'Chocolatey fallback completed with exit code $chocoExitCode but AcrylicService.exe was not found',
                'Acrylic DNS Proxy installed successfully via Chocolatey'
            )
        }
    }
}
