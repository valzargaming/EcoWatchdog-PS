Describe 'PSUseApprovedVerbs' {
    It 'All functions use approved verbs (no synonyms to avoid)' {
        # Approved verbs from PowerShell
        $approved = (Get-Verb).Verb | Select-Object -Unique

        # Synonyms mapping (non-exhaustive) -> suggested approved verb
        $synonyms = @{
            'Delete'      = 'Remove'
            'Eliminate'   = 'Remove'
            'Load'        = 'Import'
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
            'Read'        = 'Get'
            'Open'        = 'Get'
            'Search'      = 'Search'
            'Schedule'    = 'Set'
            'Cancel'      = 'Stop'
        }

        # Determine repository root robustly when running under Pester
        if ($PSScriptRoot) {
            $repoRoot = Split-Path -Parent $PSScriptRoot
        } else {
            $repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
        }
        $psFiles = Get-ChildItem -Path $repoRoot -Filter '*.ps1' -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '\\tests\\' }

        $issues = @()

        foreach ($f in $psFiles) {
            $text = Get-Content -Path $f.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $text) { continue }

            $matches = [regex]::Matches($text, '(?mi)^\s*function\s+([A-Za-z0-9-]+)')
            foreach ($m in $matches) {
                $fn = $m.Groups[1].Value
                if ($fn -notmatch '-') { continue }
                $parts = $fn -split '-', 2
                $verb = $parts[0]
                if ($approved -contains $verb) { continue }

                $suggest = $null
                if ($synonyms.ContainsKey($verb)) { $suggest = $synonyms[$verb] } else { $suggest = ($approved | Sort-Object { [int]([string]::Compare($_, $verb, $true)) } | Select-Object -First 1) }

                # If an approved-verb wrapper already exists (e.g., Get-StorageSaveName for Load-StorageSaveName), skip reporting
                $wrapperName = "$suggest-$($parts[1])"
                $wrapperExists = $false
                foreach ($g in $psFiles) {
                    $content = Get-Content -Path $g.FullName -Raw -ErrorAction SilentlyContinue
                    if ($content -match "(?mi)^\s*function\s+${wrapperName}\b") { $wrapperExists = $true; break }
                }
                if ($wrapperExists) { continue }

                $issues += [PSCustomObject]@{
                    File = $f.FullName
                    Function = $fn
                    Verb = $verb
                    SuggestedVerb = $suggest
                }
            }
        }

        if ($issues.Count -gt 0) {
            $msg = "Found functions using non-approved verbs:`n"
            $issues | ForEach-Object { $msg += "  $($_.File) -> $($_.Function) (verb='$($_.Verb)') suggested='$($_.SuggestedVerb)'-`n" }
            throw $msg
        }
    }
}
