param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Arguments = @()
)

if ($null -eq $Arguments) {
    $Arguments = @()
}
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Normalize empty, single-item, and multi-item argument lists.
$Arguments = @($Arguments)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$GridScript = Join-Path $PSScriptRoot 'Grid.ps1'

if (-not (Test-Path -LiteralPath $GridScript -PathType Leaf)) {
    Write-Host "Grid.ps1 was not found: $GridScript" -ForegroundColor Red
    exit 1
}


function Invoke-GridCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [switch]$Seed,

        [string[]]$ExtraArgs = @()
    )

    $childArgs = @(
        '-NoLogo',
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $GridScript,
        $Name
    )

    if ($Seed) {
        $childArgs += '-Seed'
    }

    $ExtraArgs = @($ExtraArgs)
    if ($ExtraArgs.Count -gt 0) {
        $childArgs += $ExtraArgs
    }

    Write-Host ''
    Write-Host "Running Grid command: $Name" -ForegroundColor Cyan
    if ($Seed) {
        Write-Host 'Mode: seed' -ForegroundColor Cyan
    }

    # Capture both native output streams so the child's error details are relayed
    # consistently before the menu's failure summary.
    $childOutput = @(& powershell.exe @childArgs 2>&1)
    $code = $LASTEXITCODE
    foreach ($line in $childOutput) {
        Write-Host $line
    }

    if ($code -ne 0) {
        Write-Host ''
        Write-Host '========== COMMAND FAILED ==========' -ForegroundColor Red
        Write-Host "Command: $Name" -ForegroundColor Yellow
        Write-Host "Exit code: $code" -ForegroundColor Red
        Write-Host 'See the diagnostic output above for the error details and line number.' -ForegroundColor Yellow
        Write-Host '====================================' -ForegroundColor Red
    } else {
        Write-Host "Command '$Name' completed successfully." -ForegroundColor Green
    }

    return $code
}

function Read-GridSetupMode {
    while ($true) {
        Write-Host ''
        Write-Host 'Choose setup mode:'
        Write-Host '  seed - Create the first Grid node'
        Write-Host '  join - Join an existing Grid'
        Write-Host '  0    - Cancel'

        $choice = (Read-Host 'Mode').Trim().ToLowerInvariant()

        switch ($choice) {
            'seed' { return 'seed' }
            'join' { return 'join' }
            '0'    { return 'cancel' }
            default {
                Write-Host 'Enter seed, join, or 0.' -ForegroundColor Yellow
            }
        }
    }
}

function Invoke-GridSetupOrPreflight {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$RequestedMode
    )

    if ([string]::IsNullOrWhiteSpace($RequestedMode)) {
        $RequestedMode = Read-GridSetupMode
    } else {
        $RequestedMode = $RequestedMode.Trim().ToLowerInvariant()
    }

    if ($RequestedMode -eq '0' -or $RequestedMode -eq 'cancel') {
        return 0
    }

    switch ($RequestedMode) {
        'seed' {
            return (Invoke-GridCommand -Name $Name -Seed)
        }
        'join' {
            return (Invoke-GridCommand -Name $Name)
        }
        default {
            Write-Host "Unknown mode '$RequestedMode'. Use seed or join." -ForegroundColor Red
            return 2
        }
    }
}

function Show-GridMenu {
    while ($true) {

        Write-Host ''
        Write-Host '========== Personal Grid ==========' -ForegroundColor Cyan
        Write-Host '1. Setup Grid' -ForegroundColor Green
        Write-Host '2. Uninstall Grid' -ForegroundColor Red
        Write-Host '3. Preflight checks' -ForegroundColor Yellow
        Write-Host '4. Status / audit' -ForegroundColor Cyan
        Write-Host '5. Open PowerShell here' -ForegroundColor Gray
        Write-Host '6. Open elevated PowerShell here' -ForegroundColor Gray
        Write-Host '7. Help' -ForegroundColor Magenta
        Write-Host '0. Exit' -ForegroundColor DarkGray
        Write-Host '===================================' -ForegroundColor Cyan

        $choice = (Read-Host 'Select an option').Trim().ToLowerInvariant()

        switch ($choice) {
            '1' {
                Invoke-GridSetupOrPreflight -Name 'setup' | Out-Null
            }
            '2' {
                Invoke-GridCommand -Name 'uninstall' | Out-Null
            }
            '3' {
                Invoke-GridSetupOrPreflight -Name 'preflight' | Out-Null
            }
            '4' {
                Invoke-GridCommand -Name 'status' | Out-Null
            }
            '5' {
                & powershell.exe -NoLogo -NoProfile -NoExit `
                    -Command "Set-Location -LiteralPath '$PSScriptRoot'"
            }
            '6' {
                Start-Process powershell.exe -Verb RunAs -ArgumentList @(
                    '-NoLogo',
                    '-NoProfile',
                    '-NoExit',
                    '-Command',
                    "Set-Location -LiteralPath '$PSScriptRoot'"
                )
            }
            '7' {
                Write-Host ''
                Write-Host 'Examples:'
                Write-Host '  .\Grid.cmd setup seed'
                Write-Host '  .\Grid.cmd setup join'
                Write-Host '  .\Grid.cmd preflight seed'
                Write-Host '  .\Grid.cmd preflight join'
                Write-Host '  .\Grid.cmd status'
            }
            '0' {
                return
            }
            default {
                Write-Host 'Invalid selection.' -ForegroundColor Yellow
            }
        }

        Read-Host 'Press Enter to return to the menu' | Out-Null
    }
}

# Support both direct commands and numbered menu commands.
if ($Arguments.Count -gt 0) {
    $name = $Arguments[0].Trim().ToLowerInvariant()
    $mode = if ($Arguments.Count -gt 1) {
        $Arguments[1].Trim().ToLowerInvariant()
    } else {
        ''
    }

    $commandMap = @{
        '1' = 'setup'
        '2' = 'uninstall'
        '3' = 'preflight'
        '4' = 'status'
    }

    if ($commandMap.ContainsKey($name)) {
        $name = $commandMap[$name]
    }

    if ($name -in @('setup', 'preflight')) {
        if ($Arguments.Count -gt 2) {
            Write-Host "Usage: Grid.cmd $name [seed|join]" -ForegroundColor Red
            exit 2
        }

        $code = Invoke-GridSetupOrPreflight -Name $name -RequestedMode $mode
        exit $code
    }

    if ($name -in @('status', 'audit', 'start', 'stop', 'repair', 'uninstall')) {
        $extra = @()
        if ($Arguments.Count -gt 1) {
            $extra = @($Arguments | Select-Object -Skip 1)
        }

        $code = Invoke-GridCommand -Name $name -ExtraArgs $extra
        exit $code
    }

    if ($name -in @('0', 'exit', 'menu')) {
        Show-GridMenu
        exit 0
    }

    Write-Host "Unknown command: $name" -ForegroundColor Red
    Write-Host 'Use Grid.cmd with no arguments to open the menu.'
    exit 2
}

Show-GridMenu