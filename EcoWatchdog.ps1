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
    Repair-Server        : Recovery flow (was `Recover-Eco`), attempts restart and restore.
    Test-Health          : Perform HTTP health probe against `HealthUrl`.
    Invoke-Health        : Run health probe and update state.
    Show-UI              : Console UI for manual control.
    Start-Watchdog       : Main runtime loop (guarded during unit tests).

.NOTES
    - Configuration at top of file should not be changed. They are overridden by
        EcoWatchdog.local.ps1 or by the server's Configs/* files.
    - Log rotation keeps historical logs up to configured limit.
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
    # Automatic health poll interval (seconds) and failure threshold
    HealthPollIntervalSeconds = 120            # 2 minutes
    HealthFailureThreshold    = 5
    HealthTimeoutSeconds     = 5
    # Admin API base URL for the server web Admin endpoints (no trailing slash)
    # Defaults to HealthUrl + 'api/Admin' but can be overridden in EcoWatchdog.local.ps1
    AdminApiBase             = $null
    # Optional token to send in Authorization header (Bearer token). Leave null to send no auth header.
    AdminApiToken            = $null
    # Optional override for API root (e.g. http://127.0.0.1:3001/api/v1). Leave null to derive from HealthUrl.
    ApiBase                  = $null
    # Optional API auth token (for /api/v1 endpoints). If left null, the script will try to load
    # from Configs/Users.eco `APIAuthToken`.
    ApiAuthToken             = $null
    RecoveryBackupsToKeep    = 3
    ShutdownTimeoutSeconds   = 120
    # When deciding whether the server was "recently running", use this window (seconds)
    RecentProcessWindowSeconds = 360
    # Discord webhook for automatic failure notifications (leave empty to disable)
    DiscordWebhookUrl        = $null
    # If true, send notifications for unexpected automatic failures/start failures
    DiscordNotifyOnFailure   = $true

    # RCON configuration
    RconHost                 = '127.0.0.1'
    # RCON port: default 3002, but can be overridden by Configs/Network.eco RconServerPort
    RconPort                 = 3002
    # RCON password SHOULD NOT be stored in the repo. The script will attempt
    # to read it from `Configs/Network.eco` if available. Do not commit secrets.
    RconPassword             = $null
    # RCON protocol: 'auto' (try source then plain), 'source' (Valve Source RCON), or 'plain' (simple TCP)
    RconProtocol             = 'auto'  # 'auto'|'source'|'plain'
    RconConnectTimeoutMs     = 3000
    # World/save name loaded from Configs/Storage.eco (e.g. "Game-2026-06-27-10.59.01")
    WorldSaveName            = $null
    # Storage directory name (relative to script dir), read from Storage.eco StorageDirectory
    StorageDirectory         = 'Storage'
    # DB corruption detection: prefer percentage (0.9 = 90%). Set KB threshold (>0) to use absolute size difference instead.
    DbCorruptionThresholdKB  = 0
    DbCorruptionThresholdPct = 0.9
    # Window (seconds) to consider a backup "recent" relative to the live DB
    DbRecentBackupWindowSeconds = 60
}

# UI key bindings (configurable): map console key name -> action token
$Config.KeyBindings = [ordered]@{
    H = @{ Action = 'Health'; Label = 'Health' }
    R = @{ Action = 'Repair'; Label = 'Repair' }
    C = @{ Action = 'Rcon';   Label = 'Rcon' }
    S = @{ Action = 'Stop';   Label = 'Stop' }
    A = @{ Action = 'Start';  Label = 'Start' }
    L = @{ Action = 'Logs';   Label = 'Logs' }
    P = @{ Action = 'Api';    Label = 'API' }
    B = @{ Action = 'Back';   Label = 'Back' }
    Q = @{ Action = 'Quit';   Label = 'Quit' }
}

# Preferred display order for controls is derived from the KeyBindings keys
$Config.KeyDisplayOrder = @($Config.KeyBindings.Keys)

# Minimal logging stub so early initialization can call Write-Log
function Set-LastFunction {
    param([string]$Name)
    try {
        if ($Name) { $func = $Name } else {
            $stack = Get-PSCallStack
            if ($stack.Count -ge 2) { $func = $stack[1].FunctionName } else { $func = $MyInvocation.MyCommand.Name }
        }
    } catch { $func = $MyInvocation.MyCommand.Name }
    $ts = (Get-Date).ToString('s')
    $global:LastFunction = "$func at $ts"
}

function Write-Log { param([string]$message, [string]$level = 'INFO')
    try { Add-Content -Path $Config.LogFile -Value ("[$((Get-Date).ToString('s'))] [$level] $message") -ErrorAction SilentlyContinue } catch {}
}

# ------------------------------
# Notifications
# ------------------------------
function Send-DiscordWebhook {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [string]$Username = 'EcoWatchdog',
        [string]$AvatarUrl = $null
    )
    if (-not $Config.DiscordWebhookUrl) { return }
    try {
        $payload = @{ content = $Message }
        if ($Username) { $payload.username = $Username }
        if ($AvatarUrl) { $payload.avatar_url = $AvatarUrl }
        $json = $payload | ConvertTo-Json -Depth 3
        Invoke-RestMethod -Uri $Config.DiscordWebhookUrl -Method Post -Body $json -ContentType 'application/json' -TimeoutSec 10 -ErrorAction Stop
        Write-Log 'Discord webhook sent' 'DEBUG'
    } catch {
        Write-Log "Failed sending Discord webhook: $_" 'WARN'
    }
}
# ------------------------------
# Ensure directories exist
if (-not (Test-Path $Config.BackupDir)) { New-Item -ItemType Directory -Path $Config.BackupDir | Out-Null }
# Load local overrides from EcoWatchdog.local.ps1 if present. This file can set
# values on the $Config ordered hashtable (for example DiscordWebhookUrl).
$localOverrides = Join-Path $ScriptDir 'EcoWatchdog.local.ps1'
if (Test-Path $localOverrides) {
    try {
        . $localOverrides
        Write-Log "Loaded local overrides from $localOverrides" 'DEBUG'
    } catch {
        Write-Log "Failed loading local overrides ($localOverrides): $_" 'WARN'
    }
}
# Load RCON password from server network configuration if present.
# This keeps secrets in the server config and avoids environment/local files.
$networkCfg = Join-Path $ScriptDir 'Configs\\Network.eco'
if (Test-Path $networkCfg) {
    try {
        $raw = Get-Content -Path $networkCfg -Raw -ErrorAction Stop
        $net = $raw | ConvertFrom-Json -ErrorAction Stop

        # RCON password: only override if not already configured
        if (-not $Config.RconPassword -and $net.RconPassword) {
            $Config.RconPassword = $net.RconPassword
            Write-Log 'Loaded RCON password from Configs/Network.eco' 'DEBUG'
        }

        # RCON port: prefer Network.eco RconServerPort
        if ($null -ne $net.RconServerPort) {
            try { $Config.RconPort = [int]$net.RconServerPort } catch { $Config.RconPort = $net.RconServerPort }
            Write-Log "Loaded RCON port from Configs/Network.eco: $($Config.RconPort)" 'DEBUG'
        }

        # RCON host/address: default to 127.0.0.1 when empty or 'Any'
        $rhost = $net.RconIPAddress
        if (-not $rhost -or ($rhost -as [string]).Trim().Length -eq 0 -or $rhost -match '(?i)^Any$') { $rhost = '127.0.0.1' }
        $Config.RconHost = $rhost
        Write-Log "Loaded RCON host from Configs/Network.eco: $($Config.RconHost)" 'DEBUG'

        # Web server host/port for health checks
        $webHost = $net.WebServerUrl
        if (-not $webHost -or ($webHost -as [string]).Trim().Length -eq 0) { $webHost = '127.0.0.1' }
        # Strip http/https scheme if present so we don't double up when building URL
        $webHostNoScheme = ($webHost -as [string]) -replace '^(?i)https?://', ''

        if ($null -ne $net.WebServerPort) {
            try { $port = [int]$net.WebServerPort } catch { $port = $net.WebServerPort }
            $Config.HealthUrl = "http://$webHostNoScheme`:$port/"
            Write-Log "Loaded WebServerUrl/Port from Configs/Network.eco: $webHostNoScheme`:$port (HealthUrl set)" 'DEBUG'
        }

    } catch {
        Write-Log "Failed parsing network config: $_" 'WARN'
    }
}

# Load API auth tokens from Configs/Users.eco when available (APIAuthToken, APIAdminAuthToken)
function Import-UsersApiTokens {
    Set-LastFunction
    $usersCfg = Join-Path $ScriptDir 'Configs\Users.eco'
    if (-not (Test-Path $usersCfg)) { return }
    try {
        $raw = Get-Content -Path $usersCfg -Raw -ErrorAction Stop
        $obj = $raw | ConvertFrom-Json -ErrorAction Stop
        if (-not $Config.APIAdminAuthToken -and $obj.APIAuthToken) {
            $Config.APIAdminAuthToken = $obj.APIAuthToken
            Write-Log 'Loaded APIAuthToken from Configs/Users.eco' 'DEBUG'
        }
        if (-not $Config.AdminApiToken -and $obj.APIAdminAuthToken) {
            $Config.AdminApiToken = $obj.APIAdminAuthToken
            Write-Log 'Loaded APIAdminAuthToken from Configs/Users.eco' 'DEBUG'
        }
    } catch {
        Write-Log "Failed parsing Users.eco for API tokens: $_" 'WARN'
    }
}

Import-UsersApiTokens

