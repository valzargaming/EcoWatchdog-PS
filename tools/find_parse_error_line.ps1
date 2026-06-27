 $lines = Get-Content EcoWatchdog.ps1
 $low = 1; $high = $lines.Count
 while ($low -lt $high) {
     $mid = [int](($low + $high) / 2)
     $chunk = $lines[0..($mid-1)] -join "`r`n"
     try {
         [scriptblock]::Create($chunk) | Out-Null
         # prefix parses: search higher
         $low = $mid + 1
     } catch {
         # prefix fails: search lower half
         $high = $mid
     }
}
Write-Host "First failing line index approximated as $high"
try { [scriptblock]::Create(($lines[0..($high-1)] -join "`r`n")) | Out-Null; Write-Host "Prefix up to $($high-1) parses OK" } catch { Write-Host "Prefix up to $($high-1) fails: $($_.Exception.Message)" }
try { [scriptblock]::Create(($lines[0..($high)] -join "`r`n")) | Out-Null; Write-Host "Prefix up to $($high) parses OK" } catch { Write-Host "Prefix up to $($high) fails: $($_.Exception.Message)" }
