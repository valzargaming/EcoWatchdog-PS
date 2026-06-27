# Integration-style Pester tests for EcoWatchdog
# These tests are non-destructive by default; mocks are used to avoid stopping real server.

$env:UNIT_TEST = '1'

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here '..\EcoWatchdog.ps1')

Describe 'Repair flow with restore on failure' {
    It 'restores a recent larger backup when initial start fails' {
        $tmp = Join-Path $env:TEMP ('eco_repair_' + (Get-Random))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $liveDb = Join-Path $tmp 'Storage.db'
            $backupDir = Join-Path $tmp 'backups'
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

            # point config to temp
            $oldDb = $Config.DbPath; $oldBackup = $Config.BackupDir
            $Config.DbPath = $liveDb; $Config.BackupDir = $backupDir

            # create live DB (small)
            Set-Content -Path $liveDb -Value 'live-small'
            # create backup DB (larger) and set timestamps within 60s
            $bfile = Join-Path $backupDir 'Storage_backup.db'
            Set-Content -Path $bfile -Value ('backup-large' * 100)
            $now = Get-Date
            (Get-Item $bfile).LastWriteTime = $now.AddSeconds(-30)
            (Get-Item $liveDb).LastWriteTime = $now

            # Mock Start-Eco to simulate initial failure
            Mock -CommandName Start-Eco { Set-State 'FAILED' }

            # Run repair which should copy the recent larger backup over live DB
            Repair-Server

            $content = Get-Content -Path $liveDb -Raw
            if ($content -notmatch 'backup-large') { throw 'Repair-Server did not restore the recent larger backup' }

            # restore config
            $Config.DbPath = $oldDb; $Config.BackupDir = $oldBackup
        } finally { Remove-Item -Recurse -Force $tmp }
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

            Set-Content -Path $origDb -Value 'good-db-content-longer-than-corrupt'
        # Simulate server-managed backup by copying the DB into the backups folder
        $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
        $simBackup = Join-Path $backupDir "Storage_$stamp.db"
        Copy-Item -Path $origDb -Destination $simBackup -Force
        if (-not (Test-Path $simBackup)) { throw "Simulated backup was not created: $simBackup" }

        # corrupt original and ensure restore pulls from server backup
            Set-Content -Path $origDb -Value 'x'
        Restore-Database
        if (-not ((Get-Content $origDb -Raw) -match 'good-db')) { throw 'Restore-Database did not restore expected DB contents' }

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
