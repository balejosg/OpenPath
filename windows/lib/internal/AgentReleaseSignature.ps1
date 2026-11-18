# Signed canary agent releases: verifies that a release manifest was produced by
# the release signing key before the agent downloads any file. Leaf helper,
# dot-sourced by the update module; it holds no module state.
#
# Canonical signed text (UTF-8, LF, every line newline-terminated):
#   openpath-agent-release-v1
#   <ring>
#   <build>
#   <sourceSha>
#   <path>\t<sha256>        (sorted by path, ordinal)
#
# Stable manifests keep the behavior they had before this leaf existed: only a
# non-stable ring requires a valid RSA/SHA-256 signature over that text.

function Get-OpenPathAgentReleaseCanonicalText {
    <#
    .SYNOPSIS
        Builds the exact UTF-8 text a canary release signature covers.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Manifest
    )

    $ring = if ($Manifest.PSObject.Properties['ring'] -and $null -ne $Manifest.ring) { [string]$Manifest.ring } else { '' }
    $build = if ($Manifest.PSObject.Properties['build'] -and $null -ne $Manifest.build) { [string]$Manifest.build } else { '' }
    $sourceSha = if ($Manifest.PSObject.Properties['sourceSha'] -and $null -ne $Manifest.sourceSha) { [string]$Manifest.sourceSha } else { '' }

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($file in @($Manifest.files)) {
        if ($null -eq $file) { continue }
        $path = if ($file.PSObject.Properties['path'] -and $null -ne $file.path) { [string]$file.path } else { '' }
        $sha256 = if ($file.PSObject.Properties['sha256'] -and $null -ne $file.sha256) { [string]$file.sha256 } else { '' }
        [void]$lines.Add($path + "`t" + $sha256)
    }

    $sorted = $lines.ToArray()
    [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)

    $canonical = "openpath-agent-release-v1`n" + $ring + "`n" + $build + "`n" + $sourceSha + "`n"
    foreach ($line in $sorted) {
        $canonical += $line + "`n"
    }
    return $canonical
}

function Test-OpenPathAgentReleaseSignature {
    <#
    .SYNOPSIS
        Tells whether a release manifest may be installed on this agent.
    .DESCRIPTION
        A manifest without a ring, or with ring `stable`, is accepted exactly as
        before signing existed. Every other ring needs `signature` (base64,
        RSA PKCS#1 v1.5 with SHA-256) over the canonical text and the public key
        shipped with the agent. Any unreadable key, malformed signature or
        verification error rejects the release; this function never throws.
    .PARAMETER Manifest
        The manifest object returned by the agent delivery endpoint.
    .PARAMETER PublicKeyXml
        Test-only override of the shipped RSA public key XML.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Manifest,

        [string]$PublicKeyXml = ''
    )

    if ($null -eq $Manifest) {
        return $false
    }

    $ring = if ($Manifest.PSObject.Properties['ring'] -and $null -ne $Manifest.ring) { [string]$Manifest.ring } else { '' }
    if ([string]::IsNullOrWhiteSpace($ring) -or
        [string]::Equals($ring, 'stable', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $signatureText = if ($Manifest.PSObject.Properties['signature'] -and $null -ne $Manifest.signature) { [string]$Manifest.signature } else { '' }
    if ([string]::IsNullOrWhiteSpace($signatureText)) {
        return $false
    }

    try {
        if ([string]::IsNullOrWhiteSpace($PublicKeyXml)) {
            $keyPath = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'agent-release-public-key.xml'
            if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) {
                return $false
            }
            $PublicKeyXml = Get-Content -LiteralPath $keyPath -Raw -Encoding UTF8
        }

        $key = [xml]$PublicKeyXml
        $modulusNode = $key.SelectSingleNode('/RSAKeyValue/Modulus')
        $exponentNode = $key.SelectSingleNode('/RSAKeyValue/Exponent')
        if ($null -eq $modulusNode -or $null -eq $exponentNode) {
            return $false
        }

        $parameters = New-Object System.Security.Cryptography.RSAParameters
        $parameters.Modulus = [Convert]::FromBase64String($modulusNode.InnerText)
        $parameters.Exponent = [Convert]::FromBase64String($exponentNode.InnerText)

        $signature = [Convert]::FromBase64String($signatureText.Trim())
        $canonical = Get-OpenPathAgentReleaseCanonicalText -Manifest $Manifest
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($canonical)

        $rsa = [System.Security.Cryptography.RSA]::Create()
        try {
            $rsa.ImportParameters($parameters)
            return [bool]$rsa.VerifyData(
                $bytes,
                $signature,
                [System.Security.Cryptography.HashAlgorithmName]::SHA256,
                [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
            )
        }
        finally {
            $rsa.Dispose()
        }
    }
    catch {
        return $false
    }
}
