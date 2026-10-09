[CmdletBinding()]
param(
    [ValidateSet("Install", "Uninstall")]
    [string]$Action = "Install"
)

$ErrorActionPreference = "Stop"

$GridRoot = Split-Path -Parent $PSScriptRoot
$GridMenu = Join-Path $GridRoot "GridMenu.ps1"

if (-not (Test-Path -LiteralPath $GridMenu -PathType Leaf)) {
    throw "GridMenu.ps1 not found: $GridMenu"
}

$PowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

# Current-user keys: no machine-wide registration.

$BaseKeys = @(
    "HKCU:\Software\Classes\Directory\shell\GridControl",
    "HKCU:\Software\Classes\Directory\Background\shell\GridControl"
)

if ($Action -eq "Uninstall") {
    foreach ($key in $BaseKeys) {
        if (Test-Path -LiteralPath $key) {
            Remove-Item -LiteralPath $key -Recurse -Force
        }
    }

    Write-Host "Grid Explorer menu entries removed." -ForegroundColor Green
    exit 0
}

foreach ($base in $BaseKeys) {
    $panelKey = Join-Path $base "Panel"
    $adminKey = Join-Path $base "Admin"

    New-Item -Path $panelKey -Force | Out-Null
    Set-Item -Path $panelKey -Value "Grid Control Panel"
    Set-ItemProperty -Path $panelKey -Name "Icon" -Value $PowerShell

    $panelCommand = Join-Path $panelKey "command"
    New-Item -Path $panelCommand -Force | Out-Null

    $panelArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" menu' -f $GridMenu
    Set-Item -Path $panelCommand -Value ('"{0}" {1}' -f $PowerShell, $panelArgs)

    New-Item -Path $adminKey -Force | Out-Null
    Set-Item -Path $adminKey -Value "Grid Admin Terminal"
    Set-ItemProperty -Path $adminKey -Name "Icon" -Value $PowerShell

    $adminCommand = Join-Path $adminKey "command"
    New-Item -Path $adminCommand -Force | Out-Null

    $adminArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" admin' -f $GridMenu
    Set-Item -Path $adminCommand -Value ('"{0}" {1}' -f $PowerShell, $adminArgs)
}

Write-Host "Grid Explorer menu entries installed for the current user." -ForegroundColor Green
Write-Host "Right-click a folder or its background to find Grid Control Panel."