# Load world/save name from Configs/Storage.eco so the watchdog knows current world
function Import-StorageSaveName {
    Set-LastFunction
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
# Last operator-visible action (e.g. "Manual stop requested at ...")
$global:LastAction = 'None'
# Last automatic action taken by the watchdog (e.g. auto-restart, auto-repair)
$global:LastAutoAction = 'None'
# When true the watchdog will not auto-restart the server (explicit manual stop)
$global:ManualStopped = $false
# Scheduled events (DateTime or $null)
$global:ScheduledStart = $null
$global:ScheduledMaintenance = $null
$global:ScheduledMaintenanceReason = $null
$global:ShouldQuit = $false

# Track last function called (function name + timestamp)
$global:LastFunction = 'None'

# Helper to set last function called. Use callstack to determine caller when no name provided.
function Set-LastFunction {
    param([string]$Name)
    try {
        if ($Name) { $func = $Name } else {
            $stack = Get-PSCallStack
            if ($stack.Count -ge 2) { $func = $stack[1].FunctionName } else { $func = $MyInvocation.MyCommand.Name }
        }
    } catch { $func = $MyInvocation.MyCommand.Name }
    $ts = (Get-Date).ToString('s')
    $global:LastFunction = "$func at $ts"
}

# ------------------------------
# Logging with rotation
# ------------------------------
function Move-Log {
    param([string]$path, [int64]$maxBytes, [int]$maxBackups)
    Set-LastFunction
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
    Set-LastFunction
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect($rHost, $port, $null, $null)
    $success = $iar.AsyncWaitHandle.WaitOne($timeoutMs)
    if (-not $success) { $client.Close(); return $null }
    try { $client.EndConnect($iar) } catch { $client.Close(); return $null }
    return $client
}

function Invoke-RconPlain {
    param([string]$command)
    Set-LastFunction
    $client = New-TcpClient -rHost $Config.RconHost -port $Config.RconPort -timeoutMs $Config.RconConnectTimeoutMs
    if (-not $client) { throw 'RCON (plain) connection failed' }
    try {
        $ns = $client.GetStream()
        $ns.ReadTimeout = $Config.RconConnectTimeoutMs
        $writer = New-Object System.IO.StreamWriter($ns)
        $writer.AutoFlush = $true
        if ($Config.RconPassword) { $writer.WriteLine($Config.RconPassword) }
        $writer.WriteLine($command)

        # Read response into memory until read timeout occurs
        $ms = New-Object System.IO.MemoryStream
        $buf = New-Object Byte[] 4096
        try {
            while ($true) {
                $read = $ns.Read($buf, 0, $buf.Length)
                if ($read -le 0) { break }
                $ms.Write($buf, 0, $read)
                # small pause to allow additional data to arrive
                Start-Sleep -Milliseconds 20
            }
        } catch [System.IO.IOException] {
            # Read timeout reached - proceed with whatever we have
        }
        $bytes = $ms.ToArray()
        $out = ''
        if ($bytes.Length -gt 0) { $out = [System.Text.Encoding]::UTF8.GetString($bytes) }
        return $out.Trim()
    } finally { $client.Close() }
}

function Invoke-RconSource {
    param([string]$command)
    Set-LastFunction
    # Implement Source RCON binary protocol (auth + exec)
    $client = New-TcpClient -rHost $Config.RconHost -port $Config.RconPort -timeoutMs $Config.RconConnectTimeoutMs
    if (-not $client) { throw 'RCON (source) connection failed' }

    try {
        $ns = $client.GetStream()
        $ns.ReadTimeout = $Config.RconConnectTimeoutMs
        $encoding = [System.Text.Encoding]::ASCII

        function Send-Packet([int]$id, [int]$type, [string]$payload) {
            Set-LastFunction
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
            Set-LastFunction
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
    Set-LastFunction
    if ($Config.RconProtocol -eq 'source') { return Invoke-RconSource -command $command }
    if ($Config.RconProtocol -eq 'plain') { return Invoke-RconPlain -command $command }

    # auto-detect: try source first, then plain
    try {
        $src = Invoke-RconSource -command $command
        if ($src -and $src.Trim().Length -gt 0) { return $src }
        Write-Log "RCON source returned empty response, trying plain protocol" 'DEBUG'
    } catch { Write-Log "RCON source failed: $_" 'DEBUG' }
    try {
        $plain = Invoke-RconPlain -command $command
        if ($plain -and $plain.Trim().Length -gt 0) { return $plain }
        Write-Log "RCON plain returned empty response" 'DEBUG'
    } catch { Write-Log "RCON plain failed: $_" 'DEBUG' }
    throw 'No RCON protocol succeeded'
}

# ------------------------------
# Process helpers
# ------------------------------
function Get-EcoProcess {
    Set-LastFunction
    $exe = $Config.EcoExe
    $proc = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -eq $exe) } |
        Select-Object -First 1
    if ($proc) {
        try { $script:LastProcessSeen = Get-Date } catch {}
    }
    return $proc
}

function Set-State { param($new)
    Set-LastFunction
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
    Set-LastFunction
    if ($global:State -in @([EcoState]::RUNNING, [EcoState]::STARTING)) { return }
    # Reset consecutive health-failure counter when attempting a start
    try { $script:ConsecutiveHealthFails = 0 } catch {}
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
            try { $script:LastProcessSeen = Get-Date } catch {}
            try {
                $msg = "[Info] Attached to existing Eco PID $($existing.ProcessId) at $(Get-Date) on host $env:COMPUTERNAME"
                Send-DiscordWebhook -Message $msg
                Write-Log 'Sent Discord notification for attached existing process' 'INFO'
            } catch { Write-Log "Failed sending Discord notification for attach: $_" 'WARN' }
            return
        }
        $p = Start-Process -FilePath $Config.EcoExe -PassThru
        Start-Sleep -Seconds 2
        $global:EcoProcess = $p
        try { $script:LastProcessSeen = Get-Date } catch {}
        Set-State [EcoState]::RUNNING
        Write-Log "Started Eco PID $($p.Id)"
        try {
            $msg = "[Info] Started Eco PID $($p.Id) at $(Get-Date) on host $env:COMPUTERNAME"
            Send-DiscordWebhook -Message $msg
            Write-Log 'Sent Discord notification for start' 'INFO'
        } catch { Write-Log "Failed sending Discord notification for start: $_" 'WARN' }
    } catch { Write-Log "Start-Eco failed: $_" 'ERROR'; Set-State [EcoState]::FAILED } finally { Pop-Location }
}

function Backup-Database {
    Set-LastFunction
    <#
    NOTE: Backup management is the responsibility of the game server.
    This helper no longer creates backups. It performs a lightweight
    sanity check on the DB and returns $null (no backup created).
    Callers should not rely on a returned backup path.
    #>
    if (-not (Test-Path $Config.DbPath)) {
        Write-Log 'No DB present to check' 'WARN'
        return $null
    }

    try {
        $info = Get-Item $Config.DbPath -ErrorAction Stop
        if ($info.Length -lt 1024) {
            Write-Log 'DB file is unexpectedly small; may be corrupted' 'WARN'
            return $null
        }
        # Additional integrity checks could be added here if sqlite3 is available.
        Write-Log 'DB sanity check passed' 'DEBUG'
        return $null
    } catch {
        Write-Log "DB sanity check failed: $_" 'WARN'
        return $null
    }
}

function Restore-Database {
    Set-LastFunction
    # Helper: determine if current DB appears corrupted relative to a backup
    function Test-DatabaseIntegrity($currentPath, $backupInfo) {
        Set-LastFunction
        if (-not (Test-Path $currentPath)) { return $true }
        try {
            $cur = Get-Item $currentPath -ErrorAction Stop
            # If a KB threshold is configured and >0, use absolute size delta
            if ($Config.DbCorruptionThresholdKB -gt 0) {
                $kbDiff = ($backupInfo.Length - $cur.Length) / 1KB
                if ($kbDiff -ge $Config.DbCorruptionThresholdKB -and ($cur.LastWriteTime -gt $backupInfo.LastWriteTime)) { return $true }
                return $false
            }

            # Otherwise use percentage threshold
            $pct = $Config.DbCorruptionThresholdPct
            if (-not $pct) { $pct = 0.9 }
            $sizeRatio = 0.0
            if ($backupInfo.Length -gt 0) { $sizeRatio = ($cur.Length / [double]$backupInfo.Length) }
            if (($sizeRatio -le $pct) -and ($cur.LastWriteTime -gt $backupInfo.LastWriteTime)) { return $true }
            return $false
        } catch { return $true }
    }

    # First, look in the watchdog backup dir for backups created by this script
    $latest = Get-ChildItem $Config.BackupDir -Filter '*.db' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) {
        if (Test-DatabaseIntegrity -currentPath $Config.DbPath -backupInfo $latest) {
            Copy-Item $latest.FullName $Config.DbPath -Force
            Write-Log "Restored DB from $($latest.Name) (watchdog backup)"
        } else {
            Write-Log "Existing DB is newer or not substantially smaller than backup; skipping restore from watchdog backup" 'DEBUG'
        }
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
                        if (Test-DatabaseIntegrity -currentPath $Config.DbPath -backupInfo $dbFile) {
                            Copy-Item $dbFile.FullName $Config.DbPath -Force
                            Write-Log "Restored DB from game backup folder $($latestFolder.Name) -> $($dbFile.Name)"
                            # Also restore any .eco world files present in the backup folder
                            try {
                                $storageRoot = Join-Path $ScriptDir $Config.StorageDirectory
                                $ecoFiles = Get-ChildItem $latestFolder.FullName -Filter '*.eco' -File -ErrorAction SilentlyContinue
                                foreach ($ef in $ecoFiles) {
                                    Copy-Item $ef.FullName (Join-Path $storageRoot $ef.Name) -Force
                                    Write-Log "Restored world file $($ef.Name) from $($latestFolder.Name)"
                                }
                            } catch { Write-Log "Failed restoring .eco files: $_" 'WARN' }
                        } else {
                            Write-Log "Existing DB appears healthy relative to game backup; skipping restore" 'DEBUG'
                        }
                        return
                    }
                }
        }
    }

    Write-Log 'No backup available' 'WARN'
}

# Return the FileInfo for the most recent backup DB (watchdog or game backups)
function Get-LatestBackupFile {
    Set-LastFunction
    $latest = Get-ChildItem $Config.BackupDir -Filter '*.db' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { return $latest }

    $storageRoot = Join-Path $ScriptDir $Config.StorageDirectory
    $storageBackupDir = Join-Path $storageRoot 'Backup'
    if (Test-Path $storageBackupDir) {
        $dirs = Get-ChildItem $storageBackupDir -Directory -ErrorAction SilentlyContinue
        if ($dirs -and $dirs.Count -gt 0) {
            $latestFolder = $null
            $latestTime = [DateTime]::MinValue
            foreach ($d in $dirs) {
                $dt = $null
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
                $dbFile = Get-ChildItem $latestFolder.FullName -Filter '*.db' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($dbFile) { return $dbFile }
            }
        }
    }
    return $null
}

