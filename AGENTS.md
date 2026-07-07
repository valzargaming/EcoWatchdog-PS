# PowerShell Best Practices (for agents and scripts)

Purpose: concise guidelines for writing safe, maintainable PowerShell scripts used by agents and automation.

Best practices
- **Use Approved Verbs:** Prefer standard verbs (check `Get-Verb`). Common choices: **Get**, **Set**, **New**, **Remove**, **Start**, **Stop**, **Restart**, **Test**, **Invoke**, **Register**, **Unregister**, **Add**, **Update**.

- **Enforce Approved Verbs:** Follow the Microsoft approved verb list for PowerShell cmdlets to ensure consistency and discoverability. See the official list for PowerShell 7.6: https://learn.microsoft.com/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands?view=powershell-7.6. When adding or renaming functions, prefer approved verbs (e.g., `Import-`, `Export-`, `Backup-Database`, `Restore-Database`, `Invoke-`, `Test-`). Update tests to call the approved-verb public entrypoints (you may keep legacy internal names but expose approved wrappers).
- **Do not assign to automatic variables:** Never overwrite automatic variables such as `$PID`, `$Error`, `$PSVersionTable`, `$HOME`, `$MyInvocation`. Treat them as readonly values.
- **Avoid aliases and short commands:** Use full cmdlet names (`Get-Content` not `gc`) and explicit parameters. This improves readability and portability.
 - **Null comparisons:** Put `$null` on the left side of equality checks (for example, `$null -eq $var` or `$null -ne $var`). This avoids issues when variables are uninitialized and follows PowerShell best practices.
