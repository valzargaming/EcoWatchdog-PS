$path = 'EcoWatchdog.ps1'
Copy-Item $path "$path.bak.encoding" -Force
$s = Get-Content -Raw -Path $path
# Remove any non-ASCII characters
$s = $s -replace '[^\u0000-\u007F]', ''
Set-Content -Path $path -Value $s -Encoding UTF8
Write-Host "Stripped non-ASCII characters from $path (backup at $path.bak.encoding)"
