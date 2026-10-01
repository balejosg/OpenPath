# Launches a command line inside the active console session as its interactive
# user (WTSQueryUserToken + CreateProcessAsUser). Runs as SYSTEM, so the guest
# harness can start Firefox in the student's desktop where the browser policy
# and the extension actually apply.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CommandLine,
    [string]$WorkingDirectory = 'C:\Users\Public'
)

$ErrorActionPreference = 'Stop'
$source = @'
using System;
using System.Runtime.InteropServices;

public static class OpenPathSessionLaunch
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [DllImport("kernel32.dll")]
    private static extern uint WTSGetActiveConsoleSessionId();

    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSQueryUserToken(int sessionId, out IntPtr token);

    [DllImport("userenv.dll", SetLastError = true)]
    private static extern bool CreateEnvironmentBlock(out IntPtr environment, IntPtr token, bool inherit);

    [DllImport("userenv.dll", SetLastError = true)]
    private static extern bool DestroyEnvironmentBlock(IntPtr environment);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CreateProcessAsUser(IntPtr token, string appName, string commandLine, IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, int creationFlags, IntPtr environment, string currentDirectory, ref STARTUPINFO startupInfo, out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public static string Run(string commandLine, string workingDirectory)
    {
        uint session = WTSGetActiveConsoleSessionId();
        if (session == 0xFFFFFFFF) { return "no-active-console-session"; }
        IntPtr token;
        if (!WTSQueryUserToken((int)session, out token))
        {
            return "wts-query-failed:" + Marshal.GetLastWin32Error();
        }
        IntPtr environment = IntPtr.Zero;
        try
        {
            bool hasEnv = CreateEnvironmentBlock(out environment, token, false);
            var startupInfo = new STARTUPINFO();
            startupInfo.cb = Marshal.SizeOf(startupInfo);
            startupInfo.lpDesktop = "winsta0\\default";
            PROCESS_INFORMATION processInformation;
            const int CREATE_UNICODE_ENVIRONMENT = 0x00000400;
            if (!CreateProcessAsUser(token, null, commandLine, IntPtr.Zero, IntPtr.Zero, false, CREATE_UNICODE_ENVIRONMENT, hasEnv ? environment : IntPtr.Zero, workingDirectory, ref startupInfo, out processInformation))
            {
                return "create-as-user-failed:" + Marshal.GetLastWin32Error() + ",session=" + session;
            }
            try { return "started,pid=" + processInformation.dwProcessId + ",session=" + session; }
            finally
            {
                CloseHandle(processInformation.hProcess);
                CloseHandle(processInformation.hThread);
            }
        }
        finally
        {
            if (environment != IntPtr.Zero) { DestroyEnvironmentBlock(environment); }
            CloseHandle(token);
        }
    }
}
'@
Add-Type -TypeDefinition $source -ErrorAction Stop
Write-Output ([OpenPathSessionLaunch]::Run($CommandLine, $WorkingDirectory))
