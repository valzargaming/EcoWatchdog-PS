# Send Source RCON manage save and schedule maintenance 1 minute ahead, wait up to 3 minutes for exit
$env:UNIT_TEST = '1'
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'EcoWatchdog.ps1')

$proc = Get-EcoProcess
if (-not $proc) { Write-Host 'No Eco process found'; exit 2 }
$targetPid = $proc.ProcessId
Write-Host "Target PID: $targetPid"

Write-Host 'Sending manage save via Source RCON...'
try {
    $resp = Invoke-RconSource -command 'manage save'
    Write-Host 'Save response:'
    Write-Host $resp
} catch {
    Write-Host "Save failed: $($_.Exception.Message)"
}

$time = (Get-Date).AddMinutes(1).ToString('HH:mm')
$cmd = "manage maintenance $time, Watchdog scheduled shutdown, Shutdown"
Write-Host "Scheduling maintenance: $cmd"
try {
    $resp2 = Invoke-RconSource -command $cmd
    Write-Host 'Maintenance response:'
    Write-Host $resp2
} catch {
    Write-Host "Maintenance failed: $($_.Exception.Message)"
}

$deadline = (Get-Date).AddSeconds(180)
Write-Host 'Waiting up to 180 seconds for process to exit.'
while ((Get-Date) -lt $deadline) {
    if (-not (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)) {
        Write-Host 'Process exited.'
        exit 0
    }
    Start-Sleep -Seconds 5
}
Write-Host 'Timeout; process still running.'
exit 1
