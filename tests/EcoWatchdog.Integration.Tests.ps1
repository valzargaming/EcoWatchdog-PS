# Integration-style Pester tests for EcoWatchdog
# These tests are non-destructive by default; mocks are used to avoid stopping real server.

$env:UNIT_TEST = '1'

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here '..\EcoWatchdog.ps1')

Describe 'Repair flow with restore on failure' {
    It 'attempts Restore-LatestBackup when Start-Eco fails initially' {
        # Prepare mocks: Start-Eco fails, Restore-LatestBackup recorded
        Mock -CommandName Start-Eco { Set-State 'FAILED' }
        Mock -CommandName Restore-LatestBackup { } -Verifiable

        # Run Repair-Eco
        Repair-Eco

        # Assert restore called
        Assert-MockCalled -CommandName Restore-LatestBackup -Times 1
    }
}

Describe 'Backup and Restore real files in temp dir' {
    $tmpdir = Join-Path $env:TEMP ('eco_watchdog_files_' + (Get-Random))
    It 'backs up DB and restores latest' {
        New-Item -ItemType Directory -Path $tmpdir | Out-Null
        $origDb = Join-Path $tmpdir 'Storage.db'
        $backupDir = Join-Path $tmpdir 'backups'
        New-Item -ItemType Directory -Path $backupDir | Out-Null

        # point config to temp
        $oldDb = $Config.DbPath; $oldBackup = $Config.BackupDir
        $Config.DbPath = $origDb; $Config.BackupDir = $backupDir

        Set-Content -Path $origDb -Value 'good-db'
        $b = Backup-DB
        Test-Path $b | Should Be $true

        # corrupt original
        Set-Content -Path $origDb -Value 'corrupt'
        Restore-LatestBackup
        (Get-Content $origDb -Raw) | Should Match 'good-db'

        # cleanup
        $Config.DbPath = $oldDb; $Config.BackupDir = $oldBackup
        Remove-Item -Recurse -Force $tmpdir
    }
}

Describe 'Stop-Eco uses RCON and writes signal but does not kill when mocked' {
    It 'calls Invoke-Rcon and writes signal file' {
        $tmp = Join-Path $env:TEMP ('eco_watchdog_sig_' + (Get-Random))
        $Config.ShutdownSignal = $tmp
        Mock -CommandName Invoke-Rcon { } -Verifiable
        # Mock Get-Process to simulate a running process object for Stop-Eco to operate on
        $fakeProc = New-Object psobject -Property @{ Id = 99999; HasExited = $false }
        $global:EcoProcess = $fakeProc
        # Mock Get-Process used in Stop-Eco loop to return $null immediately
        Mock -CommandName Get-Process { return $null }

        Stop-Eco
        Assert-MockCalled -CommandName Invoke-Rcon -Times 1
        Test-Path $tmp | Should Be $false
    }
}
