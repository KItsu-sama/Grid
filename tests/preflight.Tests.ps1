#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Get-ChildItem -LiteralPath (Join-Path $root 'bootstrap') -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
    . $_.FullName
}

function New-TestPreflightContext {
    param(
        [bool]$Seed = $true,
        [bool]$WithGridRoot = $true
    )
    $bootstrapRoot = Join-Path $TestDrive 'bootstrap'
    New-Item -ItemType Directory -Path (Join-Path $bootstrapRoot 'config') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $bootstrapRoot 'packages') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'config\grid.example.json') -Destination (Join-Path $bootstrapRoot 'config\grid.example.json') -Force
    Copy-Item -LiteralPath (Join-Path $root 'packages\manifest.json') -Destination (Join-Path $bootstrapRoot 'packages\manifest.json') -Force
    $context = New-GridContext -LauncherRoot $bootstrapRoot -Command 'preflight' -Seed:$Seed
    $context.Settings.tailscale.enabled = $false
    $context.Settings.syncthing.enabled = $false
    $context | Add-Member -NotePropertyName Environment -NotePropertyValue ([pscustomobject]@{
        Windows       = [pscustomobject]@{ IsWindows = $true }
        Drives        = @()
        Tailscale     = [pscustomobject]@{ Installed = $false }
        Installations = @()
        Architecture  = 'amd64'
    }) -Force
    if ($WithGridRoot) {
        Set-GridContextRoot -Context $context -GridRoot (Join-Path $TestDrive 'grid-root') | Out-Null
    } else {
        $context | Add-Member -NotePropertyName RuntimeResolutionError -NotePropertyValue 'No eligible fixed local drive has enough free space.' -Force
    }
    return $context
}

Describe 'Setup preflight' {
    It 'reports example defaults and seed setup without creating files' {
        $context = New-TestPreflightContext
        $report = Get-GridPreflightReport -Context $context
        $report.overall | Should Be 'ready'
        ($report.checks | Where-Object { $_.name -eq 'Configuration' }).status | Should Be 'action'
        ($report.checks | Where-Object { $_.name -eq 'Pairing data' }).status | Should Be 'ready'
        ($report.checks | Where-Object { $_.name -eq 'Tailscale email metadata' }).status | Should Be 'optional'
        (Test-Path -LiteralPath $context.GridRoot) | Should Be $false
    }

    It 'aggregates storage, installer, and secondary-node blockers' {
        $context = New-TestPreflightContext -Seed:$false -WithGridRoot:$false
        $context.Settings.tailscale.enabled = $true
        $context.Settings.syncthing.enabled = $true
        $report = Get-GridPreflightReport -Context $context
        $blockers = @($report.checks | Where-Object { $_.status -eq 'blocker' })
        $report.overall | Should Be 'blocked'
        $blockers.Count | Should BeGreaterThan 3
        @($blockers | Where-Object { $_.name -eq 'Persistent storage' }).Count | Should Be 1
        @($blockers | Where-Object { $_.name -eq 'Pairing data' }).Count | Should Be 1
        (Test-Path -LiteralPath (Join-Path $TestDrive 'grid-root')) | Should Be $false
    }

    It 'does not reveal the contents of optional Tailscale metadata' {
        $context = New-TestPreflightContext
        $email = 'private-user@example.com'
        Set-Content -LiteralPath (Join-Path $context.BootstrapRoot 'tailscale.txt') -Value $email
        $report = Get-GridPreflightReport -Context $context
        $metadata = $report.checks | Where-Object { $_.name -eq 'Tailscale email metadata' }
        $metadata.reason | Should Not Match $email
    }

    It 'reports an unpinned or mismatched package as a blocker without copying it' {
        $context = New-TestPreflightContext
        $package = Join-Path $context.BootstrapRoot 'packages\tailscale-setup-1.102.4.exe'
        Set-Content -LiteralPath $package -Value 'not the vendor installer'
        $check = Test-GridPreflightPackage -Context $context -Id 'tailscale'
        $check.status | Should Be 'blocker'
        (Test-Path -LiteralPath (Join-Path $context.GridRoot 'packages')) | Should Be $false
    }
}