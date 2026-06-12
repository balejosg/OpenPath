function Read-NativeMessage {
    # reads a length-prefixed native messaging frame from stdin and returns the deserialized json object, or $null when the frame is truncated or exceeds the size limit.
    $stdin = [Console]::OpenStandardInput()
    $lengthBuffer = New-Object byte[] 4
    $read = $stdin.Read($lengthBuffer, 0, 4)
    if ($read -ne 4) {
        return $null
    }

    $length = [System.BitConverter]::ToInt32($lengthBuffer, 0)
    if ($length -le 0 -or $length -gt $script:MaxMessageBytes) {
        return $null
    }

    $payload = New-Object byte[] $length
    $offset = 0
    while ($offset -lt $length) {
        $chunk = $stdin.Read($payload, $offset, $length - $offset)
        if ($chunk -le 0) {
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
