# One-off: attempt graceful stop via RCON/file-signal then restart if stopped
$env:UNIT_TEST = '1'
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'EcoWatchdog.ps1')
Write-Host 'Attached watchdog functions.'

$existing = Get-EcoProcess
if ($existing) {
    Write-Host "Found Eco pid: $($existing.ProcessId)"
    try { $global:EcoProcess = Get-Process -Id $existing.ProcessId -ErrorAction Stop } catch { $global:EcoProcess = $null }
} else {
    Write-Host 'No Eco process found via Get-EcoProcess.'
}

Write-Host 'Invoking Stop-Eco...'
try { Stop-Eco; Write-Host 'Stop-Eco completed.' } catch { Write-Host "Stop-Eco threw: $($_.Exception.Message)" }

Start-Sleep -Seconds 2
$after = Get-EcoProcess
if (-not $after) {
    Write-Host 'Eco process not found; attempting Start-Eco...'
    try {
        Start-Eco
        Start-Sleep -Seconds 3
        $now = Get-EcoProcess
        if ($now) {
            Write-Host "Restarted Eco pid: $($now.ProcessId)"
            exit 0
        } else {
            Write-Host 'Start-Eco did not create a process'
            exit 2
        }
    } catch { Write-Host "Start-Eco threw: $($_.Exception.Message)"; exit 2 }
} else {
    Write-Host "Eco still running (pid $($after.ProcessId))"
    exit 1
}
