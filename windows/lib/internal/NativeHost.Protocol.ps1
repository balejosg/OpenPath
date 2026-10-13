$script:NativeHostStdinStopLogged = $false
# Phase 8e E0.3: one UTF-8 preamble may precede the first frame (.NET Framework
# Process.StandardInput writes the console input encoding preamble). It is
# discarded once per process; the three checked bytes are kept when they are
# not a preamble so no frame byte is lost.
$script:NativeHostStdinPreambleChecked = $false
$script:NativeHostStdinPrefetched = New-Object byte[] 3
$script:NativeHostStdinPrefetchedCount = 0

function Read-NativeStdinBytes {
    # serves any bytes kept by the one-time preamble check before the stream.
    param(
        [Parameter(Mandatory = $true)]$Stdin,
        [Parameter(Mandatory = $true)][byte[]]$Buffer,
        [Parameter(Mandatory = $true)][int]$Offset,
        [Parameter(Mandatory = $true)][int]$Count
    )

    if ($script:NativeHostStdinPrefetchedCount -gt 0) {
        $take = [Math]::Min($Count, $script:NativeHostStdinPrefetchedCount)
        [Array]::Copy($script:NativeHostStdinPrefetched, 0, $Buffer, $Offset, $take)
        for ($i = $take; $i -lt $script:NativeHostStdinPrefetchedCount; $i++) {
            $script:NativeHostStdinPrefetched[$i - $take] = $script:NativeHostStdinPrefetched[$i]
        }
        $script:NativeHostStdinPrefetchedCount -= $take
        return $take
    }
    return $Stdin.Read($Buffer, $Offset, $Count)
}

function Test-NativeStdinPreamble {
    # discards a single UTF-8 preamble (EF BB BF) at the start of stdin, once
    # per process; no valid length (1..MaxMessageBytes) starts with it.
    param([Parameter(Mandatory = $true)]$Stdin)

    if ($script:NativeHostStdinPreambleChecked) { return $true }
    $script:NativeHostStdinPreambleChecked = $true
    $prefix = New-Object byte[] 3
    $prefixRead = 0
    while ($prefixRead -lt 3) {
        $chunk = $Stdin.Read($prefix, $prefixRead, (3 - $prefixRead))
        if ($chunk -le 0) {
            Write-NativeHostStdinReadStopped -Reason 'stdin-eof'
            return $false
        }
        $prefixRead += $chunk
    }
    if (-not ($prefix[0] -eq 0xEF -and $prefix[1] -eq 0xBB -and $prefix[2] -eq 0xBF)) {
        [Array]::Copy($prefix, 0, $script:NativeHostStdinPrefetched, 0, 3)
        $script:NativeHostStdinPrefetchedCount = 3
    }
    return $true
}

function Write-NativeHostStdinReadStopped {
    <#
    .SYNOPSIS
        One literal line per process explaining why the stdin reader stopped.
    .DESCRIPTION
        Phase 8e E0.1: the compiled host logs the same line (parity). The four
        header bytes are formatted as lowercase hex without separators
        ('efbbbf22' is the H1 signature); the payload is never included.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Reason,
        [byte[]]$Header = $null
    )

    if ($script:NativeHostStdinStopLogged) { return }
    $script:NativeHostStdinStopLogged = $true
    $line = "Native host stdin read stopped: reason=$Reason"
    if ($Header -and $Header.Length -eq 4) {
        $line = $line + ' header=' + ((@($Header | ForEach-Object { $_.ToString('x2') })) -join '')
    }
    $logCommand = Get-Command -Name Write-NativeHostLog -ErrorAction SilentlyContinue
    if ($logCommand) { Write-NativeHostLog $line }
}

function Read-NativeMessage {
    # reads a length-prefixed native messaging frame from stdin and returns the deserialized json object, or $null when the frame is truncated or exceeds the size limit.
    $stdin = [Console]::OpenStandardInput()
    if (-not (Test-NativeStdinPreamble -Stdin $stdin)) {
        return $null
    }
    $lengthBuffer = New-Object byte[] 4
    $read = 0
    while ($read -lt 4) {
        $chunk = Read-NativeStdinBytes -Stdin $stdin -Buffer $lengthBuffer -Offset $read -Count (4 - $read)
        if ($chunk -le 0) {
            Write-NativeHostStdinReadStopped -Reason 'stdin-eof'
            return $null
        }
        $read += $chunk
    }

    $length = [System.BitConverter]::ToInt32($lengthBuffer, 0)
    if ($length -le 0 -or $length -gt $script:MaxMessageBytes) {
        Write-NativeHostStdinReadStopped -Reason 'invalid-frame-length' -Header $lengthBuffer
        return $null
    }

    $payload = New-Object byte[] $length
    $offset = 0
    while ($offset -lt $length) {
        $chunk = Read-NativeStdinBytes -Stdin $stdin -Buffer $payload -Offset $offset -Count ($length - $offset)
        if ($chunk -le 0) {
            Write-NativeHostStdinReadStopped -Reason 'payload-eof'
            return $null
        }
        $offset += $chunk
    }

    $json = [System.Text.Encoding]::UTF8.GetString($payload)
    return $json | ConvertFrom-Json
}

function Write-NativeMessage {
    # serializes $Message to compressed json, prepends a 4-byte little-endian length, and writes the frame to stdout.
    param(
        [Parameter(Mandatory = $true)]
        [object]$Message
    )

    $stdout = [Console]::OpenStandardOutput()
    $json = $Message | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $lengthBytes = [System.BitConverter]::GetBytes([int]$bytes.Length)
    $stdout.Write($lengthBytes, 0, $lengthBytes.Length)
    $stdout.Write($bytes, 0, $bytes.Length)
    $stdout.Flush()
}
