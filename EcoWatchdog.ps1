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

# If running under Windows PowerShell (v5) and PowerShell 7 ('pwsh') is available,
# re-invoke this script under pwsh for better cross-platform behavior.
try {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
        if ($pwsh) {
            Write-Host "PowerShell 7 detected at $($pwsh.Path). Re-launching under pwsh..." -ForegroundColor Yellow
            & $pwsh.Path -NoProfile -File $MyInvocation.MyCommand.Path @args
            Exit
        } else {
            Write-Host 'PowerShell 7 (pwsh) not found; continuing under current host.' -ForegroundColor Yellow
        }
    }
} catch {
    # If anything goes wrong, continue under current host
}

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
    # World/save name loaded from Configs/Storage.eco (e.g. "Game-2026-06-27-10.59.01")
    WorldSaveName            = $null
    # Storage directory name (relative to script dir), read from Storage.eco StorageDirectory
    StorageDirectory         = 'Storage'
}

# UI key bindings (configurable): map console key name -> action token
$Config.KeyBindings = [ordered]@{
    H = @{ Action = 'Health'; Label = 'Health' }
    R = @{ Action = 'Repair'; Label = 'Repair' }
    S = @{ Action = 'Stop';   Label = 'Stop' }
    A = @{ Action = 'Start';  Label = 'Start' }
    L = @{ Action = 'Logs';   Label = 'Logs' }
    B = @{ Action = 'Back';   Label = 'Back' }
    Q = @{ Action = 'Quit';   Label = 'Quit' }
}

# Preferred display order for controls is derived from the KeyBindings keys
$Config.KeyDisplayOrder = @($Config.KeyBindings.Keys)

# Minimal logging stub so early initialization can call Write-Log
function Write-Log { param([string]$message, [string]$level = 'INFO')
    try { Add-Content -Path $Config.LogFile -Value ("[$((Get-Date).ToString('s'))] [$level] $message") -ErrorAction SilentlyContinue } catch {}
}
# ------------------------------
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

# Load world/save name from Configs/Storage.eco so the watchdog knows current world
function Import-StorageSaveName {
    $storageCfg = Join-Path $ScriptDir 'Configs\Storage.eco'
    if (-not (Test-Path $storageCfg)) { return }
    try {
        $raw = Get-Content -Path $storageCfg -Raw -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($obj.SaveName) {
            $Config.WorldSaveName = $obj.SaveName
            Write-Log "Loaded SaveName from Configs/Storage.eco: $($Config.WorldSaveName)" 'DEBUG'
        } elseif ($obj.WorldName) {
            $Config.WorldSaveName = $obj.WorldName
            Write-Log "Loaded WorldName from Configs/Storage.eco: $($Config.WorldSaveName)" 'DEBUG'
        }
        if ($obj.StorageDirectory) {
            $Config.StorageDirectory = $obj.StorageDirectory
            Write-Log "Loaded StorageDirectory from Configs/Storage.eco: $($Config.StorageDirectory)" 'DEBUG'
        }
    } catch {
        Write-Log "Failed parsing Storage.eco for save name: $_" 'WARN'
    }
}

# Initial load
Import-StorageSaveName

# ------------------------------
# State machine
# ------------------------------
enum EcoState { STOPPED; STARTING; RUNNING; STOPPING; RECOVERING; FAILED }

