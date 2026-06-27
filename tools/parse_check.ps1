$t=$null; $e=$null
[System.Management.Automation.Language.Parser]::ParseFile('EcoWatchdog.ps1',[ref]$t,[ref]$e)
if ($e) {
    foreach ($err in $e) {
        Write-Host $err.Message
        Write-Host ("Line: $($err.Extent.StartLineNumber) Col: $($err.Extent.StartColumn)")
    }
} else { Write-Host 'No parse errors' }

# Print surrounding lines for the first error to aid debugging
if ($e -and $e.Count -gt 0) {
    $err = $e[0]
    $start = [Math]::Max(1, $err.Extent.StartLineNumber - 3)
    $end = $err.Extent.StartLineNumber + 3
    Write-Host "\nContext around error (lines $start..$end):"
    Get-Content EcoWatchdog.ps1 | Select-Object -Index ($start-1)..($end-1) | ForEach-Object -Begin { $ln = $start } -Process { Write-Host ("$ln`: $_"); $ln++ }
}
