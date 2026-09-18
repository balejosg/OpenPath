<#
.SYNOPSIS
    Parse OpenPath Windows sources without executing them.
.DESCRIPTION
    This is deliberately a parser-only gate.  It never dot-sources or imports a
    source file, so a broken installer cannot mutate the machine while syntax is
    being checked.  The same script is used by Windows PowerShell 5.1 and pwsh.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$Root
)

$ErrorActionPreference = 'Stop'
$rootPath = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\', '/')
$roots = @(
    (Join-Path $rootPath 'windows'),
    (Join-Path $rootPath 'tests/e2e')
)
$excludedSegments = @('node_modules', '.git', 'coverage', 'dist', 'build', 'artifacts',
    '.turbo', 'test-results', 'playwright-report')
$files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
foreach ($sourceRoot in $roots) {
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { continue }
    foreach ($file in @(Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -ErrorAction Stop)) {
        if ($file.Extension -notin @('.ps1', '.psm1', '.psd1')) { continue }
        $relative = $file.FullName.Substring($rootPath.Length).TrimStart('\', '/')
        $segments = $relative -split '[\\/]'
        if (@($segments | Where-Object { $_ -in $excludedSegments }).Count -gt 0) { continue }
        [void]$files.Add($file)
    }
}

$errorCount = 0
foreach ($file in @($files | Sort-Object FullName)) {
    $tokens = $null
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$tokens, [ref]$parseErrors)
    $relative = $file.FullName.Substring($rootPath.Length).TrimStart('\', '/')
    foreach ($parseError in @($parseErrors)) {
        $errorCount++
        $line = $parseError.Extent.StartLineNumber
        $errorId = [string]$parseError.ErrorId
        Write-Error ("{0}:{1}: {2}: {3}" -f $relative, $line, $errorId, $parseError.Message)
    }
}

if ($files.Count -eq 0) {
    Write-Error 'No PowerShell source files were analysed.'
    exit 1
}
if ($errorCount -gt 0) { exit 1 }
Write-Output ("Parsed {0} PowerShell source files with no syntax errors." -f $files.Count)
exit 0