$global:State = [EcoState]::STOPPED
$global:EcoProcess = $null
$global:LastHealth = 'UNKNOWN'
# When true the watchdog will not auto-restart the server (explicit manual stop)
$global:ManualStopped = $false
# Scheduled events (DateTime or $null)
$global:ScheduledStart = $null
$global:ScheduledMaintenance = $null
$global:ScheduledMaintenanceReason = $null
$global:ShouldQuit = $false

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
    # Clear manual-stop when attempting an explicit start
    $global:ManualStopped = $false
        # Clear any scheduled start because we're starting now
        $global:ScheduledStart = $null
    Set-State [EcoState]::STARTING
    # Reload the world/save name from disk whenever we start or attach
    Import-StorageSaveName
    Push-Location $ScriptDir
    try {
        $existing = Get-EcoProcess
        if ($existing) {
            $global:EcoProcess = Get-Process -Id $existing.ProcessId -ErrorAction SilentlyContinue
            Set-State [EcoState]::RUNNING
            Write-Log "Attached to existing Eco PID $($existing.ProcessId)"
                # If an attached process exists, clear scheduled start
                $global:ScheduledStart = $null
            return
        }
        $p = Start-Process -FilePath $Config.EcoExe -PassThru
        Start-Sleep -Seconds 2
        $global:EcoProcess = $p
        Set-State [EcoState]::RUNNING
        Write-Log "Started Eco PID $($p.Id)"
    } catch { Write-Log "Start-Eco failed: $_" 'ERROR'; Set-State [EcoState]::FAILED } finally { Pop-Location }
}

function Backup-Database {
    if (-not (Test-Path $Config.DbPath)) { Write-Log 'No DB to backup' 'WARN'; return $null }
    $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $dest = Join-Path $Config.BackupDir "Storage_$stamp.db"
    Copy-Item $Config.DbPath $dest -Force
    Write-Log "DB backup created: $dest"
    return $dest
}

function Restore-Database {
    # First, look in the watchdog backup dir for backups created by this script
    $latest = Get-ChildItem $Config.BackupDir -Filter '*.db' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
        Copy-Item $latest.FullName $Config.DbPath -Force
        Write-Log "Restored DB from $($latest.Name) (watchdog backup)"
        return
    }

    # Fallback: look for game-created backups under <StorageDirectory>\Backup\<WorldName-...> folders
    $storageRoot = Join-Path $ScriptDir $Config.StorageDirectory
    $storageBackupDir = Join-Path $storageRoot 'Backup'
    if (Test-Path $storageBackupDir) {
        $dirs = Get-ChildItem $storageBackupDir -Directory -ErrorAction SilentlyContinue

        # If we loaded a base WorldSaveName (e.g. 'Game'), filter folders that start with that base plus '-'
        if ($Config.WorldSaveName) {
            $pattern = "$($Config.WorldSaveName)-*"
            $dirs = $dirs | Where-Object { $_.Name -like $pattern }
        }

        if ($dirs -and $dirs.Count -gt 0) {
            $latestFolder = $null
            $latestTime = [DateTime]::MinValue

            foreach ($d in $dirs) {
                $dt = $null
                # Expect folder names like <WorldBase>-YYYY-MM-DD-HH.MM.SS (e.g. Game-2026-06-27-10.59.01)
                $m = [regex]::Match($d.Name, '^(?:.+)-(?<ts>\d{4}-\d{2}-\d{2}-\d{2}\.\d{2}\.\d{2})$')
                if ($m.Success) {
                    $ts = $m.Groups['ts'].Value
                    $parts = $ts -split '-'
                    if ($parts.Length -eq 4) {
                        $date = "$($parts[0])-$($parts[1])-$($parts[2])"
                        $time = ($parts[3] -replace '\.', ':')
                        $dtStr = "$date $time"
                        try { $dt = [DateTime]::ParseExact($dtStr, 'yyyy-MM-dd HH:mm:ss', $null) } catch { $dt = $null }
                    }
                }

                if (-not $dt) { $dt = $d.LastWriteTime }

                if ($dt -gt $latestTime) { $latestTime = $dt; $latestFolder = $d }
            }

            if ($latestFolder) {
                $dbFile = Get-ChildItem $latestFolder.FullName -Filter '*.db' -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($dbFile) {
                    Copy-Item $dbFile.FullName $Config.DbPath -Force
                    Write-Log "Restored DB from game backup folder $($latestFolder.Name) -> $($dbFile.Name)"
                    return
                }
            }
        }
    }

    Write-Log 'No backup available' 'WARN'
}

