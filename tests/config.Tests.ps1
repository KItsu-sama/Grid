#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Get-ChildItem -LiteralPath (Join-Path $root 'bootstrap') -Filter '*.ps1' | Sort-Object Name | ForEach-Object {
    . $_.FullName
}

function New-GridExampleOnlyTestRoot {
    param([Parameter(Mandatory = $true)][string]$Name)
    $testRoot = Join-Path $TestDrive $Name
    New-Item -ItemType Directory -Path (Join-Path $testRoot 'config') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'config\grid.example.json') -Destination (Join-Path $testRoot 'config\grid.example.json') -Force
    return $testRoot
}

Describe 'Grid example configuration' {
    It 'parses grid.example.json' {
        $path = Join-Path $root 'config\grid.example.json'
        $doc = ConvertFrom-GridJson -Path $path -Label 'grid.example.json'
        Test-GridSettings -Settings $doc -SourcePath $path
        $doc.schemaVersion | Should Be 1
        $doc.defaultMode | Should Be 'persistent'
        $doc.is_root | Should Be $false
        $doc.can_be_main | Should Be $false
        $doc.syncthing.folders.Count | Should Be 6
        (@($doc.syncthing.folders | ForEach-Object { $_.id }) -contains 'grid-inbox') | Should Be $true
    }

    It 'parses syncconfig.example.json' {
        $path = Join-Path $root 'config\syncconfig.example.json'
        $doc = ConvertFrom-GridJson -Path $path -Label 'syncconfig.example.json'
        $doc.schemaVersion | Should Be 1
        $doc.seedDevice.deviceId | Should Be ''
        (@($doc.folders | ForEach-Object { $_.id }) -contains 'grid-secondbrain') | Should Be $true
    }

    It 'fails usefully on malformed JSON' {
        $tmp = Join-Path $TestDrive 'bad.json'
        Set-Content -LiteralPath $tmp -Value '{ not json' -Encoding UTF8
        { ConvertFrom-GridJson -Path $tmp -Label 'grid.json' } | Should Throw 'not valid JSON'
    }

    It 'does not silently accept an unsupported schema version' {
        $tmp = Join-Path $TestDrive 'grid.json'
        Set-Content -LiteralPath $tmp -Value '{"schemaVersion":99,"defaultMode":"persistent","persistent":{"targetDrive":"AUTO","targetFolder":"PersonalGrid","minimumFreeBytes":1},"device":{},"tailscale":{},"syncthing":{"folders":[]}}' -Encoding UTF8
        $doc = ConvertFrom-GridJson -Path $tmp -Label 'grid.json'
        { Test-GridSettings -Settings $doc -SourcePath $tmp } | Should Throw 'Unsupported config schemaVersion'
    }

    It 'requires explicit main capability when device.isMain is true' {
        $settings = ConvertFrom-GridJson -Path (Join-Path $root 'config\grid.example.json') -Label 'grid.example.json'
        $settings.device.isMain = $true
        { Test-GridSettings -Settings $settings -SourcePath 'test-grid.json' } | Should Throw 'requires can_be_main=true'
        $settings.can_be_main = $true
        { Test-GridSettings -Settings $settings -SourcePath 'test-grid.json' } | Should Not Throw
    }

    It 'loads example defaults when grid.json is absent' {
        $testRoot = New-GridExampleOnlyTestRoot -Name 'example-only'
        $ctx = New-GridContext -LauncherRoot $testRoot -Command 'status'
        $ctx.UsedExample | Should Be $true
        $ctx.Mode | Should Be 'persistent'
        $ctx.TemporaryRuntime | Should Match 'PersonalGrid\\runtime'
    }

    It 'gitignores generated machine-specific config' {
        Push-Location $root
        try {
            git check-ignore -q 'config/grid.json'
            $LASTEXITCODE | Should Be 0
            git check-ignore -q 'config/syncconfig.json'
            $LASTEXITCODE | Should Be 0
            git check-ignore -q 'tailscale.txt'
            $LASTEXITCODE | Should Be 0
            git check-ignore -q 'config/grid.example.json'
            $LASTEXITCODE | Should Be 1
            git check-ignore -q 'config/syncconfig.example.json'
            $LASTEXITCODE | Should Be 1
        } finally {
            Pop-Location
        }
    }
}

