# RCON diagnostic script — non-destructive
$env:UNIT_TEST = '1'
$RepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $RepoRoot 'EcoWatchdog.ps1')

Write-Host "RCON Host: $($Config.RconHost):$($Config.RconPort)"

# Test TCP connect
$client = New-TcpClient -rHost $Config.RconHost -port $Config.RconPort -timeoutMs 3000
if (-not $client) { Write-Host 'TCP connect failed'; exit 2 }
Write-Host 'TCP connect OK'
$ns = $client.GetStream()
$ns.ReadTimeout = 2000

function Test-RconPlain([string]$cmd) {
    try {
        $sw = New-Object System.IO.StreamWriter($ns)
        $sw.AutoFlush = $true
        if ($Config.RconPassword) { $sw.WriteLine($Config.RconPassword); Start-Sleep -Milliseconds 100 }
        $sw.WriteLine($cmd)
        Start-Sleep -Milliseconds 200
        $sr = New-Object System.IO.StreamReader($ns)
        $out = ''
        while ($ns.DataAvailable) { $out += $sr.ReadLine() + "`n" }
        return $out.Trim()
    } catch { return "ERROR: $_" }
}

function Test-RconSource([string]$cmd) {
    try {
        return Invoke-RconSource -command $cmd
    } catch { return "ERROR: $_" }
}

Write-Host '--- Plain attempt (manage save) ---'
$pout = Test-RconPlain 'manage save'
Write-Host $pout

Write-Host '--- Source attempt (manage save) ---'
$sout = Test-RconSource 'manage save'
Write-Host $sout

# Check recent server logs for RconPlugin messages
$logsDir = Join-Path $RepoRoot 'Logs'
$logs = Get-ChildItem -Path $logsDir -Filter 'log_*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3
foreach ($l in $logs) {
    Write-Host "--- Tail: $($l.Name) ---"
    Get-Content -Path $l.FullName -Tail 200 | Select-String -Pattern 'Rcon' | ForEach-Object { Write-Host $_ }
}

# close
$client.Close()
Write-Host 'Done'
