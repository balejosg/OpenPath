# OpenPath Windows egress floor lab acceptance probe: pure helper unit tests

Import-Module (Join-Path $PSScriptRoot "..\..\tests\e2e\ci\EgressFloorProbe.psm1") -Force

Describe "Egress floor acceptance probe helpers" {
    Context "Observation parsing" {
        It "reads the last http code from curl-style output" {
            ConvertTo-OpenPathEgressProbeObservation -Kind Http -Output "http=000`r`nexit=0" | Should -Be 'unreachable'
            ConvertTo-OpenPathEgressProbeObservation -Kind Http -Output "noise http=000 retry http=301 | exit=0" | Should -Be 'reachable'
        }

        It "returns unknown when the probe produced no http marker" {
            ConvertTo-OpenPathEgressProbeObservation -Kind Http -Output 'TASK-ERROR: access denied' | Should -Be 'unknown'
            ConvertTo-OpenPathEgressProbeObservation -Kind Http -Output '' | Should -Be 'unknown'
        }

        It "detects ping replies by the locale-independent TTL= marker" {
            ConvertTo-OpenPathEgressProbeObservation -Kind Ping -Output 'Respuesta desde 11.0.0.1: bytes=32 tiempo=4ms TTL=57' | Should -Be 'reachable'
            ConvertTo-OpenPathEgressProbeObservation -Kind Ping -Output "Paquetes: enviados = 2, recibidos = 0`r`nexit=1" | Should -Be 'unreachable'
            ConvertTo-OpenPathEgressProbeObservation -Kind Ping -Output 'NO-OUTPUT lastResult=0x41303' | Should -Be 'unknown'
        }
    }

    Context "Verdicts" {
        It "passes only when the observation matches the expectation" {
            Get-OpenPathEgressProbeVerdict -Expectation Blocked -Observation unreachable | Should -Be 'pass'
            Get-OpenPathEgressProbeVerdict -Expectation Blocked -Observation reachable | Should -Be 'fail'
            Get-OpenPathEgressProbeVerdict -Expectation Allowed -Observation reachable | Should -Be 'pass'
            Get-OpenPathEgressProbeVerdict -Expectation Allowed -Observation unreachable | Should -Be 'fail'
        }

        It "never turns an unknown observation into a pass" {
            Get-OpenPathEgressProbeVerdict -Expectation Blocked -Observation unknown | Should -Be 'unknown'
            Get-OpenPathEgressProbeVerdict -Expectation Allowed -Observation unknown | Should -Be 'unknown'
        }

        It "fails the run on any fail, unknown or required-but-missing fixture" {
            $pass = [pscustomobject]@{ status = 'pass' }
            Get-OpenPathEgressProbeOverallStatus -Probes @($pass, $pass) | Should -Be 'pass'
            Get-OpenPathEgressProbeOverallStatus -Probes @($pass, [pscustomobject]@{ status = 'unknown' }) | Should -Be 'fail'
            Get-OpenPathEgressProbeOverallStatus -Probes @($pass, [pscustomobject]@{ status = 'fail' }) | Should -Be 'fail'
            Get-OpenPathEgressProbeOverallStatus -Probes @($pass, [pscustomobject]@{ status = 'manual' }) | Should -Be 'pass-pending-manual'
            Get-OpenPathEgressProbeOverallStatus -Probes @() | Should -Be 'fail'
        }

        It "maps a missing fixture to skip, or fail when fixtures are required" {
            Get-OpenPathEgressProbeMissingFixtureStatus | Should -Be 'skip'
            Get-OpenPathEgressProbeMissingFixtureStatus -RequireFixtures | Should -Be 'fail'
        }
    }

    Context "Student task command line" {
        It "wraps the command for cmd /s /c and appends the exit code to the output file" {
            $argument = New-OpenPathEgressProbeCmdArgument -CommandLine 'C:\Windows\System32\curl.exe -s https://11.0.0.1/' -OutputPath 'C:\Probe\out\a.txt'
            $argument | Should -Be '/s /c "C:\Windows\System32\curl.exe -s https://11.0.0.1/ > "C:\Probe\out\a.txt" 2>&1 & echo exit=%errorlevel% >> "C:\Probe\out\a.txt""'
        }
    }

    Context "Secret redaction" {
        It "replaces every secret occurrence and ignores blank secrets" {
            $secret = 'Pw' + [guid]::NewGuid().ToString('N')
            $text = "user logon failed for $secret (again $secret)"
            $result = Protect-OpenPathEgressProbeText -Text $text -Secrets @($secret, '', $null)
            $result | Should -Not -Match ([regex]::Escape($secret))
            $result | Should -Be 'user logon failed for <redacted> (again <redacted>)'
        }
    }

    Context "Batch logon right" {
        It "appends the SID to an existing SeBatchLogonRight line once" {
            $lines = @('[Privilege Rights]', 'SeBatchLogonRight = *S-1-5-32-544,*S-1-5-32-551', 'SeServiceLogonRight = *S-1-5-20')
            $first = Add-OpenPathEgressProbeBatchLogonSid -Lines $lines -Sid 'S-1-5-21-1-2-3-1001'
            $first[1] | Should -Be 'SeBatchLogonRight = *S-1-5-32-544,*S-1-5-32-551,*S-1-5-21-1-2-3-1001'
            $second = Add-OpenPathEgressProbeBatchLogonSid -Lines $first -Sid 'S-1-5-21-1-2-3-1001'
            $second[1] | Should -Be $first[1]
        }

        It "adds the line under Privilege Rights when it is missing" {
            $lines = @('[Unicode]', 'Unicode=yes', '[Privilege Rights]', 'SeServiceLogonRight = *S-1-5-20')
            $result = Add-OpenPathEgressProbeBatchLogonSid -Lines $lines -Sid 'S-1-5-21-1-2-3-1001'
            $result[3] | Should -Be 'SeBatchLogonRight = *S-1-5-21-1-2-3-1001'
            $result.Count | Should -Be 5
        }
    }

    Context "Audit setting" {
        It "reads the numeric setting column by position, not by localized header" {
            $csv = @(
                'Nombre de equipo,Destino de directiva,Subcategoria,GUID de subcategoria,Configuracion de inclusion,Configuracion de exclusion,Valor de configuracion',
                'PC01,Sistema,Conexion de Plataforma de filtrado,{0CCE9226-69AE-11D9-BED3-505054503030},Error,,2'
            )
            ConvertFrom-OpenPathEgressProbeAuditCsv -Lines $csv | Should -Be 2
            ConvertFrom-OpenPathEgressProbeAuditCsv -Lines @('header only') | Should -BeNullOrEmpty
        }
    }

    Context "Runner script" {
        It "ships a parseable runner that never serializes passwords" {
            $scriptPath = Join-Path $PSScriptRoot '..\..\tests\e2e\ci\run-windows-egress-floor-probe.ps1'
            $tokens = $null
            $parseErrors = $null
            [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
            @($parseErrors).Count | Should -Be 0

            $content = Get-Content -LiteralPath $scriptPath -Raw
            $content | Should -Not -MatchExactly '\bpassword\s*=\s*\$'
            $content | Should -Not -Match 'ConvertTo-Json[^\r\n]*Password'
            $content | Should -Match 'Protect-OpenPathEgressProbeText'
        }
    }
}
