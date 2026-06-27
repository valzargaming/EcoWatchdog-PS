$b=[System.IO.File]::ReadAllBytes('EcoWatchdog.ps1')
for ($i=0; $i -lt $b.Length; $i++) {
    if ($b[$i] -gt 127) { Write-Output ($i.ToString() + ': ' + $b[$i].ToString()) }
}
