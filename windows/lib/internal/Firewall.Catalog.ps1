function Get-DefaultDohResolverIps {
    <#
    .SYNOPSIS
        Returns default DoH resolver IP catalog used for egress blocking
    #>
    return @(
        '8.8.8.8', '8.8.4.4',
        '2001:4860:4860::8888', '2001:4860:4860::8844',
        '1.1.1.1', '1.0.0.1',
        '2606:4700:4700::1111', '2606:4700:4700::1001',
        '9.9.9.9', '149.112.112.112',
        '2620:fe::fe', '2620:fe::9',
        '208.67.222.222', '208.67.220.220',
        '45.90.28.0', '45.90.30.0',
        '194.242.2.2', '194.242.2.3',
        '94.140.14.14', '94.140.15.15',
        '76.76.2.0', '76.76.10.0'
    )
}

function Get-DefaultVpnBlockRules {
    <#
    .SYNOPSIS
        Returns default VPN egress block rules (protocol/port/name)
    #>
    return @(
        [PSCustomObject]@{ Protocol = 'UDP'; Port = 1194; Name = 'OpenVPN' },
        [PSCustomObject]@{ Protocol = 'TCP'; Port = 1194; Name = 'OpenVPN-TCP' },
        [PSCustomObject]@{ Protocol = 'UDP'; Port = 51820; Name = 'WireGuard' },
        [PSCustomObject]@{ Protocol = 'TCP'; Port = 1723; Name = 'PPTP' },
        [PSCustomObject]@{ Protocol = 'UDP'; Port = 500; Name = 'IKE' },
        [PSCustomObject]@{ Protocol = 'UDP'; Port = 4500; Name = 'IPSec-NAT' }
    )
}

function Get-DefaultTorBlockPorts {
    <#
    .SYNOPSIS
        Returns default Tor-related TCP ports to block
    #>
    return @(9001, 9030, 9050, 9051, 9150)
}

function Get-DefaultResolverBypassClientPrograms {
    <#
    .SYNOPSIS
        Returns user-facing clients that must not reach public resolver IPs directly.
    #>
    $windowsRoot = if ($env:SystemRoot) { [string]$env:SystemRoot } elseif ($env:WINDIR) { [string]$env:WINDIR } else { 'C:\Windows' }
    $programFiles = if ($env:ProgramFiles) { [string]$env:ProgramFiles } else { 'C:\Program Files' }
    $programFilesX86 = if (${env:ProgramFiles(x86)}) { [string]${env:ProgramFiles(x86)} } else { 'C:\Program Files (x86)' }

    return @(
        "$windowsRoot\System32\curl.exe",
        "$windowsRoot\SysWOW64\curl.exe",
        "$windowsRoot\System32\nslookup.exe",
        "$windowsRoot\SysWOW64\nslookup.exe",
        "$windowsRoot\System32\WindowsPowerShell\v1.0\powershell.exe",
        "$windowsRoot\SysWOW64\WindowsPowerShell\v1.0\powershell.exe",
        "$programFiles\PowerShell\7\pwsh.exe",
        "$programFilesX86\PowerShell\7\pwsh.exe",
        "$programFiles\Mozilla Firefox\firefox.exe",
        "$programFilesX86\Mozilla Firefox\firefox.exe",
        "$programFiles\Google\Chrome\Application\chrome.exe",
        "$programFilesX86\Google\Chrome\Application\chrome.exe",
        "$programFiles\Microsoft\Edge\Application\msedge.exe",
        "$programFilesX86\Microsoft\Edge\Application\msedge.exe"
    ) | Where-Object { $_ } | Select-Object -Unique
}
