# Attempt graceful shutdown via RCON + shutdown signal, wait up to ShutdownTimeoutSeconds, then restart if stopped.
$env:UNIT_TEST = '1'
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'EcoWatchdog.ps1')

$existing = Get-EcoProcess
if (-not $existing) { Write-Host 'No Eco process detected; nothing to stop.'; exit 0 }
Write-Host "Found Eco process PID: $($existing.ProcessId)"
$global:EcoProcess = Get-Process -Id $existing.ProcessId -ErrorAction SilentlyContinue

# Attempt RCON save + maintenance shutdown
try {
    Write-Host 'Sending manage save via RCON...'
    Invoke-Rcon -command 'manage save' | Out-Null
} catch { Write-Host "RCON save failed: $($_.Exception.Message)" }

try {
    $t = (Get-Date).AddMinutes(1).ToString('HH:mm')
    Write-Host "Sending manage maintenance $t via RCON..."
    Invoke-Rcon -command "manage maintenance $t, Watchdog scheduled shutdown, Shutdown" | Out-Null
} catch { Write-Host "RCON maintenance failed: $($_.Exception.Message)" }

# Write shutdown signal file
try {
    Write-Host "Writing shutdown signal: $($Config.ShutdownSignal)"
    New-Item -ItemType File -Path $Config.ShutdownSignal -Force | Out-Null
} catch { Write-Host "Failed to write shutdown signal: $($_.Exception.Message)" }

# Wait for graceful exit
$deadline = (Get-Date).AddSeconds($Config.ShutdownTimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    if (-not (Get-Process -Id $global:EcoProcess.Id -ErrorAction SilentlyContinue)) {
        Write-Host 'Eco exited gracefully.'
        Remove-Item $Config.ShutdownSignal -ErrorAction SilentlyContinue
        # attempt restart
        Write-Host 'Attempting to restart Eco...'
        Start-Eco
        Start-Sleep -Seconds 3
        $now = Get-EcoProcess
        if ($now) { Write-Host "Restarted Eco PID: $($now.ProcessId)"; exit 0 } else { Write-Host 'Start-Eco did not create a process'; exit 2 }
    }
    Start-Sleep -Seconds 2
}

Write-Host "Timeout reached ($($Config.ShutdownTimeoutSeconds)s): Eco still running. Not forcing kill." 
exit 1