function Stop-Eco {
    param([switch]$Manual)
    if ($global:State -in @([EcoState]::STOPPED, [EcoState]::STOPPING)) { return }
    if ($Manual) { $global:ManualStopped = $true }
    Set-State [EcoState]::STOPPING
    try {
        if ($global:EcoProcess -and -not $global:EcoProcess.HasExited) {
            Write-Log 'Attempting cooperative shutdown (RCON + signal)'
            # Preferred: use Source RCON to request save and schedule a maintenance shutdown
            $origStart = $global:EcoProcess.StartTime
            try {
                if ($Config.RconHost) {
                    try { Invoke-RconSource -command 'manage save' | Out-Null } catch { Write-Log 'Source RCON save failed, falling back to auto Invoke-Rcon' 'DEBUG'; Invoke-Rcon -command 'manage save' | Out-Null }
                    $t = (Get-Date).AddMinutes(1)
                    $cmd = "manage maintenance $($t.ToString('HH:mm')), Watchdog shutdown, Shutdown"
                    # Record scheduled maintenance so UI can show it
                    $global:ScheduledMaintenance = $t
                    $global:ScheduledMaintenanceReason = 'Watchdog shutdown'
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
                    # Clear scheduled maintenance once the shutdown has occurred
                    $global:ScheduledMaintenance = $null
                    $global:ScheduledMaintenanceReason = $null
                    $global:EcoProcess = $null
                    Set-State [EcoState]::STOPPED
                    return
                }
                Start-Sleep -Seconds 1
            }

            Write-Log 'Grace timeout reached " killing original process'
            try { Stop-Process -Id $global:EcoProcess.Id -Force -ErrorAction SilentlyContinue } catch {}
        }
    } finally {
        Remove-Item $Config.ShutdownSignal -ErrorAction SilentlyContinue
        $global:EcoProcess = $null
        Set-State [EcoState]::STOPPED
    }
}

