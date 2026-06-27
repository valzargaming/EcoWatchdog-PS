$path = 'EcoWatchdog.ps1'
# Read raw file
$s = Get-Content -Raw -Path $path
# Replace em-dash and other Unicode punctuation with ASCII equivalents
$s = $s -replace [char]0x2014, '-'
$s = $s -replace [char]0x2013, '-'
$s = $s -replace [char]0x2019, "'"
$s = $s -replace [char]0x2018, "'"
$s = $s -replace [char]0x201C, '"'
$s = $s -replace [char]0x201D, '"'
# Save normalized file as UTF8
Set-Content -Path $path -Value $s -Encoding UTF8
Write-Host "Normalized $path"