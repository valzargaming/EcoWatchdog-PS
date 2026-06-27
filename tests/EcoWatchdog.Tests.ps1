# Pester tests for EcoWatchdog.ps1

$env:UNIT_TEST = '1'

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here '..\EcoWatchdog.ps1')

Describe 'EcoWatchdog functions' {

    Context 'Move-Log' {
        It 'rotates when file exceeds max size' {
            $tmp = Join-Path $env:TEMP 'eco_watchdog_test.log'
            if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
            # create ~1KB file
            Set-Content -Path $tmp -Value ('X' * 1024)
            Move-Log -path $tmp -maxBytes 512 -maxBackups 3
            Test-Path ($tmp + '.1') | Should Be $true
            Remove-Item ($tmp + '.1') -ErrorAction SilentlyContinue
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
    }

    Context 'Write-Log' {
        It 'writes a log line to configured file' {
            $tmp = Join-Path $env:TEMP 'eco_watchdog_write.log'
            if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
            $Config.LogFile = $tmp
            Write-Log 'unit-test-entry' 'INFO'
            (Get-Content $tmp -Raw) | Should Match 'unit-test-entry'
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
    }

    Context 'Get-EcoProcess' {
        It 'returns process info or null' {
            $res = Get-EcoProcess
            if ($res) { $res.ExecutablePath | Should Be $Config.EcoExe } else { $res | Should Be $null }
        }
    }

    Context 'RCON' {
        It 'Invoke-Rcon throws when no RCON available (mocked)' {
            Mock New-TcpClient { return $null }
            { Invoke-Rcon 'status' } | Should Throw
        }
    }

    Context 'Health check' {
        It 'returns true when Invoke-WebRequest succeeds (mocked)' {
            Mock Invoke-WebRequest { return $null }
            (Test-Health) | Should Be $true
        }
    }
}