Describe 'Drive selection' {
    $script:GridMinBytes = 10737418240
    $script:GridCtx = New-GridContext -LauncherRoot (New-GridExampleOnlyTestRoot -Name 'drive-selection') -Command 'setup'
    $script:GridDisks = @(
        [pscustomobject]@{ DeviceID = 'C:'; DriveType = 3; FreeSpace = 20GB }
        [pscustomobject]@{ DeviceID = 'D:'; DriveType = 3; FreeSpace = 80GB }
        [pscustomobject]@{ DeviceID = 'E:'; DriveType = 2; FreeSpace = 200GB }
        [pscustomobject]@{ DeviceID = 'Z:'; DriveType = 4; FreeSpace = 400GB }
    )

    It 'marks USB and network drives ineligible' {
        $drives = Get-GridCandidateDrives -Context $script:GridCtx -Disks $script:GridDisks
        ($drives | Where-Object { $_.DeviceId -eq 'E:' }).EligiblePersistent | Should Be $false
        ($drives | Where-Object { $_.DeviceId -eq 'Z:' }).EligiblePersistent | Should Be $false
        ($drives | Where-Object { $_.DeviceId -eq 'D:' }).EligiblePersistent | Should Be $true
    }

    It 'AUTO chooses the eligible fixed drive with the most free bytes' {
        $choice = Select-GridTargetDrive -Context $script:GridCtx -Drives (Get-GridCandidateDrives -Context $script:GridCtx -Disks $script:GridDisks)
        $choice.Strategy | Should Be 'auto-most-free'
        $choice.Drive.DeviceId | Should Be 'D:'
        $choice.GridRoot | Should Be 'D:\PersonalGrid'
        $choice.Drive.FreeBytes | Should BeGreaterThan $script:GridMinBytes
    }

    It 'respects a manual target path' {
        $manualRoot = New-GridExampleOnlyTestRoot -Name 'manual-target'
        $manual = New-GridContext -LauncherRoot $manualRoot -Command 'setup' -TargetPath 'C:\Users\Admin\GridData'
        $choice = Select-GridTargetDrive -Context $manual -Drives (Get-GridCandidateDrives -Context $manual -Disks $script:GridDisks)
        $choice.Strategy | Should Be 'manual-path'
        $choice.GridRoot | Should Match 'GridData$'
    }

    It 'resolves temporary GridRoot without implementing the mode' {
        $temporaryRoot = New-GridExampleOnlyTestRoot -Name 'temporary-mode'
        $tmpCtx = New-GridContext -LauncherRoot $temporaryRoot -Command 'setup' -Mode 'temporary'
        $envInfo = [pscustomobject]@{ Installations = @(); Architecture = 'amd64'; Drives = @() }
        $resolved = Resolve-GridRuntime -Context $tmpCtx -Environment $envInfo
        $resolved.GridRoot | Should Be $resolved.TemporaryRuntime
        { Assert-GridModeSupported -Context $resolved } | Should Throw 'not supported'
    }
}

Describe 'Package architecture selection' {
    It 'does not substitute amd64 packages on ARM64' {
        $testRoot = New-GridExampleOnlyTestRoot -Name 'arm64-packages'
        New-Item -ItemType Directory -Path (Join-Path $testRoot 'packages') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root 'packages\manifest.json') -Destination (Join-Path $testRoot 'packages\manifest.json') -Force
        $context = New-GridContext -LauncherRoot $testRoot -Command 'preflight'
        $context | Add-Member -NotePropertyName Environment -NotePropertyValue ([pscustomobject]@{ Architecture = 'arm64' }) -Force
        { Find-GridPackageSpec -Context $context -Id 'syncthing' } | Should Throw 'A different architecture package is never substituted'
    }
}