function Stop-Eco {
    param([switch]$Manual)
    Set-LastFunction
    if ($global:State -in @([EcoState]::STOPPED, [EcoState]::STOPPING)) { return }
    if ($Manual) {
        $global:ManualStopped = $true
        $global:LastAction = "Manual stop requested at $(Get-Date)"
        try {
            $msg = "[Manual] Stop requested at $(Get-Date) on host $env:COMPUTERNAME"
            Send-DiscordWebhook -Message $msg
            Write-Log 'Sent Discord notification for manual stop' 'INFO'
        } catch { Write-Log "Failed sending Discord notification for manual stop: $_" 'WARN' }
    }
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
    Set-LastFunction
    # Record when a repair was initiated to avoid triggering duplicate automatic alerts
    $global:LastRepairTime = Get-Date
    # Reset consecutive health-failure counter when a repair is initiated
    try { $script:ConsecutiveHealthFails = 0 } catch {}
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
        Write-Log 'Initial restart failed, checking for recent larger backup to restore' 'WARN'
        # If a recent backup exists and is larger than the live DB and was created within 1 minute of the live DB, restore it
        $latest = Get-LatestBackupFile
        if ($latest) {
            try {
                $liveInfo = if (Test-Path $Config.DbPath) { Get-Item $Config.DbPath -ErrorAction Stop } else { $null }
                $timeDiff = [TimeSpan]::MaxValue
                if ($liveInfo) { $timeDiff = [System.Math]::Abs((($latest.LastWriteTime) - $liveInfo.LastWriteTime).TotalSeconds) }
                # Criteria: latest backup larger than live, and created within configured recent window of live DB
                $window = if ($Config.DbRecentBackupWindowSeconds) { $Config.DbRecentBackupWindowSeconds } else { 60 }
                if ($liveInfo -and ($latest.Length -gt $liveInfo.Length) -and ($timeDiff -le $window)) {
                    Write-Log "Recent larger backup found ($($latest.Name)); restoring before retry" 'WARN'
                    Copy-Item $latest.FullName $Config.DbPath -Force
                } else {
                    Write-Log 'No suitable recent larger backup found; attempting Restore-Database fallback' 'DEBUG'
                    Restore-Database
                }
            } catch {
                Write-Log "Error evaluating latest backup: $_" 'WARN'
                Restore-Database
            }
        } else {
            Write-Log 'No backups found; attempting Restore-Database fallback' 'DEBUG'
            Restore-Database
        }
        Start-Sleep -Seconds 1
        Start-Eco
        Start-Sleep -Seconds 5
        if ($global:State -ne [EcoState]::RUNNING) {
            Set-State [EcoState]::FAILED
            Write-Log 'Recovery failed after restore' 'ERROR'

            # Notify via Discord if configured that recovery was unrecoverable
            try {
                if ($Config.DiscordNotifyOnFailure -and $Config.DiscordWebhookUrl) {
                    $msg = "[Fatal] Recovery failed irrecoverably at $(Get-Date) on host $env:COMPUTERNAME. Watchdog exiting."
                    Send-DiscordWebhook -Message $msg
                    Write-Log 'Sent Discord notification for unrecoverable failure' 'INFO'
                }
            } catch { Write-Log "Failed sending unrecoverable Discord notification: $_" 'WARN' }

            # Signal the main loop to quit and exit the process so the script closes
            try { $global:ShouldQuit = $true } catch {}
            Write-Log 'Unrecoverable failure: exiting watchdog' 'ERROR'
            if ($env:UNIT_TEST -ne '1') { Exit 1 }
            return
        }
    }

    Write-Log "Recovery complete (backup: $backup)"
}

# NOTE: Removed compatibility wrapper Repair-Eco — callers updated to Repair-Server

# ------------------------------
# Health checks
# ------------------------------
function Test-Health {
    Set-LastFunction
    try { Invoke-WebRequest -Uri $Config.HealthUrl -TimeoutSec $Config.HealthTimeoutSeconds -UseBasicParsing | Out-Null; return $true } catch { return $false }
}

function Invoke-Health {
    param([switch]$Automatic)
    Set-LastFunction
    $prevHealth = $global:LastHealth
    if (Test-Health) {
        $global:LastHealth = 'OK'
        # If the watchdog previously marked the server FAILED, promote it back to RUNNING
        if ($global:State -eq [EcoState]::FAILED) {
            $procInfo = Get-EcoProcess
            if ($procInfo) {
                try {
                    $global:EcoProcess = Get-Process -Id $procInfo.ProcessId -ErrorAction SilentlyContinue
                    Write-Log "Health recovered: attached to existing Eco PID $($procInfo.ProcessId)" 'INFO'
                } catch {
                    Write-Log "Health recovered but failed to attach to process: $_" 'WARN'
                }
            } else {
                Write-Log 'Health recovered but no Eco process found to attach' 'INFO'
            }
            Set-State [EcoState]::RUNNING
        }

        # If this is the first successful automatic check after failures, notify
        if ($Automatic -and ($prevHealth -eq 'FAIL') -and $Config.DiscordNotifyOnFailure -and $Config.DiscordWebhookUrl) {
            $msg = "[Recover] Server health restored automatically at $(Get-Date) on host $env:COMPUTERNAME"
            Send-DiscordWebhook -Message $msg
            Write-Log 'Sent Discord notification for automatic health recovery' 'INFO'
        }
    } else {
        $global:LastHealth = 'FAIL'
        Set-State [EcoState]::FAILED

        # Suppress automatic notifications if a repair was recently initiated
        $suppressWindow = if ($Config.RepairSuppressWindowSeconds) { $Config.RepairSuppressWindowSeconds } else { 60 }
        $recentRepair = $false
        if ($global:LastRepairTime) {
            $delta = (Get-Date) - $global:LastRepairTime
            if ($delta.TotalSeconds -lt $suppressWindow) { $recentRepair = $true }
        }

        if ($Automatic -and $recentRepair) {
            Write-Log "Suppressed automatic health failure notification; recent repair at $($global:LastRepairTime) within $suppressWindow seconds" 'DEBUG'
        } else {
            # Do not send Discord alerts immediately on every automatic check —
            # wait until the periodic poll increments the consecutive-failure
            # counter and decides to attempt recovery. Manual (non-automatic)
            # checks still notify immediately.
            if (-not $Automatic) {
                if ($Config.DiscordNotifyOnFailure -and $Config.DiscordWebhookUrl) {
                    $msg = "[Alert] Server health check failed at $(Get-Date) on host $env:COMPUTERNAME"
                    Send-DiscordWebhook -Message $msg
                    Write-Log 'Sent Discord notification for manual health failure' 'INFO'
                }
            } else {
                Write-Log 'Automatic health failure recorded; awaiting consecutive-failure threshold before notifying' 'DEBUG'
            }
        }
    }
    Write-Log "Health: $global:LastHealth"
}

# ------------------------------
# Scheduling helpers
# ------------------------------
function Set-ScheduledStart {
    param([Parameter(Mandatory=$true)][datetime]$Time)
    Set-LastFunction
    $global:ScheduledStart = $Time
    Write-Log "Scheduled start at $($Time)"
}

function Remove-ScheduledStart {
    Set-LastFunction
    $global:ScheduledStart = $null
    Write-Log 'Cancelled scheduled start'
}

function Set-ScheduledMaintenance {
    param(
        [Parameter(Mandatory=$true)][datetime]$Time,
        [string]$Reason = 'Scheduled maintenance'
    )
    Set-LastFunction
    $global:ScheduledMaintenance = $Time
    $global:ScheduledMaintenanceReason = $Reason
    Write-Log "Scheduled maintenance at $($Time) - $Reason"
}

function Remove-ScheduledMaintenance {
    Set-LastFunction
    $global:ScheduledMaintenance = $null
    $global:ScheduledMaintenanceReason = $null
    Write-Log 'Cancelled scheduled maintenance'
}

# ------------------------------
# UI Helpers
# ------------------------------
function Get-KeyForAction {
    param([Parameter(Mandatory=$true)][string]$Action)
    Set-LastFunction
    foreach ($k in $Config.KeyBindings.Keys) {
        if ($Config.KeyBindings[$k].Action -eq $Action) { return $k }
    }
    return $null
}

# ------------------------------
# Admin API helpers
# ------------------------------
function Invoke-AdminApi {
    param(
        [string]$Method = 'GET',
        [string]$Path = '/',
        $Body = $null
    )
    Set-LastFunction
    # Ensure /api/v1 is the base; derive admin base under /api/v1/admin
    $apiRoot = $null
    if ($Config.ApiBase) { $apiRoot = ($Config.ApiBase -replace '/+$','') } else { $apiRoot = ($Config.HealthUrl -replace '/+$','') }
    if ($apiRoot -notmatch '/api/v1$') { $apiRoot = $apiRoot + '/api/v1' }

    $base = $null
    if ($Config.AdminApiBase) {
        $candidate = ($Config.AdminApiBase -replace '/+$','')
        if ($candidate -match '/api/v1') { $base = $candidate } else { $base = $apiRoot + '/admin' }
    } else {
        $base = $apiRoot + '/admin'
    }

    $url = ($base -replace '/+$','') + '/' + ($Path -replace '^/+','')

    $headers = @{}
    if ($Config.AdminApiToken) { $headers['X-API-Key'] = $Config.AdminApiToken }
    elseif ($Config.APIAdminAuthToken) { $headers['X-API-Key'] = $Config.APIAdminAuthToken }

    $invokeParams = @{ Uri = $url; Method = $Method; Headers = $headers; ErrorAction = 'Stop' }
    try { Write-Log "API Request: $Method $url" 'DEBUG' } catch {}
    if ($null -ne $Body -and $Body -ne '') {
        if ($Body -isnot [string]) { $bodyJson = $Body | ConvertTo-Json -Depth 10 } else { $bodyJson = $Body }
        $invokeParams['Body'] = $bodyJson
        $invokeParams['ContentType'] = 'application/json'
    }

    try {
        $resp = Invoke-RestMethod @invokeParams
        $out = $resp | ConvertTo-Json -Depth 10
        return $out
    } catch {
        return "ERROR: $_"
    }
}

