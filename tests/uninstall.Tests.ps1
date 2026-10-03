#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Get-ChildItem -LiteralPath (Join-Path $root 'bootstrap') -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
    . $_.FullName
}

Describe 'Grid uninstall' {
    BeforeEach {
        $bootstrapRoot = Join-Path $TestDrive 'uninstall-bootstrap'
        New-Item -ItemType Directory -Path (Join-Path $bootstrapRoot 'config') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root 'config\grid.example.json') -Destination (Join-Path $bootstrapRoot 'config\grid.example.json') -Force
        $script:uninstallContext = New-GridContext -LauncherRoot $bootstrapRoot -Command 'uninstall'
        Set-GridContextRoot -Context $script:uninstallContext -GridRoot (Join-Path $TestDrive 'uninstall-grid') | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:uninstallContext.GridRoot '.grid') -Force | Out-Null
        New-Item -ItemType Directory -Path (Split-Path -Parent $script:uninstallContext.SyncthingBin) -Force | Out-Null
        New-Item -ItemType Directory -Path (Get-GridSyncRoot -Context $script:uninstallContext) -Force | Out-Null
        Set-Content -LiteralPath $script:uninstallContext.DevicePath -Value '{}' -Encoding UTF8
        Set-Content -LiteralPath $script:uninstallContext.SyncthingBin -Value 'binary' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path (Get-GridSyncRoot -Context $script:uninstallContext) 'user-file.txt') -Value 'keep me' -Encoding UTF8
    }

    AfterEach {
        if (Test-Path -LiteralPath $script:uninstallContext.GridRoot) {
            Uninstall-GridInstallation -Context $script:uninstallContext -RemoveData
        }
    }

    Mock Stop-GridSyncthing {}
    Mock Unregister-GridSyncthingStartup {}
    Mock Write-GridLog {}

    It 'removes runtime files but preserves synced user data by default' {
        Uninstall-GridInstallation -Context $script:uninstallContext
        (Test-Path -LiteralPath (Join-Path $script:uninstallContext.GridRoot '.grid')) | Should Be $false
        (Test-Path -LiteralPath $script:uninstallContext.SyncthingBin) | Should Be $false
        (Test-Path -LiteralPath (Join-Path (Get-GridSyncRoot -Context $script:uninstallContext) 'user-file.txt')) | Should Be $true
        Assert-MockCalled Stop-GridSyncthing -Times 1
        Assert-MockCalled Unregister-GridSyncthingStartup -Times 1
    }

    It 'removes synced user data only when RemoveData is explicit' {
        Uninstall-GridInstallation -Context $script:uninstallContext -RemoveData
        (Test-Path -LiteralPath (Get-GridSyncRoot -Context $script:uninstallContext)) | Should Be $false
    }

    It 'preserves the default Sync folder unless RemoveDefaultSync is explicit' {
        $oldProfile = $env:USERPROFILE
        $testProfile = Join-Path $TestDrive 'test-user-profile'
        $defaultSync = Join-Path $testProfile 'Sync'
        try {
            $env:USERPROFILE = $testProfile
            New-Item -ItemType Directory -Path $defaultSync -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $defaultSync 'user-file.txt') -Value 'keep me' -Encoding UTF8
            Uninstall-GridInstallation -Context $script:uninstallContext
            (Test-Path -LiteralPath (Join-Path $defaultSync 'user-file.txt')) | Should Be $true
            Uninstall-GridInstallation -Context $script:uninstallContext -RemoveDefaultSync
            (Test-Path -LiteralPath $defaultSync) | Should Be $false
        } finally {
            $env:USERPROFILE = $oldProfile
        }
    }

    It 'resets stale root runtime data without deleting synced user files' {
        Reset-GridRootData -Context $script:uninstallContext
        (Test-Path -LiteralPath $script:uninstallContext.DevicePath) | Should Be $false
        (Test-Path -LiteralPath $script:uninstallContext.SyncthingBin) | Should Be $false
        (Test-Path -LiteralPath (Join-Path (Get-GridSyncRoot -Context $script:uninstallContext) 'user-file.txt')) | Should Be $true
    }

    It 'refuses RemoveData when the configured sync path escapes GridRoot' {
        $outside = Join-Path $TestDrive 'outside-grid-data'
        New-Item -ItemType Directory -Path $outside -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'keep.txt') -Value 'keep me' -Encoding UTF8
        $script:uninstallContext.Settings.syncthing.rootFolder = '..\outside-grid-data'
        { Uninstall-GridInstallation -Context $script:uninstallContext -RemoveData } | Should Throw 'outside GridRoot'
        (Test-Path -LiteralPath (Join-Path $outside 'keep.txt')) | Should Be $true
        (Test-Path -LiteralPath $script:uninstallContext.DevicePath) | Should Be $true
        $script:uninstallContext.Settings.syncthing.rootFolder = 'ZinoSync'
    }
}

Describe 'Bootstrap snapshot' {
    It 'includes effective settings, sync manifest, and package manifest and can run from itself' {
        $bootstrapRoot = Join-Path $TestDrive 'snapshot-source'
        New-Item -ItemType Directory -Path (Join-Path $bootstrapRoot 'config') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $bootstrapRoot 'bootstrap') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $bootstrapRoot 'packages') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root 'Grid.ps1') -Destination (Join-Path $bootstrapRoot 'Grid.ps1')
        Copy-Item -LiteralPath (Join-Path $root 'config\grid.example.json') -Destination (Join-Path $bootstrapRoot 'config\grid.example.json')
        Copy-Item -LiteralPath (Join-Path $root 'config\syncconfig.example.json') -Destination (Join-Path $bootstrapRoot 'config\syncconfig.example.json')
        Set-Content -LiteralPath (Join-Path $bootstrapRoot 'bootstrap\audit.ps1') -Value 'Set-StrictMode -Version Latest'
        Set-Content -LiteralPath (Join-Path $bootstrapRoot 'packages\manifest.json') -Value '{"schemaVersion":1,"packages":[]}'
        $settings = ConvertFrom-GridJson -Path (Join-Path $bootstrapRoot 'config\grid.example.json') -Label 'grid.example.json'
        $settings.device.name = 'SnapshotNode'
        Write-GridJsonAtomic -Path (Join-Path $bootstrapRoot 'config\grid.json') -InputObject $settings

        $context = New-GridContext -LauncherRoot $bootstrapRoot -Command 'setup'
        Set-GridContextRoot -Context $context -GridRoot (Join-Path $TestDrive 'snapshot-grid') | Out-Null
        Write-GridJsonAtomic -Path $context.SyncConfigPath -InputObject ([pscustomobject]@{ schemaVersion = 1; seedDevice = [pscustomobject]@{ name = 'Seed'; deviceId = 'SEED-ID' }; folders = @() })
        Copy-GridBootstrapSnapshot -Context $context

        $snapshot = Join-Path $context.GridRoot '.grid\bootstrap'
        (Test-Path -LiteralPath (Join-Path $snapshot 'config\grid.json')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $snapshot 'config\syncconfig.json')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $snapshot 'packages\manifest.json')) | Should Be $true
        $snapshotContext = New-GridContext -LauncherRoot $snapshot -Command 'status'
        Set-GridContextRoot -Context $snapshotContext -GridRoot $context.GridRoot | Out-Null
        $snapshotContext.Settings.device.name | Should Be 'SnapshotNode'
        { Copy-GridBootstrapSnapshot -Context $snapshotContext } | Should Not Throw
    }
}