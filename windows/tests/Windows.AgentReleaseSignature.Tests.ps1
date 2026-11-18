#Requires -Modules Pester

# Signed canary releases: the agent accepts a non-stable ring only when the
# manifest carries an RSA/SHA-256 signature over the canonical text, using the
# public key shipped with the agent. Stable manifests keep their old behavior.

BeforeAll {
    $script:windowsRoot = Join-Path $PSScriptRoot '..'
    $script:internalPath = Join-Path (Join-Path $script:windowsRoot 'lib') 'internal'
    $script:leafPath = Join-Path $script:internalPath 'AgentReleaseSignature.ps1'
    $script:publicKeyPath = Join-Path (Join-Path $script:windowsRoot 'lib') 'agent-release-public-key.xml'

    . $script:leafPath

    $script:rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $script:parameters = $script:rsa.ExportParameters($true)
    $script:testPublicKeyXml = '<RSAKeyValue><Modulus>' +
        [Convert]::ToBase64String($script:parameters.Modulus) +
        '</Modulus><Exponent>' +
        [Convert]::ToBase64String($script:parameters.Exponent) +
        '</Exponent></RSAKeyValue>'

    function New-TestManifest {
        param(
            [string]$Ring = 'canary',
            [string]$Build = 'a1b2c3d4',
            [string]$SourceSha = '0123456789abcdef0123456789abcdef01234567',
            [object[]]$Files = @(
                [pscustomobject]@{ path = 'lib/Alpha.psm1'; sha256 = ('a' * 64) },
                [pscustomobject]@{ path = 'scripts/Run.ps1'; sha256 = ('b' * 64) }
            ),
            [string]$Signature = ''
        )

        return [pscustomobject]@{
            ring      = $Ring
            build     = $Build
            sourceSha = $SourceSha
            files     = $Files
            signature = $Signature
        }
    }

    function New-TestCanonicalText {
        param([object]$Manifest)

        $lines = @(
            $Manifest.files |
                ForEach-Object { ([string]$_.path) + "`t" + ([string]$_.sha256) } |
                Sort-Object -CaseSensitive
        )
        $text = "openpath-agent-release-v1`n" + [string]$Manifest.ring + "`n" +
            [string]$Manifest.build + "`n" + [string]$Manifest.sourceSha + "`n"
        foreach ($line in $lines) { $text += $line + "`n" }
        return $text
    }

    function New-SignedManifest {
        param(
            [string]$Ring = 'canary',
            [string]$Build = 'a1b2c3d4',
            [string]$SourceSha = '0123456789abcdef0123456789abcdef01234567',
            [object[]]$Files = @(
                [pscustomobject]@{ path = 'lib/Alpha.psm1'; sha256 = ('a' * 64) },
                [pscustomobject]@{ path = 'scripts/Run.ps1'; sha256 = ('b' * 64) }
            )
        )

        $manifest = New-TestManifest -Ring $Ring -Build $Build -SourceSha $SourceSha -Files $Files
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes((New-TestCanonicalText $manifest))
        $manifest.signature = [Convert]::ToBase64String(
            $script:rsa.SignData(
                $bytes,
                [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
            )
        )
        return $manifest
    }

    function Test-Signature {
        param([object]$Manifest)
        return [bool](Test-OpenPathAgentReleaseSignature -Manifest $Manifest -PublicKeyXml $script:testPublicKeyXml)
    }
}

AfterAll {
    if ($script:rsa) { $script:rsa.Dispose() }
}

Describe 'Test-OpenPathAgentReleaseSignature' {
    It 'accepts a valid canary signature' {
        Test-Signature (New-SignedManifest) | Should -BeTrue
    }

    It 'rejects a manifest whose file hash changed after signing' {
        $manifest = New-SignedManifest
        $manifest.files[0].sha256 = ('c' * 64)
        Test-Signature $manifest | Should -BeFalse
    }

    It 'rejects a manifest whose build changed after signing' {
        $manifest = New-SignedManifest
        $manifest.build = 'ffffffff'
        Test-Signature $manifest | Should -BeFalse
    }

    It 'rejects a manifest whose source SHA changed after signing' {
        $manifest = New-SignedManifest
        $manifest.sourceSha = 'ffffffffffffffffffffffffffffffffffffffff'
        Test-Signature $manifest | Should -BeFalse
    }

    It 'rejects a non-stable ring changed after signing' {
        $manifest = New-SignedManifest -Ring 'canary'
        $manifest.ring = 'beta'
        Test-Signature $manifest | Should -BeFalse
    }

    It 'rejects a manifest whose file path changed after signing' {
        $manifest = New-SignedManifest
        $manifest.files[1].path = 'scripts/Other.ps1'
        Test-Signature $manifest | Should -BeFalse
    }

    It 'accepts the same files published in another order because the text is sorted' {
        $files = @(
            [pscustomobject]@{ path = 'lib/Alpha.psm1'; sha256 = ('a' * 64) },
            [pscustomobject]@{ path = 'scripts/Run.ps1'; sha256 = ('b' * 64) }
        )
        $manifest = New-SignedManifest -Files $files
        $manifest.files = @($manifest.files[1], $manifest.files[0])
        Test-Signature $manifest | Should -BeTrue
    }

    It 'rejects a canary without a signature' {
        Test-Signature (New-TestManifest) | Should -BeFalse
    }

    It 'rejects a canary with an invalid base64 signature without throwing' {
        $manifest = New-TestManifest -Signature 'not-base64!'
        { Test-Signature $manifest } | Should -Not -Throw
        Test-Signature $manifest | Should -BeFalse
    }

    It 'rejects a canary when the public key is unusable without throwing' {
        $manifest = New-TestManifest -Signature ('A' * 344)
        $result = Test-OpenPathAgentReleaseSignature -Manifest $manifest -PublicKeyXml '<RSAKeyValue></RSAKeyValue>'
        $result | Should -BeFalse
    }

    It 'keeps stable manifests working without a signature' {
        Test-Signature (New-TestManifest -Ring 'stable') | Should -BeTrue
    }

    It 'treats a manifest without a ring as stable' {
        $manifest = New-TestManifest -Ring ''
        Test-Signature $manifest | Should -BeTrue
    }

    It 'ships a parseable RSA public key' {
        Test-Path -LiteralPath $script:publicKeyPath -PathType Leaf | Should -BeTrue
        $key = [xml](Get-Content -LiteralPath $script:publicKeyPath -Raw)
        $modulus = [Convert]::FromBase64String($key.RSAKeyValue.Modulus)
        $exponent = [Convert]::FromBase64String($key.RSAKeyValue.Exponent)
        $modulus.Length | Should -BeGreaterThan 256
        $exponent.Length | Should -BeGreaterThan 0
    }

    It 'builds the canonical text with the version marker and sorted tab-separated lines' {
        $manifest = New-TestManifest
        $text = Get-OpenPathAgentReleaseCanonicalText -Manifest $manifest

        $text | Should -Be (
            "openpath-agent-release-v1`n" +
            "canary`n" +
            "a1b2c3d4`n" +
            "0123456789abcdef0123456789abcdef01234567`n" +
            "lib/Alpha.psm1`t" + ('a' * 64) + "`n" +
            "scripts/Run.ps1`t" + ('b' * 64) + "`n"
        )
    }
}

Describe 'Update flow integration' {
    It 'checks the release signature before the first file download' {
        $updatePath = Join-Path $script:internalPath 'Common.Update.ps1'
        $content = Get-Content -LiteralPath $updatePath -Raw

        $signatureCheck = $content.IndexOf('Test-OpenPathAgentReleaseSignature')
        $firstDownload = $content.IndexOf('Invoke-WebRequest -Uri $fileUrl')
        $signatureCheck | Should -BeGreaterThan -1
        $firstDownload | Should -BeGreaterThan -1
        $signatureCheck | Should -BeLessThan $firstDownload
    }

    It 'loads the leaf from the update runtime and protects it in the integrity baseline' {
        $runtime = Get-Content -LiteralPath (Join-Path (Join-Path $script:windowsRoot 'lib') 'Update.Runtime.psm1') -Raw
        $common = Get-Content -LiteralPath (Join-Path (Join-Path $script:windowsRoot 'lib') 'Common.psm1') -Raw
        $integrity = Get-Content -LiteralPath (Join-Path $script:internalPath 'Common.Integrity.ps1') -Raw

        $runtime.Contains('AgentReleaseSignature.ps1') | Should -BeTrue
        $common.Contains('AgentReleaseSignature.ps1') | Should -BeTrue
        $integrity.Contains('AgentReleaseSignature.ps1') | Should -BeTrue
        $integrity.Contains('agent-release-public-key.xml') | Should -BeTrue
    }
}