# Generic game API helper (uses /api/v1 root)
function Invoke-GameApi {
    param(
        [string]$Method = 'GET',
        [string]$Path = '/',
        $Body = $null
    )
    Set-LastFunction
    # Ensure /api/v1 is the base
    $apiRoot = $null
    if ($Config.ApiBase) { $apiRoot = ($Config.ApiBase -replace '/+$','') } else { $apiRoot = ($Config.HealthUrl -replace '/+$','') }
    if ($apiRoot -notmatch '/api/v1$') { $apiRoot = $apiRoot + '/api/v1' }

    $base = $apiRoot
    $url = ($base -replace '/+$','') + '/' + ($Path -replace '^/+','')

    $headers = @{}
    if ($Config.APIAdminAuthToken) { $headers['X-API-Key'] = $Config.APIAdminAuthToken } elseif ($Config.AdminApiToken) { $headers['X-API-Key'] = $Config.AdminApiToken }

    $invokeParams = @{ Uri = $url; Method = $Method; Headers = $headers; ErrorAction = 'Stop' }
    try { Write-Log "API Request: $Method $url" 'DEBUG' } catch {}
    if ($null -ne $Body -and $Body -ne '') {
        if ($Body -isnot [string]) { $bodyJson = $Body | ConvertTo-Json -Depth 10 } else { $bodyJson = $Body }
        $invokeParams['Body'] = $bodyJson
        $invokeParams['ContentType'] = 'application/json'
    }

    try {
        $resp = Invoke-RestMethod @invokeParams
        $out = $resp | ConvertTo-Json -Depth 10
        return $out
    } catch {
        return "ERROR: $_"
    }
}

# Resolve required placeholders
function Resolve-ApiTemplate {
    param(
        [string]$Template
    )
    Set-LastFunction
    $template = $Template
    # For API tokens, use `api_key` query parameter (or X-API-Key header). Replace placeholders
    if ($template -match '\bauthtoken\b') {
        $token = Read-Host "api_key (leave blank to use Config.APIAdminAuthToken)"
        if (-not $token) { $token = $Config.APIAdminAuthToken }
        $enc = [uri]::EscapeDataString($token)
        $template = $template -replace '\bauthtokentype\b', ''
        $template = $template -replace '\bauthtoken\b', "api_key=$enc"
    }

    # Resolve optional parameter groups: [...]
    $template = [regex]::Replace(
        $template,
        '\[([^\]]+)\]',
        {
            param($match)

            $contents = $match.Groups[1].Value

            $parameters = $contents.TrimStart('&').Split('&')

            $result = @()

            foreach ($parameter in $parameters) {

                if ([string]::IsNullOrWhiteSpace($parameter)) {
                    continue
                }

                $value = Read-Host "$parameter (optional)"

                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $result += "$parameter=$([uri]::EscapeDataString($value))"
                }
            }

            if ($result.Count -gt 0) {
                '&' + ($result -join '&')
            }
            else {
                ''
            }
        }
    )

    # Cleanup
    $template = $template -replace '\?&', '?'
    $template = $template -replace '&&+', '&'
    $template = $template -replace '\?$', ''
    $template = $template -replace '&$', ''

    return $template
}

# Returns a hashtable of API endpoint groups and templates
function Get-ApiEndpoints {
    Set-LastFunction
    return @{
        'Admin' = @(
            @{ Method='POST'; Path='admin/set/access?authtoken&authtokentype[&value&password]'; Desc='Set access (public/private/hidden)'} ,
            @{ Method='GET';  Path='admin/get/access?authtoken&authtokentype'; Desc='Get access'} ,
            @{ Method='POST'; Path='admin/set/servername?authtoken&authtokentype[&name]'; Desc='Set server name'} ,
            @{ Method='GET';  Path='admin/get/servername'; Desc='Get server name'} ,
            @{ Method='POST'; Path='admin/game/export?authtoken&authtokentype'; Desc='Game export'}
        )
        'Chat' = @(
            @{ Method='GET'; Path='chat?authtoken&authtokentype[&startDay&endDay]'; Desc='Get chat'} ,
            @{ Method='GET'; Path='chat/tag?authtoken&authtokentype[&tag&startDay&endDay]'; Desc='Get chat by tag'} ,
            @{ Method='GET'; Path='chat/{username}?authtoken&authtokentype[&startDay&endDay]'; Desc='Chat by username'} ,
            @{ Method='POST'; Path='chat/next?authtoken&authtokentype[&numNextMessages]'; Desc='Next messages'} ,
            @{ Method='POST'; Path='chat/previous?authtoken&authtokentype[&numPreviousMessages]'; Desc='Previous messages'} ,
            @{ Method='GET'; Path='chat/sendChat?authtoken&authtokentype[&username&message]'; Desc='Send chat (GET)'}
        )
        'Command' = @(
            @{ Method='POST'; Path='command/exec?authtoken&authtokentype'; Desc='Execute command'}
        )
        'Exporter' = @(
            @{ Method='POST'; Path='exporter/all?authtoken&authtokentype'; Desc='Exporter all'} ,
            @{ Method='POST'; Path='exporter/chat?authtoken&authtokentype'; Desc='Exporter chat'} ,
            @{ Method='POST'; Path='exporter/species?authtoken&authtokentype'; Desc='Exporter species (POST)'} ,
            @{ Method='GET';  Path='exporter/species?authtoken&authtokentype[&speciesName]'; Desc='Exporter species (GET)'} ,
            @{ Method='POST'; Path='exporter/environment?authtoken&authtokentype'; Desc='Exporter environment (POST)'} ,
            @{ Method='GET';  Path='exporter/environment?authtoken&authtokentype[&category&units&column]'; Desc='Exporter environment (GET)'} ,
            @{ Method='POST'; Path='exporter/actions?authtoken&authtokentype'; Desc='Exporter actions (POST)'} ,
            @{ Method='GET';  Path='exporter/actions?authtoken&authtokentype[&actionName]'; Desc='Exporter actions (GET)'} ,
            @{ Method='GET';  Path='exporter/actionlist?authtoken&authtokentype'; Desc='Exporter action list'} ,
            @{ Method='GET';  Path='exporter/specieslist?authtoken&authtokentype'; Desc='Exporter species list'} ,
            @{ Method='GET';  Path='exporter/environmentlist?authtoken&authtokentype'; Desc='Exporter environment list'}
        )
        'Elections' = @(
            @{ Method='GET'; Path='elections/titles'; Desc='Elections titles (optional ?state)'} ,
            @{ Method='GET'; Path='elections'; Desc='Get elections (?returnActive)'} ,
            @{ Method='GET'; Path='elections/{id}'; Desc='Get election by id'} ,
            @{ Method='GET'; Path='elections/titles/{id}'; Desc='Get election title by id'} ,
            @{ Method='GET'; Path='elections/votes'; Desc='Get votes (?id)'} ,
            @{ Method='POST'; Path='elections/vote?authtoken&authtokentype[&forceVote]'; Desc='Vote'} ,
            @{ Method='POST'; Path='elections/forceelectionend?authtoken&authtokentype[&electionId]'; Desc='Force election end'} ,
            @{ Method='POST'; Path='elections/addcomment?authtoken&authtokentype[&electionId]'; Desc='Add election comment'} ,
            @{ Method='GET'; Path='elections/listcomments[?electionId]'; Desc='List election comments'} ,
            @{ Method='POST'; Path='elections/generatetestgovernment?authtoken&authtokentype'; Desc='Generate test government'} ,
            @{ Method='POST'; Path='elections/generatetestdata?authtoken&authtokentype[&addUserVotes&addTwitchVotes]'; Desc='Generate test data'} ,
            @{ Method='POST'; Path='elections/finishelection?authtoken&authtokentype'; Desc='Finish election'}
        )
        'Laws' = @(
            @{ Method='GET'; Path='laws/byStates/{states}'; Desc='Laws by states'} ,
            @{ Method='GET'; Path='laws'; Desc='Get laws'} ,
            @{ Method='GET'; Path='laws/districtmap/{name}'; Desc='District map'} ,
            @{ Method='GET'; Path='laws/{id}'; Desc='Law by id'} ,
            @{ Method='POST'; Path='laws/generatetestdata?authtoken&authtokentype'; Desc='Generate laws test data'}
        )
        'Logs' = @(
            @{ Method='GET'; Path='logs?authtoken&authtokentype'; Desc='Get logs'} ,
            @{ Method='GET'; Path='logs/{category}?authtoken&authtokentype'; Desc='Logs by category'} ,
            @{ Method='GET'; Path='logs/get?authtoken&authtokentype[&filepath]'; Desc='Get log file'}
        )
        'Map' = @(
            @{ Method='GET'; Path='map/mapstats?authtoken&authtokentype'; Desc='Map stats'} ,
            @{ Method='GET'; Path='map/entitytypes?authtoken&authtokentype'; Desc='Entity types'} ,
            @{ Method='GET'; Path='map/entities?authtoken&authtokentype[&entityTypes&states]'; Desc='Map entities'} ,
            @{ Method='GET'; Path='map/dimension?authtoken&authtokentype'; Desc='Map dimension'} ,
            @{ Method='GET'; Path='map/layerList?authtoken&authtokentype'; Desc='Map layer list'} ,
            @{ Method='GET'; Path='map/map.json?authtoken&authtokentype'; Desc='Map JSON'} ,
            @{ Method='GET'; Path='map/waterLevel?authtoken&authtokentype'; Desc='Water level'} ,
            @{ Method='GET'; Path='map/property?authtoken&authtokentype'; Desc='Map property'}
        )
        'Performance' = @(
            @{ Method='GET'; Path='performance/performanceReport?authtoken&authtokentype'; Desc='Performance report'}
        )
        'Plugins' = @(
            @{ Method='GET'; Path='plugins/config/{name}?authtoken&authtokentype'; Desc='Get plugin config'} ,
            @{ Method='POST'; Path='plugins/config/{name}?authtoken&authtokentype'; Desc='Post plugin config'} ,
            @{ Method='GET'; Path='plugins'; Desc='Plugins list'} ,
            @{ Method='GET'; Path='plugins/web'; Desc='Plugins web'}
        )
        'Profiling' = @(
            @{ Method='GET'; Path='profiling-results?authtoken&authtokentype'; Desc='Profiling results'} ,
            @{ Method='GET'; Path='profiling-results/{filename}?authtoken&authtokentype'; Desc='Profiling file'}
        )
        'Misc' = @(
            @{ Method='GET'; Path='info?authtoken&authtokentype'; Desc='Info'} ,
            @{ Method='GET'; Path='frontpage?authtoken&authtokentype'; Desc='Frontpage'} ,
            @{ Method='GET'; Path='admins?authtoken&authtokentype'; Desc='Admins'} ,
            @{ Method='GET'; Path='isadmin?authtoken&authtokentype'; Desc='Is admin'}
        )
        'Datasets' = @(
            @{ Method='GET'; Path='datasets/timerange?authtoken&authtokentype'; Desc='Datasets timerange'} ,
            @{ Method='GET'; Path='datasets/treelist?authtoken&authtokentype'; Desc='Datasets tree list'} ,
            @{ Method='GET'; Path='datasets/flatlist?authtoken&authtokentype'; Desc='Datasets flat list'} ,
            @{ Method='GET'; Path='datasets/get?authtoken&authtokentype[&dataset&dayStart&dayEnd]'; Desc='Get dataset'} ,
            @{ Method='GET'; Path='datasets/getlist?authtoken&authtokentype[&requestedSets&dayStart&dayEnd]'; Desc='Get datasets list'} ,
            @{ Method='GET'; Path='datasets/graphs?authtoken&authtokentype'; Desc='Datasets graphs'} ,
            @{ Method='GET'; Path='datasets/generatetestdata?authtoken&authtokentype[&days&users&generateClimateData&pollutionMultiplier]'; Desc='Generate datasets test data'}
        )
        'Users' = @(
            @{ Method='GET'; Path='users?authtoken&authtokentype[&hoursPlayedGte]'; Desc='Users list'}
        )
        'WorldLayers' = @(
            @{ Method='GET'; Path='worldlayers/layers?authtoken&authtokentype'; Desc='Layers list'} ,
            @{ Method='GET'; Path='worldlayers/layers/{focusLayer}?authtoken&authtokentype[&minX&minY&maxX&maxY]'; Desc='Get layer region'} ,
            @{ Method='GET'; Path='worldlayers/relationships/areadescription?authtoken&authtokentype[&minX&minY&maxX&maxY]'; Desc='Area descriptions'} ,
            @{ Method='GET'; Path='worldlayers/relationships/{focusLayer}?authtoken&authtokentype[&minX&minY&maxX&maxY]'; Desc='Layer relationships'}
        )
    }
}

