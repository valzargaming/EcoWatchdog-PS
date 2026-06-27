# Helper script to parse-check EcoWatchdog and run Pester tests when available
$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $script:RepoRoot 'EcoWatchdog.ps1'
$content = Get-Content -Raw -LiteralPath $scriptPath
[System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$null) | Out-Null
Write-Host 'PARSE_OK'
if (Get-Command Invoke-Pester -ErrorAction SilentlyContinue) {
    Set-Location -LiteralPath $script:RepoRoot
    $env:UNIT_TEST = '1'
    # Run all tests in the tests folder
    # If PowerShell 7 is available, run tests explicitly under pwsh for consistent behavior
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) {
        $cmd = 'Set-Location -LiteralPath ' + "'" + $script:RepoRoot + "'" + "; `$env:UNIT_TEST='1'; Invoke-Pester -Script (Get-ChildItem -Path .\tests -Filter *.ps1 | Select-Object -ExpandProperty FullName) -PassThru"
        & $pwsh.Path -NoProfile -Command $cmd
        exit $LASTEXITCODE
    } else {
        Invoke-Pester -Script (Get-ChildItem -Path .\tests -Filter *.ps1 | Select-Object -ExpandProperty FullName) -PassThru
    }
} else {
    Write-Host 'PesterNotFound'
}
