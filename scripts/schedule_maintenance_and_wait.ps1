# Schedule maintenance via RCON to trigger server shutdown, then wait for exit.
$env:UNIT_TEST = '1'
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'EcoWatchdog.ps1')

$existing = Get-EcoProcess
if (-not $existing) { Write-Host 'No Eco process detected; nothing to schedule.'; exit 0 }
Write-Host "Found Eco process PID: $($existing.ProcessId)"
$global:EcoProcess = Get-Process -Id $existing.ProcessId -ErrorAction SilentlyContinue

# schedule time 2 minutes from now
$time = (Get-Date).AddMinutes(2).ToString('HH:mm')
Write-Host "Scheduling maintenance at $time"

try {
    Write-Host 'Sending manage save via RCON...'
    Invoke-Rcon -command 'manage save' | Out-Null
    Write-Host 'Save sent.'
} catch { Write-Host "RCON save failed: $($_.Exception.Message)" }

try {
    $cmd = "manage maintenance $time, Watchdog scheduled shutdown, Shutdown"
    Write-Host "Sending: $cmd"
    Invoke-Rcon -command $cmd | Out-Null
    Write-Host 'Maintenance scheduled.'
} catch { Write-Host "RCON maintenance failed: $($_.Exception.Message)" }

# Wait up to 5 minutes for graceful exit
$waitSeconds = 300
$deadline = (Get-Date).AddSeconds($waitSeconds)
Write-Host "Waiting up to $waitSeconds seconds for Eco to exit..."
while ((Get-Date) -lt $deadline) {
    if (-not (Get-Process -Id $global:EcoProcess.Id -ErrorAction SilentlyContinue)) {
        Write-Host 'Eco exited gracefully due to maintenance.'
        Remove-Item $Config.ShutdownSignal -ErrorAction SilentlyContinue
        # attempt restart
        Write-Host 'Attempting to restart Eco...'
        Start-Eco
        Start-Sleep -Seconds 3
        $now = Get-EcoProcess
        if ($now) { Write-Host "Restarted Eco PID: $($now.ProcessId)"; exit 0 } else { Write-Host 'Start-Eco did not create a process'; exit 2 }
    }
    Start-Sleep -Seconds 5
}

Write-Host "Timeout reached ($waitSeconds s): Eco still running. No further action taken." 
exit 1