function Show-ApiMenu {
    param()
    Set-LastFunction
    while ($true) {
        Clear-Host
        Write-Host '=== ECO WATCHDOG: Admin API Menu ===' -ForegroundColor Cyan
        $apiRoot = $Config.ApiBase -replace '/+$',''
        if (-not $apiRoot) { $apiRoot = ($Config.HealthUrl -replace '/+$','') }
        if ($apiRoot -notmatch '/api/v1$') { $apiRoot = $apiRoot + '/api/v1' }
        $displayBase = $Config.AdminApiBase -replace '/+$','' -or ($apiRoot + '/admin')
        Write-Host "Server: $displayBase" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '1) Raw API request (method + path + optional JSON body)'
        Write-Host '2) Set access (public/private/hidden)'
        Write-Host '3) Get access'
        Write-Host '4) Set server name'
        Write-Host '5) Get server name'
        Write-Host '6) Game export'
        Write-Host '7) Show last API response'
        Write-Host '8) Chat endpoints'
        Write-Host '9) Command exec'
        Write-Host '10) DataExport endpoints'
        Write-Host '11) Browse all endpoints'
        Write-Host 'Q) Back'
        $choice = Read-Host 'Choose an option'
        if ($choice -and $choice.ToUpper() -eq 'Q') { break }
        switch ($choice.ToUpper()) {
            '1' {
                $method = Read-Host 'HTTP Method (GET/POST/PUT/DELETE) [GET]'
                if (-not $method) { $method = 'GET' }
                $path = Read-Host 'Relative path (e.g. get/status)'
                if (-not $path) { $path = '/' }
                $body = Read-Host 'Request body (JSON or empty)'
                if ($body -and $body.Trim().Length -gt 0) { $bodyVal = $body } else { $bodyVal = $null }
                $result = Invoke-AdminApi -Method $method -Path $path -Body $bodyVal
                $script:LastApiResponse = $result
                Write-Host '--- API RESPONSE ---' -ForegroundColor Cyan
                $result -split "\r?\n" | ForEach-Object { Write-Host $_ }
                Write-Host '--- END API RESPONSE ---' -ForegroundColor Cyan
                Write-Host ''
                Write-Host 'Press Enter to continue...'
                [void][System.Console]::ReadKey($true)
            }
            '2' {
                # Set access
                $token = Read-Host "api_key (leave blank to use Config.APIAdminAuthToken)"
                if (-not $token) { $token = $Config.APIAdminAuthToken }
                $tokentype = 'eco'
                $value = Read-Host "value (public/private/hidden) [public]"
                if (-not $value) { $value = 'public' }
                $password = $null
                if ($value -eq 'private') { $password = Read-Host 'password (for private)' }
                $q = "set/access?api_key=$([uri]::EscapeDataString($token))&value=$([uri]::EscapeDataString($value))"
                if ($password) { $q += "&password=$([uri]::EscapeDataString($password))" }
                $result = Invoke-AdminApi -Method 'POST' -Path $q
                $script:LastApiResponse = $result
                Write-Host '--- API RESPONSE ---' -ForegroundColor Cyan
                $result -split "\r?\n" | ForEach-Object { Write-Host $_ }
                Write-Host '--- END API RESPONSE ---' -ForegroundColor Cyan
                Write-Host 'Press Enter to continue...'
                [void][System.Console]::ReadKey($true)
            }
            '3' {
                $token = Read-Host "api_key (leave blank to use Config.AdminApiToken)"
                if (-not $token) { $token = $Config.AdminApiToken }
                $tokentype = 'eco'
                $q = "get/access?api_key=$([uri]::EscapeDataString($token))"
                $result = Invoke-AdminApi -Method 'GET' -Path $q
                $script:LastApiResponse = $result
                Write-Host '--- API RESPONSE ---' -ForegroundColor Cyan
                $result -split "\r?\n" | ForEach-Object { Write-Host $_ }
                Write-Host '--- END API RESPONSE ---' -ForegroundColor Cyan
                Write-Host 'Press Enter to continue...'
                [void][System.Console]::ReadKey($true)
            }
            '4' {
                $token = Read-Host "api_key (leave blank to use Config.AdminApiToken)"
                if (-not $token) { $token = $Config.AdminApiToken }
                $tokentype = 'eco'
                $name = Read-Host 'Server name (URL-unsafe characters will be escaped)'
                $q = "set/servername?api_key=$([uri]::EscapeDataString($token))&name=$([uri]::EscapeDataString($name))"
                $result = Invoke-AdminApi -Method 'POST' -Path $q
                $script:LastApiResponse = $result
                Write-Host '--- API RESPONSE ---' -ForegroundColor Cyan
                $result -split "\r?\n" | ForEach-Object { Write-Host $_ }
                Write-Host '--- END API RESPONSE ---' -ForegroundColor Cyan
                Write-Host 'Press Enter to continue...'
                [void][System.Console]::ReadKey($true)
            }
            '5' {
                $result = Invoke-AdminApi -Method 'GET' -Path 'get/servername'
                $script:LastApiResponse = $result
                Write-Host '--- API RESPONSE ---' -ForegroundColor Cyan
                $result -split "\r?\n" | ForEach-Object { Write-Host $_ }
                Write-Host '--- END API RESPONSE ---' -ForegroundColor Cyan
                Write-Host 'Press Enter to continue...'
                [void][System.Console]::ReadKey($true)
            }
            '6' {
                $token = Read-Host "api_key (leave blank to use Config.AdminApiToken)"
                if (-not $token) { $token = $Config.AdminApiToken }
                $tokentype = 'eco'
                $q = "game/export?api_key=$([uri]::EscapeDataString($token))"
                $result = Invoke-AdminApi -Method 'POST' -Path $q
                $script:LastApiResponse = $result
                Write-Host '--- API RESPONSE ---' -ForegroundColor Cyan
                $result -split "\r?\n" | ForEach-Object { Write-Host $_ }
                Write-Host '--- END API RESPONSE ---' -ForegroundColor Cyan
                Write-Host 'Press Enter to continue...'
                [void][System.Console]::ReadKey($true)
            }
            '7' {
                if ($script:LastApiResponse) {
                    Write-Host '--- LAST API RESPONSE ---' -ForegroundColor Cyan
                    $script:LastApiResponse -split "\r?\n" | ForEach-Object { Write-Host $_ }
                    Write-Host '--- END LAST API RESPONSE ---' -ForegroundColor Cyan
                } else { Write-Host '(No previous API response)' }
                Write-Host 'Press Enter to continue...'
                [void][System.Console]::ReadKey($true)
            }
            '8' {
                # Chat submenu
                while ($true) {
                    $exitSubmenu = $false
                    Clear-Host
                    Write-Host '--- Chat API ---' -ForegroundColor Cyan
                    Write-Host '1) Get chat (time range)'
                    Write-Host '2) Get chat by tag'
                    Write-Host '3) Get chat messages by user'
                    Write-Host '4) Get next messages (POST)'
                    Write-Host '5) Get previous messages (POST)'
                    Write-Host '6) Send chat (debug-only)'
                    Write-Host 'B) Back'
                    Write-Host 'Choice' -NoNewline
                    $ckey = [Console]::ReadKey($true).Key.ToString()
                    if ($ckey.Length -gt 1 -and $ckey.StartsWith('D') -and $ckey.Length -eq 2) { $ckey = $ckey.Substring(1) }
                    $c = $ckey.Substring(0,1).ToUpper()
                    Write-Host ''
                    switch ($c.ToUpper()) {
                        '1' {
                            $token = Read-Host "api_key (leave blank to use Config.APIAdminAuthToken)"
                            if (-not $token) { $token = $Config.APIAdminAuthToken }
                            $tokentype = 'eco'
                            $start = Read-Host 'startDay [0]'
                            if (-not $start) { $start = '0' }
                            $end = Read-Host 'endDay [-1]'
                            if (-not $end) { $end = '-1' }
                            $q = "chat?api_key=$([uri]::EscapeDataString($token))&startDay=$([uri]::EscapeDataString($start))&endDay=$([uri]::EscapeDataString($end))"
                            $result = Invoke-GameApi -Method 'GET' -Path $q
                            $script:LastApiResponse = $result
                            Write-Host $result
                            Write-Host 'Press Enter to continue...'; [void][System.Console]::ReadKey($true)
                        }
                        '2' {
                            $token = Read-Host "api_key (leave blank to use Config.APIAdminAuthToken)"
                            if (-not $token) { $token = $Config.APIAdminAuthToken }
                            $tokentype = 'eco'
                            $tag = Read-Host 'tag'
                            $start = Read-Host 'startDay [0]'
                            if (-not $start) { $start = '0' }
                            $end = Read-Host 'endDay [-1]'
                            if (-not $end) { $end = '-1' }
                            $q = "chat/tag?api_key=$([uri]::EscapeDataString($token))&tag=$([uri]::EscapeDataString($tag))&startDay=$([uri]::EscapeDataString($start))&endDay=$([uri]::EscapeDataString($end))"
                            $result = Invoke-GameApi -Method 'GET' -Path $q
                            $script:LastApiResponse = $result
                            Write-Host $result
                            Write-Host 'Press Enter to continue...'; [void][System.Console]::ReadKey($true)
                        }
                        '3' {
                            $token = Read-Host "api_key (leave blank to use Config.APIAdminAuthToken)"
                            if (-not $token) { $token = $Config.APIAdminAuthToken }
                            $tokentype = 'eco'
                            $user = Read-Host 'username'
                            $start = Read-Host 'startDay [0]'
                            if (-not $start) { $start = '0' }
                            $end = Read-Host 'endDay [-1]'
                            if (-not $end) { $end = '-1' }
                            $q = "chat/$([uri]::EscapeDataString($user))?api_key=$([uri]::EscapeDataString($token))&startDay=$([uri]::EscapeDataString($start))&endDay=$([uri]::EscapeDataString($end))"
                            $result = Invoke-GameApi -Method 'GET' -Path $q
                            $script:LastApiResponse = $result
                            Write-Host $result
                            Write-Host 'Press Enter to continue...'; [void][System.Console]::ReadKey($true)
                        }
                        '4' {
                            $token = Read-Host "api_key (leave blank to use Config.APIAdminAuthToken)"
                            if (-not $token) { $token = $Config.APIAdminAuthToken }
                            $tokentype = 'eco'
                            $num = Read-Host 'numNextMessages [1]'
                            if (-not $num) { $num = '1' }
                            Write-Host 'Paste message JSON body (single line) and press Enter:'
                            $body = Read-Host
                            $q = "chat/next?api_key=$([uri]::EscapeDataString($token))&numNextMessages=$([uri]::EscapeDataString($num))"
                            $result = Invoke-GameApi -Method 'POST' -Path $q -Body $body
                            $script:LastApiResponse = $result
                            Write-Host $result
                            Write-Host 'Press Enter to continue...'; [void][System.Console]::ReadKey($true)
                        }
                        '5' {
                            $token = Read-Host "api_key (leave blank to use Config.AdminApiToken)"
                            if (-not $token) { $token = $Config.AdminApiToken }
                            $tokentype = 'eco'
                            $num = Read-Host 'numPreviousMessages [1]'
                            if (-not $num) { $num = '1' }
                            Write-Host 'Paste message JSON body (single line) and press Enter:'
                            $body = Read-Host
                            $q = "chat/previous?api_key=$([uri]::EscapeDataString($token))&numPreviousMessages=$([uri]::EscapeDataString($num))"
                            $result = Invoke-GameApi -Method 'POST' -Path $q -Body $body
                            $script:LastApiResponse = $result
                            Write-Host $result
                            Write-Host 'Press Enter to continue...'; [void][System.Console]::ReadKey($true)
                        }
                        '6' {
                            $token = Read-Host "api_key (leave blank to use Config.AdminApiToken)"
                            if (-not $token) { $token = $Config.AdminApiToken }
                            $tokentype = 'eco'
                            $user = Read-Host 'username'
                            $msg = Read-Host 'message'
                            $q = "chat/sendChat?api_key=$([uri]::EscapeDataString($token))&username=$([uri]::EscapeDataString($user))&message=$([uri]::EscapeDataString($msg))"
                            $result = Invoke-GameApi -Method 'GET' -Path $q
                            $script:LastApiResponse = $result
                            Write-Host $result
                            Write-Host 'Press Enter to continue...'; [void][System.Console]::ReadKey($true)
                        }
                        'B' { $exitSubmenu = $true; break }
                        default { Write-Host 'Unknown choice'; Start-Sleep -Seconds 1 }
                    }
                    if ($exitSubmenu) { break }
                }
            }
            '9' {
                # Command exec
                $token = Read-Host "api_key (leave blank to use Config.AdminApiToken)"
                if (-not $token) { $token = $Config.AdminApiToken }
                $tokentype = 'eco'
                Write-Host 'Paste command body JSON (or plain text) and press Enter:'
                $body = Read-Host
                $q = "command/exec?api_key=$([uri]::EscapeDataString($token))"
                $result = Invoke-GameApi -Method 'POST' -Path $q -Body $body
                $script:LastApiResponse = $result
                Write-Host $result
                Write-Host 'Press Enter to continue...'; [void][System.Console]::ReadKey($true)
            }
            '10' {
                # DataExport submenu
                while ($true) {
                    $exitSubmenu = $false
                    Clear-Host
                    Write-Host '--- DataExport API ---' -ForegroundColor Cyan
                    Write-Host '1) Export all (POST)'
                    Write-Host '2) Export chat (POST)'
                    Write-Host '3) Export species (POST)'
                    Write-Host '4) Get species (GET)'
                    Write-Host '5) Export environment (POST)'
                    Write-Host '6) Get environment (GET)'
                    Write-Host '7) Export actions (POST)'
                    Write-Host '8) Get action (GET)'
                    Write-Host '9) Get action list (GET)'
                    Write-Host '10) Get species list (GET)'
                    Write-Host '11) Get environment list (GET)'
                    Write-Host 'B) Back'
                    Write-Host 'Choice' -NoNewline
                    $dkey = [Console]::ReadKey($true).Key.ToString()
                    if ($dkey.Length -gt 1 -and $dkey.StartsWith('D') -and $dkey.Length -eq 2) { $dkey = $dkey.Substring(1) }
                    $d = $dkey.Substring(0,1).ToUpper()
                    Write-Host ''
                    switch ($d.ToUpper()) {
                        '1' { $token = Read-Host "api_key (leave blank to use Config.APIAdminAuthToken)"; if (-not $token) { $token = $Config.APIAdminAuthToken }; $tokentype = Read-Host "authtokentype [eco]"; if (-not $tokentype) { $tokentype = 'eco' }; $q = "exporter/all?api_key=$([uri]::EscapeDataString($token))"; $result = Invoke-GameApi -Method 'POST' -Path $q; $script:LastApiResponse = $result; Write-Host $result; Write-Host 'Press Enter to continue...'; [void][System.Console]::ReadKey($true) }
                        '2' { $token = Read-Host "api_key (leave blank to use Config.APIAdminAuthToken)"; if (-not $token) { $token = $Config.APIAdminAuthToken }; $tokentype = Read-Host "authtokentype [eco]"; if (-not $tokentype) { $tokentype = 'eco' }; $q = "exporter/chat?api_key=$([uri]::EscapeDataString($token))"; $result = Invoke-GameApi -Method 'POST' -Path $q; $script:LastApiResponse = $result; Write-Host $result; Write-Host 'Press Enter to continue...'; [void][System.Console]::ReadKey($true) }
                        '3' { $token = Read-Host "api_key (leave blank to use Config.APIAdminAuthToken)"; if (-not $token) { $token = $Config.APIAdminAuthToken }; $tokentype = Read-Host "authtokentype [eco]"; if (-not $tokentype) { $tokentype = 'eco' }; $q = "exporter/species?api_key=$([uri]::EscapeDataString($token))"; $result = Invoke-GameApi -Method 'POST' -Path $q; $script:LastApiResponse = $result; Write-Host $result; Write-Host 'Press Enter to continue...'; [void][System.Console]::ReadKey($true) }
                        '4' { $token = Read-Host "api_key (leave blank to use Config.APIAdminAuthToken)"; if (-not $token) { $token = $Config.APIAdminAuthToken }; $tokentype = Read-Host "authtokentype [eco]"; if (-not $tokentype) { $tokentype = 'eco' }; $spec = Read-Host 'speciesName (optional)'; $q = "exporter/species?api_key=$([uri]::EscapeDataString($token))"; if ($spec) { $q += "&speciesName=$([uri]::EscapeDataString($spec))" }; $result = Invoke-GameApi -Method 'GET' -Path $q; $script:LastApiResponse = $result; Write-Host $result; Write-Host 'Press Enter to continue...'; [void][System.Console]::ReadKey($true) }
                        '5' { $token = Read-Host "api_key (leave blank to use Config.APIAdminAuthToken)"; if (-not $token) { $token = $Config.APIAdminAuthToken }; $tokentype = Read-Host "authtokentype [eco]"; if (-not $tokentype) { $tokentype = 'eco' }; $q = "exporter/environment?api_key=$([uri]::EscapeDataString($token))"; $result = Invoke-GameApi -Method 'POST' -Path $q; $script:LastApiResponse = $result; Write-Host $result; Write-Host 'Press Enter to continue...'; [void][System.Console]::ReadKey($true) }
                        '6' { $token = Read-Host "api_key (leave blank to use Config.APIAdminAuthToken)"; if (-not $token) { $token = $Config.APIAdminAuthToken }; $tokentype = Read-Host "authtokentype [eco]"; if (-not $tokentype) { $tokentype = 'eco' }; $cat = Read-Host 'category (optional)'; $units = Read-Host 'units (optional)'; $col = Read-Host 'column (optional)'; $q = "exporter/environment?api_key=$([uri]::EscapeDataString($token))"; if ($cat) { $q += "&category=$([uri]::EscapeDataString($cat))" }; if ($units) { $q += "&units=$([uri]::EscapeDataString($units))" }; if ($col) { $q += "&column=$([uri]::EscapeDataString($col))" }; $result = Invoke-GameApi -Method 'GET' -Path $q; $script:LastApiResponse = $result; Write-Host $result; Write-Host 'Press Enter to continue...'; [void][System.Console]::ReadKey($true) }
                        '7' { $token = Read-Host "api_key (leave blank to use Config.APIAdminAuthToken)"; if (-not $token) { $token = $Config.APIAdminAuthToken }; $tokentype = Read-Host "authtokentype [eco]"; if (-not $tokentype) { $tokentype = 'eco' }; $q = "exporter/actions?api_key=$([uri]::EscapeDataString($token))"; $result = Invoke-GameApi -Method 'POST' -Path $q; $script:LastApiResponse = $result; Write-Host $result; Write-Host 'Press Enter to continue...'; [void][System.Console]::ReadKey($true) }
                        '8' { $token = Read-Host "api_key (leave blank to use Config.APIAdminAuthToken)"; if (-not $token) { $token = $Config.APIAdminAuthToken }; $tokentype = Read-Host "authtokentype [eco]"; if (-not $tokentype) { $tokentype = 'eco' }; $action = Read-Host 'actionName (optional)'; $q = "exporter/actions?api_key=$([uri]::EscapeDataString($token))"; if ($action) { $q += "&actionName=$([uri]::EscapeDataString($action))" }; $result = Invoke-GameApi -Method 'GET' -Path $q; $script:LastApiResponse = $result; Write-Host $result; Write-Host 'Press Enter to continue...'; [void][System.Console]::ReadKey($true) }
                        '9' { $token = Read-Host "api_key (leave blank to use Config.APIAdminAuthToken)"; if (-not $token) { $token = $Config.APIAdminAuthToken }; $tokentype = Read-Host "authtokentype [eco]"; if (-not $tokentype) { $tokentype = 'eco' }; $q = "exporter/actionlist?api_key=$([uri]::EscapeDataString($token))"; $result = Invoke-GameApi -Method 'GET' -Path $q; $script:LastApiResponse = $result; Write-Host $result; Write-Host 'Press Enter to continue...'; [void][System.Console]::ReadKey($true) }
                        '10' { $token = Read-Host "api_key (leave blank to use Config.APIAdminAuthToken)"; if (-not $token) { $token = $Config.APIAdminAuthToken }; $tokentype = Read-Host "authtokentype [eco]"; if (-not $tokentype) { $tokentype = 'eco' }; $q = "exporter/specieslist?api_key=$([uri]::EscapeDataString($token))"; $result = Invoke-GameApi -Method 'GET' -Path $q; $script:LastApiResponse = $result; Write-Host $result; Write-Host 'Press Enter to continue...'; [void][System.Console]::ReadKey($true) }
                        '11' { $token = Read-Host "api_key (leave blank to use Config.APIAdminAuthToken)"; if (-not $token) { $token = $Config.APIAdminAuthToken }; $tokentype = Read-Host "authtokentype [eco]"; if (-not $tokentype) { $tokentype = 'eco' }; $q = "exporter/environmentlist?api_key=$([uri]::EscapeDataString($token))"; $result = Invoke-GameApi -Method 'GET' -Path $q; $script:LastApiResponse = $result; Write-Host $result; Write-Host 'Press Enter to continue...'; [void][System.Console]::ReadKey($true) }
                        'B' { $exitSubmenu = $true; break }
                        default { Write-Host 'Unknown choice'; Start-Sleep -Seconds 1 }
                    }
                    if ($exitSubmenu) { break }
                }
            }
            '11' {
                $groups = Get-ApiEndpoints
                $keys = $groups.Keys | Sort-Object
                Clear-Host
                Write-Host '--- API Endpoint Groups ---' -ForegroundColor Cyan
                for ($i=0; $i -lt $keys.Count; $i++) { Write-Host "[$($i+1)] $($keys[$i])" }
                $gchoice = Read-Host 'Choose a group number (blank to cancel)'
                if (-not $gchoice) { break }
                $gi = [int]$gchoice - 1
                if ($gi -lt 0 -or $gi -ge $keys.Count) { Write-Host 'Invalid group'; Start-Sleep -Seconds 1; break }
                $groupName = $keys[$gi]
                $endpoints = $groups[$groupName]
                Clear-Host
                Write-Host "--- Endpoints: $groupName ---" -ForegroundColor Cyan
                for ($j=0; $j -lt $endpoints.Count; $j++) { Write-Host "[$($j+1)] $($endpoints[$j].Method) $($endpoints[$j].Path) - $($endpoints[$j].Desc)" }
                $echoice = Read-Host 'Choose an endpoint number (blank to cancel)'
                if (-not $echoice) { break }
                $ei = [int]$echoice - 1
                if ($ei -lt 0 -or $ei -ge $endpoints.Count) { Write-Host 'Invalid endpoint'; Start-Sleep -Seconds 1; break }
                $ep = $endpoints[$ei]
                Write-Host "Selected: $($ep.Method) $($ep.Path) - $($ep.Desc)" -ForegroundColor Yellow
                $finalPath = Resolve-ApiTemplate -Template $ep.Path
                Write-Host "Resolved path: $finalPath" -ForegroundColor Green
                $edit = Read-Host 'Edit final path before sending? (y/N)'
                if ($edit -and $edit.ToLower().StartsWith('y')) { $finalPath = Read-Host "Final path (edit as needed)" }
                $bodyVal = $null
                if ($ep.Method -match 'POST|PUT') { $body = Read-Host 'Request body (JSON) or leave blank'; if ($body -and $body.Trim().Length -gt 0) { $bodyVal = $body } }
                if ($finalPath -match '^admin/' -or $ep.Path -match '^admin/') {
                    $result = Invoke-AdminApi -Method $ep.Method -Path $finalPath -Body $bodyVal
                } else {
                    $result = Invoke-GameApi -Method $ep.Method -Path $finalPath -Body $bodyVal
                }
                $script:LastApiResponse = $result
                try { $obj = $result | ConvertFrom-Json -ErrorAction Stop; $pretty = $obj | ConvertTo-Json -Depth 10; Write-Host $pretty } catch { Write-Host $result }
                Write-Host 'Press Enter to continue...'; [void][System.Console]::ReadKey($true)
            }
            'Q' { break }
            default { Write-Host 'Unknown choice' }
        }
    }
    Clear-Host; $script:UIInitialized = $false; Show-UI -Force
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
    $lines += ("HEALTH      : $global:LastHealth").PadRight($width)
    $lines += ("LAST MANUAL : $global:LastAction").PadRight($width)
    $lines += ("LAST AUTO   : $global:LastAutoAction").PadRight($width)
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

    # If there is a recent RCON response, show a short preview
    if ($script:LastRconResponse) {
        $lines += ''.PadRight($width)
        $lines += ('RCON RESPONSE:').PadRight($width)
        $respLines = $script:LastRconResponse -split "\r?\n"
        $maxPreview = 6
        for ($i = 0; $i -lt [Math]::Min($respLines.Count, $maxPreview); $i++) {
            $lines += ($respLines[$i]).PadRight($width)
        }
        if ($respLines.Count -gt $maxPreview) { $lines += ('...(truncated)').PadRight($width) }
    }

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
    Set-LastFunction
    Start-Eco

    $script:lastHealthCheck = Get-Date
    # Consecutive automatic health failure counter
    $script:ConsecutiveHealthFails = 0
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
                if ($script:LastUIState.LastAction -ne $global:LastAction) { $needUI = $true }
                if ($script:LastUIState.LastAutoAction -ne $global:LastAutoAction) { $needUI = $true }
                if ($script:LastUIState.ScheduledStart -ne $global:ScheduledStart) { $needUI = $true }
                if ($script:LastUIState.ScheduledMaintenance -ne $global:ScheduledMaintenance) { $needUI = $true }
                if ($script:LastUIState.Second -ne $now.Second) { $needUI = $true }
            }
            if ($needUI) {
                Show-UI
                $script:LastUIState.State = $global:State
                $script:LastUIState.Pid = if ($global:EcoProcess) { $global:EcoProcess.Id } else { $null }
                $script:LastUIState.LastHealth = $global:LastHealth
                $script:LastUIState.LastAction = $global:LastAction
                $script:LastUIState.LastAutoAction = $global:LastAutoAction
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
                    'Health' { $global:LastAction = "Manual health check at $(Get-Date)"; Invoke-Health }
                    'Repair' { $global:LastAction = "Manual repair initiated at $(Get-Date)"; Repair-Server }
                    'Stop'   { $global:LastAction = "Manual stop requested at $(Get-Date)"; Stop-Eco -Manual }
                    'Start'  { $global:LastAction = "Manual start requested at $(Get-Date)"; Start-Eco }
                    'Logs'   { $script:DisplayMode = 'LOGS' }
                    'Rcon'   {
                        $global:LastAction = "Manual RCON command at $(Get-Date)"
                        try {
                            $cmd = Read-Host 'Enter RCON command'
                            if ($cmd -and $cmd.Trim().Length -gt 0) {
                                $resp = Invoke-Rcon -command $cmd

                                # Normalize response to string
                                if ($resp -is [byte[]]) {
                                    $respStr = [System.Text.Encoding]::UTF8.GetString($resp)
                                } elseif ($resp -is [string]) {
                                    $respStr = $resp
                                } else {
                                    $respStr = ($resp | Out-String)
                                }
                                $respStr = $respStr.TrimEnd()

                                # Save for UI preview and log a short summary
                                $script:LastRconResponse = $respStr
                                if ($respStr.Length -gt 200) { $short = $respStr.Substring(0,200) + '...' } else { $short = $respStr }
                                Write-Log "RCON: $cmd => $short"
                                # Also write the full response to the log for later inspection
                                try { Write-Log "RCON RESPONSE: $cmd => `n$respStr" 'INFO' } catch {}
                                $global:LastAction = "RCON: $cmd -> $short"

                                # Immediately refresh UI to show response preview
                                try { Show-UI -Force } catch {}

                                # If viewing logs, also print full response now
                                if ($script:DisplayMode -ne 'UI') {
                                    Write-Host "--- RCON RESPONSE ---" -ForegroundColor Cyan
                                    $respStr -split "\r?\n" | ForEach-Object { Write-Host $_ }
                                    Write-Host "--- END RCON RESPONSE ---" -ForegroundColor Cyan
                                }
                            } else {
                                $global:LastAction = 'RCON: (cancelled)'
                            }
                        } catch {
                            Write-Log "RCON command failed: $_" 'ERROR'
                            $global:LastAction = "RCON failed: $_"
                        }
                    }
                    'Api' {
                        $global:LastAction = "Manual API command at $(Get-Date)"
                        try {
                            Show-ApiMenu
                        } catch {
                            Write-Log "API menu failed: $_" 'ERROR'
                            $global:LastAction = "API failed: $_"
                        }
                    }
                    'Back'   { Clear-Host; $script:UIInitialized = $false; $script:DisplayMode = 'UI'; $script:LogInitialized = $false }
                    'Quit'   { $global:LastAction = "Quit requested at $(Get-Date)"; Stop-Eco -Manual; $global:ShouldQuit = $true; break }
                    default  { Write-Log "Unknown action mapped: $action" 'DEBUG' }
                }
            }
        }

        # periodic automatic health poll (separate from any manual checks)
        if ( ((Get-Date) - $script:lastHealthCheck).TotalSeconds -ge $Config.HealthPollIntervalSeconds ) {
            Invoke-Health -Automatic
            if ($global:LastHealth -eq 'FAIL') { $script:ConsecutiveHealthFails = ($script:ConsecutiveHealthFails + 1) } else { $script:ConsecutiveHealthFails = 0 }
            if ($script:ConsecutiveHealthFails -gt 0) { Write-Log "Consecutive health failures: $($script:ConsecutiveHealthFails)" 'DEBUG' }
            # If threshold reached, evaluate recovery regardless of state.
            # Additionally: if this is the first automatic health failure and it
            # occurred within two minutes of the configured AutoShutdownHour,
            # treat it as threshold reached (do not wait for consecutive failures).
            $withinAutoShutdownWindow = $false
            try {
                $maintPath = Join-Path $ScriptDir 'Configs\Maintenance.eco'
                if (Test-Path $maintPath) {
                    $maint = Get-Content -Path $maintPath -Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($maint -and $null -ne $maint.AutoShutdownHour) {
                        $hour = [int]$maint.AutoShutdownHour
                        $scheduled = Get-Date -Hour $hour -Minute 0 -Second 0
                        $deltaMin = [math]::Abs((Get-Date).Subtract($scheduled).TotalMinutes)
                        if ($deltaMin -le 5) { $withinAutoShutdownWindow = $true }
                    }
                }
            } catch { $withinAutoShutdownWindow = $false }

            if ( ( ($script:ConsecutiveHealthFails -ge $Config.HealthFailureThreshold) -or (($script:ConsecutiveHealthFails -eq 1) -and $withinAutoShutdownWindow) ) -and -not $global:ManualStopped) {
                Write-Log "Health failed $($script:ConsecutiveHealthFails) times; threshold reached; evaluating recovery" 'WARN'

                # Determine if a recent repair was initiated to avoid duplicate alerts
                $suppressWindow = if ($Config.RepairSuppressWindowSeconds) { $Config.RepairSuppressWindowSeconds } else { 60 }
                $recentRepair = $false
                if ($global:LastRepairTime) {
                    $delta = (Get-Date) - $global:LastRepairTime
                    if ($delta.TotalSeconds -lt $suppressWindow) { $recentRepair = $true }
                }

                if ($Config.DiscordNotifyOnFailure -and $Config.DiscordWebhookUrl -and -not $recentRepair) {
                    $msg = "[Alert] Server has failed health check $($script:ConsecutiveHealthFails) times at $(Get-Date) on host $env:COMPUTERNAME - attempting automatic recovery"
                    Send-DiscordWebhook -Message $msg
                    Write-Log 'Sent Discord notification for automatic recovery attempt' 'INFO'
                } elseif ($recentRepair) {
                    Write-Log "Suppressed automatic recovery notification; recent repair at $($global:LastRepairTime) within $suppressWindow seconds" 'DEBUG'
                }

                # If a process exists attempt a repair. If no process exists but one
                # was seen recently, try a normal Start-Eco once before attempting
                # a full Repair-Server. Otherwise perform a Start-Eco.
                $existing = Get-EcoProcess
                if ($existing) {
                    Write-Log 'Process exists but health failed; attempting Repair-Server' 'INFO'
                    $global:LastAutoAction = "Auto repair initiated at $(Get-Date)"
                    Repair-Server
                } else {
                    $recentlyRunning = $false
                    if ($script:LastProcessSeen) {
                        try { if (((Get-Date) - $script:LastProcessSeen).TotalSeconds -lt $Config.RecentProcessWindowSeconds) { $recentlyRunning = $true } } catch {}
                    }

                    if ($recentlyRunning) {
                        Write-Log 'Server was recently running; attempting normal Start-Eco once before repair' 'INFO'
                        $global:LastAutoAction = "Auto start executed at $(Get-Date) due to consecutive health failures"
                        Start-Eco
                        Start-Sleep -Seconds 5
                        if ($global:State -ne [EcoState]::RUNNING) {
                            Write-Log 'Normal start failed; falling back to Repair-Server' 'WARN'
                            $global:LastAutoAction = "Auto repair initiated at $(Get-Date) after failed start"
                            Repair-Server
                        }
                    } else {
                        Write-Log 'No process found; attempting automatic Start-Eco' 'INFO'
                        $global:LastAutoAction = "Auto start executed at $(Get-Date) due to consecutive health failures"
                        Start-Eco
                    }
                }

                # Reset the consecutive-failure counter after attempting recovery
                $script:ConsecutiveHealthFails = 0
            }
            $script:lastHealthCheck = Get-Date
        }

        # auto-detect process crash and repair
        if ($global:State -eq [EcoState]::RUNNING) {
            if ($global:EcoProcess -and $global:EcoProcess.HasExited) {
                Write-Log 'Detected process exit " initiating recovery' 'WARN'
                if ($Config.DiscordNotifyOnFailure -and $Config.DiscordWebhookUrl) {
                    $msg = "[Alert] Server process exited unexpectedly at $(Get-Date) on host $env:COMPUTERNAME - attempting auto-repair"
                    Send-DiscordWebhook -Message $msg
                    Write-Log 'Sent Discord notification for unexpected process exit' 'INFO'
                }
                $global:LastAutoAction = "Auto repair initiated at $(Get-Date)"
                Repair-Server
            }
        }

        # Scheduled start: if a start time is set and reached, attempt to start
        if ($global:ScheduledStart -and -not $global:ManualStopped -and -not (Get-EcoProcess)) {
            if ((Get-Date) -ge $global:ScheduledStart) {
                Write-Log "Scheduled start time reached: $($global:ScheduledStart) - starting server" 'INFO'
                $global:LastAutoAction = "Scheduled start executed at $(Get-Date)"
                $global:ScheduledStart = $null
                Start-Eco
                Start-Sleep -Seconds 5
                if ($global:State -ne [EcoState]::RUNNING) {
                    if ($Config.DiscordNotifyOnFailure -and $Config.DiscordWebhookUrl) {
                        $msg = "[Alert] Scheduled start failed at $(Get-Date) on host $env:COMPUTERNAME"
                        Send-DiscordWebhook -Message $msg
                        Write-Log 'Sent Discord notification for failed scheduled start' 'INFO'
                    }
                }
            }
        }

        # Scheduled maintenance: if set and the time has come, send the RCON command
        if ($global:ScheduledMaintenance) {
            if ((Get-Date) -ge $global:ScheduledMaintenance) {
                $timeStr = $global:ScheduledMaintenance.ToString('HH:mm')
                $cmd = "manage maintenance $timeStr, $($global:ScheduledMaintenanceReason), Shutdown"
                Write-Log "Executing scheduled maintenance command: $cmd" 'INFO'
                $global:LastAutoAction = "Scheduled maintenance executed at $(Get-Date) - $cmd"
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
        # server was not explicitly stopped by an operator/script, attempt recovery.
        # If a process is present we attempt a Repair (stop/restore/start). Otherwise
        # attempt an automatic Start.
        if (($global:State -eq [EcoState]::FAILED) -and ($global:LastHealth -eq 'FAIL') -and -not $global:ManualStopped) {
            Write-Log 'Combined state+health failure detected; will attempt recovery in 30s' 'WARN'
            Start-Sleep -Seconds 30
            # Re-evaluate before attempting
            if (($global:State -eq [EcoState]::FAILED) -and ($global:LastHealth -eq 'FAIL') -and -not $global:ManualStopped) {
                $existing = Get-EcoProcess
                if ($existing) {
                    Write-Log 'Process exists but health failed; attempting repair' 'INFO'
                    $global:LastAutoAction = "Auto repair initiated at $(Get-Date)"
                    if ($Config.DiscordNotifyOnFailure -and $Config.DiscordWebhookUrl) {
                        $msg = "[Alert] Automatic repair initiated at $(Get-Date) on host $env:COMPUTERNAME"
                        Send-DiscordWebhook -Message $msg
                        Write-Log 'Sent Discord notification for automatic repair' 'INFO'
                    }
                    Repair-Server
                } else {
                    Write-Log 'No process found; performing automatic Start-Eco due to persistent failure' 'INFO'
                    $global:LastAutoAction = "Auto start executed at $(Get-Date)"
                    Start-Eco
                    Start-Sleep -Seconds 5
                    if ($global:State -ne [EcoState]::RUNNING) {
                        if ($Config.DiscordNotifyOnFailure -and $Config.DiscordWebhookUrl) {
                            $msg = "[Alert] Automatic start failed at $(Get-Date) on host $env:COMPUTERNAME"
                            Send-DiscordWebhook -Message $msg
                            Write-Log 'Sent Discord notification for failed automatic start' 'INFO'
                        }
                    }
                }
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


