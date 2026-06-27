# Attempt to CloseMainWindow on current Eco process and restart if it stops
param(
    [int]$targetPid = 21348
)
try {
    $p = Get-Process -Id $targetPid -ErrorAction Stop
} catch { Write-Host "Process $targetPid not found"; exit 2 }
Write-Host "Sending CloseMainWindow() to PID $targetPid"
try {
    $sent = $p.CloseMainWindow()
    Write-Host "CloseMainWindow returned: $sent"
} catch { Write-Host "CloseMainWindow failed: $($_.Exception.Message)" }

$deadline = (Get-Date).AddSeconds(120)
while ((Get-Date) -lt $deadline) {
    if ($p.HasExited -or -not (Get-Process -Id $targetPid -ErrorAction SilentlyContinue)) {
        Write-Host 'Process exited'
        # attempt restart
        Write-Host 'Attempting Start-Eco'
        $RepoRoot = Split-Path -Parent $PSScriptRoot
        $env:UNIT_TEST = '1'
        . (Join-Path $RepoRoot 'EcoWatchdog.ps1')
        Start-Eco
        Start-Sleep -Seconds 3
        $now = Get-EcoProcess
        if ($now) { Write-Host "Restarted Eco PID: $($now.ProcessId)"; exit 0 } else { Write-Host 'Start-Eco did not create a process'; exit 3 }
    }
    Start-Sleep -Seconds 2
}
Write-Host 'Timeout waiting for CloseMainWindow; not forcing kill' ; exit 1