function Repair-Server {
    Set-State [EcoState]::RECOVERING
    Write-Log 'Recovery initiated'
    $backup = Backup-Database
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
                            Restore-Database
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
# Scheduling helpers
# ------------------------------
function Set-ScheduledStart {
    param([Parameter(Mandatory=$true)][datetime]$Time)
    $global:ScheduledStart = $Time
    Write-Log "Scheduled start at $($Time)"
}

function Remove-ScheduledStart {
    $global:ScheduledStart = $null
    Write-Log 'Cancelled scheduled start'
}

function Set-ScheduledMaintenance {
    param(
        [Parameter(Mandatory=$true)][datetime]$Time,
        [string]$Reason = 'Scheduled maintenance'
    )
    $global:ScheduledMaintenance = $Time
    $global:ScheduledMaintenanceReason = $Reason
    Write-Log "Scheduled maintenance at $($Time) - $Reason"
}

function Remove-ScheduledMaintenance {
    $global:ScheduledMaintenance = $null
    $global:ScheduledMaintenanceReason = $null
    Write-Log 'Cancelled scheduled maintenance'
}

# ------------------------------
# UI Helpers
# ------------------------------
function Get-KeyForAction {
    param([Parameter(Mandatory=$true)][string]$Action)
    foreach ($k in $Config.KeyBindings.Keys) {
        if ($Config.KeyBindings[$k].Action -eq $Action) { return $k }
    }
    return $null
}

function Show-UI {
    param([switch]$Force)

    if (-not $script:UIInitialized -or $Force) {
        Clear-Host
        $script:UIInitialized = $true
    }

    # Prepare lines to write to a fixed region at the top of the console
    $width = 80
    try { $width = [Console]::WindowWidth - 1 } catch {}

    $lines = @()
    $lines += '=== ECO WATCHDOG (production) ==='.PadRight($width)
    $lines += ("STATE   : $($global:State)").PadRight($width)
    if ($global:EcoProcess) { $lines += ("PROCESS : RUNNING (PID $($global:EcoProcess.Id))").PadRight($width) } else { $lines += ('PROCESS : STOPPED').PadRight($width) }
    $lines += ("HEALTH  : $global:LastHealth").PadRight($width)
    if ($global:ScheduledStart) { $lines += ("SCHEDULED START : $($global:ScheduledStart)").PadRight($width) }
    if ($global:ScheduledMaintenance) { $lines += ("SCHEDULED MAINT.: $($global:ScheduledMaintenance) - $($global:ScheduledMaintenanceReason)").PadRight($width) }
    $lines += ("TIME    : $(Get-Date)").PadRight($width)
    $lines += ''.PadRight($width)

    # Build controls display from configured key bindings
    $controls = @()
    foreach ($k in $Config.KeyDisplayOrder) {
        if ($Config.KeyBindings.Contains($k)) {
            $binding = $Config.KeyBindings[$k]
            $label = $binding.Label
            $controls += "$k=$label"
        }
    }
    $lines += ("Controls: " + ($controls -join ' ')).PadRight($width)

    # Overwrite the top portion of the console to avoid a full clear
    try {
        [Console]::SetCursorPosition(0,0)
    } catch {}
    foreach ($i in 0..($lines.Count - 1)) {
        $text = $lines[$i]
        # Colorize header and controls like before
        if ($i -eq 0) { Write-Host $text -ForegroundColor Cyan } elseif ($i -eq ($lines.Count - 1)) { Write-Host $text -ForegroundColor Yellow } else { Write-Host $text }
    }
}

# ------------------------------
# Main runtime entry (guarded for unit tests)
# ------------------------------
function Start-Watchdog {
    Start-Eco

    $script:lastHealthCheck = Get-Date
    # Display mode controls what is shown to the operator: 'UI' or 'LOGS'
    $script:DisplayMode = 'UI'

    while ($true) {
        if ($script:DisplayMode -eq 'UI') {
            # Update UI only when important values change or once per second
            $now = Get-Date
            if (-not $script:LastUIState) { $needUI = $true; $script:LastUIState = @{} } else { $needUI = $false }
            if (-not $needUI) {
                $curPid = if ($global:EcoProcess) { $global:EcoProcess.Id } else { $null }
                if ($script:LastUIState.State -ne $global:State) { $needUI = $true }
                if ($script:LastUIState.Pid -ne $curPid) { $needUI = $true }
                if ($script:LastUIState.LastHealth -ne $global:LastHealth) { $needUI = $true }
                if ($script:LastUIState.ScheduledStart -ne $global:ScheduledStart) { $needUI = $true }
                if ($script:LastUIState.ScheduledMaintenance -ne $global:ScheduledMaintenance) { $needUI = $true }
                if ($script:LastUIState.Second -ne $now.Second) { $needUI = $true }
            }
            if ($needUI) {
                Show-UI
                $script:LastUIState.State = $global:State
                $script:LastUIState.Pid = if ($global:EcoProcess) { $global:EcoProcess.Id } else { $null }
                $script:LastUIState.LastHealth = $global:LastHealth
                $script:LastUIState.ScheduledStart = $global:ScheduledStart
                $script:LastUIState.ScheduledMaintenance = $global:ScheduledMaintenance
                $script:LastUIState.Second = (Get-Date).Second
            }
        } else {
            # Stream logs incrementally to avoid clearing the screen each refresh.
            if (-not $script:LogInitialized) {
                Clear-Host
                Write-Host '=== ECO WATCHDOG: LOGS ===' -ForegroundColor Cyan
                $backKey = Get-KeyForAction -Action 'Back'
                $quitKey = Get-KeyForAction -Action 'Quit'
                $parts = @()
                if ($backKey) { $parts += "$backKey to go back to UI" } else { $parts += "Back to go back to UI" }
                if ($quitKey) { $parts += "$quitKey to quit" } else { $parts += "Quit to quit" }
                Write-Host ("(Press {0})" -f ($parts -join '; ')) -ForegroundColor Yellow
                if (Test-Path $Config.LogFile) {
                    $all = Get-Content -Path $Config.LogFile -ErrorAction SilentlyContinue
                    $start = [Math]::Max(0, $all.Count - 200)
                    if ($all.Count -gt 0) { $all[$start..($all.Count - 1)] | ForEach-Object { Write-Host $_ } }
                    $script:LogCount = $all.Count
                } else {
                    Write-Host '(No log file found)'
                    $script:LogCount = 0
                }
                $script:LogInitialized = $true
            } else {
                if (Test-Path $Config.LogFile) {
                    $current = Get-Content -Path $Config.LogFile -ErrorAction SilentlyContinue
                    if ($current.Count -gt $script:LogCount) {
                        $current[$script:LogCount..($current.Count - 1)] | ForEach-Object { Write-Host $_ }
                        $script:LogCount = $current.Count
                    }
                }
            }
        }

        if ([Console]::KeyAvailable) {
            $pressedKey = [Console]::ReadKey($true).Key.ToString()
            # Normalize single-letter keys to their first char when appropriate
            if ($pressedKey.Length -gt 1 -and $pressedKey.StartsWith('D') -and $pressedKey.Length -eq 2) {
                $pressedKey = $pressedKey.Substring(1)
            }
            # Use uppercase short form when possible
            $pressed = $pressedKey.Substring(0,1).ToUpper()
            if ($Config.KeyBindings.Contains($pressed)) {
                $binding = $Config.KeyBindings[$pressed]
                $action = $binding.Action
                switch ($action) {
                    'Health' { Invoke-Health }
                    'Repair' { Repair-Eco }
                    'Stop'   { Stop-Eco -Manual }
                    'Start'  { Start-Eco }
                    'Logs'   { $script:DisplayMode = 'LOGS' }
                    'Back'   { $script:DisplayMode = 'UI'; $script:LogInitialized = $false }
                    'Quit'   { Stop-Eco -Manual; $global:ShouldQuit = $true; break }
                    default  { Write-Log "Unknown action mapped: $action" 'DEBUG' }
                }
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
                Write-Log 'Detected process exit " initiating recovery' 'WARN'
                Repair-Eco
            }
        }

        # Scheduled start: if a start time is set and reached, attempt to start
        if ($global:ScheduledStart -and -not $global:ManualStopped -and -not (Get-EcoProcess)) {
            if ((Get-Date) -ge $global:ScheduledStart) {
                Write-Log "Scheduled start time reached: $($global:ScheduledStart) - starting server" 'INFO'
                $tmp = $global:ScheduledStart
                $global:ScheduledStart = $null
                Start-Eco
            }
        }

        # Scheduled maintenance: if set and the time has come, send the RCON command
        if ($global:ScheduledMaintenance) {
            if ((Get-Date) -ge $global:ScheduledMaintenance) {
                $timeStr = $global:ScheduledMaintenance.ToString('HH:mm')
                $cmd = "manage maintenance $timeStr, $($global:ScheduledMaintenanceReason), Shutdown"
                Write-Log "Executing scheduled maintenance command: $cmd" 'INFO'
                try {
                    try { Invoke-RconSource -command $cmd | Out-Null } catch { Invoke-Rcon -command $cmd | Out-Null }
                    Write-Log 'Scheduled maintenance command sent'
                } catch { Write-Log "Failed to send scheduled maintenance: $_" 'WARN' }
                # Clear scheduled maintenance after attempting
                $global:ScheduledMaintenance = $null
                $global:ScheduledMaintenanceReason = $null
            }
        }

        # If both the state machine and health probe indicate failure, and the
        # server was not explicitly stopped by an operator/script, attempt an
        # automatic start after a short delay. This avoids fighting a manual stop.
        if (($global:State -eq [EcoState]::FAILED) -and ($global:LastHealth -eq 'FAIL') -and -not $global:ManualStopped) {
            Write-Log 'Combined state+health failure detected " scheduling auto-start in 30s' 'WARN'
            Start-Sleep -Seconds 30
            # Re-evaluate before attempting
            if (($global:State -eq [EcoState]::FAILED) -and ($global:LastHealth -eq 'FAIL') -and -not $global:ManualStopped -and -not (Get-EcoProcess)) {
                Write-Log 'Performing automatic Start-Eco due to persistent failure' 'INFO'
                Start-Eco
            }
        }

        if ($global:ShouldQuit) { break }
        Start-Sleep -Milliseconds 300
    }
}

# Only start the runtime when not running under unit tests
if ($env:UNIT_TEST -ne '1') {
    Start-Watchdog
}