- **Use script-safe paths:** Use `$PSScriptRoot` or `Split-Path -Parent $MyInvocation.MyCommand.Path` for locating files relative to the script.
- **Parameter validation & CmdletBinding:** Use `[CmdletBinding()]`, typed parameters and validation attributes (`[Parameter(Mandatory=$true)]`, `[ValidateNotNullOrEmpty()]`) to make functions robust.
- **Return objects, not text:** Emit structured objects from functions so callers can pipe and inspect results.
- **No global state unless explicit:** Avoid `Set-Variable -Scope Global` or writing globals unless clearly documented. Prefer returning results and letting callers decide scope.
- **Logging & levels:** Provide a `Write-Log` helper that supports levels (`DEBUG`, `INFO`, `WARN`, `ERROR`) and rotate logs when large.
- **Error handling:** Use `Try/Catch` with `-ErrorAction Stop` for predictable failure handling. Use `Write-Error`/`Write-Warning` and return non-zero exit codes in scripts.
- **Minimize side effects in tests:** Honor a test mode (e.g., `$env:UNIT_TEST='1'`) and guard loops or process-starts so unit tests don't start real servers.
- **Secrets must not be committed:** Do not store passwords or secrets in the repo. Use ignored local files, OS secret stores (`SecretManagement`), or environment variables. If reading from a server config, ensure that config file is not committed with secrets.
- **Prefer objects for health/status APIs:** Provide `Test-Health`/`Invoke-Health` that return booleans or objects describing status.
- **Use comment-based help:** Add `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, and examples to every public function for discoverability and `Get-Help` support.
- **Use `-WhatIf`/`-Confirm` where appropriate:** For destructive actions provide safety switches.
- **Avoid one-letter variable names:** Use descriptive variable names; prefer splatting for long parameter sets.

Quick examples
- Minimal function header:

```powershell
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Path
)
function Test-Something { <# ... #> }
```

- Guard the script entry point for unit tests:

```powershell
if ($env:UNIT_TEST -ne '1') { Start-Watchdog }
```

Checklist before committing a script
- No alias usage (run `Get-Command -CommandType Alias` to find accidental uses).
- No assignments to automatic variables (`$PID`, `$PSHOME`, etc.).
- Secrets removed or placed in ignored files.
- Comment-based help present for public functions.
- Script uses `$PSScriptRoot` for relative paths.
- Pester tests added where behavior is non-trivial.

Notes:
 The helper above uses `Get-Verb` to determine approved verbs and a small built-in synonyms mapping derived from the Microsoft "Synonyms to avoid" guidance. Extend the `$synonyms` table for project-specific cases.
 Important: do NOT add backwards-compatible wrapper functions (compatibility shims) in new code. Instead, update call sites to use the approved-verb function name, or provide an explicit migration step or automated codemod that updates dependent scripts and tests. Agents and contributors must not introduce shim functions that mask underlying API changes.
**Validate Approved Verbs**
- **Purpose:** Provide a simple lint helper to detect function names that use non-approved or "synonym" verbs (the "Synonyms to avoid" category on the Microsoft approved verbs page) and suggest the appropriate approved verb.
- **Usage:** Run the snippet below against your scripts before committing. It reports functions whose verb part is not an approved verb and suggests replacements where a common synonym is detected.

```powershell
# Lint helper: find functions with non-approved verbs and suggest approved alternatives
function Test-ApprovedVerbs {
    param(
        [string]$Path = '.',
        [switch]$Recurse
    )

    # Common synonyms -> recommended approved verb (non-exhaustive; update as needed)
    $synonyms = @{
        'Delete'      = 'Remove'
        'Eliminate'   = 'Remove'
        'Append'      = 'Add'
        'Attach'      = 'Add'
        'Concatenate' = 'Add'
        'Insert'      = 'Add'
        'Flush'       = 'Clear'
        'Erase'       = 'Clear'
        'Release'     = 'Clear'
        'Unset'       = 'Clear'
        'Duplicate'   = 'Copy'
        'Clone'       = 'Copy'
        'Replicate'   = 'Copy'
        'Create'      = 'New'
        'Generate'    = 'New'
        'Build'       = 'New'
        'Make'        = 'New'
        'Save'        = 'Backup'
        'Fix'         = 'Repair'
        'Run'         = 'Invoke'
        'Start'       = 'Start'
        'Stop'        = 'Stop'
        'Read'        = 'Get'
        'Open'        = 'Get'
        'Find'        = 'Find'
        'Search'      = 'Search'
    }

    $approved = (Get-Verb).Verb | Select-Object -Unique

    $files = Get-ChildItem -Path $Path -Filter '*.ps1' -File -ErrorAction SilentlyContinue
    if ($Recurse) { $files = Get-ChildItem -Path $Path -Filter '*.ps1' -File -Recurse -ErrorAction SilentlyContinue }

    foreach ($f in $files) {
        $text = Get-Content -Path $f.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $text) { continue }

        # crude function name matcher: matches 'function Name' or 'function Name {' or 'function Name()'
        $matches = [regex]::Matches($text, '(?mi)^\s*function\s+([A-Za-z0-9-]+)')
        foreach ($m in $matches) {
            $fn = $m.Groups[1].Value
            if ($fn -notmatch '-') { continue }
            $parts = $fn -split '-', 2
            $verb = $parts[0]
            if ($approved -contains $verb) { continue }

            $suggest = $null
            if ($synonyms.ContainsKey($verb)) { $suggest = $synonyms[$verb] }
            else {
                # heuristic: try to find close matches from approved verbs
                $closest = $approved | Sort-Object { [int]([string]::Compare($_, $verb, $true)) } | Select-Object -First 1
                $suggest = $closest
            }

            [PSCustomObject]@{
                File = $f.FullName
                Function = $fn
                Verb = $verb
                SuggestedVerb = $suggest
            }
        }
    }
}

# Example: lint current folder recursively
# Test-ApprovedVerbs -Path . -Recurse | Format-Table -AutoSize
```

Notes:
- The helper above uses `Get-Verb` to determine approved verbs and a small built-in synonyms mapping derived from the Microsoft "Synonyms to avoid" guidance. Extend the `$synonyms` table for project-specific cases.
- For bulk renames, prefer adding approved-verb wrappers (approved verb function that calls legacy function) so external scripts/tests can be updated gradually.

