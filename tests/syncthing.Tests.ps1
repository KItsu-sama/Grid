#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Get-ChildItem -LiteralPath (Join-Path $root 'bootstrap') -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
    . $_.FullName
}

Describe 'Syncthing launch arguments' {
    It 'quotes a home path with spaces and disables automatic upgrades' {
        $testRoot = Join-Path $TestDrive 'syncthing-launcher'
        New-Item -ItemType Directory -Path (Join-Path $testRoot 'config') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root 'config\grid.example.json') -Destination (Join-Path $testRoot 'config\grid.example.json') -Force
        $context = New-GridContext -LauncherRoot $testRoot -Command 'start'
        Set-GridContextRoot -Context $context -GridRoot (Join-Path $TestDrive 'Personal Grid') | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $context.SyncthingBin) -Force | Out-Null
        Set-Content -LiteralPath $context.SyncthingBin -Value 'binary' -Encoding UTF8
        $script:syncthingStartArguments = @()
        Mock Get-GridSyncthingProcess { @() }
        Mock Start-Process { $script:syncthingStartArguments = @($ArgumentList) }
        Mock Wait-GridSyncthingReady {}

        Start-GridSyncthing -Context $context

        $script:syncthingStartArguments[0] | Should Be "--home=`"$($context.SyncthingHome)`""
        (@($script:syncthingStartArguments) -contains '--no-upgrade') | Should Be $true
        (@($script:syncthingStartArguments) -contains '--no-restart') | Should Be $true
    }
}