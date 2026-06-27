Describe 'LastFunction tracking' {
    BeforeAll {
        # Ensure watchdog runtime doesn't auto-start while running tests
        $env:UNIT_TEST = '1'
        $scriptPath = Join-Path $PSScriptRoot '..\EcoWatchdog.ps1'
        . $scriptPath
    }

    It 'updates LastFunction for Set-State' {
        $global:LastFunction = 'None'
        Set-State 'STOPPED'
        $global:LastFunction | Should Match 'Set-State'
    }

    It 'updates LastFunction for Get-KeyForAction' {
        $global:LastFunction = 'None'
        Get-KeyForAction -Action 'Start' | Out-Null
        $global:LastFunction | Should Match 'Get-KeyForAction'
    }

    It 'updates LastFunction for Get-EcoProcess' {
        $global:LastFunction = 'None'
        Get-EcoProcess | Out-Null
        $global:LastFunction | Should Match 'Get-EcoProcess'
    }

    It 'does not update LastFunction for Show-UI (view-only)' {
        $global:LastFunction = 'None'
        Show-UI -Force
        $global:LastFunction | Should Be 'None'
    }
}
