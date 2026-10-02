#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Get-ChildItem -LiteralPath (Join-Path $root 'bootstrap') -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
    . $_.FullName
}

Describe 'Install state' {
    It 'writes state atomically and resumes completed stages' {
        $gridRoot = Join-Path $TestDrive 'PersonalGrid'
        New-Item -ItemType Directory -Path (Join-Path $gridRoot '.grid') -Force | Out-Null
        $ctx = New-GridContext -LauncherRoot $root -Command 'setup'
        Set-GridContextRoot -Context $ctx -GridRoot $gridRoot | Out-Null
        $state = New-GridInstallState
        Set-GridStageStatus -Context $ctx -State $state -Name 'prepare' -Status completed
        Test-Path -LiteralPath $ctx.StatePath | Should Be $true
        Test-Path -LiteralPath ($ctx.StatePath + '.tmp') | Should Be $false
        $loaded = Read-GridInstallState -Context $ctx
        Test-GridStageCompleted -State $loaded -Name 'prepare' | Should Be $true
        Test-GridStageCompleted -State $loaded -Name 'tailscale' | Should Be $false
        $script:gridStageRan = $false
        Invoke-GridStage -Context $ctx -State $loaded -Name 'prepare' -Action { $script:gridStageRan = $true }
        $script:gridStageRan | Should Be $false
    }

    It 'records failure without dropping earlier completed stages' {
        $gridRoot = Join-Path $TestDrive 'PersonalGrid-fail'
        New-Item -ItemType Directory -Path (Join-Path $gridRoot '.grid') -Force | Out-Null
        $ctx = New-GridContext -LauncherRoot $root -Command 'setup'
        Set-GridContextRoot -Context $ctx -GridRoot $gridRoot | Out-Null
        $state = New-GridInstallState
        Set-GridStageStatus -Context $ctx -State $state -Name 'prepare' -Status completed
        { Invoke-GridStage -Context $ctx -State $state -Name 'tailscale' -Action { throw 'simulated interrupt' } } | Should Throw 'simulated interrupt'
        $loaded = Read-GridInstallState -Context $ctx
        Test-GridStageCompleted -State $loaded -Name 'prepare' | Should Be $true
        (Get-GridStageRecord -State $loaded -Name 'tailscale').status | Should Be 'failed'
        (Get-GridStageRecord -State $loaded -Name 'tailscale').error | Should Be 'simulated interrupt'
    }

    It 'does not treat an existing Syncthing cert/key pair as missing' {
        $gridRoot = Join-Path $TestDrive 'PersonalGrid-id'
        $ctx = New-GridContext -LauncherRoot $root -Command 'setup'
        Set-GridContextRoot -Context $ctx -GridRoot $gridRoot | Out-Null
        New-Item -ItemType Directory -Path $ctx.SyncthingHome -Force | Out-Null
        Get-GridSyncthingIdentityExists -Context $ctx | Should Be $false
        Set-Content -LiteralPath (Join-Path $ctx.SyncthingHome 'cert.pem') -Value 'cert'
        Set-Content -LiteralPath (Join-Path $ctx.SyncthingHome 'key.pem') -Value 'key'
        Get-GridSyncthingIdentityExists -Context $ctx | Should Be $true
    }

    It 'refuses unverified package hashes' {
        $ctx = New-GridContext -LauncherRoot $root -Command 'setup'
        $spec = [pscustomobject]@{ file = 'dummy.exe'; sha256 = 'REPLACE_ME' }
        $dummy = Join-Path $TestDrive 'dummy.exe'
        Set-Content -LiteralPath $dummy -Value 'x'
        { Test-GridPackageHash -Path $dummy -Spec $spec } | Should Throw 'Unverified installers are never executed'
    }
}
